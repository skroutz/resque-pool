require 'spec_helper'

RSpec.configure do |config|
  config.after {
    Object.send(:remove_const, :RAILS_ENV) if defined? RAILS_ENV
    ENV.delete 'RACK_ENV'
    ENV.delete 'RAILS_ENV'
    ENV.delete 'RESQUE_ENV'
  }
end

describe Resque::Pool, "when loading a simple pool configuration" do
  let(:config) do
    { 'foo' => 1, 'bar' => 2, 'foo,bar' => 3, 'bar,foo' => 4, }
  end
  subject { Resque::Pool.new(config) }

  context "when ENV['RACK_ENV'] is set" do
    before { ENV['RACK_ENV'] = 'development' }

    it "should load the values from the Hash" do
      subject.config["foo"].should == 1
      subject.config["bar"].should == 2
      subject.config["foo,bar"].should == 3
      subject.config["bar,foo"].should == 4
    end
  end

end

describe Resque::Pool, "when loading the pool configuration from a Hash" do

  let(:config) do
    {
      'foo' => 8,
      'test'        => { 'bar' => 10, 'foo,bar' => 12 },
      'development' => { 'baz' => 14, 'foo,bar' => 16 },
    }
  end

  subject { Resque::Pool.new(config) }

  context "when RAILS_ENV is set" do
    before { RAILS_ENV = "test" }

    it "should load the default values from the Hash" do
      subject.config["foo"].should == 8
    end

    it "should merge the values for the correct RAILS_ENV" do
      subject.config["bar"].should == 10
      subject.config["foo,bar"].should == 12
    end

    it "should not load the values for the other environments" do
      subject.config["foo,bar"].should == 12
      subject.config["baz"].should be_nil
    end

  end

  context "when Rails.env is set" do
    before(:each) do
      module Rails; end
      Rails.stub(:env).and_return('test')
    end

    it "should load the default values from the Hash" do
      subject.config["foo"].should == 8
    end

    it "should merge the values for the correct RAILS_ENV" do
      subject.config["bar"].should == 10
      subject.config["foo,bar"].should == 12
    end

    it "should not load the values for the other environments" do
      subject.config["foo,bar"].should == 12
      subject.config["baz"].should be_nil
    end

    after(:all) { Object.send(:remove_const, :Rails) }
  end


  context "when ENV['RESQUE_ENV'] is set" do
    before { ENV['RESQUE_ENV'] = 'development' }
    it "should load the config for that environment" do
      subject.config["foo"].should == 8
      subject.config["foo,bar"].should == 16
      subject.config["baz"].should == 14
      subject.config["bar"].should be_nil
    end
  end

  context "when there is no environment" do
    it "should load the default values only" do
      subject.config["foo"].should == 8
      subject.config["bar"].should be_nil
      subject.config["foo,bar"].should be_nil
      subject.config["baz"].should be_nil
    end
  end

end

describe Resque::Pool, "given no configuration" do
  subject { Resque::Pool.new(nil) }
  it "should have no worker types" do
    subject.config.should == {}
  end
end

describe Resque::Pool, "when loading the pool configuration from a file" do

  subject { Resque::Pool.new("spec/resque-pool.yml") }

  context "when RAILS_ENV is set" do
    before { RAILS_ENV = "test" }

    it "should load the default YAML" do
      subject.config["foo"].should == 1
    end

    it "should merge the YAML for the correct RAILS_ENV" do
      subject.config["bar"].should == 5
      subject.config["foo,bar"].should == 3
    end

    it "should not load the YAML for the other environments" do
      subject.config["foo"].should == 1
      subject.config["bar"].should == 5
      subject.config["foo,bar"].should == 3
      subject.config["baz"].should be_nil
    end

  end

  context "when ENV['RACK_ENV'] is set" do
    before { ENV['RACK_ENV'] = 'development' }
    it "should load the config for that environment" do
      subject.config["foo"].should == 1
      subject.config["foo,bar"].should == 4
      subject.config["baz"].should == 23
      subject.config["bar"].should be_nil
    end
  end

  context "when there is no environment" do
    it "should load the default values only" do
      subject.config["foo"].should == 1
      subject.config["bar"].should be_nil
      subject.config["foo,bar"].should be_nil
      subject.config["baz"].should be_nil
    end
  end

  context "when a custom file is specified" do
    before { ENV["RESQUE_POOL_CONFIG"] = 'spec/resque-pool-custom.yml.erb' }
    subject { Resque::Pool.new(Resque::Pool.choose_config_file) }
    it "should find the right file, and parse the ERB" do
      subject.config["foo"].should == 2
    end
  end

end

describe Resque::Pool, "when config file has skroutz syntax only" do
  subject { Resque::Pool.new('spec/resque-pool-skroutz.yml')  }

  context "when RACK_ENV is set" do
    before { ENV['RACK_ENV'] = 'development' }

    it "fetches all the known queues (global ones plus the ones for the specific environment)" do
      subject.all_known_queues.should == ["foo", "lala", "foo,bar", "baz", "koko"]
    end

    it "fetches the count of workers correctly" do
      subject.config_get_worker_count("foo").should == 1
      subject.config_get_worker_count("lala").should == 7
      subject.config_get_worker_count("foo,bar").should == 4
      subject.config_get_worker_count("baz").should == 23
      subject.config_get_worker_count("koko").should == 1
    end

    it "recognizes if fork is enabled or not" do
      subject.fork_enabled_for_queues?(["foo"]).should == true
      subject.fork_enabled_for_queues?(["lala"]).should == false
      subject.fork_enabled_for_queues?(["foo", "bar"]).should == true
      subject.fork_enabled_for_queues?(["baz"]).should == true
      subject.fork_enabled_for_queues?(["koko"]).should == false
    end

    it "creates forking workers if fork is enabled (forking is true by default)" do
      worker_foo = subject.create_worker("foo")
      worker_foo_bar = subject.create_worker("foo,bar")
      worker_baz = subject.create_worker("baz")

      worker_foo.fork_per_job?.should == true
      worker_foo_bar.fork_per_job?.should == true
      worker_baz.fork_per_job?.should == true
    end

    it "creates non forking workers if fork is not enabled" do
      worker_lala = subject.create_worker("lala")
      worker_koko = subject.create_worker("koko")

      worker_lala.fork_per_job?.should == false
      worker_koko.fork_per_job?.should == false
    end
  end

  context "when RACK_ENV is not set" do
    it "fetches all the known queues (only the global ones)" do
      subject.all_known_queues.should == ["foo", "lala"]
    end

    it "loads keys which do not have an environment and fetches the count of workers correctly" do
      subject.config_get_worker_count("foo").should == 1
      subject.config_get_worker_count("lala").should == 7
      subject.config_get_worker_count("foo,bar").should == 0
      subject.config_get_worker_count("bar").should == 0
    end

    it "loads keys which do not have an enviroment and recognizes if fork is enabled or not" do
      subject.fork_enabled_for_queues?(["foo"]).should == true
      subject.fork_enabled_for_queues?(["lala"]).should == false
      subject.fork_enabled_for_queues?(["foo", "bar"]).should == true
      subject.fork_enabled_for_queues?(["bar"]).should == true
    end

    it "creates forking workers if fork is enabled" do
      worker_foo = subject.create_worker("foo")

      worker_foo.fork_per_job?.should == true
    end

    it "creates non forking workers if fork is not enabled" do
      worker_foo = subject.create_worker("lala")

      worker_foo.fork_per_job?.should == false
    end
  end
end

describe Resque::Pool, "when config file has mixed syntax" do
  subject { Resque::Pool.new('spec/resque-pool-mixed.yml')  }

  context "when RACK_ENV is set" do
    before { ENV['RACK_ENV'] = 'development' }

    it "fetches all the known queues (global ones plus the ones for the specific environment)" do
      subject.all_known_queues.should == ["foo", "lala", "foo,bar", "baz", "koko"]
    end

    it "fetches the count of workers correctly" do
      subject.config_get_worker_count("foo").should == 1
      subject.config_get_worker_count("lala").should == 7
      subject.config_get_worker_count("foo,bar").should == 4
      subject.config_get_worker_count("baz").should == 23
      subject.config_get_worker_count("koko").should == 1
    end

    it "recognizes if fork is enabled or not" do
      subject.fork_enabled_for_queues?(["foo"]).should == true
      subject.fork_enabled_for_queues?(["lala"]).should == false
      subject.fork_enabled_for_queues?(["foo", "bar"]).should == true
      subject.fork_enabled_for_queues?(["baz"]).should == true
      subject.fork_enabled_for_queues?(["koko"]).should == false
    end

    it "creates forking workers if fork is enabled (forking is true by default)" do
      worker_foo = subject.create_worker("foo")
      worker_foo_bar = subject.create_worker("foo,bar")
      worker_baz = subject.create_worker("baz")

      worker_foo.fork_per_job?.should == true
      worker_foo_bar.fork_per_job?.should == true
      worker_baz.fork_per_job?.should == true
    end

    it "creates non forking workers if fork is not enabled" do
      worker_lala = subject.create_worker("lala")
      worker_koko = subject.create_worker("koko")

      worker_lala.fork_per_job?.should == false
      worker_koko.fork_per_job?.should == false
    end
  end

  context "when RACK_ENV is not set" do
    it "fetches all the known queues (only the global ones)" do
      subject.all_known_queues.should == ["foo", "lala"]
    end

    it "loads keys which do not have an environment and fetches the count of workers correctly" do
      subject.config_get_worker_count("foo").should == 1
      subject.config_get_worker_count("lala").should == 7
      subject.config_get_worker_count("foo,bar").should == 0
      subject.config_get_worker_count("bar").should == 0
    end

    it "loads keys which do not have an enviroment and recognizes if fork is enabled or not" do
      subject.fork_enabled_for_queues?(["foo"]).should == true
      subject.fork_enabled_for_queues?(["lala"]).should == false
      subject.fork_enabled_for_queues?(["foo", "bar"]).should == true
      subject.fork_enabled_for_queues?(["bar"]).should == true
    end

    it "creates forking workers if fork is enabled" do
      worker_foo = subject.create_worker("foo")

      worker_foo.fork_per_job?.should == true
    end

    it "creates non forking workers if fork is not enabled" do
      worker_foo = subject.create_worker("lala")

      worker_foo.fork_per_job?.should == false
    end
  end
end
