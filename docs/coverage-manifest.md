# coverage manifest

`config/pruner_coverage.yml` is the app-owner contract for a production
profile. It says which workloads were reviewed and which transforms those
workloads are allowed to justify.

Generate a starter file:

```bash
bundle exec rails-dependency-pruner coverage template \
  --app . \
  --write config/pruner_coverage.yml
```

The generated file is not proof. Sections marked `review_required: true` must
be edited before production approval counts them.

## reviewed sections

Use version `2` for production profiles:

```yaml
version: 2
rails_env: production
boot:
  eager_load: true
routes:
  review_required: false
  include: all
requests:
  review_required: false
  paths:
    - method: GET
      path: /health
      expected_status: 200
  web_servers:
    - server: puma
      mode: clustered
      clustered: true
      coverage_required:
        - requests
jobs:
  review_required: false
  classes:
    - CleanupJob
  queue_adapters:
    - adapter: solid_queue
      gem: solid_queue
      class: job_adapter
      risk: medium
mailers:
  review_required: false
  actions:
    - UserMailer#welcome
  delivery_methods:
    - environment: production
      method: smtp
      risk: medium
  smtp_settings:
    - path: config/initializers/email.rb
      risk: medium
channels:
  review_required: false
  classes:
    - NotificationsChannel
  cable_adapters:
    - environment: production
      adapter: redis
      gem: redis
      class: cable_adapter
      risk: medium
inbound_email:
  review_required: false
  mailboxes:
    - ApplicationMailbox
active_storage:
  review_required: false
  declarations_expected: false
  configured_services:
    - environment: production
      service: local
      adapter: Disk
      risk: low
  service_definitions:
    - name: local
      adapter: Disk
      risk: low
  declarations:
    - class: Avatar
      kind: has_one_attached
      name: image
  upload: false
  analyze: false
  variant: false
  preview: false
  representation: false
  attachment_read: false
action_text:
  review_required: false
  rich_text_expected: false
  declarations:
    - class: Avatar
      name: bio
rake_tasks:
  review_required: false
  tasks:
    - assets:precompile
    - maintenance:sweep
lazy_gems:
  ruby-vips:
    review_required: false
    status: manual_app_use
    constants:
      - Vips
external_integrations:
  rack-mini-profiler:
    review_required: false
    status: disabled_in_production
    class: middleware_integration
    risk: medium
    strategies:
      - noop_shim
  sentry-rails:
    review_required: false
    status: disabled_in_profile
    class: railtie_integration
    risk: high
    strategies:
      - disabled_in_profile
  sentry-ruby:
    review_required: false
    status: covered
    class: sdk_integration
    risk: high
    strategies:
      - lazy_constant
canary:
  review_required: false
  duration_minutes: 60
  request_count: 100
  unexpected_events_count: 0
  min_duration_minutes: 60
  min_request_count: 10000
rollback:
  review_required: false
  disable_env_tested: true
  env_var: RAILS_DEPENDENCY_PRUNER_DISABLE
```

For `disable_eager_load`, job classes, mailer actions, channel classes,
mailboxes, Active Storage attachments, and Action Text rich-text declarations
and rake tasks are matched by exact entry. A reviewed `jobs` section that omits
`ReportJob` does not cover first use of `ReportJob`; an `active_storage`
section that omits `Avatar#image` does not cover that attachment, an
`action_text` section that omits `Avatar#bio` does not cover that rich-text
field, and a `rake_tasks` section that omits `maintenance:sweep` does not cover
that task.

Production verification fails when a transform needs a workload that is missing
or still marked for review. Active Storage declarations alone do not count as
attachment coverage; at least one reviewed storage action must be true.

Generated `jobs.queue_adapters` entries show configured
`config.active_job.queue_adapter` values. They are review context for job
coverage and do not replace exact job class coverage.
Generated `requests.web_servers` entries show static web server topology, such
as Puma single or clustered mode. They are review context for request coverage
and do not replace exact request path coverage.
Generated `mailers.delivery_methods` and `mailers.smtp_settings` entries show
mail delivery configuration. They are review context for mailer coverage and do
not replace exact mailer action coverage.
Generated `channels.cable_adapters` entries show `config/cable.yml` adapters.
They are review context for Action Cable coverage and do not replace exact
channel class coverage.
Generated `active_storage.configured_services` and `service_definitions`
entries show the configured storage backend. They are review context for Active
Storage coverage and do not replace upload, analysis, variant, preview,
representation, or attachment-read coverage.
Context-only entries do not add workloads to the manifest digest or production
proof; exact classes, actions, declarations, request paths, or task names do.
Reviewed empty exact lists, such as `mailers.actions: []`, can declare that the
workload was checked and absent when no generated context entry is standing in
for proof.

If a lazy gem is used directly by app code, the manifest must also review that
first-use surface under `lazy_gems`. Accepted statuses are `covered`,
`first_use_covered`, `manual_app_use`, `not_on_boot_path`, and
`not_on_request_path`. A generated template leaves these entries as
`review_required: true` until the app owner confirms the request or manual path
that can load the constant.

Lazy or stubbed middleware and Railtie integration gems also need reviewed
`external_integrations` entries. Generated entries may include class, risk, and
strategy metadata, but they still do not count while `review_required: true`.

## policy sections

`memory_policy` defines the RSS and latency gates used by approval and ablation
assessment:

```yaml
memory_policy:
  min_total_savings_mib: 20
  min_total_savings_percent: 10
  min_transform_savings_mib: 2
  max_first_request_latency_regression_ms: 100
  max_warmed_p95_latency_regression_percent: 5
  max_warmed_p99_latency_regression_percent: 10
```

`safety_policy` may repeat the generated fail-closed defaults. It must not
weaken them for production approval.

For v2 manifests, `canary` must be reviewed before production approval. The
sample passes when `unexpected_events_count` is `0` and either the duration or
request count reaches the configured minimum.

Generic overrides can approve a known dynamic edge by path:

```yaml
overrides:
  - id: allow_dynamic_constantize_admin_reports
    reason: "Admin reports constantize only app-owned report classes"
    owner: "platform-team"
    expires_at: "2026-08-31"
    paths:
      - app/services/report_runner.rb
```

An override must have an id, owner, reason, future expiry, and at least one
path. Valid entries are copied into the profile and are part of the profile
digest. They currently apply to dynamic `require` or `load` edges and dynamic
constantization risks for the listed files.

High-risk overrides are temporary and explicit:

```yaml
high_risk_overrides:
  stub_active_storage_vips_analyzer:
    accepted_by: "app owner"
    reason: "no Active Storage image analysis in production"
    expires_at: "2026-09-01"
```

Expired or incomplete overrides do not count. Prefer reviewed workload coverage
when the app can express the real contract.
