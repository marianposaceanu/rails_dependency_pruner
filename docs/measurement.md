# measurement

The measurement commands answer three different questions:

- how much process RSS changed
- which Rails and Ruby buckets moved when it changed
- whether boot or request timing moved while RSS changed

RSS is the hard process number. The Rails and Ruby buckets are attribution
signals. They explain where the win probably came from, but they are not
byte-exact ownership by framework.

## measure

Compare a baseline boot with a profiled variant:

```bash
bundle exec rails-dependency-pruner measure \
  --app . \
  --profile config/rails_dependency_pruner_profile.json \
  --coverage config/pruner_coverage.yml \
  --variants baseline,boot_prune \
  --target requests \
  --runs 5 \
  --process-memory-details \
  --output tmp/pruner-requests.json \
  --markdown tmp/pruner-requests.md
```

When `--coverage` is present, the report records the coverage path, digest,
Rails env, and reviewed workloads. Request measurements use reviewed coverage
request paths when `--request-paths` is not provided.

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
  --process-memory-details \
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
  min_transform_savings_mib: 2
  max_first_request_latency_regression_ms: 100
  max_warmed_p95_latency_regression_percent: 5
  max_warmed_p99_latency_regression_percent: 10
  forced_transform_ids: []
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
- the measurement artifact omits or declares a different profile id, coverage
  digest, Rails env, or reviewed workload names
- a request measurement omits reviewed coverage request paths
- baseline or candidate RSS is missing
- total saved RSS is below `min_total_savings_mib`
- total saved RSS is below `min_total_savings_percent`
- first request latency exceeds `max_first_request_latency_regression_ms`
  or `max_first_request_latency_regression_percent`
- request p95/p99 latency exceeds `max_request_p95_latency_regression_*`
  or `max_request_p99_latency_regression_*`
- warmed p95/p99 latency exceeds `max_warmed_p95_latency_regression_*`
  or `max_warmed_p99_latency_regression_*`
- request-target measurements lack a request status matrix, report request
  errors, or return statuses that differ from baseline
- measurement, variant, or run summaries report unexpected runtime events
- saved RSS is below the requested percentage of `reference_savings_mib`
- `reference_profile_id` is set and does not match the measurement profile id

`min_transform_savings_mib` can also be set for stricter local release checks.
It evaluates individual ablation transform groups and is intentionally harsh:
low-risk transforms that do not save RSS will fail that gate. Failed individual
ablation variants also fail policy approval because a memory win with a broken
transform is not usable.
When an ablation report has a memory policy, JSON and Markdown include
per-variant assessments. Variants can be `production_candidate`,
`not_worth_enabling`, `unsafe_for_production`, or `forced`. Use
`forced_transform_ids` only for reviewed transforms that should stay enabled
despite a local threshold miss.

## what eats memory

The report records:

- process RSS from the measured child process
- structured `process_memory` for each run, with RSS everywhere, Linux PSS/USS
  from `/proc/self/smaps_rollup` when present, and macOS physical footprint
  when `--process-memory-details` is set
- total loaded features
- Rails loaded features grouped by framework gem
- `GC.stat` medians and deltas, including `total_allocated_objects`
- live Ruby object type counts from `ObjectSpace.count_objects`
- optional ObjectSpace memsize by Ruby object type and class when
  `--object-memory` is set
- request status and response size for request-warmed runs
- early-boot event counts, unexpected-event counts, and telemetry counters when
  a profiled variant runs
- app boot time, first request time, and warmed request percentiles

The Rails part of memory shows up in three surfaces:

Generated Markdown reports include process memory tables for variant medians and
deltas so RSS, PSS, USS, and physical footprint can be compared without opening
the JSON artifact. With `--object-memory`, they also include top Ruby heap
classes and class-size deltas.

- framework code and constants loaded from gems such as `activerecord`,
  `actionview`, `activestorage`, and `railties`
- Ruby heap objects created by those frameworks, visible as movement in object
  types such as `T_STRING`, `T_ARRAY`, `T_HASH`, `T_CLASS`, `T_MODULE`,
  `T_IMEMO`, and `T_DATA`
- native or external storage behind those objects, including external string
  buffers, regexp data, array and hash backing storage, VM tables, and extension
  payloads

The Rails framework table groups loaded files by gem. This is not a byte ledger.
It tells you which framework stopped loading code when RSS moved. If
`disable_eager_load_only` removes many `activerecord` and `actionview` files,
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

## benchmark apps

Use Lobsters for the larger real-app workload. For a smaller generic blog app,
use `generic_blog_app`. The target for that app is at
least `40%` RSS reduction on a production request workload, measured with the
same baseline and candidate request paths before it is reported as a success.
The current Ruby `4.0.5` smoke on a temporary copy saved `34672 KB` RSS
(`33.9 MiB`, `21.5%`) on `/up`, `/`, `/archive`, `/home/about`,
`/home/projects`, `/feed`, and `/404`, so the target remains open.

The checked-in static regression matrix lives under `test/fixtures/apps`. It
covers minimal Rails, Active Record only, Action Mailer, Active Storage
attachments, Active Job, Action Text, Action Cable, mounted engine shapes, and
observability plus native-heavy gem signals. Matrix fixtures assert planner
decisions; doctor fixtures assert app capability signals. Lobsters and
generic_blog_app remain the RSS benchmarks.
