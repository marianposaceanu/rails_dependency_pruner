# lobsters ruby 4.0.5, rails 8.1.3

Local app copy: `tmp/lobsters-ruby405-rails813`

Runtime:

- macOS/Darwin on arm64
- Ruby `4.0.5` via RVM
- Rails `8.1.3`
- `RAILS_ENV=production`
- request smoke: `/privacy`, `/login`, `/404`

## profile

The current profile keeps Action Mailbox and Active Storage. It disables eager
loading, skips `rails/test_unit/railtie`, defers selected boot gems, installs a
no-op `Rack::MiniProfiler` shim, and stubs Active Storage's Vips analyzer for
this no-attachment workload.

Lobsters does not declare `has_one_attached` or `has_many_attached`. It uses
`Vips` directly in `app/models/story_image.rb`, so direct image-generation code
still loads `ruby-vips` on first use. Apps that use Active Storage attachments
need attachment analysis coverage before approving the `ruby-vips` analyzer
stub, because the stub makes that analyzer decline instead of loading libvips.

Production approval:

- artifact: `tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-request-approve.json`
- `verified`: `true`
- `production_allowed`: `true`
- verifier errors: `0`
- profile id: `sha256:38b32261d9e4f00de55ac39d0f67b94b7e70827c4001732cd8537ab30c61e404`

Registered transforms:

- `disable_eager_load`
- `disable_framework:actiontext`
- `prune_railtie:action_text/engine`
- `skip_railtie:rails/test_unit/railtie`
- `stub:rack_mini_profiler`
- `stub:active_storage_vips_analyzer`
- `lazy_gem:*` for the approved boot-deferred gems

## results

| target | baseline RSS | pruned RSS | saved RSS | Rails features | GC live slots |
| --- | ---: | ---: | ---: | ---: | ---: |
| requests | `208432 KB` | `125952 KB` | `82480 KB` (`80.5 MiB`, `39.6%`) | `-201` | `-273750` |
| environment | `231632 KB` | `110912 KB` | `120720 KB` (`117.9 MiB`, `52.1%`) | `-434` | `-303782` |

The request run hit `/privacy` and `/login` with `200`, and `/404` with `404`.
The earlier reference run for the same runtime behavior measured
`228576 KB -> 127904 KB`, saving `100672 KB` (`98.3 MiB`, `44.0%`). The
loaded-feature deltas are unchanged in the current run, but macOS RSS moved.

Artifacts:

- `tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-request-profile.json`
- `tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-request-measurement.json`
- `tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-request-measurement.md`
- `tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-environment-measurement.json`
- `tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-environment-measurement.md`

## what eats memory

RSS is not additive by Rails framework, so these rows are attribution signals,
not exact framework memory ownership. The measurement can prove process RSS,
loaded Rails feature counts, and GC live-slot deltas.

Request-warmed framework deltas:

| framework | loaded feature delta |
| --- | ---: |
| activerecord | `-66` |
| actionview | `-45` |
| activestorage | `-38` |
| actionmailbox | `-24` |
| activesupport | `-14` |
| railties | `-11` |
| actionpack | `-1` |
| activejob | `-1` |
| activemodel | `-1` |
| actionmailer | `0` |

Environment boot framework deltas:

| framework | loaded feature delta |
| --- | ---: |
| activerecord | `-216` |
| actionview | `-65` |
| activemodel | `-55` |
| activestorage | `-38` |
| actionmailbox | `-24` |
| activesupport | `-20` |
| railties | `-11` |
| actionpack | `-3` |
| activejob | `-2` |
| actionmailer | `0` |

The largest Rails-side pressure in this Lobsters boot is eager-loaded
ActiveRecord, followed by Action View and Active Model. Request warming brings
some of that back, but ActiveRecord and Action View remain the biggest Rails
feature reductions.

The Vips analyzer is separate from normal Rails feature counts. Before the Vips
analyzer stub, the reference request-warmed profile saved `77488 KB` RSS. With
the stub it saved `100672 KB`, an extra `23776 KB` (`23.2 MiB`). That paired
reference is the better Vips-specific estimate than comparing unrelated RSS
runs. The gain comes from avoiding the ActiveStorage analyzer's boot-time
`ruby-vips` load; it does not remove direct app `Vips` use.

## commands

Build and approve:

```bash
APP="$PWD/tmp/lobsters-ruby405-rails813"
COVERAGE="$PWD/tmp/lobsters-ruby405-rails813-request-coverage.yml"
PROFILE="$PWD/tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-request-profile.json"

LAZY_GEMS="bcrypt,builder,commonmarker,faker,flamegraph,htmlentities"
LAZY_GEMS="$LAZY_GEMS,memory_profiler,nokogiri,oauth,parslet,pdf-reader"
LAZY_GEMS="$LAZY_GEMS,rack-mini-profiler,rotp,rqrcode,ruby-vips"
LAZY_GEMS="$LAZY_GEMS,sentry-rails,sitemap_generator,stackprof,svg-graph"

bundle exec exe/rails-dependency-pruner plan \
  --app "$APP" \
  --coverage "$COVERAGE" \
  --profile "$PROFILE" \
  --disable-eager-load \
  --skip-railties rails/test_unit/railtie \
  --lazy-gems "$LAZY_GEMS"

bundle exec exe/rails-dependency-pruner approve \
  --profile "$PROFILE" \
  --app "$APP" \
  --coverage "$COVERAGE"
```

Measure requests:

```bash
RAILS_ENV=production \
SECRET_KEY_BASE_DUMMY=1 \
DATABASE_HOST=127.0.0.1 \
bundle exec exe/rails-dependency-pruner measure \
  --app tmp/lobsters-ruby405-rails813 \
  --profile tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-request-profile.json \
  --target requests \
  --request-paths /privacy,/login,/404 \
  --variants baseline,boot_prune \
  --runs 3 \
  --output tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-request-measurement.json \
  --markdown tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-request-measurement.md
```

Measure environment boot:

```bash
RAILS_ENV=production \
SECRET_KEY_BASE_DUMMY=1 \
DATABASE_HOST=127.0.0.1 \
bundle exec exe/rails-dependency-pruner measure \
  --app tmp/lobsters-ruby405-rails813 \
  --profile tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-request-profile.json \
  --target environment \
  --variants baseline,boot_prune \
  --runs 3 \
  --output tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-environment-measurement.json \
  --markdown tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-environment-measurement.md
```
