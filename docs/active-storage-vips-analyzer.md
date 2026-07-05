# Active Storage Vips analyzer

`stub:active_storage_vips_analyzer` makes Active Storage's Vips analyzer decline
instead of loading `ruby-vips` during boot. It can save significant RSS for apps
that do not use Active Storage image analysis, but it changes analyzer
selection behavior and is high risk.

Direct app calls to `Vips` are separate. They can still lazy-load `ruby-vips`
through the structured lazy constant policy.

## required proof

Production approval requires one of these:

- static proof that the app declares no Active Storage attachments
- reviewed coverage for upload, analyze, variant, preview, representation, and
  attachment read paths
- an unexpired `high_risk_overrides.stub_active_storage_vips_analyzer` entry

The override form is:

```yaml
high_risk_overrides:
  stub_active_storage_vips_analyzer:
    accepted_by: "app owner"
    reason: "no Active Storage image analysis in production"
    expires_at: "2026-09-01"
```

Use the override only when coverage cannot express the app's real production
contract.

## how to test

Run `doctor` first. It reports attachment DSL declarations and direct `Vips`
usage:

```bash
bundle exec rails-dependency-pruner doctor --app . --json
```

For apps with attachments, review and run storage coverage before approval:

```yaml
active_storage:
  review_required: false
  declarations_expected: true
  upload: true
  analyze: true
  variant: true
  preview: true
  representation: true
  attachment_read: true
```

Measure the stub in ablation. A useful report should show the
`active_storage_vips_analyzer_stub_only` variant, preserved request statuses,
zero unexpected events, and acceptable first-use latency.

## rollback

Set `RAILS_DEPENDENCY_PRUNER_DISABLE=1` to bypass the hook. For a patch rollout,
remove `ruby-vips` from the generated lazy-gem profile or restore the previous
profile.
