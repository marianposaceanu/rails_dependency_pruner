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

Measure the profile before treating it as a win. See
[docs/measurement.md](docs/measurement.md) for ablation runs and Rails memory
bucket notes.

Run `doctor --app . --json` before planning a profile. See
[docs/doctor.md](docs/doctor.md) for the static capability report.
Generate a starter coverage manifest with
`coverage template --app . --write config/pruner_coverage.yml`; see
[docs/coverage.md](docs/coverage.md).

Add a coverage manifest and write a reviewed patch when you are ready to replace
`rails/all` or comment unused railtie requires:

```bash
bundle exec rails-dependency-pruner plan \
  --coverage config/pruner_coverage.yml \
  --patch tmp/pruner-boot-plan.patch
```

The generated schema v3 profile stores the boot plan, disabled frameworks,
disabled railties, and per-framework explanations. The patch is still only a
review artifact; the command does not modify the app.
When a pruned framework owns conventional app paths, such as `app/jobs` or
`app/channels`, the profile also records autoload/eager-load ignore suggestions.

Validate it before using it:

```bash
bundle exec rails-dependency-pruner check \
  --app . \
  --profile config/rails_dependency_pruner_profile.json
```

After a production verification passes, approve the profile for production-mode
early boot:

```bash
bundle exec rails-dependency-pruner approve \
  --app . \
  --profile config/rails_dependency_pruner_profile.json \
  --coverage config/pruner_coverage.yml \
  --measurement tmp/pruner-ablation.json \
  --approved-by release-owner
```

Production approval rejects unclassified dynamic require/load edges in
boot-critical `config/*.rb` files and dynamic constantization that could resolve
to pruned Rails namespaces. It also rejects profiles built from truncated
runtime evidence. Successful approval records `approved_at`, `approved_by`, the
verifier version, and verifier errors/warnings in profile safety metadata.

Write one reviewed rollout patch after approval:

```bash
bundle exec rails-dependency-pruner rollout \
  --app . \
  --profile config/rails_dependency_pruner_profile.json \
  --coverage config/pruner_coverage.yml \
  --patch tmp/pruner-rollout.patch
```

The rollout patch includes the boot-plan change, early boot shim, env-gated
production config, approved profile, and coverage manifest. It does not edit the
app.

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

This records `require`, `require_relative`, and `load` events with caller and
phase fields. Literal Rails require/load events are merged back into the
planner as keep evidence for the constants defined by the loaded file.
Static literal `require`, `require_relative`, and `load` calls are also treated
as keep evidence. If a used Rails file requires another Rails file, the required
file is kept too. Receiver calls such as `params.require(:id)` and
`relation.load` are ignored because they are not Ruby load edges.

Runtime JSON includes a `limits` section and truncation flags for called methods,
require events, load events, and snapshots. Use
`RAILS_DEPENDENCY_PRUNER_MAX_CALLS`, `RAILS_DEPENDENCY_PRUNER_MAX_REQUIRE_EVENTS`,
`RAILS_DEPENDENCY_PRUNER_MAX_LOAD_EVENTS`, and
`RAILS_DEPENDENCY_PRUNER_MAX_SNAPSHOTS` to cap large workloads.
When `Rails.application` is available, runtime JSON also records capped
middleware and route summaries. Use `RAILS_DEPENDENCY_PRUNER_MAX_MIDDLEWARE` and
`RAILS_DEPENDENCY_PRUNER_MAX_ROUTES` to bound those sections.
Production approval rejects a profile when a disabled framework still appears in
recorded middleware or routes.
If early-boot or canary output JSON is passed through `--runtime-evidence`,
production approval also rejects unexpected runtime events.

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

Or collect boot runtime evidence through the CLI:

```bash
bundle exec rails-dependency-pruner runtime collect \
  --app . \
  --coverage config/pruner_coverage.yml \
  --output tmp/rails_dependency_pruner_runtime.json
```

When `--rails-root` is omitted, the collector asks the app bundle for the
installed Rails framework gem paths and uses them to filter runtime features.
For a Rails checkout, add `--rails-root /path/to/rails`.

Apps can add explicit markers during a workload:

```ruby
RailsDependencyPruner::RuntimeRecorder.snapshot!("after_routes_load")
```

## coverage manifest

Production profiles should declare the workload they cover:

```yaml
version: 2
rails_env: production
boot:
  eager_load: true
routes:
  review_required: false
  include: all
jobs:
  review_required: false
  classes:
    - CleanupJob
mailers:
  review_required: false
  actions:
    - UserMailer#welcome
active_storage:
  review_required: false
  declarations_expected: false
  upload: false
  analyze: false
  variant: false
  preview: false
  representation: false
  attachment_read: false
action_text:
  review_required: false
  rich_text_expected: false
  declarations: []
external_integrations:
  sentry-rails:
    review_required: false
    status: disabled_in_production
  rack-mini-profiler:
    review_required: false
    status: disabled_in_production
rake_tasks:
  review_required: false
  tasks:
    - assets:precompile
rollback:
  review_required: false
  disable_env_tested: true
  env_var: RAILS_DEPENDENCY_PRUNER_DISABLE
```

Use `bundle exec rails-dependency-pruner coverage template --app . --write
config/pruner_coverage.yml` to create a starter file. Generated sections are
marked `review_required: true` and do not count as coverage proof until edited.

The profile stores this file's digest and inferred workload names. Validation
fails if the manifest changes.
Production approval also rejects disabled frameworks when their required
workload type is missing, such as pruning Action Mailer without `mailers`.

Merge that evidence into the next profile:

```bash
bundle exec rails-dependency-pruner plan \
  --app . \
  --runtime-evidence tmp/rails_dependency_pruner_runtime.json \
  --profile config/rails_dependency_pruner_profile.json
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

For early require/load observation, load the shim from `config/boot.rb` after Bundler:

```ruby
require "bundler/setup"
require "rails_dependency_pruner/early_boot" if ENV["RAILS_DEPENDENCY_PRUNER_EARLY"] == "1"
```

To generate that as a reviewed patch:

```bash
bundle exec rails-dependency-pruner shim \
  --app . \
  --patch tmp/pruner-early-boot.patch
```

Shadow mode records would-block `require`, `require_relative`, and `load`
events and does not change boot behavior.
`RAILS_DEPENDENCY_PRUNER_MODE=boot_prune` blocks disabled require/load paths.
`RAILS_DEPENDENCY_PRUNER_MODE=canary` applies the profile with production safety
checks. `RAILS_DEPENDENCY_PRUNER_MODE=production` requires
`safety.production_allowed=true`, a matching `profile_id` in the profile, and
`RAILS_DEPENDENCY_PRUNER_PROFILE_ID=sha256:...`. Safety modes classify early
boot events against the profile's `expected_events`. Generated profiles fail
closed for unexpected canary events, fail production boot for unexpected boot
events, and report production request events. Unknown event policy values fail
profile validation and are rejected by canary/production early boot. Lazy
constants can be limited to declared phases through `lazy_constants`. Set
`RAILS_DEPENDENCY_PRUNER_EVENT_LOG=tmp/pruner-events.ndjson` to mirror structured
events to an NDJSON file. Set
`RAILS_DEPENDENCY_PRUNER_DISABLE=1` to skip it.

## cli

- `bundle exec rails-dependency-pruner plan`
- `bundle exec rails-dependency-pruner plan --coverage config/pruner_coverage.yml --patch tmp/pruner-boot-plan.patch`
- `bundle exec rails-dependency-pruner check --app . --profile config/rails_dependency_pruner_profile.json`
- `bundle exec rails-dependency-pruner approve --app . --profile config/rails_dependency_pruner_profile.json --coverage config/pruner_coverage.yml --measurement tmp/pruner-ablation.json`
- `bundle exec rails-dependency-pruner diff --old config/pruner.prev.json --new config/rails_dependency_pruner_profile.json`
- `bundle exec rails-dependency-pruner doctor --app .`
- `bundle exec rails-dependency-pruner coverage template --app . --write config/pruner_coverage.yml`
- `bundle exec rails-dependency-pruner patch --app . --profile config/rails_dependency_pruner_profile.json --patch tmp/pruner-boot-plan.patch`
- `bundle exec rails-dependency-pruner shim --app . --patch tmp/pruner-early-boot.patch`
- `bundle exec rails-dependency-pruner rollout --app . --profile config/rails_dependency_pruner_profile.json --coverage config/pruner_coverage.yml --patch tmp/pruner-rollout.patch`
- `bundle exec rails-dependency-pruner measure --app . --profile config/rails_dependency_pruner_profile.json --coverage config/pruner_coverage.yml --variants baseline,boot_prune --runs 5 --process-memory-details --output tmp/pruner-memory-report.json --markdown tmp/pruner-memory-report.md`
- `bundle exec rails-dependency-pruner runtime collect --app . --coverage config/pruner_coverage.yml --output tmp/pruner-runtime.json`
- `bundle exec rails-dependency-pruner explain ActiveRecord::Base --app .`
- `bundle exec rails-dependency-pruner explain ActiveStorage --profile config/rails_dependency_pruner_profile.json`

Lower-level scan commands are still available for experiments:

- `bundle exec rails-dependency-pruner index`
- `bundle exec rails-dependency-pruner audit --app . --json --no-tree`

Older nested commands such as `profile validate`, `profile diff`,
`apply boot-plan`, `apply early-boot-shim`, `measure boot`, and `verify` remain
as aliases.

Installed Rails `8.x` gems are used by default. `--rails-root PATH` exists only
for fixture and development checks against a Rails checkout.

## feature catalog

Rails DSL usage is treated as framework evidence. The catalog in
`config/rails_dependency_pruner/catalogs/rails_8_1.yml` maps calls such as
`has_one_attached`, `has_rich_text`, `queue_as`, `mail`, and `stream_from` to
framework constants that should stay reachable. Catalog entries also record
owned railties, required coverage sections, and negative rules that keep a
framework when boot-critical evidence is present.

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

## lobsters benchmark

Latest local strict-profile smoke: Lobsters on arm64 Darwin, Ruby `4.0.5`,
Rails `8.1.3`. The profile keeps Action Mailbox and Active Storage, disables
eager loading, skips Rails test-unit, defers selected gems except `svg-graph`,
stubs `rack-mini-profiler`, and stubs Active Storage's Vips analyzer for this
no-attachment workload.

| target | baseline RSS | pruned RSS | saved |
| --- | ---: | ---: | ---: |
| requests `/privacy,/login,/404`, one run | `233072 KB` | `129920 KB` | `103152 KB` (`100.7 MiB`, `44.3%`) |

Boot time moved from `2610.6 ms` to `871.0 ms`. First request moved from
`14.3 ms` to `231.4 ms` because the profile defers boot work; warmed p95 moved
from `4.2 ms` to `23.9 ms`. Lobsters uses `Vips` directly in `StoryImage`, but
does not declare `has_one_attached` or `has_many_attached`; apps that use Active
Storage attachments must provide attachment workload coverage before approving
the `ruby-vips` analyzer stub. The biggest Rails-side reductions are
ActiveRecord, Action View, and Active Storage.

Small-app benchmark target: `generic_blog_app` is the
"generic blog simple app". Acceptance target: at least `40%` RSS reduction on a
measured production request workload. Current Ruby `4.0.5` request smoke saved
`34672 KB` RSS (`33.9 MiB`, `21.5%`) after pruning unused Rails engines and
disabling eager load, so this target is not met yet.

Detailed commands and local artifact paths are in
`docs/lobsters-ruby405-rails813.md`.
Schema v3 fingerprints are described in `docs/profile-schema.md`.
Production profile transform ids are described in `docs/transform-registry.md`.
Rollout, coverage, lazy-gem, and Vips analyzer details are in `docs/rollout.md`,
`docs/coverage-manifest.md`, `docs/lazy-gems.md`, and
`docs/active-storage-vips-analyzer.md`.
Rails and app-shape support is listed in `docs/rails-version-support.md`.

## limits

- static analysis misses string constantization and some metaprogramming
- runtime evidence only covers the workload you ran
- guards prove missing coverage by failing loudly, not by saving memory alone
- use this in development or benchmark experiments before considering production
