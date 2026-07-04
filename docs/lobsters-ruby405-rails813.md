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
- profile id: `sha256:46be13455983b2e1f38e1509036fbe0decc498d966dea01f517f25d6870db1dc`

## results

| target | baseline RSS | pruned RSS | saved RSS | Rails features | GC live slots |
| --- | ---: | ---: | ---: | ---: | ---: |
| requests | `228576 KB` | `127904 KB` | `100672 KB` (`98.3 MiB`, `44.0%`) | `-201` | `-273764` |
| environment | `218592 KB` | `111312 KB` | `107280 KB` (`104.8 MiB`, `49.1%`) | `-434` | `-303816` |

The request run hit `/privacy` and `/login` with `200`, and `/404` with `404`.

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
analyzer stub, the same request-warmed profile saved `77488 KB` RSS. With the
stub it saves `100672 KB`, an extra `23776 KB` (`23.2 MiB`). Environment boot
improved by `23408 KB` (`22.9 MiB`). That gain comes from avoiding the
ActiveStorage analyzer's boot-time `ruby-vips` load; it does not remove direct
app `Vips` use.

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
