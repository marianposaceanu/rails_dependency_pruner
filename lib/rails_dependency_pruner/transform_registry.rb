# frozen_string_literal: true

module RailsDependencyPruner
  class TransformRegistry
    Transform = Struct.new(
      :id,
      :kind,
      :risk,
      :description,
      :source,
      :required_coverage,
      :expected_events,
      :registered,
      keyword_init: true,
    ) do
      def to_h
        {
          "id" => id,
          "kind" => kind,
          "risk" => risk,
          "description" => description,
          "source" => source,
          "required_coverage" => Array(required_coverage).sort,
          "expected_events" => Array(expected_events),
          "registered" => registered != false,
        }
      end
    end

    LAZY_GEM_POLICIES = {
      "bcrypt" => ["native_heavy_library", "medium"],
      "builder" => ["pure_library", "low"],
      "commonmarker" => ["native_heavy_library", "medium"],
      "faker" => ["pure_library", "low"],
      "flamegraph" => ["pure_library", "low"],
      "htmlentities" => ["pure_library", "low"],
      "memory_profiler" => ["pure_library", "low"],
      "nokogiri" => ["native_heavy_library", "medium"],
      "oauth" => ["pure_library", "low"],
      "parslet" => ["pure_library", "low"],
      "pdf-reader" => ["pure_library", "low"],
      "rack-mini-profiler" => ["middleware_integration", "medium"],
      "rotp" => ["pure_library", "low"],
      "rqrcode" => ["pure_library", "low"],
      "ruby-vips" => ["native_heavy_library", "high"],
      "sentry-rails" => ["railtie_integration", "high"],
      "sitemap_generator" => ["pure_library", "low"],
      "stackprof" => ["native_heavy_library", "medium"],
      "svg-graph" => ["pure_library", "low"],
    }.freeze

    STATIC_DEFINITIONS = {
      "disable_eager_load" => {
        "kind" => "eager_load",
        "risk" => "medium",
        "description" => "Disable Rails eager loading during boot",
        "source" => "extreme_boot.disable_eager_load",
        "required_coverage" => %w[requests],
      },
      "stub:rack_mini_profiler" => {
        "kind" => "stub",
        "risk" => "medium",
        "description" => "Install a no-op Rack::MiniProfiler shim",
        "source" => "extreme_boot.lazy_gems",
        "required_coverage" => %w[requests],
      },
      "stub:active_storage_vips_analyzer" => {
        "kind" => "stub",
        "risk" => "high",
        "description" => "Make Active Storage's Vips analyzer decline instead of loading ruby-vips during boot",
        "source" => "extreme_boot.lazy_gems",
        "required_coverage" => [],
        "expected_events" => [
          {
            "phase" => "boot",
            "action" => "stubbed_lazy_gem_require",
            "path" => "active_storage/analyzer/image_analyzer/vips",
            "gem" => "ruby-vips",
          },
        ],
      },
    }.freeze

    class << self
      def transforms_for_payload(payload)
        transforms = []
        pruning = payload["pruning"] || {}
        extreme_boot = payload["extreme_boot"] || {}

        Array(pruning["disabled_frameworks"]).each do |framework|
          transforms << dynamic_transform(
            "disable_framework:#{framework}",
            kind: "framework",
            risk: "high",
            description: "Disable Rails framework #{framework}",
            source: "pruning.disabled_frameworks",
          )
        end

        Array(pruning["disabled_railties"]).each do |railtie|
          transforms << dynamic_transform(
            "prune_railtie:#{railtie}",
            kind: "railtie",
            risk: "high",
            description: "Remove #{railtie} from the app boot plan",
            source: "pruning.disabled_railties",
          )
        end

        Array(pruning["autoload_ignores"]).each do |path|
          transforms << dynamic_transform(
            "ignore_autoload_path:#{path}",
            kind: "autoload_path",
            risk: "medium",
            description: "Ignore #{path} from Rails autoload paths",
            source: "pruning.autoload_ignores",
          )
        end

        Array(pruning["eager_load_ignores"]).each do |path|
          transforms << dynamic_transform(
            "ignore_eager_load_path:#{path}",
            kind: "eager_load_path",
            risk: "medium",
            description: "Ignore #{path} from Rails eager load paths",
            source: "pruning.eager_load_ignores",
          )
        end

        transforms << static_transform("disable_eager_load") if extreme_boot["disable_eager_load"] == true

        Array(extreme_boot["skip_railties"]).each do |railtie|
          transforms << dynamic_transform(
            "skip_railtie:#{railtie}",
            kind: "railtie",
            risk: railtie == "rails/test_unit/railtie" ? "low" : "high",
            description: "Skip #{railtie} during early boot",
            source: "extreme_boot.skip_railties",
            expected_events: [
              {
                "phase" => "boot",
                "action" => "skipped",
                "path" => railtie,
              },
            ],
          )
        end

        Array(extreme_boot["lazy_require_paths"]).each do |path|
          transforms << dynamic_transform(
            "lazy_require:#{path}",
            kind: "lazy_require",
            risk: "medium",
            description: "Defer #{path} until first use",
            source: "extreme_boot.lazy_require_paths",
          )
        end

        Array(extreme_boot["lazy_gems"]).each do |gem_name|
          transforms << lazy_gem_transform(gem_name)
          transforms << static_transform("stub:rack_mini_profiler") if gem_name == "rack-mini-profiler"
          transforms << static_transform("stub:active_storage_vips_analyzer") if gem_name == "ruby-vips"
        end

        transforms.compact.uniq { |transform| transform.id }.sort_by(&:id).map(&:to_h)
      end

      def required_transform_ids(payload)
        transforms_for_payload(payload).map { |transform| transform.fetch("id") }.sort
      end

      def profile_transform_ids(payload)
        Array(payload["transforms"]).filter_map { |transform| transform["id"].to_s if transform.is_a?(Hash) }.sort
      end

      def missing_transform_ids(payload)
        required_transform_ids(payload) - profile_transform_ids(payload)
      end

      def unknown_transform_ids(payload)
        profile_transform_ids(payload).reject { |id| registered_id?(id) }.sort
      end

      def registered_id?(id)
        return true if STATIC_DEFINITIONS.key?(id)
        return true if id.start_with?("disable_framework:")
        return true if id.start_with?("prune_railtie:")
        return true if id.start_with?("ignore_autoload_path:")
        return true if id.start_with?("ignore_eager_load_path:")
        return true if id.start_with?("skip_railtie:")
        return true if id.start_with?("lazy_require:")

        if id.start_with?("lazy_gem:")
          return LAZY_GEM_POLICIES.key?(id.delete_prefix("lazy_gem:"))
        end

        false
      end

      private
        def static_transform(id)
          config = STATIC_DEFINITIONS.fetch(id)
          Transform.new(
            id: id,
            kind: config.fetch("kind"),
            risk: config.fetch("risk"),
            description: config.fetch("description"),
            source: config.fetch("source"),
            required_coverage: config.fetch("required_coverage", []),
            expected_events: config.fetch("expected_events", []),
            registered: true,
          )
        end

        def dynamic_transform(id, kind:, risk:, description:, source:, required_coverage: [], expected_events: [])
          Transform.new(
            id: id,
            kind: kind,
            risk: risk,
            description: description,
            source: source,
            required_coverage: required_coverage,
            expected_events: expected_events,
            registered: registered_id?(id),
          )
        end

        def lazy_gem_transform(gem_name)
          policy = LAZY_GEM_POLICIES[gem_name]
          gem_class, risk = policy || ["unsafe_unknown", "unknown"]
          dynamic_transform(
            "lazy_gem:#{gem_name}",
            kind: gem_class,
            risk: risk,
            description: "Defer #{gem_name} until first approved use",
            source: "extreme_boot.lazy_gems",
          )
        end
    end
  end
end
