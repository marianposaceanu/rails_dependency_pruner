# measurement

The measurement commands answer two different questions:

- how much process RSS changed
- which Rails and Ruby buckets moved when it changed

RSS is the hard process number. The Rails and Ruby buckets are attribution
signals. They explain where the win probably came from, but they are not
byte-exact ownership by framework.

## ablation

Run the approved profile one transform group at a time:

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

The command runs fresh processes sequentially. It generates temporary profiles
for each variant, measures them, then deletes those temporary profiles.

Variants are derived from the source profile:

- `baseline`
- `process_warmup`
- `skip_test_railtie_only`
- `disable_eager_load_only`
- `lazy_gems_only`
- `rack_mini_profiler_stub_only`
- `active_storage_vips_analyzer_stub_only`
- `rails_prune_plan_only`
- `all_low_risk_transforms`
- `all_approved_transforms`

Some variants are omitted when the source profile does not contain the matching
transform.

## memory policy

A coverage manifest can define a profile-level memory policy:

```yaml
memory_policy:
  min_total_savings_mib: 20
  min_total_savings_percent: 10
  preserve_at_least_percent_of_reference_savings: 80
  reference_savings_mib: 98.3
  reference_profile_id: sha256:...
```

The policy is copied into generated schema v3 profiles. Production verification
then requires a measurement artifact:

```bash
bundle exec rails-dependency-pruner approve \
  --app . \
  --profile config/rails_dependency_pruner_profile.json \
  --coverage config/pruner_coverage.yml \
  --measurement tmp/pruner-ablation.json
```

For ablation reports, the default candidate is `all_approved_transforms`. For
regular measurement reports, the default candidate is `boot_prune`. The policy
fails production approval when:

- the measurement artifact is missing
- baseline or candidate RSS is missing
- total saved RSS is below `min_total_savings_mib`
- total saved RSS is below `min_total_savings_percent`
- saved RSS is below the requested percentage of `reference_savings_mib`
- `reference_profile_id` is set and does not match the measurement profile id

`min_transform_savings_mib` can also be set for stricter local release checks.
It evaluates individual ablation transform groups and is intentionally harsh:
low-risk transforms that do not save RSS will fail that gate.

## what eats memory

The report records:

- process RSS from the measured child process
- total loaded features
- Rails loaded features grouped by framework gem
- `GC.stat[:heap_live_slots]`
- live Ruby object type counts from `ObjectSpace.count_objects`
- request status and response size for request-warmed runs

The Rails framework table groups loaded files by gem, for example
`activerecord`, `actionview`, `activestorage`, and `railties`. This is not a
byte ledger. It tells you which framework stopped loading code when RSS moved.
If `disable_eager_load_only` removes many `activerecord` and `actionview` files,
that is the Rails-side bucket to investigate first.

Use the tables together:

- ablation RSS says whether a transform actually saves process memory
- Rails loaded-feature deltas say which framework code stopped loading
- GC live slots say whether the win is visible in Ruby heap objects
- object type deltas say whether the heap movement is mostly strings, arrays,
  hashes, classes, `T_DATA`, or VM internals
- request statuses say whether the smaller process still behaves like the app

For the measured Lobsters profile, the Rails-side pressure is mostly boot-time
eager loading. The largest loaded-feature reductions are ActiveRecord first,
then Action View, Active Storage, Action Mailbox, Active Support, and railties.
The `lazy_gems_only` win is different: it saves RSS without reducing Rails
loaded-feature counts, so it points to app/gem boot surface rather than Rails
framework files.

The Ruby object table shows whether the heap-side movement mostly came from
`T_STRING`, `T_ARRAY`, `T_HASH`, `T_OBJECT`, or another Ruby object type. This
does not include all native memory. Native extension state, external string
buffers, VM tables, regexp data, array and hash backing storage, and `T_DATA`
payloads can still move RSS without showing up as Ruby slot savings.

For request workloads, trust a variant only when the request matrix still
returns the expected statuses. A smaller RSS number with a broken request is not
a valid memory win.
