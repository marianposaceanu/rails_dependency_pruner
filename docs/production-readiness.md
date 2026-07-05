# production readiness

Production use is app-specific. Build a deterministic profile, prove it against
coverage and runtime evidence, measure it, then ship only a reviewed patch.
Rails and app-shape support is tracked in `rails-version-support.md`.

## flow

```bash
bundle exec rails-dependency-pruner doctor --app .
bundle exec rails-dependency-pruner coverage template --app . --write config/pruner_coverage.yml
bundle exec rails-dependency-pruner runtime collect --app . --coverage config/pruner_coverage.yml --output tmp/pruner-runtime.json
bundle exec rails-dependency-pruner plan --app . --coverage config/pruner_coverage.yml --runtime-evidence tmp/pruner-runtime.json
bundle exec rails-dependency-pruner measure ablation --app . --profile config/rails_dependency_pruner_profile.json --coverage config/pruner_coverage.yml --target requests --request-paths /,/login,/health --process-memory-details --output tmp/pruner-ablation.json --markdown tmp/pruner-ablation.md
bundle exec rails-dependency-pruner approve --app . --profile config/rails_dependency_pruner_profile.json --coverage config/pruner_coverage.yml --measurement tmp/pruner-ablation.json --approved-by release-owner
bundle exec rails-dependency-pruner rollout --app . --profile config/rails_dependency_pruner_profile.json --coverage config/pruner_coverage.yml --patch tmp/pruner-rollout.patch
```

If environment and request measurements are captured separately, use
`--measurements tmp/pruner-environment.json,tmp/pruner-requests.json` at
approval time.

Review and apply `tmp/pruner-rollout.patch` in the app repo. The command does
not edit the app. See `rollout.md` for shadow, canary, production, and rollback
steps.

## rollout patch

The patch can include:

- `config/application.rb` replacement of `rails/all` or comments for pruned
  explicit railtie requires
- `config/boot.rb` early boot shim
- `config/environments/production.rb` config enabling the reviewed profile
- `config/rails_dependency_pruner_profile.json`
- `config/pruner_coverage.yml`

If `--coverage` is omitted, the patch includes a generated coverage template.
Generated workload sections still need review before production approval.
The coverage contract is described in `coverage-manifest.md`.
The generated production config is gated by
`RAILS_DEPENDENCY_PRUNER_ENABLED=1`; early boot can also be bypassed with
`RAILS_DEPENDENCY_PRUNER_DISABLE=1`.
Pruned railtie comments include the transform ids and, when the profile has
per-framework explanations, the profile proof key that justified the transform.

## production gates

A profile is ready only when:

- `approve` exits with verifier errors `0`
- the coverage digest in the profile matches the reviewed manifest
- coverage-bound measurement artifacts declare their target and name the same
  profile id, coverage digest, Rails env, and reviewed workload names, and
  request measurements cover the reviewed request paths
- measurement suites include both environment and request targets when separate
  artifacts are used
- source, environment, bundle, runtime evidence, and profile fingerprints match
- request, job, mail, storage, Action Text, cable, and task coverage covers the
  transforms
- lazy gems are classified in `config/rails_dependency_pruner/gem_policies.yml`
- lazy or stubbed integration gems have reviewed `external_integrations`
  production status
- canary event evidence passed through `--runtime-evidence` has no unexpected
  boot or request events
- v2 coverage records reviewed canary evidence with zero unexpected events and
  enough duration or request volume
- v2 coverage records reviewed rollback evidence with
  `rollback.disable_env_tested: true`
- RSS savings satisfy the app memory policy
- first request, p95, and p99 latency regressions satisfy the app policy
- request-target measurements keep the same status matrix as baseline and have
  no request errors or unexpected runtime events
- `safety_policy` keeps the generated fail-closed defaults
- the approved profile records `approved_at`, `approved_by`, verifier version,
  and verifier errors/warnings

Start with `RAILS_DEPENDENCY_PRUNER_MODE=canary`. Move to production only with a
matching `RAILS_DEPENDENCY_PRUNER_PROFILE_ID` and a rollback path through
`RAILS_DEPENDENCY_PRUNER_DISABLE=1`.
