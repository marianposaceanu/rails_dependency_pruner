# Rails Dependency Pruner

`rails_dependency_pruner` is an experimental static analysis tool for Rails
memory work. It builds a constant dependency tree from Rails source, scans a
Rails app for Rails constants it actually references, computes the dependency
closure, and can write guard shims for Rails constants outside that closure.

The tool does not boot Rails or the target app.

## Usage

```bash
exe/rails-dependency-pruner audit \
  --rails-root RAILS_ROOT \
  --app LOBSTERS_APP \
  --json
```

Generate a shim:

```bash
exe/rails-dependency-pruner audit \
  --rails-root RAILS_ROOT \
  --app LOBSTERS_APP \
  --write-shim tmp/rails_dependency_pruner_shim.rb
```

The generated shim installs fail-fast constants for unused Rails constants only
when their parent namespace is already loaded. It does not remove loaded Rails
classes unless you edit the shim to pass `force: true`.

## Deterministic Runtime Workflow

Prism is deterministic because it parses source, not process state. Runtime
usage should therefore be treated as evidence captured by a controlled workload,
then merged back into the Prism-derived dependency graph offline.

The workflow is:

1. Build the Rails constant index from source with Prism.
2. Scan the app source with Prism for direct Rails constant references.
3. Run the app test suite or a representative request workload with the runtime
   recorder enabled.
4. Merge the runtime evidence JSON into the Prism plan.
5. Generate a shim for constants outside the merged dependency closure.
6. Re-run the same workload with the shim loaded.

Record runtime evidence:

```bash
RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT=tmp/rails_dependency_pruner_runtime.json \
RAILS_DEPENDENCY_PRUNER_RAILS_ROOT=RAILS_ROOT \
RUBYOPT="-rrails_dependency_pruner/runtime_recorder" \
bin/rails test
```

For deeper but slower evidence, enable method-call tracing:

```bash
RAILS_DEPENDENCY_PRUNER_TRACE_CALLS=1 \
RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT=tmp/rails_dependency_pruner_runtime.json \
RAILS_DEPENDENCY_PRUNER_RAILS_ROOT=RAILS_ROOT \
RUBYOPT="-rrails_dependency_pruner/runtime_recorder" \
bin/rails test
```

Merge runtime evidence into the audit:

```bash
exe/rails-dependency-pruner audit \
  --rails-root RAILS_ROOT \
  --app LOBSTERS_APP \
  --runtime-evidence tmp/rails_dependency_pruner_runtime.json \
  --write-shim tmp/rails_dependency_pruner_shim.rb
```

The runtime JSON can include `defined_constants`, `called_constants`,
`called_methods`, and `loaded_features`. The offline audit maps those facts back
to Rails constants from the Prism index and keeps their dependency closure.

## Current Lobsters Smoke Result

Against `RAILS_ROOT` and
`LOBSTERS_APP`, the static audit currently reports:

- Rails Ruby files scanned: `1444`
- Rails constants indexed: `2386`
- Lobsters Ruby files scanned: `157`
- Lobsters direct Rails constants: `48`
- Reachable Rails constants after dependency closure: `776`
- Unused Rails constant candidates: `1610`
- Rails parse errors: `0`
- App parse errors: `0`

The latest local outputs are ignored under `tmp/`.

## Caveats

This is intentionally conservative and static. Ruby metaprogramming, string
constantization, Zeitwerk autoloads, reflection, and framework callbacks can all
make a constant reachable even when it does not appear in source. Treat generated
shims as an experiment and run the app test suite before using the results as a
memory-saving strategy.
