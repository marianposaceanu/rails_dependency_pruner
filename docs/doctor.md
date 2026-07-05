# doctor

`doctor` is a static app capability scan. It does not boot Rails.

```bash
bundle exec rails-dependency-pruner doctor --app . --json
```

The report keeps the existing `recommendations` list and adds:

- `runtime`: Ruby, Rails, and Bundler group context
- `capabilities.configured_frameworks`: `rails/all` and explicit railtie usage
- `capabilities.loaded_railties`: railties required by `config/application.rb`
- `capabilities.engines`: local engine directories and `Rails::Engine` classes
- `capabilities.mounted_rack_apps`: `mount` calls in routes with mount paths
- `capabilities.middleware`: `config.middleware.*` calls
- `capabilities.routes`: route files and route DSL call sites
- `capabilities.jobs`, `mailers`, `channels`
- `capabilities.rake_tasks`: tasks from `Rakefile` and `lib/tasks/**/*.rake`
- `capabilities.active_storage`: `has_one_attached` and `has_many_attached`
- `capabilities.action_text`: `has_rich_text`
- `capabilities.direct_gem_usage`: direct `Vips`, `Nokogiri`, `Sentry`,
  `Honeybadger`, and `Rollbar` API use
- `capabilities.native_heavy_gems`: policy-registered native-heavy gems present
  in the bundle or directly used by app code
- `capabilities.integrations`: known observability/profiler gems
- `capabilities.integration_gem_policies`: policy classes for integration gems,
  such as `railtie_integration` and `middleware_integration`
- `capabilities.unclassified_integrations`: known integration gems without a
  production lazy/stub policy
- `capabilities.adapters`: known server/job/boot adapter gems
- `capabilities.adapter_gem_policies`: adapter class, risk, coverage sections,
  and production rule for known adapters
- `risks.initializers_dynamic_require_load`
- `risks.dynamic_constantization`

The output is evidence for choosing candidate transforms. It is not production
approval by itself. Production approval still needs profile verification,
coverage, runtime evidence where required, and measurement policy gates.

To turn the scan into a starter workload contract:

```bash
bundle exec rails-dependency-pruner coverage template --app . --write config/pruner_coverage.yml
```

The generated manifest keeps inferred workload sections under review until they
are edited.
