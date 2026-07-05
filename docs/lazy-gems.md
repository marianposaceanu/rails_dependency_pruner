# lazy gems

Lazy gems are boot-time deferrals. They are production-eligible only when the
gem has a registry policy and the profile records the structured lazy-gem
contract used at planning time.

## profile shape

The profile keeps both the requested boot mutation and the reviewed policy:

```json
{
  "extreme_boot": {
    "lazy_gems": ["rack-mini-profiler"]
  },
  "lazy_gems": {
    "rack-mini-profiler": {
      "gem": "rack-mini-profiler",
      "strategy": "noop_shim",
      "strategies": ["noop_shim"],
      "boot_require_blocked": true,
      "high_risk": false
    }
  }
}
```

Production verification rejects an unknown lazy gem and rejects a known gem when
the structured entry is missing or no longer matches the registry policy.

## policy classes

The registry classes are:

- `pure_library`
- `native_heavy_library`
- `railtie_integration`
- `middleware_integration`
- `monkey_patch`
- `unsafe_unknown`

`railtie_integration` and `middleware_integration` gems require a reviewed
`external_integrations` entry in the coverage manifest. Accepted statuses
include `disabled_in_production`, `disabled_in_profile`, `covered`, `not_used`,
and `no_production_dsn`.

## phases

Lazy constants can declare allowed and disallowed phases. Canary and production
modes record every lazy load event. Canary rejects unexpected or disallowed
events. Production fails closed for unexpected boot events and reports request
events unless the profile asks for stricter behavior.

The lazy constant list is an allowlist from the gem policy registry. Production
verification rejects extra `lazy_constants` entries, even when they point to an
approved lazy gem.

## measuring

Use ablation to keep only lazy-gem groups that actually save RSS:

```bash
bundle exec rails-dependency-pruner measure ablation \
  --app . \
  --profile config/rails_dependency_pruner_profile.json \
  --coverage config/pruner_coverage.yml \
  --target requests \
  --request-paths /,/login,/health \
  --runs 5 \
  --output tmp/pruner-ablation.json \
  --markdown tmp/pruner-ablation.md
```

The ablation policy classifies transform groups as `production_candidate`,
`not_worth_enabling`, `unsafe_for_production`, or `forced`.

## rollback

Use `RAILS_DEPENDENCY_PRUNER_DISABLE=1` to bypass early boot hooks. For a
reviewed app patch, remove the generated rollout patch or restore the gem to
normal boot loading.
