# lobsters ruby 4.0.5, rails 8.1.3

Local app copy: `tmp/lobsters-ruby405-rails813`

Runtime:

- macOS/Darwin on arm64
- Ruby `4.0.5` via RVM
- Rails `8.1.3`
- `RAILS_ENV=production`
- request smoke: `/privacy`, `/login`, `/404`

## profile

The current strict smoke profile keeps Action Mailbox and Active Storage. It
disables eager loading, skips `rails/test_unit/railtie`, defers selected boot
gems except `svg-graph`, installs a no-op `Rack::MiniProfiler` shim, and stubs
Active Storage's Vips analyzer for this no-attachment workload.

Lobsters does not declare `has_one_attached` or `has_many_attached`. It uses
`Vips` directly in `app/models/story_image.rb`, so direct image-generation code
still loads `ruby-vips` on first use. Apps that use Active Storage attachments
need attachment analysis coverage before approving the `ruby-vips` analyzer
stub, because the stub makes that analyzer decline instead of loading libvips.

Strict no-`svg-graph` profile:

- artifact: `tmp/lobsters-ruby405-rails813-policy-profile-no-svg-graph.json`
- `production_allowed`: `true`
- expected runtime events: `2`
- profile id: `sha256:46725bec00671762321dc0c575e120261d1b5341baea7099d61ed317d30815dd`

Earlier full-profile approval:

- artifact: `tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-request-approve.json`
- `verified`: `true`
- `production_allowed`: `true`
- verifier errors: `0`
- profile id: `sha256:0ffece1883f3f4b20d8e041bb19edc2604115f4aae1116c938c32b8ef6742187`

Registered transforms:

- `disable_eager_load`
- `disable_framework:actiontext`
- `prune_railtie:action_text/engine`
- `skip_railtie:rails/test_unit/railtie`
- `stub:rack_mini_profiler`
- `stub:active_storage_vips_analyzer`
- `lazy_gem:*` for the approved boot-deferred gems

## results

Strict no-`svg-graph` profile smoke, one run:

| target | baseline RSS | pruned RSS | saved RSS | boot ms | first req ms | warm p95 ms | Rails features | GC live slots |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| requests | `233072 KB` | `129920 KB` | `103152 KB` (`100.7 MiB`, `44.3%`) | `2610.6 -> 871.0` | `14.3 -> 231.4` | `4.2 -> 23.9` | `-201` | `-273497` |

Request-status and event-policy smoke, one run:

| target | baseline RSS | production RSS | saved RSS | events | unexpected | request status gate |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| requests | `232672 KB` | `123344 KB` | `109328 KB` (`106.8 MiB`, `47.0%`) | `2` | `0` | passed for `/privacy`, `/login`, `/404` |

Safety-policy profile smoke, one run:

| target | baseline RSS | boot_prune RSS | saved RSS | events | unexpected | request status gate |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| requests | `253264 KB` | `123248 KB` | `130016 KB` (`127.0 MiB`, `51.3%`) | `2` | `0` | passed for `/privacy`, `/login`, `/404` |

The strict-profile request smoke hit `/privacy` and `/login` with `200`, and
`/404` with `404`. The first request is slower because deferred boot work moves
into that request. Warmed p95 moved by `+19.6 ms` in this one-run smoke.

Earlier full-profile measurements:

| target | baseline RSS | pruned RSS | saved RSS | Rails features | GC live slots |
| --- | ---: | ---: | ---: | ---: | ---: |
| requests | `216768 KB` | `127680 KB` | `89088 KB` (`87.0 MiB`, `41.1%`) | `-201` | `-273725` |
| environment | `220128 KB` | `109264 KB` | `110864 KB` (`108.3 MiB`, `50.4%`) | `-434` | `-303781` |

The request run hit `/privacy` and `/login` with `200`, and `/404` with `404`.
The earlier reference run for the same runtime behavior measured
`228576 KB -> 127904 KB`, saving `100672 KB` (`98.3 MiB`, `44.0%`). The
loaded-feature deltas are unchanged in the current run, while macOS RSS moved.

Artifacts:

- `tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-request-profile.json`
- `tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-request-measurement.json`
- `tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-request-measurement.md`
- `tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-environment-measurement.json`
- `tmp/lobsters-ruby405-rails813-lazy-more-profiler-vips-environment-measurement.md`
- `tmp/lobsters-ruby405-rails813-ablation-request.json`
- `tmp/lobsters-ruby405-rails813-ablation-request.md`
- `tmp/lobsters-ruby405-rails813-policy-profile.json`
- `tmp/lobsters-ruby405-rails813-policy-profile-no-svg-graph.json`
- `tmp/lobsters-ruby405-rails813-latency-smoke.json`
- `tmp/lobsters-ruby405-rails813-latency-smoke.md`
- `tmp/lobsters-ruby405-rails813-latency-smoke.stdout.json`
- `tmp/lobsters-ruby405-rails813-latency-policy-smoke.json`
- `tmp/lobsters-ruby405-rails813-high-risk-policy-smoke.json`
- `tmp/lobsters-ruby405-rails813-transform-contract-smoke.json`
- `tmp/lobsters-ruby405-rails813-approval-metadata-smoke.json`
- `tmp/lobsters-ruby405-rails813-rollout-env-gate-smoke.json`
- `tmp/lobsters-ruby405-rails813-rollout-env-gate-smoke.patch`
- `tmp/lobsters-ruby405-rails813-runtime-event-summary-smoke.json`
- `tmp/lobsters-ruby405-rails813-gem-policy-smoke.json`
- `tmp/lobsters-ruby405-rails813-policy-approve.json`
- `tmp/lobsters-ruby405-rails813-doctor.json`
- `tmp/lobsters-ruby405-rails805-doctor-direct-gem-smoke.json`
- `tmp/lobsters-ruby405-rails813-coverage-template.yml`
- `tmp/lobsters-ruby405-request-status-policy-smoke.json`
- `tmp/lobsters-ruby405-request-status-policy-smoke.md`
- `tmp/lobsters-ruby405-safety-policy-profile-smoke.json`
- `tmp/lobsters-ruby405-safety-policy-measurement-smoke.json`
- `tmp/lobsters-ruby405-safety-policy-measurement-smoke.md`

Static capability scan:

| capability | result |
| --- | --- |
| Rails version | `8.1.3` |
| loaded railties | `action_controller`, `action_mailbox`, `action_mailer`, `action_view`, `active_job`, `active_model`, `active_record`, `active_storage`, `rails/test_unit` |
| Active Storage attachment DSL | `0` declarations |
| Action Text DSL | `0` declarations |
| direct `Vips` use | yes, `app/models/story_image.rb` |
| direct `Nokogiri` use | yes |
| direct `Sentry` use | yes |
| mounted Rack apps | `MissionControl::Jobs::Engine` |
| jobs / mailers / channels | `10` / `8` / `0` |
| integrations | `rack-mini-profiler`, `sentry-rails`, `sentry-ruby` |
| adapters | `puma` |
| dynamic initializer require/load risks | `0` |
| dynamic constantization risks | `0` |
| parse errors | `0` |

Coverage template smoke:

- artifact: `tmp/lobsters-ruby405-rails813-coverage-template.yml`
- `version`: `2`
- `rails_env`: `production`
- inferred request entries: `20`
- inferred jobs / mailer actions / channels: `10` / `10` / `0`
- Active Storage declarations: `false`
- Action Text declarations: `false`
- integrations: `rack-mini-profiler`, `sentry-rails`, `sentry-ruby`
- inferred workload sections are marked `review_required: true`

Gem policy smoke:

- artifact: `tmp/lobsters-ruby405-rails813-gem-policy-smoke.json`
- lazy gems in the strict profile: `18`
- unsupported lazy gems: `0`

Latency policy smoke:

- artifact: `tmp/lobsters-ruby405-rails813-latency-policy-smoke.json`
- policy: `min_total_savings_mib: 20`, `min_total_savings_percent: 10`,
  `max_first_request_latency_regression_ms: 100`,
  `max_warmed_p95_latency_regression_percent: 5`
- result: failed latency gates while still saving `100.7 MiB`
- first request delta: `+217.1 ms`
- warmed p95 delta: `+464.4%`

High-risk verifier smoke:

- artifact: `tmp/lobsters-ruby405-rails813-high-risk-policy-smoke.json`
- result: production verification fails until `disable_eager_load` has first
  request, p95, and p99 latency gates in the copied `memory_policy`
- Vips analyzer stub proof: accepted by static analysis because Lobsters has no
  `has_one_attached` or `has_many_attached` declarations

Transform contract smoke:

- artifact: `tmp/lobsters-ruby405-rails813-transform-contract-smoke.json`
- result: the older local profile fails production verification with `24`
  transform contract gaps
- next action before approval: regenerate the profile with the current registry
  so every transform carries its proof, rollback, and production rule fields

Approval metadata smoke:

- artifact: `tmp/lobsters-ruby405-rails813-approval-metadata-smoke.json`
- result: `profile_approved: false`
- reason: the older local profile still fails contract and latency-policy gates
  before approval metadata can be written

Rollout env-gate smoke:

- artifact: `tmp/lobsters-ruby405-rails813-rollout-env-gate-smoke.json`
- result: generated production config is gated by
  `RAILS_DEPENDENCY_PRUNER_ENABLED=1`
- rollback note: generated patch mentions `RAILS_DEPENDENCY_PRUNER_DISABLE=1`

Runtime event summary smoke:

- artifact: `tmp/lobsters-ruby405-rails813-runtime-event-summary-smoke.json`
- input: corrected canary and production event-manifest smokes
- result: `4` events, `4` expected, `0` unexpected

Request ablation smoke, one run per variant:

| variant | RSS | saved RSS | Rails features | GC live slots | T_STRING |
| --- | ---: | ---: | ---: | ---: | ---: |
| baseline | `204528 KB` | `0 KB` | `1074` | `545213` | `250649` |
| process_warmup | `184912 KB` | `19616 KB` (`19.2 MiB`, `9.6%`) | `0` | `+11` | `0` |
| skip_test_railtie_only | `213408 KB` | `-8880 KB` (`-8.7 MiB`, `-4.3%`) | `-4` | `+247` | `+79` |
| disable_eager_load_only | `190192 KB` | `14336 KB` (`14.0 MiB`, `7.0%`) | `-196` | `-71296` | `-10446` |
| lazy_gems_only | `160416 KB` | `44112 KB` (`43.1 MiB`, `21.6%`) | `0` | `-189677` | `-160144` |
| rack_mini_profiler_stub_only | `208576 KB` | `-4048 KB` (`-4.0 MiB`, `-2.0%`) | `0` | `-1835` | `-732` |
| active_storage_vips_analyzer_stub_only | `176752 KB` | `27776 KB` (`27.1 MiB`, `13.6%`) | `-1` | `-5058` | `-1492` |
| rails_prune_plan_only | `208064 KB` | `-3536 KB` (`-3.5 MiB`, `-1.7%`) | `0` | `+624` | `+218` |
| all_low_risk_transforms | `182048 KB` | `22480 KB` (`22.0 MiB`, `11.0%`) | `-4` | `-176664` | `-155916` |
| all_approved_transforms | `126192 KB` | `78336 KB` (`76.5 MiB`, `38.3%`) | `-201` | `-273736` | `-174427` |

All ablation variants returned `/privacy:200`, `/login:200`, and `/404:404`.
The single-run ablation baseline is lower than the three-run measurement above,
so use the ablation table for transform attribution and the three-run table for
the more stable headline RSS number.

Memory policy approval smoke:

- policy thresholds: `min_total_savings_mib: 20`, `min_total_savings_percent: 10`,
  preserve `80%` of a `76.5 MiB` reference saving
- measurement candidate: `all_approved_transforms`
- policy result: passed
- measured policy saving: `78336 KB` (`76.5 MiB`, `38.3%`)
- verifier errors: `0`
- approved policy profile id:
  `sha256:6fec6cca5c99ca981badba5ad6e54859ba2c3fefa39155ecf1fde0c24b60a777`

Early boot strict-mode smoke:

- `production` accepted the policy profile only with matching
  `RAILS_DEPENDENCY_PRUNER_PROFILE_ID`
- `canary` accepted the same policy profile with matching profile id
- `production` without `RAILS_DEPENDENCY_PRUNER_PROFILE_ID` failed closed before
  app boot

Runtime event manifest smoke:

- original policy profile failed strict `canary` with one unexpected event:
  `boot:loaded_lazy_gem:svg-graph`
- caller path: `lib/time_series.rb`, through `SVG`
- this means `svg-graph` is not safe to treat as a strict lazy boot gem for
  Lobsters without a narrower shim
- temporary corrected profile:
  `tmp/lobsters-ruby405-rails813-policy-profile-no-svg-graph.json`
- corrected profile id:
  `sha256:46725bec00671762321dc0c575e120261d1b5341baea7099d61ed317d30815dd`
- corrected `canary`: `2` events, `2` expected, `0` unexpected
- corrected `production`: `2` events, `2` expected, `0` unexpected
- lazy-constant policy follow-up canary on the corrected profile: `2` events,
  `2` expected, `0` unexpected
- telemetry follow-up canary on the corrected profile: `2` early events and `2`
  NDJSON telemetry events, all expected
- telemetry counter follow-up canary on the corrected profile: `2` expected
  events, `0` unexpected events, `pruner.event.skipped_require=1`,
  `pruner.event.stub_used=1`; max RSS `169721856` bytes
- runtime counter summary smoke preserved the same counters from the telemetry
  artifact without booting Rails; max RSS `20398080` bytes
- reference-matrix static planner smoke scanned Lobsters with Rails `8.1.3`,
  kept every framework except Action Text, and used max RSS `46612480` bytes
- process-memory detail smoke on the same static scan reported RSS `44608 KB`
  and macOS physical footprint `35226 KB`; max RSS `45957120` bytes
- process-memory report-render smoke wrote the Markdown `## Process Memory`
  section from the static scan; max RSS `45973504` bytes
- rollback-template smoke wrote reviewed rollback placeholders to
  `tmp/lobsters-ruby405-rollback-template-smoke.yml`; max RSS `42205184` bytes
- fixture-matrix doctor smoke scanned Lobsters without booting it, detected
  Rack Mini Profiler, Sentry, Puma, jobs, and mailers, and used max RSS
  `41353216` bytes
- coverage-template smoke generated the reviewed storage action checklist with
  `active_storage.attachment_read: false`; max RSS `42614784` bytes
- Action Text coverage smoke generated explicit negative rich-text coverage
  with `action_text.rich_text_expected: false`; max RSS `42319872` bytes
- external-integration coverage smoke generated review placeholders for
  Rack Mini Profiler and Sentry integrations; max RSS `42418176` bytes
- disable-eager-load coverage smoke generated declared job and mailer coverage
  candidates for the stricter first-use proof; max RSS `42287104` bytes
- event artifacts:
  `tmp/lobsters-ruby405-rails813-event-manifest-smoke.json`,
  `tmp/lobsters-ruby405-rails813-event-manifest-no-svg-graph-smoke.json`,
  `tmp/lobsters-ruby405-rails813-event-manifest-no-svg-graph-production-smoke.json`,
  `tmp/lobsters-ruby405-rails813-lazy-constant-policy-smoke.json`,
  `tmp/lobsters-ruby405-rails813-telemetry-smoke.json`,
  `tmp/lobsters-ruby405-rails813-telemetry-smoke.ndjson`,
  `tmp/lobsters-ruby405-rails813-telemetry-counters-smoke.json`,
  `tmp/lobsters-ruby405-rails813-telemetry-counters-smoke.ndjson`,
  `tmp/lobsters-ruby405-rails813-runtime-counter-summary-smoke.json`,
  `tmp/lobsters-ruby405-reference-matrix-static-smoke.json`,
  `tmp/lobsters-ruby405-process-memory-details-smoke.json`,
  `tmp/lobsters-ruby405-process-memory-report-smoke.json`,
  `tmp/lobsters-ruby405-process-memory-report-smoke.md`,
  `tmp/lobsters-ruby405-fixture-matrix-doctor-smoke.json`,
  `tmp/lobsters-ruby405-fixture-matrix-doctor-smoke.time`,
  `tmp/lobsters-ruby405-rails813/tmp/lobsters-ruby405-coverage-template-attachment-read-smoke.yml`,
  `tmp/lobsters-ruby405-coverage-template-attachment-read-smoke.time`,
  `tmp/lobsters-ruby405-rails813/tmp/lobsters-ruby405-action-text-coverage-smoke.yml`,
  `tmp/lobsters-ruby405-action-text-coverage-smoke.time`,
  `tmp/lobsters-ruby405-rails813/tmp/lobsters-ruby405-external-integrations-smoke.yml`,
  `tmp/lobsters-ruby405-external-integrations-smoke.time`,
  `tmp/lobsters-ruby405-rails813/tmp/lobsters-ruby405-disable-eager-load-coverage-smoke.yml`,
  `tmp/lobsters-ruby405-disable-eager-load-coverage-smoke.time`

The current strict-profile smoke above uses the no-`svg-graph` profile. The
older full-profile RSS rows are still useful as historical context, but do not
use that exact profile as a production candidate because `svg-graph` is now
known to load during boot.
The runtime can now express this as a `lazy_constants` phase policy: a gem such
as `svg-graph` should not be approved as lazy for Lobsters boot unless its
configured constant phase matches the observed `lib/time_series.rb` boot use.

## catalog smoke

Latest static catalog smoke used the current local Lobsters lockfile, which has
Rails `8.0.5`. The scanner selected `rails_8_0`, scanned `157` files, and did
not boot the app. The richer catalog metadata produced coverage requirements for
`active_model`, `active_record`, `attachments`, `boot`, `jobs`, `mailers`, and
`requests`. Max RSS for the smoke process was `43401216` bytes.

Artifact: `tmp/lobsters-ruby405-rails805-feature-catalog-smoke.json`.

Structured lazy-gem policy smoke, also static-only, generated review entries for
`faker`, `pdf-reader`, and `ruby-vips`, plus lazy constants for `Faker`, `PDF`,
and `Vips`. Max RSS for that smoke process was `126369792` bytes.

Artifact: `tmp/lobsters-ruby405-rails805-lazy-gem-policy-smoke.json`.

Direct lazy-gem proof smoke, static-only, generated a fresh Lobsters profile for
`ruby-vips` and verified it with reviewed `lazy_gems.ruby-vips` coverage:

- artifacts: `tmp/lazy-gem-direct-use-lobsters-plan.json`,
  `tmp/lazy-gem-direct-use-lobsters-profile.json`,
  `tmp/lazy-gem-direct-use-lobsters-coverage.yml`,
  `tmp/lazy-gem-direct-use-lobsters-verify.json`,
  `tmp/lazy-gem-direct-use-lobsters-rollout.json`,
  `tmp/lazy-gem-direct-use-lobsters.patch`
- result: production verify passed with no lazy-gem direct-use gaps and no
  high-risk Vips analyzer gaps
- max RSS: plan `133152768` bytes, verify `75055104` bytes, rollout
  `42041344` bytes
- coverage template artifact:
  `tmp/lazy-gem-direct-use-lobsters-coverage-template.yml`; max RSS
  `42352640` bytes
- template direct-use review entries: `nokogiri`, `sentry-rails`, and
  `ruby-vips`

Small-app static smoke used `generic_blog_app`, the
generic blog simple app. Doctor found Rails `8.1.3`, `34` route calls, no direct
`Vips`, `Nokogiri`, or `Sentry` lazy-gem use, and no integration gems. Max RSS
was `36077568` bytes for doctor and `36323328` bytes for coverage template. It
did not run a request RSS benchmark, so the `40%` RSS reduction remains the
small-app target, not a measured result.

Mounted-app coverage smoke generated a Lobsters starter request entry for
`GET /jobs`, sourced from `MissionControl::Jobs::Engine` at
`config/routes.rb:273`. Artifact:
`tmp/mount-path-coverage-lobsters-template.yml`; max RSS `42778624` bytes.
The same static template smoke on `generic_blog_app`
found no mounted Rack apps; max RSS `36421632` bytes.

Rake-task coverage smoke found six Lobsters app tasks:
`backfill_notifications`, `build`, `data_stats`, `fake_data`, `privacy_wipe`,
and `update_banned_url_shorteners`. Artifact:
`tmp/rake-task-coverage-lobsters-template.yml`; max RSS `42565632` bytes.
The same static smoke on `generic_blog_app` found
`admin:user:create` and `semantic_search:reindex`; max RSS `36503552` bytes.
The follow-up approval-gate smoke used the same task lists after production
verification started requiring reviewed `rake_tasks` coverage for
`disable_eager_load`; max RSS was `42582016` bytes for Lobsters template and
`36814848` bytes for the generic_blog_app template.

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
ActiveRecord. In the request-warmed run it is still the biggest framework delta
at `-66` loaded features, followed by Action View at `-45`, Active Storage at
`-38`, Action Mailbox at `-24`, Active Support at `-14`, and railties at `-11`.
The environment-only boot shows the same shape more sharply, with ActiveRecord
at `-216`.

That makes the low-hanging Rails work pretty specific: reduce eager-loaded
ActiveRecord and Action View code first, then verify whether Active Storage
analyzer setup is needed for the workload. The data does not point to Action
Mailer in this app; its loaded-feature delta is `0` in both headline runs.
Active Model moves mostly because ActiveRecord pulls it in.

The request ablation narrows this further:

- `disable_eager_load_only` removes `196` Rails loaded features, mostly
  `activerecord -66`, `actionview -45`, `activestorage -37`,
  `actionmailbox -24`, and `activesupport -14`.
- `all_approved_transforms` removes `201` Rails loaded features, with the same
  Rails framework shape plus the Vips analyzer stub.
- `lazy_gems_only` saves `44112 KB` RSS without reducing Rails feature counts,
  so that win is mostly app/gem boot surface, not Rails framework files.
- `rails_prune_plan_only` does not save RSS in this workload because the pruned
  Action Text railtie is already absent from the loaded request path.

Ruby heap object movement in the full approved ablation is dominated by
`T_STRING -174427`, then `T_IMEMO -61177`, `T_ARRAY -11628`,
`T_DATA -7778`, and `T_CLASS -4869`. That explains why the win is visible in
heap shape as well as RSS, but it still does not account for every native byte.

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
