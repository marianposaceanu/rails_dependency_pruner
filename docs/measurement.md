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

## what eats memory

The report records:

- process RSS from the measured child process
- total loaded features
- Rails loaded features grouped by framework gem
- `GC.stat[:heap_live_slots]`
- live Ruby object type counts from `ObjectSpace.count_objects`
- request status and response size for request-warmed runs

The Rails framework table groups loaded files by gem, for example
`activerecord`, `actionview`, `activestorage`, and `railties`. If
`disable_eager_load_only` removes many `activerecord` and `actionview` files,
that is the Rails-side bucket to investigate first.

The Ruby object table shows whether the heap-side movement mostly came from
`T_STRING`, `T_ARRAY`, `T_HASH`, `T_OBJECT`, or another Ruby object type. This
does not include all native memory. Native extension state, external string
buffers, VM tables, regexp data, array and hash backing storage, and `T_DATA`
payloads can still move RSS without showing up as Ruby slot savings.

For request workloads, trust a variant only when the request matrix still
returns the expected statuses. A smaller RSS number with a broken request is not
a valid memory win.
