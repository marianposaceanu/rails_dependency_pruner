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
- `tmp/rake-task-entry-gate-lobsters-template.yml`
- `tmp/rake-task-entry-gate-lobsters-template.stdout`
- `tmp/rake-task-entry-gate-lobsters-template.time`
- `tmp/rake-task-entry-gate-mp-template.yml`
- `tmp/rake-task-entry-gate-mp-template.stdout`
- `tmp/rake-task-entry-gate-mp-template.time`
- `tmp/process-memory-details-flag-lobsters-template.yml`
- `tmp/process-memory-details-flag-lobsters-template.stdout`
- `tmp/process-memory-details-flag-lobsters-template.time`
- `tmp/process-memory-details-flag-mp-template.yml`
- `tmp/process-memory-details-flag-mp-template.stdout`
- `tmp/process-memory-details-flag-mp-template.time`
- `tmp/native-heavy-doctor-lobsters.json`
- `tmp/native-heavy-doctor-lobsters.time`
- `tmp/native-heavy-doctor-mp.json`
- `tmp/native-heavy-doctor-mp.time`
- `tmp/integration-policy-doctor-lobsters.json`
- `tmp/integration-policy-doctor-lobsters.time`
- `tmp/integration-policy-doctor-mp.json`
- `tmp/integration-policy-doctor-mp.time`
- `tmp/integration-policy-coverage-lobsters-template.yml`
- `tmp/integration-policy-coverage-lobsters-template.stdout`
- `tmp/integration-policy-coverage-lobsters-template.time`
- `tmp/integration-policy-coverage-mp-template.yml`
- `tmp/integration-policy-coverage-mp-template.stdout`
- `tmp/integration-policy-coverage-mp-template.time`
- `tmp/adapter-policy-doctor-lobsters.json`
- `tmp/adapter-policy-doctor-lobsters.time`
- `tmp/adapter-policy-doctor-mp.json`
- `tmp/adapter-policy-doctor-mp.time`
- `tmp/queue-adapter-doctor-lobsters.json`
- `tmp/queue-adapter-doctor-lobsters.time`
- `tmp/queue-adapter-doctor-mp.json`
- `tmp/queue-adapter-doctor-mp.time`
- `tmp/queue-adapter-coverage-lobsters-template.yml`
- `tmp/queue-adapter-coverage-lobsters-template.stdout`
- `tmp/queue-adapter-coverage-lobsters-template.time`
- `tmp/queue-adapter-coverage-mp-template.yml`
- `tmp/queue-adapter-coverage-mp-template.stdout`
- `tmp/queue-adapter-coverage-mp-template.time`
- `tmp/cable-adapter-doctor-lobsters.json`
- `tmp/cable-adapter-doctor-lobsters.time`
- `tmp/cable-adapter-doctor-mp.json`
- `tmp/cable-adapter-doctor-mp.time`
- `tmp/cable-adapter-coverage-lobsters-template.yml`
- `tmp/cable-adapter-coverage-lobsters-template.stdout`
- `tmp/cable-adapter-coverage-lobsters-template.time`
- `tmp/cable-adapter-coverage-mp-template.yml`
- `tmp/cable-adapter-coverage-mp-template.stdout`
- `tmp/cable-adapter-coverage-mp-template.time`
- `tmp/storage-service-doctor-lobsters.json`
- `tmp/storage-service-doctor-lobsters.time`
- `tmp/storage-service-doctor-mp.json`
- `tmp/storage-service-doctor-mp.time`
- `tmp/storage-service-coverage-lobsters-template.yml`
- `tmp/storage-service-coverage-lobsters-template.stdout`
- `tmp/storage-service-coverage-lobsters-template.time`
- `tmp/storage-service-coverage-mp-template.yml`
- `tmp/storage-service-coverage-mp-template.stdout`
- `tmp/storage-service-coverage-mp-template.time`
- `tmp/mailer-delivery-doctor-lobsters.json`
- `tmp/mailer-delivery-doctor-lobsters.time`
- `tmp/mailer-delivery-doctor-mp.json`
- `tmp/mailer-delivery-doctor-mp.time`
- `tmp/mailer-delivery-coverage-lobsters-template.yml`
- `tmp/mailer-delivery-coverage-lobsters-template.stdout`
- `tmp/mailer-delivery-coverage-lobsters-template.time`
- `tmp/mailer-delivery-coverage-mp-template.yml`
- `tmp/mailer-delivery-coverage-mp-template.stdout`
- `tmp/mailer-delivery-coverage-mp-template.time`
- `tmp/context-workload-coverage-lobsters-template.yml`
- `tmp/context-workload-coverage-lobsters-template.stdout`
- `tmp/context-workload-coverage-lobsters-template.time`
- `tmp/context-workload-coverage-mp-template.yml`
- `tmp/context-workload-coverage-mp-template.stdout`
- `tmp/context-workload-coverage-mp-template.time`
- `tmp/observability-policy-doctor-lobsters.json`
- `tmp/observability-policy-doctor-lobsters.time`
- `tmp/observability-policy-doctor-mp.json`
- `tmp/observability-policy-doctor-mp.time`
- `tmp/observability-policy-coverage-lobsters-template.yml`
- `tmp/observability-policy-coverage-lobsters-template.stdout`
- `tmp/observability-policy-coverage-lobsters-template.time`
- `tmp/observability-policy-coverage-mp-template.yml`
- `tmp/observability-policy-coverage-mp-template.stdout`
- `tmp/observability-policy-coverage-mp-template.time`
- `tmp/sentry-sdk-policy-doctor-lobsters.json`
- `tmp/sentry-sdk-policy-doctor-lobsters.time`
- `tmp/sentry-sdk-policy-doctor-mp.json`
- `tmp/sentry-sdk-policy-doctor-mp.time`
- `tmp/sentry-sdk-policy-coverage-lobsters-template.yml`
- `tmp/sentry-sdk-policy-coverage-lobsters-template.stdout`
- `tmp/sentry-sdk-policy-coverage-lobsters-template.time`
- `tmp/sentry-sdk-policy-coverage-mp-template.yml`
- `tmp/sentry-sdk-policy-coverage-mp-template.stdout`
- `tmp/sentry-sdk-policy-coverage-mp-template.time`
- `tmp/native-heavy-matrix-doctor-lobsters.json`
- `tmp/native-heavy-matrix-doctor-lobsters.time`
- `tmp/native-heavy-matrix-doctor-mp.json`
- `tmp/native-heavy-matrix-doctor-mp.time`
- `tmp/action-mailbox-matrix-doctor-lobsters.json`
- `tmp/action-mailbox-matrix-doctor-lobsters.time`
- `tmp/action-mailbox-matrix-doctor-mp.json`
- `tmp/action-mailbox-matrix-doctor-mp.time`
- `tmp/action-mailbox-matrix-coverage-lobsters-template.yml`
- `tmp/action-mailbox-matrix-coverage-lobsters-template.stdout`
- `tmp/action-mailbox-matrix-coverage-lobsters-template.time`
- `tmp/action-mailbox-matrix-coverage-mp-template.yml`
- `tmp/action-mailbox-matrix-coverage-mp-template.stdout`
- `tmp/action-mailbox-matrix-coverage-mp-template.time`
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
| adapters | `puma`, `solid_queue` |
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
- inferred rake tasks: `8`
- integrations: `rack-mini-profiler`, `sentry-rails`, `sentry-ruby`
- inferred workload sections are marked `review_required: true`

Rake task entry gate static smoke:

| app | artifact | exact task entries | max RSS |
| --- | --- | ---: | ---: |
| Lobsters | `tmp/rake-task-entry-gate-lobsters-template.yml` | `8` | `53248000` bytes |
| generic_blog_app, generic blog simple app | `tmp/rake-task-entry-gate-mp-template.yml` | `4` | `48021504` bytes |

The generic_blog_app template found `assets:precompile`, `db:migrate`,
`admin:user:create`, and `semantic_search:reindex`. This was a static
coverage-template smoke only; the `40%` RSS reduction target for that app still
needs a production request measurement.

Process-memory detail flag static smoke:

| app | artifact | exact task entries | max RSS |
| --- | --- | ---: | ---: |
| Lobsters | `tmp/process-memory-details-flag-lobsters-template.yml` | `8` | `53116928` bytes |
| generic_blog_app, generic blog simple app | `tmp/process-memory-details-flag-mp-template.yml` | `4` | `47546368` bytes |

This was another static coverage-template smoke. It verifies the benchmark apps
still scan cheaply after making macOS physical-footprint measurement a first
class `--process-memory-details` option.

Native-heavy doctor static smoke:

| app | artifact | native-heavy surface | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/native-heavy-doctor-lobsters.json` | direct `nokogiri`, direct `ruby-vips`; bundled `bcrypt`, `commonmarker`, `stackprof` | `52723712` bytes |
| generic_blog_app, generic blog simple app | `tmp/native-heavy-doctor-mp.json` | bundled `bcrypt`, bundled `nokogiri`; no direct static app use | `47824896` bytes |

Both doctor scans reported `0` parse errors, `0` dynamic constantization risks,
and `0` initializer dynamic require/load risks.

Native-heavy matrix follow-up static smoke:

| app | artifact | native-heavy surface | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/native-heavy-matrix-doctor-lobsters.json` | direct `nokogiri`, direct `ruby-vips`; bundled `bcrypt`, `commonmarker`, `stackprof` | `53084160` bytes |
| generic_blog_app, generic blog simple app | `tmp/native-heavy-matrix-doctor-mp.json` | bundled `bcrypt`, bundled `nokogiri`; no direct static app use | `47611904` bytes |

The checked-in fixture matrix now includes the native-heavy direct-use fixture,
so direct `Nokogiri` and `Vips` use is covered by planner matrix regression as
well as doctor capability tests. No request RSS benchmark was run for
generic_blog_app in this milestone.

Integration policy doctor static smoke:

| app | artifact | integration policy surface | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/integration-policy-doctor-lobsters.json` | `rack-mini-profiler:middleware_integration`, `sentry-rails:railtie_integration`; unclassified `sentry-ruby` | `52330496` bytes |
| generic_blog_app, generic blog simple app | `tmp/integration-policy-doctor-mp.json` | no integration gems detected | `47726592` bytes |

Both scans reported `0` parse errors, `0` dynamic constantization risks, and
`0` initializer dynamic require/load risks.

Integration policy coverage-template static smoke:

| app | artifact | generated integration entries | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/integration-policy-coverage-lobsters-template.yml` | `rack-mini-profiler:middleware_integration:medium`, `sentry-rails:railtie_integration:high`, `sentry-ruby:unclassified` | `53362688` bytes |
| generic_blog_app, generic blog simple app | `tmp/integration-policy-coverage-mp-template.yml` | none | `48054272` bytes |

Generated entries remain `review_required: true`. This was a static
coverage-template smoke only; no request RSS benchmark was run for
generic_blog_app, so the `40%` RSS target remains unmeasured.

Observability policy registry static smoke:

| app | artifact | integration policy surface | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/observability-policy-doctor-lobsters.json` | `rack-mini-profiler:middleware_integration:medium`, `sentry-rails:railtie_integration:high`; unclassified `sentry-ruby` | `53870592` bytes |
| generic_blog_app, generic blog simple app | `tmp/observability-policy-doctor-mp.json` | no integration gems detected | `47972352` bytes |

Coverage-template follow-up:

| app | artifact | generated integration entries | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/observability-policy-coverage-lobsters-template.yml` | `rack-mini-profiler:middleware_integration:medium`, `sentry-rails:railtie_integration:high`, `sentry-ruby:unclassified` | `53395456` bytes |
| generic_blog_app, generic blog simple app | `tmp/observability-policy-coverage-mp-template.yml` | none | `48201728` bytes |

Honeybadger and Rollbar are now classified as high-risk Railtie integrations in
the policy registry. They did not appear in these two apps. No request RSS
benchmark was run for generic_blog_app in this milestone.

Sentry SDK policy static smoke:

| app | artifact | integration policy surface | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/sentry-sdk-policy-doctor-lobsters.json` | `rack-mini-profiler:middleware_integration:medium`, `sentry-rails:railtie_integration:high`, `sentry-ruby:sdk_integration:high`; no unclassified integrations | `52805632` bytes |
| generic_blog_app, generic blog simple app | `tmp/sentry-sdk-policy-doctor-mp.json` | no integration gems detected | `47562752` bytes |

Coverage-template follow-up:

| app | artifact | generated integration entries | generated lazy gems | max RSS |
| --- | --- | --- | --- | ---: |
| Lobsters | `tmp/sentry-sdk-policy-coverage-lobsters-template.yml` | `rack-mini-profiler`, `sentry-rails`, `sentry-ruby` | `nokogiri`, `ruby-vips`, `sentry-ruby` | `53329920` bytes |
| generic_blog_app, generic blog simple app | `tmp/sentry-sdk-policy-coverage-mp-template.yml` | none | none | `47792128` bytes |

Direct `Sentry` SDK use now maps to `lazy_gems.sentry-ruby`, while the Rails
integration remains under `external_integrations.sentry-rails`. No request RSS
benchmark was run for generic_blog_app in this milestone.

Adapter policy doctor static smoke:

| app | artifact | adapter policy surface | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/adapter-policy-doctor-lobsters.json` | `puma:web_server:low`, requests coverage required | `52314112` bytes |
| generic_blog_app, generic blog simple app | `tmp/adapter-policy-doctor-mp.json` | `puma:web_server:low`, requests coverage required | `47382528` bytes |

Both scans reported `0` parse errors, `0` dynamic constantization risks, and
`0` initializer dynamic require/load risks. No request RSS benchmark was run for
generic_blog_app in this milestone.

Queue adapter doctor static smoke:

| app | artifact | queue adapter surface | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/queue-adapter-doctor-lobsters.json` | `puma:web_server:low`; `solid_queue:job_adapter:medium`; configured `solid_queue` in development and production | `53248000` bytes |
| generic_blog_app, generic blog simple app | `tmp/queue-adapter-doctor-mp.json` | `puma:web_server:low`; no configured Active Job queue adapter | `47628288` bytes |

Both scans reported `0` parse errors, `0` dynamic constantization risks, and
`0` initializer dynamic require/load risks. No request RSS benchmark was run for
generic_blog_app in this milestone.

Queue adapter coverage-template static smoke:

| app | artifact | generated job adapter entries | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/queue-adapter-coverage-lobsters-template.yml` | `10` job classes; `solid_queue` in development and production | `53723136` bytes |
| generic_blog_app, generic blog simple app | `tmp/queue-adapter-coverage-mp-template.yml` | no jobs section | `47808512` bytes |

Generated `jobs.queue_adapters` entries remain review context while
`jobs.review_required: true`; exact job class coverage is still required before
approval. No request RSS benchmark was run for generic_blog_app in this milestone.

Cable adapter doctor static smoke:

| app | artifact | cable adapter surface | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/cable-adapter-doctor-lobsters.json` | `async` in development/test; `redis` in production | `52822016` bytes |
| generic_blog_app, generic blog simple app | `tmp/cable-adapter-doctor-mp.json` | `async` in development/production; `test` in test | `47644672` bytes |

Both scans reported `0` parse errors, `0` dynamic constantization risks, and
`0` initializer dynamic require/load risks.

Cable adapter coverage-template static smoke:

| app | artifact | generated cable adapter entries | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/cable-adapter-coverage-lobsters-template.yml` | no channel classes; `async`, `async`, `redis` adapters | `53182464` bytes |
| generic_blog_app, generic blog simple app | `tmp/cable-adapter-coverage-mp-template.yml` | no channel classes; `async`, `test`, `async` adapters | `47562752` bytes |

Generated `channels.cable_adapters` entries remain review context while
`channels.review_required: true`; exact channel class coverage is still required
before approval. No request RSS benchmark was run for generic_blog_app in this
milestone.

Storage service doctor static smoke:

| app | artifact | storage service surface | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/storage-service-doctor-lobsters.json` | configured `local:Disk` in development, production, and test | `52674560` bytes |
| generic_blog_app, generic blog simple app | `tmp/storage-service-doctor-mp.json` | `local:Disk` and `test:Disk` definitions; no configured service assignment | `48021504` bytes |

Both scans reported `0` parse errors, `0` dynamic constantization risks, and
`0` initializer dynamic require/load risks.

Storage service coverage-template static smoke:

| app | artifact | generated storage service entries | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/storage-service-coverage-lobsters-template.yml` | configured `local:Disk` in development, production, and test; no attachment declarations | `52953088` bytes |
| generic_blog_app, generic blog simple app | `tmp/storage-service-coverage-mp-template.yml` | `local:Disk` and `test:Disk` definitions; no configured service assignment or attachment declarations | `47726592` bytes |

Generated storage service entries remain review context. They do not count as
upload, analysis, variant, preview, representation, or attachment-read coverage.
No request RSS benchmark was run for generic_blog_app in this milestone.

Mailer delivery doctor static smoke:

| app | artifact | mailer delivery surface | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/mailer-delivery-doctor-lobsters.json` | `8` mailer classes; `letter_opener` development, `test` test, SMTP settings initializer | `52838400` bytes |
| generic_blog_app, generic blog simple app | `tmp/mailer-delivery-doctor-mp.json` | no mailer classes; `test` test delivery method | `48054272` bytes |

Both scans reported `0` parse errors, `0` dynamic constantization risks, and
`0` initializer dynamic require/load risks.

Mailer delivery coverage-template static smoke:

| app | artifact | generated mailer delivery entries | max RSS |
| --- | --- | --- | ---: |
| Lobsters | `tmp/mailer-delivery-coverage-lobsters-template.yml` | `10` mailer actions; `letter_opener`, `test`, and SMTP settings | `54034432` bytes |
| generic_blog_app, generic blog simple app | `tmp/mailer-delivery-coverage-mp-template.yml` | no mailer actions; `test` test delivery method | `47611904` bytes |

Generated mailer delivery entries remain review context while
`mailers.review_required: true`; exact mailer action coverage is still required
before approval. No request RSS benchmark was run for generic_blog_app in this
milestone.

Coverage context workload static smoke:

| app | artifact | generated context | loaded workloads | max RSS |
| --- | --- | --- | --- | ---: |
| Lobsters | `tmp/context-workload-coverage-lobsters-template.yml` | `10` jobs, `10` mailer actions, `3` cable adapters, `3` storage services | `boot` only | `53362688` bytes |
| generic_blog_app, generic blog simple app | `tmp/context-workload-coverage-mp-template.yml` | no jobs or mailer actions; `1` delivery method, `3` cable adapters | `boot` only | `47857664` bytes |

The generated adapter, delivery, SMTP, and storage service entries remain
context. They do not become workload proof until exact classes, actions,
declarations, request paths, or task names are reviewed. No request RSS
benchmark was run for generic_blog_app in this milestone.

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
- historical template direct-use review entries: `nokogiri`, `sentry-rails`,
  and `ruby-vips`; current Sentry SDK templates use `sentry-ruby` as shown
  above

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
The follow-up approval-gate smoke kept that `GET /jobs` request after
production verification started requiring mounted app request coverage for
`disable_eager_load`; artifact `tmp/mount-request-gate-lobsters-template.yml`,
max RSS `42844160` bytes. The generic_blog_app template still had no mounted Rack
apps; max RSS `36618240` bytes.

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
Active Storage action-gate smoke generated templates after production
verification started requiring full storage action coverage for
`active_storage/engine` skips with attachment declarations. Lobsters and
generic_blog_app both reported no attachment declarations and all storage action
flags false. Artifacts: `tmp/active-storage-action-gate-lobsters-template.yml`
and `tmp/active-storage-action-gate-mp-template.yml`; max RSS was `53149696`
bytes for Lobsters and `47497216` bytes for generic_blog_app. No request RSS
benchmark was run for this milestone.
Declared first-use entry smoke generated templates after production verification
started requiring exact job, mailer, and channel coverage for
`disable_eager_load`. Lobsters produced `10` job classes, `10` mailer actions,
and `0` channel classes; generic_blog_app produced `0` for all three. Artifacts:
`tmp/declared-entry-gate-lobsters-template.yml` and
`tmp/declared-entry-gate-mp-template.yml`; max RSS was `53035008` bytes for
Lobsters and `47726592` bytes for generic_blog_app. No request RSS benchmark was run
for this milestone.

Action Mailbox matrix follow-up added an inbound mailbox fixture to the
checked-in planner matrix. Static doctor smokes used max RSS `53133312` bytes
for Lobsters and `47923200` bytes for generic_blog_app. Coverage-template smokes
generated `3` Lobsters mailboxes (`ApplicationMailbox`, `BackstopMailbox`,
`InboxMailbox`) and no generic_blog_app mailboxes; max RSS was `53264384` bytes for
Lobsters and `48021504` bytes for generic_blog_app. Artifacts:
`tmp/action-mailbox-matrix-doctor-lobsters.json`,
`tmp/action-mailbox-matrix-doctor-mp.json`,
`tmp/action-mailbox-matrix-coverage-lobsters-template.yml`, and
`tmp/action-mailbox-matrix-coverage-mp-template.yml`. No request RSS benchmark
was run for generic_blog_app in this milestone.

Inbound mailbox gate smoke generated templates after production verification
started requiring exact inbound email mailbox coverage for `disable_eager_load`.
Lobsters produced `3` mailboxes, `10` job classes, `10` mailer actions, and `0`
channel classes; generic_blog_app produced `0` for all four. Artifacts:
`tmp/inbound-mailbox-gate-lobsters-template.yml` and
`tmp/inbound-mailbox-gate-mp-template.yml`; max RSS was `53379072` bytes for
Lobsters and `47464448` bytes for generic_blog_app. No request RSS benchmark was run
for this milestone.
Action Text declaration gate smoke generated templates after production
verification started requiring exact rich-text declaration coverage for
`disable_eager_load`. Lobsters and generic_blog_app both reported
`action_text.rich_text_expected: false` with `0` declarations. Artifacts:
`tmp/action-text-gate-lobsters-template.yml` and
`tmp/action-text-gate-mp-template.yml`; max RSS was `52969472` bytes for
Lobsters and `48119808` bytes for generic_blog_app. No request RSS benchmark was run
for this milestone.
Active Storage declaration gate smoke generated templates after production
verification started requiring exact attachment declaration coverage for
`disable_eager_load`. Lobsters and generic_blog_app both reported
`active_storage.declarations_expected: false` with `0` declarations. Artifacts:
`tmp/active-storage-declaration-gate-lobsters-template.yml` and
`tmp/active-storage-declaration-gate-mp-template.yml`; max RSS was `53575680`
bytes for Lobsters and `47595520` bytes for generic_blog_app. No request RSS
benchmark was run for this milestone.
Configured adapter matrix follow-up added a checked-in fixture for config-only
job, mailer, storage, and cable adapter settings. Lobsters doctor reported
`puma:web_server:requests`, `solid_queue:job_adapter:jobs`, `solid_queue`
queue adapters, `redis` production cable, Disk storage, and
`letter_opener`/`test` mail delivery; max RSS was `53493760` bytes. The
coverage template preserved the same adapter context with max RSS `53133312`
bytes. The generic_blog_app generic blog app doctor reported `puma` only, no
configured job queue adapter, `async` production cable, no configured storage
service, and `test` mail delivery; max RSS was `47693824` bytes. Its coverage
template used max RSS `47857664` bytes. Artifacts:
`tmp/configured-adapters-matrix-doctor-lobsters.json`,
`tmp/configured-adapters-matrix-coverage-lobsters-template.yml`,
`tmp/configured-adapters-matrix-doctor-mp.json`, and
`tmp/configured-adapters-matrix-coverage-mp-template.yml`. No request RSS
benchmark was run for this milestone.
Boot-mode matrix follow-up added first-class doctor output for environment
`config.eager_load` settings and Bootsnap/Spring boot requires. Lobsters doctor
reported `development:false`, `production:true`, no Bootsnap/Spring surface,
and max RSS `52740096` bytes; its coverage template kept `boot.eager_load: true`
with max RSS `53411840` bytes. The generic_blog_app generic blog app doctor
reported `development:false`, `production:true`, `test:false`, no
Bootsnap/Spring surface, and max RSS `47775744` bytes; its coverage template
kept `boot.eager_load: true` with max RSS `47628288` bytes. Artifacts:
`tmp/boot-mode-matrix-doctor-lobsters.json`,
`tmp/boot-mode-matrix-coverage-lobsters-template.yml`,
`tmp/boot-mode-matrix-doctor-mp.json`, and
`tmp/boot-mode-matrix-coverage-mp-template.yml`. No request RSS benchmark was
run for this milestone.
Puma topology follow-up added static doctor output for Puma mode, worker/thread
settings, `preload_app!`, and plugins. Lobsters reported clustered Puma with
dynamic worker/thread expressions, `preload_app!`, `tmp_restart` and
`solid_queue` plugins, and max RSS `52477952` bytes; its coverage template used
max RSS `53526528` bytes. The generic_blog_app generic blog app reported clustered
Puma with dynamic worker/thread expressions, `preload_app!`, no plugins, and
max RSS `47366144` bytes; its coverage template used max RSS `47808512` bytes.
Artifacts: `tmp/puma-topology-doctor-lobsters.json`,
`tmp/puma-topology-coverage-lobsters-template.yml`,
`tmp/puma-topology-doctor-mp.json`, and
`tmp/puma-topology-coverage-mp-template.yml`. No request RSS benchmark was run
for this milestone.
Web-server coverage-template follow-up now carries Puma topology into
`requests.web_servers` as review context. Lobsters generated `20` request
paths plus clustered Puma, `preload_app!`, `tmp_restart` and `solid_queue`
plugins; doctor and template max RSS were `52592640` and `54018048` bytes. The
generic_blog_app generic blog app generated `19` request paths plus clustered Puma
and `preload_app!`; doctor and template max RSS were `47759360` and `47742976`
bytes. Artifacts: `tmp/web-server-coverage-template-doctor-lobsters.json`,
`tmp/web-server-coverage-template-lobsters-template.yml`,
`tmp/web-server-coverage-template-doctor-mp.json`, and
`tmp/web-server-coverage-template-mp-template.yml`. No request RSS benchmark was
run for this milestone.
CI matrix follow-up added Rails `8.0`/`8.1` bundle Gemfiles and a GitHub
Actions matrix for Ruby `3.2`, `3.3`, `3.4`, with Ruby `4.0.5` on Rails `8.1`
marked experimental. Static doctor smokes still reported Rails `8.1.3` and
clustered Puma for both apps; max RSS was `53624832` bytes for Lobsters and
`48119808` bytes for the generic_blog_app generic blog app. Artifacts:
`tmp/ci-matrix-doctor-lobsters.json` and `tmp/ci-matrix-doctor-mp.json`. No
request RSS benchmark was run for this milestone.
Production-env scanner follow-up stopped generic `Rails` constants from keeping
framework peer constants and made `plan --coverage` honor the manifest
`rails_env` while scanning `config/environments/*.rb`. On a temporary Ruby
`4.0.5` copy of the generic_blog_app generic blog app, the profile pruned Action
Cable, Action Mailbox, Action Mailer, Action Text, Active Job, and Active
Storage. The request smoke used `/up`, `/`, `/archive`, `/home/about`,
`/home/projects`, `/feed`, and `/404`; all statuses matched. Original
`rails/all` RSS was `161328 KB`; patched baseline RSS was `131552 KB`; the
boot-pruned candidate was `126656 KB`. Total saving was `34672 KB`
(`33.9 MiB`, `21.5%`), so the `40%` target remains open. Artifacts:
`tmp/generic_blog_app-ruby405-env-filter-coverage.yml`,
`tmp/generic_blog_app-ruby405-env-filter-profile.json`,
`tmp/generic_blog_app-ruby405-env-filter.patch`,
`tmp/generic_blog_app-ruby405-env-filter-original-baseline-1run.json`, and
`tmp/generic_blog_app-ruby405-env-filter-measurement-patched-1run.json`.
Sequential static smokes also passed: Lobsters doctor max RSS `53460992` bytes,
Lobsters coverage-template max RSS `53673984` bytes, generic_blog_app doctor max
RSS `47923200` bytes, and generic_blog_app coverage-template max RSS `48496640`
bytes. Artifacts: `tmp/env-scan-doctor-lobsters.json`,
`tmp/env-scan-coverage-lobsters-template.yml`, `tmp/env-scan-doctor-mp.json`,
and `tmp/env-scan-coverage-mp-template.yml`.
Object-memory measurement follow-up added opt-in ObjectSpace memsize by Ruby
type and class via `--object-memory`. Sequential static smokes still passed:
Lobsters doctor max RSS `53411840` bytes, Lobsters coverage-template max RSS
`54214656` bytes, generic_blog_app doctor max RSS `47742976` bytes, and
generic_blog_app coverage-template max RSS `48136192` bytes. Artifacts:
`tmp/object-memory-doctor-lobsters.json`,
`tmp/lobsters-ruby405-rails813/tmp/object-memory-coverage-lobsters-template.yml`,
`tmp/object-memory-doctor-mp.json`, and
`generic_blog_app/tmp/object-memory-coverage-mp-template.yml`.
Coverage-bound measurement follow-up added `measure --coverage` so reports carry
the coverage digest, Rails env, and reviewed workloads, and request measurements
can use reviewed coverage request paths. Sequential static smokes still passed:
Lobsters doctor max RSS `54050816` bytes, Lobsters coverage-template max RSS
`53821440` bytes, generic_blog_app doctor max RSS `47775744` bytes, and
generic_blog_app coverage-template max RSS `47972352` bytes. Artifacts:
`tmp/measure-coverage-doctor-lobsters.json`,
`tmp/lobsters-ruby405-rails813/tmp/measure-coverage-lobsters-template.yml`,
`tmp/measure-coverage-doctor-mp.json`, and
`generic_blog_app/tmp/measure-coverage-mp-template.yml`.
No request RSS benchmark was run for this milestone, so the generic_blog_app `40%`
target remains open.
GC-stat measurement follow-up added `GC.stat` snapshots, medians, and deltas,
including `total_allocated_objects`, to measurement JSON and Markdown. Sequential
static smokes still passed: Lobsters doctor max RSS `53690368` bytes, Lobsters
coverage-template max RSS `54018048` bytes, generic_blog_app doctor max RSS
`48332800` bytes, and generic_blog_app coverage-template max RSS `48234496` bytes.
Artifacts: `tmp/gc-stat-doctor-lobsters.json`,
`tmp/lobsters-ruby405-rails813/tmp/gc-stat-lobsters-template.yml`,
`tmp/gc-stat-doctor-mp.json`, and
`generic_blog_app/tmp/gc-stat-mp-template.yml`.
No request RSS benchmark was run for this milestone, so the generic_blog_app `40%`
target remains open.
Measurement-context verification follow-up rejects production measurements that
declare a mismatched profile id or coverage digest. Sequential static smokes
still passed: Lobsters doctor max RSS `53903360` bytes, Lobsters
coverage-template max RSS `53592064` bytes, generic_blog_app doctor max RSS
`47939584` bytes, and generic_blog_app coverage-template max RSS `48431104` bytes.
Artifacts: `tmp/measurement-context-doctor-lobsters.json`,
`tmp/lobsters-ruby405-rails813/tmp/measurement-context-lobsters-template.yml`,
`tmp/measurement-context-doctor-mp.json`, and
`generic_blog_app/tmp/measurement-context-mp-template.yml`.
No request RSS benchmark was run for this milestone, so the generic_blog_app `40%`
target remains open.
Measurement-path verification follow-up rejects coverage-bound request
measurements that omit reviewed request paths. Sequential static smokes still
passed: Lobsters doctor max RSS `53657600` bytes, Lobsters coverage-template max
RSS `53886976` bytes, generic_blog_app doctor max RSS `47808512` bytes, and
generic_blog_app coverage-template max RSS `48267264` bytes. Artifacts:
`tmp/measurement-paths-doctor-lobsters.json`,
`tmp/lobsters-ruby405-rails813/tmp/measurement-paths-lobsters-template.yml`,
`tmp/measurement-paths-doctor-mp.json`, and
`generic_blog_app/tmp/measurement-paths-mp-template.yml`.
No request RSS benchmark was run for this milestone, so the generic_blog_app `40%`
target remains open.
Measurement-identity verification follow-up rejects production measurements
that omit profile id, coverage digest, or Rails env, and keeps explicit
environment measurements out of request-path checks. Sequential static smokes
still passed: Lobsters doctor max RSS `53690368` bytes, Lobsters
coverage-template max RSS `54247424` bytes, generic_blog_app doctor max RSS
`47939584` bytes, and generic_blog_app coverage-template max RSS `48414720` bytes.
Artifacts: `tmp/measurement-identity-doctor-lobsters.json`,
`tmp/lobsters-ruby405-rails813/tmp/measurement-identity-lobsters-template.yml`,
`tmp/measurement-identity-doctor-mp.json`, and
`generic_blog_app/tmp/measurement-identity-mp-template.yml`.
No request RSS benchmark was run for this milestone, so the generic_blog_app `40%`
target remains open.
Measurement-workload verification follow-up rejects coverage-bound production
measurements that omit reviewed workload names. Sequential static smokes still
passed: Lobsters doctor max RSS `53673984` bytes, Lobsters coverage-template max
RSS `54460416` bytes, generic_blog_app doctor max RSS `48365568` bytes, and
generic_blog_app coverage-template max RSS `48922624` bytes. Artifacts:
`tmp/measurement-workloads-doctor-lobsters.json`,
`tmp/lobsters-ruby405-rails813/tmp/measurement-workloads-lobsters-template.yml`,
`tmp/measurement-workloads-doctor-generic-blog.json`, and
`generic_blog_app/tmp/measurement-workloads-generic-blog-template.yml`.
No request RSS benchmark was run for this milestone, so the generic_blog_app
`40%` target remains open.
Measurement-target verification follow-up rejects production measurements that
omit or use an unsupported target, and request-path checks now require an
explicit `requests` target. Sequential static smokes still passed: Lobsters
doctor max RSS `53985280` bytes, Lobsters coverage-template max RSS `54345728`
bytes, generic_blog_app doctor max RSS `48545792` bytes, and generic_blog_app
coverage-template max RSS `48513024` bytes. Artifacts:
`tmp/measurement-target-doctor-lobsters.json`,
`tmp/lobsters-ruby405-rails813/tmp/measurement-target-lobsters-template.yml`,
`tmp/measurement-target-doctor-generic-blog.json`, and
`generic_blog_app/tmp/measurement-target-generic-blog-template.yml`.
No request RSS benchmark was run for this milestone, so the generic_blog_app
`40%` target remains open.
Request-measurement verification follow-up rejects `disable_eager_load`
production approval unless the measurement artifact uses `target: requests`
after the latency policy is present. Sequential static smokes still passed:
Lobsters doctor max RSS `53968896` bytes, Lobsters coverage-template max RSS
`54165504` bytes, generic_blog_app doctor max RSS `48119808` bytes, and
generic_blog_app coverage-template max RSS `48660480` bytes. Artifacts:
`tmp/request-measurement-doctor-lobsters.json`,
`tmp/lobsters-ruby405-rails813/tmp/request-measurement-lobsters-template.yml`,
`tmp/request-measurement-doctor-generic-blog.json`, and
`generic_blog_app/tmp/request-measurement-generic-blog-template.yml`.
No request RSS benchmark was run for this milestone, so the generic_blog_app
`40%` target remains open.

## what eats memory

RSS is not additive by Rails framework, so these rows are attribution signals,
not exact framework memory ownership. The measurement can prove process RSS,
loaded Rails feature counts, opt-in ObjectSpace class-size deltas, and GC stat
deltas.

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
