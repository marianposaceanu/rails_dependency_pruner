# rails_dependency_pruner

Find Rails constants your app does not appear to use, then block them with
guards during boot.

This is experimental memory work for Rails `8.x`. It parses Rails and app source
with Prism, optionally merges runtime evidence from a test run, then writes a
profile that the gem's Rails engine can apply.

## requirements

- Ruby `3.2+`
- Rails `8.x`

## install

Add to the app `Gemfile`:

```ruby
gem "rails_dependency_pruner"
```

Then install:

```bash
bundle install
```

## quick start

Build the default boot-pruning profile from the app root:

```bash
bundle exec rails-dependency-pruner plan
```

Add a coverage manifest and write a reviewed patch when you are ready to replace
`rails/all` or comment unused railtie requires:

```bash
bundle exec rails-dependency-pruner plan \
  --coverage config/pruner_coverage.yml \
  --patch tmp/pruner-boot-plan.patch
```

The generated schema v2 profile stores the boot plan, disabled frameworks,
disabled railties, and per-framework explanations. The patch is still only a
review artifact; the command does not modify the app.

Validate it before using it:

```bash
bundle exec rails-dependency-pruner profile validate \
  --app . \
  --profile config/rails_dependency_pruner_profile.json
```

Ask why a framework or require path was kept or pruned:

```bash
bundle exec rails-dependency-pruner explain ActiveStorage \
  --profile config/rails_dependency_pruner_profile.json

bundle exec rails-dependency-pruner explain require:active_storage/engine \
  --profile config/rails_dependency_pruner_profile.json
```

Enable the engine in `config/environments/development.rb` or another controlled
environment:

```ruby
config.rails_dependency_pruner.enabled = true
```

Boot or test the app. If code touches a disabled Rails constant, the guard raises
`RailsDependencyPruner::DisabledConstantError`.

## runtime evidence

Prism gives repeatable source facts. Runtime data is separate evidence from a
specific workload.

Record runtime evidence during a test run:

```bash
RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT=tmp/rails_dependency_pruner_runtime.json \
RUBYOPT="-rrails_dependency_pruner/runtime_recorder" \
bin/rails test
```

For slower method-owner tracing:

```bash
RAILS_DEPENDENCY_PRUNER_TRACE_CALLS=1 \
RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT=tmp/rails_dependency_pruner_runtime.json \
RUBYOPT="-rrails_dependency_pruner/runtime_recorder" \
bin/rails test
```

For require/load caller tracing:

```bash
RAILS_DEPENDENCY_PRUNER_TRACE_REQUIRES=1 \
RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT=tmp/rails_dependency_pruner_runtime.json \
RUBYOPT="-rrails_dependency_pruner/runtime_recorder" \
bin/rails test
```

For Ruby object type and Rails class instance sizes:

```bash
RAILS_DEPENDENCY_PRUNER_OBJECTSPACE=1 \
RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT=tmp/rails_dependency_pruner_runtime.json \
RUBYOPT="-rrails_dependency_pruner/runtime_recorder" \
bin/rails test
```

For boot/workload snapshots with process RSS and loaded features:

```bash
RAILS_DEPENDENCY_PRUNER_SNAPSHOTS=1 \
RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT=tmp/rails_dependency_pruner_runtime.json \
RUBYOPT="-rrails_dependency_pruner/runtime_recorder" \
bin/rails test
```

Apps can add explicit markers during a workload:

```ruby
RailsDependencyPruner::RuntimeRecorder.snapshot!("after_routes_load")
```

## coverage manifest

Production profiles should declare the workload they cover:

```yaml
version: 1
rails_env: production
boot:
  eager_load: true
routes:
  include: all
jobs:
  - CleanupJob
mailers:
  - UserMailer#welcome
rake_tasks:
  - assets:precompile
```

The profile stores this file's digest and inferred workload names. Validation
fails if the manifest changes.

Merge that evidence into the next profile:

```bash
bundle exec rails-dependency-pruner audit \
  --app . \
  --runtime-evidence tmp/rails_dependency_pruner_runtime.json \
  --write-profile config/rails_dependency_pruner_profile.json
```

The generated profile keeps the raw ObjectSpace snapshot and a short
`runtime_memory_summary` ranking. Use that ranking to decide which unused Rails
features are worth disabling first. The object type rows show broad Ruby heap
pressure such as `T_STRING`, `T_ARRAY`, and `T_HASH`; the Rails class rows point
to concrete framework constants when ObjectSpace can attribute the bytes.

## engine config

Defaults:

- disabled unless `config.rails_dependency_pruner.enabled = true` or
  `RAILS_DEPENDENCY_PRUNER_ENABLED=1`
- reads `config/rails_dependency_pruner_profile.json`
- does not remove constants that are already loaded

Optional config:

```ruby
config.rails_dependency_pruner.enabled = true
config.rails_dependency_pruner.profile_path = Rails.root.join("config/pruner.json")
config.rails_dependency_pruner.force = false
```

`force = true` removes already-loaded constants before installing guards. Use it
only in throwaway experiments.

## early boot shadow

For early require observation, load the shim from `config/boot.rb` after Bundler:

```ruby
require "bundler/setup"
require "rails_dependency_pruner/early_boot" if ENV["RAILS_DEPENDENCY_PRUNER_EARLY"] == "1"
```

To generate that as a reviewed patch:

```bash
bundle exec rails-dependency-pruner apply early-boot-shim \
  --app . \
  --write-patch tmp/pruner-early-boot.patch
```

Shadow mode records would-block require events and does not change boot behavior.
`RAILS_DEPENDENCY_PRUNER_MODE=boot_prune` blocks disabled require paths.
`RAILS_DEPENDENCY_PRUNER_MODE=production` also requires
`safety.production_allowed=true` in the profile. Set
`RAILS_DEPENDENCY_PRUNER_DISABLE=1` to skip it.

## cli

- `bundle exec rails-dependency-pruner plan`
- `bundle exec rails-dependency-pruner plan --coverage config/pruner_coverage.yml --patch tmp/pruner-boot-plan.patch`
- `bundle exec rails-dependency-pruner index`
- `bundle exec rails-dependency-pruner audit --app .`
- `bundle exec rails-dependency-pruner audit --app . --json --no-tree`
- `bundle exec rails-dependency-pruner audit --app . --write-profile config/rails_dependency_pruner_profile.json`
- `bundle exec rails-dependency-pruner audit --app . --deterministic --write-profile config/rails_dependency_pruner_profile.json`
- `bundle exec rails-dependency-pruner profile build --app . --coverage config/pruner_coverage.yml --write config/rails_dependency_pruner_profile.json`
- `bundle exec rails-dependency-pruner profile validate --app . --profile config/rails_dependency_pruner_profile.json`
- `bundle exec rails-dependency-pruner profile diff --old config/pruner.prev.json --new config/rails_dependency_pruner_profile.json`
- `bundle exec rails-dependency-pruner verify --app . --profile config/rails_dependency_pruner_profile.json`
- `bundle exec rails-dependency-pruner doctor --app .`
- `bundle exec rails-dependency-pruner apply boot-plan --app . --profile config/rails_dependency_pruner_profile.json --write-patch tmp/pruner-boot-plan.patch`
- `bundle exec rails-dependency-pruner apply early-boot-shim --app . --write-patch tmp/pruner-early-boot.patch`
- `bundle exec rails-dependency-pruner measure boot --app . --profile config/rails_dependency_pruner_profile.json --variants baseline,boot_prune --runs 5 --output tmp/pruner-memory-report.json`
- `bundle exec rails-dependency-pruner explain ActiveRecord::Base --app .`
- `bundle exec rails-dependency-pruner explain ActiveStorage --profile config/rails_dependency_pruner_profile.json`
- `bundle exec rails-dependency-pruner why-kept ActiveStorage --profile config/rails_dependency_pruner_profile.json`
- `bundle exec rails-dependency-pruner audit --app . --write-shim tmp/rails_dependency_pruner_shim.rb`

Installed Rails `8.x` gems are used by default. `--rails-root PATH` exists only
for fixture and development checks against a Rails checkout.

## feature catalog

Rails DSL usage is treated as framework evidence. The catalog in
`config/rails_dependency_pruner/features.yml` maps calls such as
`has_one_attached`, `has_rich_text`, `queue_as`, `mail`, and `stream_from` to
framework constants that should stay reachable.

Literal dynamic constant usage is also kept. Calls such as
`"ActionController::Base".constantize` and
`Object.const_get("ActiveRecord::Base")` become static keep evidence. Variable
constantization is reported in `dynamic_matches` as lower-confidence risk.

Rails config usage is boot-critical evidence. Settings such as
`config.active_storage.service`, `config.action_mailer.delivery_method`, and
`Rails.application.config.active_record.query_log_tags` become keep evidence and
are reported in `config_matches`.

Routes are scanned as framework evidence too. Route DSL calls keep Action Pack,
and route-specific hooks such as `mount ActionCable.server` or
`direct :rails_blob` are reported in `route_matches`.

## lobsters run

Against the local Rails `8.1.3` gems and
`LOBSTERS_APP`:

- Rails Ruby files scanned: `1409`
- Rails constants indexed: `2331`
- Lobsters Ruby files scanned: `157`
- Lobsters direct Rails constants: `48`
- Reachable Rails constants after closure: `757`
- Unused Rails constant candidates: `1574`
- Unused Rails feature files: `785`
- Rails parse errors: `0`
- app parse errors: `0`

Local outputs are ignored under `tmp/`.

## limits

- static analysis misses string constantization and some metaprogramming
- runtime evidence only covers the workload you ran
- guards prove missing coverage by failing loudly, not by saving memory alone
- use this in development or benchmark experiments before considering production
