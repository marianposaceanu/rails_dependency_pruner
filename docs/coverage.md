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
- set reviewed workload sections to `review_required: false`
- remove sections that are not covered
- add storage, inbound email, job, mailer, and channel coverage when those flows
  exist in production
- keep `rake_tasks` to the production tasks covered by the release process

The parser accepts v1-style simple arrays and v2 review sections. `channels`
normalizes to the existing `cable` workload name, and reviewed `active_storage`
coverage normalizes to `attachments` only when a storage action such as upload,
analyze, variant, preview, or representation is marked covered. A declaration
inventory by itself is not attachment coverage.
