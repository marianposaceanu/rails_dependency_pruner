# profile schema

Generated deterministic profiles use schema v3.

Schema v3 keeps the old v2 sections for compatibility, but adds production
readiness fields:

- `tool`: gem name, gem version, and optional build git sha
- `environment`: Ruby, Rails, Bundler, platform, Rails env, and Bundler groups
- `fingerprints`: material input digests
- `transforms`: registered boot mutations
- `expected_events`: events expected from registered transforms
- `unexpected_event_policy`: how safety modes handle new runtime events
- `lazy_constants`: optional phase policy for lazy top-level constants
- `memory_policy`: optional RSS savings gates copied from the coverage manifest

`analysis.feature_catalog` records the Rails feature catalog name, Rails minor
version, and catalog digest used by the static scanner.

The profile id is stored in both `profile_id` and
`fingerprints.profile_id` while v2 compatibility remains. The digest ignores
both id fields.

## safety approval

Unapproved profiles carry `safety.production_allowed: false` and empty approval
metadata. After `approve` succeeds, the profile records:

- `approved_at`
- `approved_by`
- `verifier_version`
- verifier `errors`
- verifier `warnings`

Approval metadata changes the profile digest, so the approved profile gets a new
`profile_id`. Semantic profile diffs ignore approval metadata.

## transform contract

Each transform entry must carry the production contract from the registry:

- expected memory effect
- required static, runtime, and coverage evidence
- allowed phases
- expected and disallowed events
- rollback behavior
- production eligibility rule

Production verification rejects registered transform entries that are missing
any contract field.

When static evidence blocks an extreme-boot transform,
`production_risks.extreme_boot_static_matches` includes the matched catalog
pattern, owned railties, required coverage sections, and negative rules.

## fingerprints

Production validation compares the current app against the profile. These
inputs are material:

- `Gemfile`
- `Gemfile.lock`
- `.bundle/config`
- `config/application.rb`
- `config/boot.rb`
- `config/environment.rb`
- `config/environments/*.rb`
- `config/initializers/**/*.rb`
- `config/routes.rb`
- `config/routes/**/*.rb`
- `app/**/*.rb`
- `lib/**/*.rb`
- `engines/*/app/**/*.rb`
- `engines/*/config/**/*.rb`
- the coverage manifest
- runtime evidence files

Files under `tmp`, `vendor/bundle`, and `node_modules` are ignored.

## memory policy

When `memory_policy` is present, production approval must receive a measurement
or ablation JSON file through `--measurement`. The verifier compares the
baseline RSS with `boot_prune` for regular measurements, or with
`all_approved_transforms` for ablations.

Supported gates:

- `min_total_savings_mib`
- `min_total_savings_percent`
- `max_first_request_latency_regression_ms`
- `max_first_request_latency_regression_percent`
- `max_request_p95_latency_regression_ms`
- `max_request_p95_latency_regression_percent`
- `max_request_p99_latency_regression_ms`
- `max_request_p99_latency_regression_percent`
- `max_warmed_p95_latency_regression_ms`
- `max_warmed_p95_latency_regression_percent`
- `max_warmed_p99_latency_regression_ms`
- `max_warmed_p99_latency_regression_percent`
- `preserve_at_least_percent_of_reference_savings`
- `reference_savings_kb` or `reference_savings_mib`
- `reference_profile_id`
- `min_transform_savings_mib`

Production verification also uses these gates as proof for high-risk transforms.
For `disable_eager_load`, the policy must include first request, p95, and p99
latency regression limits.

## runtime events

Early boot writes structured events for skipped, deferred, blocked, stubbed, and
lazy-loaded require paths. Events include:

- `event_id`
- `phase`
- `action`
- `path`
- `matched_path`
- `gem`
- `transform_id`
- `caller_path`
- `caller_line`
- `pid`
- `expected`

When an early-boot output JSON is passed back through `--runtime-evidence`, the
profile stores `summary.runtime_event_summary`. Production verification rejects
profiles whose runtime event summary contains unexpected events.

Safety modes compare every event with `expected_events`. Expected event entries
are partial matches, so a profile can match on `phase`, `action`, `path`, and
`gem` without pinning caller lines.

Supported `unexpected_event_policy` values:

- `fail_boot`: fail canary and production for unexpected boot events
- `fail_all`: fail canary and production for any unexpected event
- `report`: record unexpected events without raising
- `fail_in_canary_report_in_production`: fail canary, and still fail closed for
  production boot events

Lazy constant policies are keyed by exact top-level constant name:

```json
{
  "lazy_constants": {
    "Vips": {
      "gem": "ruby-vips",
      "require": "vips",
      "allowed_phases": ["manual_app_use"],
      "disallowed_phases": ["boot"]
    }
  }
}
```

When the global `const_missing` hook sees a configured constant, it records the
owner, caller path, caller line, phase, gem, and require path. A strict canary or
production boot fails if the constant is reached outside the declared phase or
if the policy points at a gem that is not approved in `extreme_boot.lazy_gems`.
Unconfigured constants are ignored by the lazy loader.

Telemetry is opt-in:

- `RAILS_DEPENDENCY_PRUNER_EVENT_LOG=tmp/pruner-events.ndjson` appends one JSON
  object per event
- `RAILS_DEPENDENCY_PRUNER_EVENT_STDERR=1` mirrors the same JSON to stderr
- when `ActiveSupport::Notifications` is already loaded, events are instrumented
  as `event.rails_dependency_pruner`

The telemetry payload includes `component`, `profile_id`, `mode`, `event`,
`event_id`, `phase`, `path`, `matched_path`, `gem`, `constant`, `transform_id`,
`expected`, `caller`, `caller_path`, `caller_line`, and `pid` when available.

## migration

`ProfileSchema.migrate_v2` can project a v2 payload into the v3 shape for
review or tooling. It is not used to silently approve old profiles as new
profiles; v2 profiles remain readable and validated through the legacy fields.
