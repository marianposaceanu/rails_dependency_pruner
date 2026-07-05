# rollout

Production rollout is a reviewed app patch plus a profile id gate. The command
writes a patch; it does not edit the app.

```bash
bundle exec rails-dependency-pruner rollout \
  --app . \
  --profile config/rails_dependency_pruner_profile.json \
  --coverage config/pruner_coverage.yml \
  --patch tmp/pruner-rollout.patch
```

Review the patch before applying it. It can include:

- `config/application.rb` boot-plan changes
- `config/boot.rb` early boot shim
- `config/environments/production.rb` env-gated profile config
- `config/rails_dependency_pruner_profile.json`
- `config/pruner_coverage.yml`

## deploy sequence

Start with shadow mode:

```bash
RAILS_DEPENDENCY_PRUNER_EARLY=1 \
RAILS_DEPENDENCY_PRUNER_MODE=shadow \
RAILS_DEPENDENCY_PRUNER_PROFILE=config/rails_dependency_pruner_profile.json \
RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT=tmp/pruner-shadow.json \
bundle exec puma
```

Shadow records would-block and would-lazy events without changing behavior.

Move to canary with the approved profile id:

```bash
RAILS_DEPENDENCY_PRUNER_EARLY=1 \
RAILS_DEPENDENCY_PRUNER_MODE=canary \
RAILS_DEPENDENCY_PRUNER_PROFILE_ID=sha256:... \
RAILS_DEPENDENCY_PRUNER_EVENT_LOG=tmp/pruner-events.ndjson \
bundle exec puma
```

Canary applies the profile and fails on unexpected events according to the
profile policy.

Production mode also requires the matching profile id:

```bash
RAILS_DEPENDENCY_PRUNER_EARLY=1 \
RAILS_DEPENDENCY_PRUNER_MODE=production \
RAILS_DEPENDENCY_PRUNER_PROFILE_ID=sha256:... \
bundle exec puma
```

The profile approval and id checks run while loading the early boot shim, before
later app boot code can mutate Rails state.

## gates

Do not roll forward unless:

- production approval has verifier errors `0`
- coverage, source, environment, bundle, runtime evidence, and measurement
  fingerprints match
- ablation marks the enabled transform set as usable
- request statuses match baseline and request errors are absent
- unexpected canary events are absent or explicitly handled by policy
- v2 coverage records reviewed canary duration or request volume
- rollback through `RAILS_DEPENDENCY_PRUNER_DISABLE=1` has been tested

## rollback

Set:

```bash
RAILS_DEPENDENCY_PRUNER_DISABLE=1
```

That bypasses early boot hooks. If needed, revert the reviewed rollout patch or
deploy the previous profile.
