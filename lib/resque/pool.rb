# -*- encoding: utf-8 -*-
require 'resque'
require 'resque/worker'
require 'resque/pool/version'
require 'resque/pool/logging'
require 'resque/pool/pooled_worker'
require 'erb'
require 'fcntl'
require 'yaml'

module Resque
  class Pool
    SIG_QUEUE_MAX_SIZE = 5
    DEFAULT_WORKER_INTERVAL = 5
    QUEUE_SIGS = [ :QUIT, :INT, :TERM, :USR1, :USR2, :CONT, :HUP, :WINCH, ]
    CHUNK_SIZE = (16 * 1024)

    include Logging
    extend  Logging
    attr_reader :config
    attr_reader :workers

    def initialize(config)
      init_config(config)
      @workers = Hash.new { |workers, queues| workers[queues] = {} }
      procline "(initialized)"
    end

    # Config: after_prefork {{{

    # The `after_prefork` hook will be run in workers if you are using the
    # preforking master worker to save memory. Use this hook to reload
    # database connections and so forth to ensure that they're not shared
    # among workers.
    #
    # Call with a block to set the hook.
    # Call with no arguments to return the hook.
    def self.after_prefork(&block)
      block ? (@after_prefork = block) : @after_prefork
    end

    # Set the after_prefork proc.
    def self.after_prefork=(after_prefork)
      @after_prefork = after_prefork
    end

    def call_after_prefork!
      self.class.after_prefork && self.class.after_prefork.call
    end

    # }}}
    # Config: class methods to start up the pool using the default config {{{

    @config_files = ["resque-pool.yml", "config/resque-pool.yml"]
    class << self; attr_accessor :config_files, :app_name; end

    def self.app_name
      @app_name ||= File.basename(Dir.pwd)
    end

    def self.handle_winch?
      @handle_winch ||= false
    end
    def self.handle_winch=(bool)
      @handle_winch = bool
    end

    def self.choose_config_file
      if ENV["RESQUE_POOL_CONFIG"]
        ENV["RESQUE_POOL_CONFIG"]
      else
        @config_files.detect { |f| File.exist?(f) }
      end
    end

    def self.run
      if GC.respond_to?(:copy_on_write_friendly=)
        GC.copy_on_write_friendly = true
      end
      Resque::Pool.new(choose_config_file).start.join
    end

    # }}}
    # Config: load config and config file {{{

    def config_file
      @config_file || (!@config && ::Resque::Pool.choose_config_file)
    end

    def init_config(config)
      case config
      when String, nil
        @config_file = config
      else
        @config = config.dup
      end
      load_config
    end

    def load_config
      if config_file
        @config = YAML.load(ERB.new(IO.read(config_file)).result)
      else
        @config ||= {}
      end
      environment and @config[environment] and config.merge!(@config[environment])
      config.delete_if {|key, value| value.is_a? Hash }
    end

    def environment
      if defined? RAILS_ENV
        RAILS_ENV
      elsif defined?(Rails) && Rails.respond_to?(:env)
        Rails.env
      else
        ENV['RACK_ENV'] || ENV['RAILS_ENV'] || ENV['RESQUE_ENV']
      end
    end

    # }}}

    # Sig handlers and self pipe management {{{

    def self_pipe; @self_pipe ||= [] end
    def sig_queue; @sig_queue ||= [] end

    def init_self_pipe!
      self_pipe.each { |io| io.close rescue nil }
      self_pipe.replace(IO.pipe)
      self_pipe.each { |io| io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) }
    end

    def init_sig_handlers!
      QUEUE_SIGS.each { |sig| trap_deferred(sig) }
      trap(:CHLD)     { |_| awaken_master }
    end

    def awaken_master
      begin
        self_pipe.last.write_nonblock('.') # wakeup master process from select
      rescue Errno::EAGAIN, Errno::EINTR
        # pipe is full, master should wake up anyways
        retry
      end
    end

    class QuitNowException < Exception; end
    # defer a signal for later processing in #join (master process)
    def trap_deferred(signal)
      trap(signal) do |sig_nr|
        if @waiting_for_reaper && [:INT, :TERM].include?(signal)
          log "Recieved #{signal}: short circuiting QUIT waitpid"
          raise QuitNowException
        end
        if sig_queue.size < SIG_QUEUE_MAX_SIZE
          sig_queue << signal
          awaken_master
        else
          log "ignoring SIG#{signal}, queue=#{sig_queue.inspect}"
        end
      end
    end

    def reset_sig_handlers!
      QUEUE_SIGS.each {|sig| trap(sig, "DEFAULT") }
    end

    def handle_sig_queue!
      case signal = sig_queue.shift
      when :USR1, :USR2, :CONT
        log "#{signal}: sending to all workers"
        signal_all_workers(signal)
      when :HUP
        log "HUP: reload config file and reload logfiles"
        load_config
        Logging.reopen_logs!
        log "HUP: gracefully shutdown old children (which have old logfiles open)"
        signal_all_workers(:QUIT)
        log "HUP: new children will inherit new logfiles"
        maintain_worker_count
      when :WINCH
        if self.class.handle_winch?
          log "WINCH: gracefully stopping all workers"
          @config = {}
          maintain_worker_count
        end
      when :QUIT
        graceful_worker_shutdown_and_wait!(signal)
      when :INT
        graceful_worker_shutdown!(signal)
      when :TERM
        case self.class.term_behavior
        when "graceful_worker_shutdown_and_wait"
          graceful_worker_shutdown_and_wait!(signal)
        when "graceful_worker_shutdown"
          graceful_worker_shutdown!(signal)
        else
          shutdown_everything_now!(signal)
        end
      end
    end

    class << self
      attr_accessor :term_behavior
    end

    def graceful_worker_shutdown_and_wait!(signal)
      log "#{signal}: graceful shutdown, waiting for children"
      signal_all_workers(:QUIT)
      reap_all_workers(0) # will hang until all workers are shutdown
      :break
    end

    def graceful_worker_shutdown!(signal)
      log "#{signal}: immediate shutdown (graceful worker shutdown)"
      signal_all_workers(:QUIT)
      :break
    end

    def shutdown_everything_now!(signal)
      log "#{signal}: immediate shutdown (and immediate worker shutdown)"
      signal_all_workers(:TERM)
      :break
    end

    # }}}
    # start, join, and master sleep {{{

    def start
      procline("(starting)")
      init_self_pipe!
      init_sig_handlers!
      maintain_worker_count
      procline("(started)")
      log "started manager"
      report_worker_pool_pids
      self
    end

    def report_worker_pool_pids
      if workers.empty?
        log "Pool is empty"
      else
        log "Pool contains worker PIDs: #{all_pids.inspect}"
      end
    end

    def join
      loop do
        reap_all_workers
        break if handle_sig_queue! == :break
        if sig_queue.empty?
          master_sleep
          maintain_worker_count
        end
        procline("managing #{all_pids.inspect}")
      end
      procline("(shutting down)")
      #stop # gracefully shutdown all workers on our way out
      log "manager finished"
      #unlink_pid_safe(pid) if pid
    end

    def master_sleep
      begin
        ready = IO.select([self_pipe.first], nil, nil, 1) or return
        ready.first && ready.first.first or return
        loop { self_pipe.first.read_nonblock(CHUNK_SIZE) }
      rescue Errno::EAGAIN, Errno::EINTR
      end
    end

    # }}}
    # worker process management {{{

    def reap_all_workers(waitpid_flags=Process::WNOHANG)
      @waiting_for_reaper = waitpid_flags == 0
      begin
        loop do
          # -1, wait for any child process
          wpid, status = Process.waitpid2(-1, waitpid_flags)
          break unless wpid

          if worker = delete_worker(wpid)
            log "Reaped resque worker[#{status.pid}] (status: #{status.exitstatus}) queues: #{worker.queues.join(",")}"
          else
            # this died before it could be killed, so it's not going to have any extra info
            log "Tried to reap worker [#{status.pid}], but it had already died. (status: #{status.exitstatus})"
          end
        end
      rescue Errno::ECHILD, QuitNowException
      end
    end

    # TODO: close any file descriptors connected to worker, if any
    def delete_worker(pid)
      worker = nil
      workers.detect do |queues, pid_to_worker|
        worker = pid_to_worker.delete(pid)
      end
      worker
    end

    def all_pids
      workers.map {|q,workers| workers.keys }.flatten
    end

    def signal_all_workers(signal)
      all_pids.each do |pid|
        Process.kill signal, pid
      end
    end

    # }}}
    # ???: maintain_worker_count, all_known_queues {{{

    def maintain_worker_count
      all_known_queues.each do |queues|
        delta = worker_delta_for(queues)
        spawn_missing_workers_for(queues) if delta > 0
        quit_excess_workers_for(queues)   if delta < 0
      end
    end

    def all_known_queues
      config.keys | workers.keys
    end

    # }}}
    # methods that operate on a single grouping of queues {{{
    # perhaps this means a class is waiting to be extracted

    def spawn_missing_workers_for(queues)
      worker_delta_for(queues).times do |nr|
        spawn_worker!(queues)
      end
    end

    def quit_excess_workers_for(queues)
      delta = -worker_delta_for(queues)
      pids_for(queues)[0...delta].each do |pid|
        Process.kill("QUIT", pid)
      end
    end

    def worker_delta_for(queues)
      config_get_worker_count(queues) - workers.fetch(queues, []).size
    end

    # Get the number of workers declared in the config file for queues
    #
    # @param queues [String] a given key/entry from the config file
    # @return [Fixnum] If the queues parameter does not exist in the config file
    # 0 is returned else the declared count of workers is returned.
    #
    # Example:
    #   config_get_worker_count("foo,bar")
    #   config_get_worker("baz")
    def config_get_worker_count(queues)
      return 0 unless config.has_key?(queues)

      v = config[queues]

      if v.is_a?(Fixnum)
        return v
      elsif v.is_a?(Array)
        workers_entry = v.find { |entry| entry.has_key?('workers') }
        return (workers_entry ? workers_entry['workers'] : 0)
      end

      return 0
    end

    # Check if certain queues should have their workers to fork or not
    #
    # NOTE: If you need to have dedicated non-forking workers for a queue then
    # you need to correctly specify false into the `fork_per_job` key of your queue.
    # An example can be found in the skroutz README.
    #
    # Default behavior is to fork in order to comply with resque since it's default
    # behavior is also to fork unless specified otherwise (See the FORK_PER_JOB
    # environment variable in resque).
    #
    # @param queues [Array<String>|String] the input queue/queues
    # @return [Boolean] true if 'fork_per_job' is true or absent and
    # false if 'fork_per_job' is declared as false
    #
    # Example:
    # fork_enabled_for_queues?(["foo", "bar"])
    # fork_enabled_for_queues?("foo,bar")
    # fork_enabled_for_queues?("baz")
    def fork_enabled_for_queues?(queues)
      queues_key = queues.is_a?(Array) ? queues.join(',') : queues
      return true unless config.has_key?(queues_key)

      v = config[queues_key]

      if v.is_a?(Array)
        fork_entry = config[queues_key].find { |entry| entry.has_key?('fork_per_job') }
        return (fork_entry ? !!fork_entry['fork_per_job'] : true)
      end

      true
    end

    def pids_for(queues)
      workers[queues].keys
    end

    def spawn_worker!(queues)
      worker = create_worker(queues)
      pid = fork do
        log_worker "Starting worker #{worker}"
        call_after_prefork!
        reset_sig_handlers!
        #self_pipe.each {|io| io.close }
        worker.work(ENV['INTERVAL'] || DEFAULT_WORKER_INTERVAL) # interval, will block
      end
      workers[queues][pid] = worker
    end

    def create_worker(queues)
      queues = queues.to_s.split(',')
      worker = ::Resque::Worker.new(*queues)
      worker.verbose = ENV['LOGGING'] || ENV['VERBOSE']
      worker.very_verbose = ENV['VVERBOSE']
      worker.fork_per_job = fork_enabled_for_queues?(queues)
      worker
    end

    # }}}

  end
end
