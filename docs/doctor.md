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
- `capabilities.mounted_rack_apps`: `mount` calls in routes
- `capabilities.middleware`: `config.middleware.*` calls
- `capabilities.routes`: route files and route DSL call sites
- `capabilities.jobs`, `mailers`, `channels`
- `capabilities.active_storage`: `has_one_attached` and `has_many_attached`
- `capabilities.action_text`: `has_rich_text`
- `capabilities.direct_gem_usage`: direct `Vips` and `Nokogiri` use
- `capabilities.integrations`: known observability/profiler gems
- `capabilities.adapters`: known server/job/boot adapter gems
- `risks.initializers_dynamic_require_load`
- `risks.dynamic_constantization`

The output is evidence for choosing candidate transforms. It is not production
approval by itself. Production approval still needs profile verification,
coverage, runtime evidence where required, and measurement policy gates.
