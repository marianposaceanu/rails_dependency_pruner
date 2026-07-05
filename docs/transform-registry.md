# transform registry

Production profiles include a `transforms` list. It names every boot mutation
the profile asks the runtime to apply.

Generated deterministic profiles use schema v3. The registry is the
production-readiness layer that names and classifies every boot mutation in the
profile.

Each transform entry includes:

- stable `id`
- `kind`, `risk`, `description`, and source profile path
- expected memory effect
- required static, runtime, and coverage evidence
- allowed phases
- expected and disallowed events
- rollback behavior
- production eligibility rule

## current transform ids

Framework and boot-plan transforms:

- `disable_framework:<framework>`
- `prune_railtie:<path>`
- `ignore_autoload_path:<path>`
- `ignore_eager_load_path:<path>`

Extreme boot transforms:

- `disable_eager_load`
- `skip_railtie:<path>`
- `lazy_require:<path>`
- `lazy_gem:<name>`
- `stub:rack_mini_profiler`
- `stub:active_storage_vips_analyzer`

## production rules

Production verification fails when a profile has a boot mutation without a
matching transform id. It also fails when the transform list contains an
unknown id or when a registered transform is missing contract fields.

`lazy_gem:<name>` is registered only when the gem has a policy in
`config/rails_dependency_pruner/gem_policies.yml`. Unknown lazy gems stay out of
production approval. Lazy-gem transforms embed the policy used at profile
generation time so review can see the class, risk, strategies, and production
rule. See `lazy-gems.md` for the profile shape and rollout rules.

Generated profiles also copy the registry policy into top-level `lazy_gems`.
Production verification rejects a supported gem listed in
`extreme_boot.lazy_gems` when the structured entry is missing or no longer
matches the registry metadata.

Current policy classes:

- `pure_library`
- `native_heavy_library`
- `railtie_integration`
- `middleware_integration`
- `sdk_integration`
- `monkey_patch`
- `unsafe_unknown`

`railtie_integration`, `middleware_integration`, and `sdk_integration`
lazy-gem transforms require a reviewed `external_integrations` entry in the
coverage manifest. Generated templates use `review`, which is only a prompt.
Production approval requires a specific status such as
`disabled_in_production`, `disabled_in_profile`, `covered`, `not_used`, or
`no_production_dsn`.

`stub:active_storage_vips_analyzer` is high risk. It is allowed only when the
app has no Active Storage attachment DSL usage or when the coverage manifest
proves the storage actions that can reach analysis behavior: upload, analyze,
variant, preview, representation, and attachment read. A reviewed
`high_risk_overrides.stub_active_storage_vips_analyzer` entry can approve the
stub temporarily, but it must include `accepted_by`, `reason`, and a future
`expires_at` date. The stub makes the Active Storage Vips analyzer decline
instead of loading `ruby-vips` during boot. Direct app use of `Vips` can still
lazy-load `ruby-vips`. See `active-storage-vips-analyzer.md` for the proof and
rollback checklist.

`disable_eager_load` is medium risk. Production verification requires request
coverage, a request-target measurement artifact, memory policy gates for first
request, p95, and p99 latency, loaded feature medians and Rails framework
feature deltas, request event counters, and reviewed exact coverage for
app-declared job classes, mailer actions, and channel classes. It also requires
exact inbound email mailbox coverage, Active Storage attachment declaration and
action coverage, exact Action Text rich-text declaration coverage, exact rake
task coverage, and mounted Rack app or engine paths. RSS savings alone are not
enough because this transform can move work from boot to first use.

`skip_railtie:active_storage/engine` requires full reviewed Active Storage
action coverage when the app declares attachments: upload, analyze, variant,
preview, representation, and attachment read. The generic `attachments` workload
only proves that storage was touched; it does not prove the railtie skip's full
surface.

## why this exists

The old profile shape could say `lazy_gems: ["ruby-vips"]`, but that hid two
different changes:

- defer the `ruby-vips` gem until direct `Vips` use;
- change Active Storage analyzer selection during boot.

The transform registry makes those changes separate and reviewable. It also
gives later work a stable place for event manifests, ablation results, and
coverage requirements.
