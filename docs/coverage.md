# coverage

Coverage manifests describe the workloads a production profile is allowed to
claim.

Generate a starter manifest:

```bash
bundle exec rails-dependency-pruner coverage template \
  --app . \
  --write config/pruner_coverage.yml
```

The command is static. It reuses the same app scan as `doctor` and does not boot
Rails.

Generated workload sections are marked `review_required: true`. The verifier
does not count those sections as coverage proof until the file is edited. This
keeps the template from approving a transform just because the app contains
`app/jobs`, `app/mailers`, channels, attachment declarations, or routes.

Typical review steps:

- replace guessed request entries with the paths and statuses actually exercised
- review mounted Rack app and engine paths generated from route `mount` calls
- set reviewed workload sections to `review_required: false`
- remove sections that are not covered
- add storage, Action Text, inbound email, job, mailer, and channel coverage
  when those flows exist in production
- keep generated job classes, mailer actions, channel classes, mailboxes,
  storage or rich-text declarations, and rake task names only when the exact
  entries were covered
- replace external integration `review` placeholders with a reviewed production
  status before lazying or stubbing integration gems
- keep `rake_tasks` to the production tasks covered by the release process;
  generated templates include `assets:precompile`, `db:migrate`, and static
  candidates found in `Rakefile` or `lib/tasks/**/*.rake`
- set `rollback.review_required: false` and `rollback.disable_env_tested: true`
  only after testing `RAILS_DEPENDENCY_PRUNER_DISABLE=1`

The parser accepts v1-style simple arrays and v2 review sections. `channels`
normalizes to the existing `cable` workload name, and reviewed `active_storage`
coverage normalizes to `attachments` only when a storage action such as upload,
analyze, variant, preview, representation, or attachment read is marked covered.
A declaration inventory by itself is not attachment coverage.

Production verification also checks coverage required by the Rails feature
catalog. For example, Active Storage catalog evidence requires the normalized
`attachments` workload before an Active Storage railtie skip can be approved.
When the app declares Active Storage attachments, skipping `active_storage/engine`
also requires reviewed upload, analyze, variant, preview, representation, and
attachment-read coverage. A single `attachments` workload marker is not enough
for that railtie skip.
Action Text pruning requires reviewed `action_text` coverage, even when the
review says rich-text declarations are not expected in production.
When `disable_eager_load` is enabled, declared job classes, mailer actions,
channel classes, inbound email mailboxes, and rich-text declarations must be
covered by exact manifest entries such as `jobs.CleanupJob`,
`mailers.UserMailer#welcome`, `channels.NotificationsChannel`,
`inbound_email.ApplicationMailbox`, and `action_text.Avatar#bio`.
Active Storage attachments are exact too, such as `attachments.Avatar#image`,
and still require at least one reviewed storage action to prove the broader
`attachments` workload.
When `disable_eager_load` is enabled, app-defined rake tasks also require
reviewed exact entries such as `rake_tasks.maintenance:sweep` because task
constants may move from boot to first use.
Mounted Rack apps and engines require reviewed request coverage for each mount
path when `disable_eager_load` is enabled.
Lazy or stubbed middleware and Railtie integration gems, such as
`rack-mini-profiler` and `sentry-rails`, require a reviewed
`external_integrations` status. Accepted statuses are `covered`,
`disabled`, `disabled_in_profile`, `disabled_in_production`,
`disabled_in_test_profile`, `no_production_dsn`, and `not_used`.
For v2 manifests, production verification also requires reviewed rollback
evidence through `rollback.disable_env_tested: true` and reviewed canary
evidence with zero unexpected events.

Coverage can include a `safety_policy` section, but generated profiles still
fail closed. Production verification rejects policy entries that weaken the
default rejection behavior for dynamic loads, missing coverage, unexpected
events, stale fingerprints, or unclassified and high-risk transforms.

Generic `overrides` entries can approve a known dynamic `require`, `load`, or
constantization edge for specific paths. They must include an id, owner, reason,
future expiry, and paths. Valid entries are copied into the profile digest.

High-risk overrides are explicit and temporary:

```yaml
high_risk_overrides:
  stub_active_storage_vips_analyzer:
    accepted_by: "app owner"
    reason: "no Active Storage image analysis in production"
    expires_at: "2026-09-01"
```

Use an override only when reviewed coverage cannot express the app's real
contract. Expired or incomplete overrides do not count.
