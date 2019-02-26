General Info
============
Please refer to the README.md for general information regarding resque-pool

How to use
-----------

## Skroutz

### YAML file config
The `config/resque-pool.yml` can recognise whether workers of a queue should
be forking or non-forking. For that reason the declaration of worker count
and fork mode has been enhanced and now the following syntaxes are supported:

1. Upstream's syntax

```
foo: 1

production:
    "bar,baz": 2
    "koko": 4
```

2. Skroutz syntax

```
foo:
  - workers: 1

production:
  "bar,baz":
    - workers: 2
  "koko":
    - workers: 4
    - fork_per_job: false
```

3. Mixed syntax

```
foo: 1

production:
  "bar,baz": 2
  "koko":
    - workers: 4
    - fork_per_job: false
```

### Start the pool manager
The queues can start as usual using:

```
    resque-pool --daemon --environment production
```

Following the template YAML files presented above with skroutz and mixed
syntax the equivalent resque commands would be the following:

```
    rake resque:work RAILS_ENV=production QUEUES=foo &
    rake resque:work RAILS_ENV=production QUEUES=bar,baz &
    rake resque:work RAILS_ENV=production QUEUES=bar,baz &
    rake resque:work RAILS_ENV=production QUEUES=koko FORK_PER_JOB=false &
    rake resque:work RAILS_ENV=production QUEUES=koko FORK_PER_JOB=false &
    rake resque:work RAILS_ENV=production QUEUES=koko FORK_PER_JOB=false &
    rake resque:work RAILS_ENV=production QUEUES=koko FORK_PER_JOB=false &
```
