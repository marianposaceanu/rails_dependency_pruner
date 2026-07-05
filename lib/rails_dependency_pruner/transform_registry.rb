# frozen_string_literal: true

require_relative "gem_policy_registry"

module RailsDependencyPruner
  class TransformRegistry
    Transform = Struct.new(
      :id,
      :kind,
      :risk,
      :description,
      :source,
      :expected_memory_effect,
      :required_static_evidence,
      :required_runtime_evidence,
      :required_coverage,
      :allowed_phases,
      :expected_events,
      :disallowed_events,
      :rollback,
      :production_rule,
      :registered,
      :gem_policy,
      keyword_init: true,
    ) do
      def to_h
        payload = {
          "id" => id,
          "kind" => kind,
          "risk" => risk,
          "description" => description,
          "source" => source,
          "expected_memory_effect" => expected_memory_effect,
          "required_static_evidence" => Array(required_static_evidence).sort,
          "required_runtime_evidence" => Array(required_runtime_evidence).sort,
          "required_coverage" => Array(required_coverage).sort,
          "allowed_phases" => Array(allowed_phases).sort,
          "expected_events" => Array(expected_events),
          "disallowed_events" => Array(disallowed_events).sort,
          "rollback" => rollback,
          "production_rule" => production_rule,
          "registered" => registered != false,
        }
        payload["gem_policy"] = gem_policy if gem_policy
        payload
      end
    end

    CONTRACT_FIELDS = %w[
      expected_memory_effect
      required_static_evidence
      required_runtime_evidence
      required_coverage
      allowed_phases
      expected_events
      disallowed_events
      rollback
      production_rule
    ].freeze

    GEM_POLICIES = GemPolicyRegistry.default
    LAZY_GEM_POLICIES = GEM_POLICIES.to_h.freeze

    STATIC_DEFINITIONS = {
      "disable_eager_load" => {
        "kind" => "eager_load",
        "risk" => "medium",
        "description" => "Disable Rails eager loading during boot",
        "source" => "extreme_boot.disable_eager_load",
        "expected_memory_effect" => "Avoid eager-loading Rails and app constants during boot; measure per app",
        "required_static_evidence" => [
          "reviewed coverage manifest",
          "matching deterministic profile fingerprints",
        ],
        "required_runtime_evidence" => [
          "first request latency",
          "warmed p95 latency",
          "warmed p99 latency",
          "unexpected event count",
        ],
        "required_coverage" => %w[requests],
        "allowed_phases" => %w[boot],
        "disallowed_events" => [
          "unexpected boot autoload",
          "unexpected request lazy load",
        ],
        "rollback" => "Set RAILS_DEPENDENCY_PRUNER_DISABLE=1 or remove the generated rollout patch",
        "production_rule" => "Allowed only with request coverage, latency policy gates, and no unexpected canary autoloads",
      },
      "stub:rack_mini_profiler" => {
        "kind" => "stub",
        "risk" => "medium",
        "description" => "Install a no-op Rack::MiniProfiler shim",
        "source" => "extreme_boot.lazy_gems",
        "expected_memory_effect" => "Avoid loading rack-mini-profiler when profiling is disabled",
        "required_static_evidence" => [
          "profiler disabled in production profile",
          "registered gem policy",
        ],
        "required_runtime_evidence" => [
          "request middleware summary",
          "unexpected event count",
        ],
        "required_coverage" => %w[requests],
        "allowed_phases" => %w[boot],
        "disallowed_events" => [
          "Rack::MiniProfiler request use",
        ],
        "rollback" => "Set RAILS_DEPENDENCY_PRUNER_DISABLE=1 or remove rack-mini-profiler from lazy_gems",
        "production_rule" => "Allowed only when profiling middleware is not required in production",
      },
      "stub:active_storage_vips_analyzer" => {
        "kind" => "stub",
        "risk" => "high",
        "description" => "Make Active Storage's Vips analyzer decline instead of loading ruby-vips during boot",
        "source" => "extreme_boot.lazy_gems",
        "expected_memory_effect" => "Avoid loading ruby-vips through Active Storage image analyzer during boot",
        "required_static_evidence" => [
          "no Active Storage attachment DSL usage",
          "or full reviewed Active Storage action coverage",
          "or unexpired high-risk override",
        ],
        "required_runtime_evidence" => [
          "unexpected event count",
          "attachment workload evidence when attachments exist",
        ],
        "required_coverage" => [],
        "allowed_phases" => %w[boot manual_app_use],
        "expected_events" => [
          {
            "phase" => "boot",
            "action" => "stubbed_lazy_gem_require",
            "path" => "active_storage/analyzer/image_analyzer/vips",
            "gem" => "ruby-vips",
          },
        ],
        "disallowed_events" => [
          "Active Storage analyzer Vips use without proof",
        ],
        "rollback" => "Set RAILS_DEPENDENCY_PRUNER_DISABLE=1 or remove ruby-vips from lazy_gems",
        "production_rule" => "Allowed only for no-attachment apps, full attachment coverage, or an unexpired override",
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

      def transform_contract_gaps(payload)
        Array(payload["transforms"]).filter_map do |transform|
          next unless transform.is_a?(Hash)

          id = transform["id"].to_s
          next unless registered_id?(id)

          missing = CONTRACT_FIELDS.select { |field| contract_field_missing?(transform, field) }
          next if missing.empty?

          {
            "transform_id" => id,
            "missing_fields" => missing,
          }
        end.sort_by { |gap| gap.fetch("transform_id") }
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
          return GEM_POLICIES.registered?(id.delete_prefix("lazy_gem:"))
        end

        false
      end

      def lazy_gem_supported?(name)
        GEM_POLICIES.registered?(name)
      end

      def lazy_gem_policy(name)
        GEM_POLICIES.policy_for(name)&.to_h
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
            expected_memory_effect: config.fetch("expected_memory_effect"),
            required_static_evidence: config.fetch("required_static_evidence", []),
            required_runtime_evidence: config.fetch("required_runtime_evidence", []),
            required_coverage: config.fetch("required_coverage", []),
            allowed_phases: config.fetch("allowed_phases", []),
            expected_events: config.fetch("expected_events", []),
            disallowed_events: config.fetch("disallowed_events", []),
            rollback: config.fetch("rollback"),
            production_rule: config.fetch("production_rule"),
            registered: true,
          )
        end

        def dynamic_transform(id, kind:, risk:, description:, source:, required_coverage: [], expected_events: [], gem_policy: nil)
          contract = dynamic_contract(id, kind: kind, risk: risk, gem_policy: gem_policy)
          Transform.new(
            id: id,
            kind: kind,
            risk: risk,
            description: description,
            source: source,
            expected_memory_effect: contract.fetch("expected_memory_effect"),
            required_static_evidence: contract.fetch("required_static_evidence"),
            required_runtime_evidence: contract.fetch("required_runtime_evidence"),
            required_coverage: required_coverage.empty? ? contract.fetch("required_coverage") : required_coverage,
            allowed_phases: contract.fetch("allowed_phases"),
            expected_events: expected_events,
            disallowed_events: contract.fetch("disallowed_events"),
            rollback: contract.fetch("rollback"),
            production_rule: contract.fetch("production_rule"),
            registered: registered_id?(id),
            gem_policy: gem_policy,
          )
        end

        def lazy_gem_transform(gem_name)
          policy = GEM_POLICIES.policy_for(gem_name)
          dynamic_transform(
            "lazy_gem:#{gem_name}",
            kind: policy&.gem_class || "unsafe_unknown",
            risk: policy&.risk || "unknown",
            description: "Defer #{gem_name} until first approved use",
            source: "extreme_boot.lazy_gems",
            expected_events: lazy_gem_expected_events(gem_name, policy),
            gem_policy: policy&.to_h,
          )
        end

        def lazy_gem_expected_events(gem_name, policy)
          return [] unless policy
          return [] unless Array(policy.strategies).map(&:to_s).include?("lazy_constant")
          return [] if policy.require_path.to_s.empty? || Array(policy.constants).empty?

          base_event = {
            "action" => "loaded_lazy_gem",
            "gem" => gem_name.to_s,
          }
          phases = Array(policy.allowed_phases).map(&:to_s).reject(&:empty?).sort
          return [base_event] if phases.empty?

          phases.map { |phase| base_event.merge("phase" => phase) }
        end

        def dynamic_contract(id, kind:, risk:, gem_policy: nil)
          case kind
          when "framework"
            framework_contract(id)
          when "railtie"
            railtie_contract(id, risk: risk)
          when "autoload_path", "eager_load_path"
            load_path_contract(id, kind: kind)
          when "lazy_require"
            lazy_require_contract(id)
          else
            lazy_gem_contract(id, gem_policy: gem_policy)
          end
        end

        def framework_contract(id)
          framework = id.delete_prefix("disable_framework:")
          {
            "expected_memory_effect" => "Avoid loading unused #{framework} framework code; measure per app",
            "required_static_evidence" => [
              "feature catalog has no #{framework} usage",
              "routes, config, and initializers do not require #{framework}",
            ],
            "required_runtime_evidence" => [
              "runtime routes and middleware do not reference #{framework}",
              "runtime evidence is not truncated",
            ],
            "required_coverage" => [],
            "allowed_phases" => %w[boot],
            "disallowed_events" => [
              "runtime #{framework} route",
              "runtime #{framework} middleware",
            ],
            "rollback" => "Set RAILS_DEPENDENCY_PRUNER_DISABLE=1 or restore the framework require",
            "production_rule" => "Allowed only when static, runtime, route, middleware, and coverage evidence agree the framework is unused",
          }
        end

        def railtie_contract(id, risk:)
          railtie = id.split(":", 2).last
          low_risk_test_unit = id == "skip_railtie:rails/test_unit/railtie"
          {
            "expected_memory_effect" => "Avoid requiring #{railtie} during Rails boot; measure per app",
            "required_static_evidence" => [
              low_risk_test_unit ? "test-unit railtie is not needed in production" : "no static use of #{railtie}",
            ],
            "required_runtime_evidence" => [
              "unexpected event count",
              "runtime evidence is not truncated",
            ],
            "required_coverage" => [],
            "allowed_phases" => %w[boot],
            "disallowed_events" => [
              "unexpected require for #{railtie}",
            ],
            "rollback" => "Set RAILS_DEPENDENCY_PRUNER_DISABLE=1 or restore #{railtie}",
            "production_rule" => if risk == "low"
              "Allowed when the railtie is not required by production boot or runtime evidence"
            else
              "Allowed only when framework catalog, routes, middleware, initializers, and runtime evidence agree"
            end,
          }
        end

        def load_path_contract(id, kind:)
          path = id.split(":", 2).last
          action = kind == "autoload_path" ? "autoload" : "eager-load"
          {
            "expected_memory_effect" => "Avoid scanning unused #{action} path #{path}; measure per app",
            "required_static_evidence" => [
              "#{path} is tied to a pruned framework or unused app path",
            ],
            "required_runtime_evidence" => [
              "unexpected event count",
            ],
            "required_coverage" => [],
            "allowed_phases" => %w[boot],
            "disallowed_events" => [
              "constant load from #{path}",
            ],
            "rollback" => "Set RAILS_DEPENDENCY_PRUNER_DISABLE=1 or restore #{path} to Rails load paths",
            "production_rule" => "Allowed only when the corresponding framework or app path is not used by covered workloads",
          }
        end

        def lazy_require_contract(id)
          path = id.delete_prefix("lazy_require:")
          {
            "expected_memory_effect" => "Defer #{path} until first approved use; measure per app",
            "required_static_evidence" => [
              "#{path} is in the supported lazy require list",
            ],
            "required_runtime_evidence" => [
              "first-use latency",
              "unexpected event count",
            ],
            "required_coverage" => [],
            "allowed_phases" => %w[boot request manual_app_use],
            "disallowed_events" => [
              "unexpected require for #{path}",
            ],
            "rollback" => "Set RAILS_DEPENDENCY_PRUNER_DISABLE=1 or remove #{path} from lazy_require_paths",
            "production_rule" => "Allowed only for supported require paths with workload coverage and no unexpected canary events",
          }
        end

        def lazy_gem_contract(id, gem_policy:)
          gem_name = id.delete_prefix("lazy_gem:")
          {
            "expected_memory_effect" => "Defer #{gem_name} until first approved use; measure per app",
            "required_static_evidence" => [
              "registered gem policy",
            ],
            "required_runtime_evidence" => [
              "first-use latency",
              "unexpected event count",
            ],
            "required_coverage" => [],
            "allowed_phases" => %w[boot request manual_app_use],
            "disallowed_events" => [
              "unexpected lazy load for #{gem_name}",
            ],
            "rollback" => "Set RAILS_DEPENDENCY_PRUNER_DISABLE=1 or remove #{gem_name} from lazy_gems",
            "production_rule" => gem_policy&.fetch("production_rule", nil) || "Unknown gems are not eligible for production",
          }
        end

        def contract_field_missing?(transform, field)
          return true unless transform.key?(field)

          value = transform[field]
          case value
          when String
            value.empty?
          when Array
            false
          when Hash
            false
          else
            value.nil?
          end
        end
    end
  end
end
