# production readiness

Production use is app-specific. Build a deterministic profile, prove it against
coverage and runtime evidence, measure it, then ship only a reviewed patch.

## flow

```bash
bundle exec rails-dependency-pruner doctor --app .
bundle exec rails-dependency-pruner coverage template --app . --write config/pruner_coverage.yml
bundle exec rails-dependency-pruner runtime collect --app . --coverage config/pruner_coverage.yml --output tmp/pruner-runtime.json
bundle exec rails-dependency-pruner plan --app . --coverage config/pruner_coverage.yml --runtime-evidence tmp/pruner-runtime.json
bundle exec rails-dependency-pruner measure ablation --app . --profile config/rails_dependency_pruner_profile.json --coverage config/pruner_coverage.yml --target requests --request-paths /,/login,/health --output tmp/pruner-ablation.json --markdown tmp/pruner-ablation.md
bundle exec rails-dependency-pruner approve --app . --profile config/rails_dependency_pruner_profile.json --coverage config/pruner_coverage.yml --measurement tmp/pruner-ablation.json
bundle exec rails-dependency-pruner rollout --app . --profile config/rails_dependency_pruner_profile.json --coverage config/pruner_coverage.yml --patch tmp/pruner-rollout.patch
```

Review and apply `tmp/pruner-rollout.patch` in the app repo. The command does
not edit the app.

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

## production gates

A profile is ready only when:

- `approve` exits with verifier errors `0`
- the coverage digest in the profile matches the reviewed manifest
- source, environment, bundle, runtime evidence, and profile fingerprints match
- request, job, mail, storage, cable, and task coverage covers the transforms
- lazy gems are classified in `config/rails_dependency_pruner/gem_policies.yml`
- canary has no unexpected boot or request events
- RSS savings satisfy the app memory policy
- first request, p95, and p99 latency regressions satisfy the app policy

Start with `RAILS_DEPENDENCY_PRUNER_MODE=canary`. Move to production only with a
matching `RAILS_DEPENDENCY_PRUNER_PROFILE_ID` and a rollback path through
`RAILS_DEPENDENCY_PRUNER_DISABLE=1`.
