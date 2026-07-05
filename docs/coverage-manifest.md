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
jobs:
  review_required: false
  classes: []
mailers:
  review_required: false
  actions: []
channels:
  review_required: false
  classes: []
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
rake_tasks:
  review_required: false
  tasks:
    - assets:precompile
rollback:
  review_required: false
  disable_env_tested: true
  env_var: RAILS_DEPENDENCY_PRUNER_DISABLE
```

Production verification fails when a transform needs a workload that is missing
or still marked for review. Active Storage declarations alone do not count as
attachment coverage; at least one reviewed storage action must be true.

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
