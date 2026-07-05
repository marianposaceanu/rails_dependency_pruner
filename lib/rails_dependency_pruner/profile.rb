# frozen_string_literal: true

require "json"
require "fileutils"
require "digest"
require "time"

require_relative "canonical_json"
require_relative "profile_schema"
require_relative "profile_context"
require_relative "profile_validator"
require_relative "gem_policy_registry"
require_relative "transform_registry"
require_relative "safety_policy"

module RailsDependencyPruner
  class Profile
    SCHEMA_VERSION = 1
    LEGACY_DETERMINISTIC_SCHEMA_VERSION = 2
    DETERMINISTIC_SCHEMA_VERSION = 3
    EXTREME_CONFIG_NAMESPACES = {
      "action_mailbox/engine" => "action_mailbox",
      "action_mailer/railtie" => "action_mailer",
      "active_job/railtie" => "active_job",
      "active_storage/engine" => "active_storage",
    }.freeze

    attr_reader :payload

    def initialize(payload)
      @payload = payload
    end

    def self.from_planner(planner)
      new(
        "schema_version" => SCHEMA_VERSION,
        "generated_at" => Time.now.utc.iso8601,
        "rails_version" => planner.index.source.version,
        "source" => planner.index.source.to_h,
        "app_root" => planner.usage.app_root.to_s,
        "rails_constants_count" => planner.index.definitions.length,
        "direct_rails_constants_count" => planner.usage.direct_rails_constants.length,
        "runtime_rails_constants_count" => planner.runtime_constants.length,
        "used_constants_count" => planner.used_constants.length,
        "unused_constants_count" => planner.unused_constants.length,
        "unused_features_count" => planner.unused_features.length,
        "unused_constants" => planner.unused_constants.to_a.sort,
        "unused_features" => planner.unused_features,
        "unused_require_paths" => planner.unused_require_paths,
        "unused_require_path_provenance" => planner.unused_require_path_provenance,
        "feature_matches" => planner.usage.feature_matches,
        "config_matches" => planner.usage.sorted_config_matches,
        "route_matches" => planner.usage.sorted_route_matches,
        "dynamic_matches" => planner.usage.sorted_dynamic_matches,
        "require_matches" => planner.usage.sorted_require_matches,
        "runtime_memory" => planner.runtime_memory,
        "runtime_memory_summary" => planner.runtime_memory_summary.to_h,
        "runtime_rails_application" => planner.runtime_rails_application,
        "runtime_event_summary" => planner.runtime_event_summary,
        "runtime_evidence_limits" => planner.runtime_evidence_limits,
        "runtime_evidence_truncation" => planner.runtime_evidence_truncation,
      )
    end

    def self.deterministic_from_planner(planner, runtime_evidence_paths: [], coverage_path: nil, mode: "guard", boot_plan: nil, explanations: nil, extreme_boot: nil)
      context = ProfileContext.from_planner(
        planner,
        runtime_evidence_paths: runtime_evidence_paths,
        coverage_path: coverage_path,
      )
      boot_plan_payload = boot_plan&.to_h || {}
      extreme_boot_payload = normalize_extreme_boot(extreme_boot)
      lazy_gem_policies = structured_lazy_gems(extreme_boot_payload.fetch("lazy_gems"))
      payload = {
        "schema_version" => DETERMINISTIC_SCHEMA_VERSION,
        "profile_id" => nil,
        "tool" => context.tool_context,
        "environment" => context.environment_context,
        "fingerprints" => context.fingerprints_context,
        "mode" => mode,
        "ruby" => context.ruby_context,
        "rails" => context.rails_context,
        "bundler" => context.bundler_context,
        "app" => context.app_context,
        "analysis" => context.analysis_context.merge(
          "parse_errors" => {
            "rails" => planner.index.parse_errors,
            "app" => planner.usage.parse_errors,
          },
        ),
        "evidence" => context.evidence_context,
        "feature_matches" => planner.usage.feature_matches,
        "config_matches" => planner.usage.sorted_config_matches,
        "route_matches" => planner.usage.sorted_route_matches,
        "dynamic_matches" => planner.usage.sorted_dynamic_matches,
        "require_matches" => planner.usage.sorted_require_matches,
        "summary" => {
          "rails_constants_count" => planner.index.definitions.length,
          "direct_rails_constants_count" => planner.usage.direct_rails_constants.length,
          "runtime_rails_constants_count" => planner.runtime_constants.length,
          "used_constants_count" => planner.used_constants.length,
          "unused_constants_count" => planner.unused_constants.length,
          "unused_features_count" => planner.unused_features.length,
          "runtime_memory_summary" => planner.runtime_memory_summary.to_h,
          "runtime_rails_application" => planner.runtime_rails_application,
          "runtime_event_summary" => planner.runtime_event_summary,
          "runtime_evidence_limits" => planner.runtime_evidence_limits,
          "runtime_evidence_truncation" => planner.runtime_evidence_truncation,
        },
        "pruning" => {
          "disabled_frameworks" => Array(boot_plan_payload["pruned_frameworks"]),
          "disabled_railties" => Array(boot_plan_payload["pruned_railties"]),
          "disabled_initializers" => [],
          "disabled_require_paths" => planner.unused_require_paths,
          "disabled_require_path_provenance" => planner.unused_require_path_provenance,
          "disabled_constants" => planner.unused_constants.to_a.sort,
          "autoload_ignores" => Array(boot_plan_payload["autoload_ignores"]),
          "eager_load_ignores" => Array(boot_plan_payload["eager_load_ignores"]),
        },
        "boot_plan" => boot_plan_payload,
        "extreme_boot" => extreme_boot_payload,
        "lazy_gems" => lazy_gem_policies,
        "lazy_constants" => lazy_constants_for(lazy_gem_policies),
        "safety_policy" => context.safety_policy_context,
        "safety" => {
          "always_keep" => [],
          "manual_keep" => [],
          "confidence_threshold" => 0.98,
          "production_allowed" => false,
          "approved_at" => nil,
          "approved_by" => nil,
          "verifier_version" => nil,
          "errors" => [],
          "warnings" => [],
          "failure_mode" => "raise",
        },
        "unexpected_event_policy" => "fail_boot",
        "explanations" => explanations || {},
      }
      memory_policy = context.memory_policy_context
      payload["memory_policy"] = memory_policy unless memory_policy.empty?
      payload["transforms"] = TransformRegistry.transforms_for_payload(payload)
      payload["expected_events"] = payload.fetch("transforms").flat_map { |transform| Array(transform["expected_events"]) }

      new(payload).tap do |profile|
        ProfileSchema.set_profile_id(profile.payload, profile.digest)
      end
    end

    def self.normalize_extreme_boot(extreme_boot)
      extreme_boot ||= {}
      disable_eager_load = extreme_boot[:disable_eager_load] || extreme_boot["disable_eager_load"]
      skip_railties = Array(extreme_boot[:skip_railties] || extreme_boot["skip_railties"]).map(&:to_s).reject(&:empty?).uniq.sort
      lazy_require_paths = Array(extreme_boot[:lazy_require_paths] || extreme_boot["lazy_require_paths"]).map(&:to_s).reject(&:empty?).uniq.sort
      lazy_gems = Array(extreme_boot[:lazy_gems] || extreme_boot["lazy_gems"]).map(&:to_s).reject(&:empty?).uniq.sort

      {
        "disable_eager_load" => disable_eager_load == true,
        "skip_railties" => skip_railties,
        "lazy_require_paths" => lazy_require_paths,
        "lazy_gems" => lazy_gems,
        "config_namespace_stubs" => skip_railties.filter_map { |railtie| EXTREME_CONFIG_NAMESPACES[railtie] }.uniq.sort,
      }
    end

    private_class_method :normalize_extreme_boot

    def self.structured_lazy_gems(names)
      registry = GemPolicyRegistry.default
      names.each_with_object({}) do |name, policies|
        policy = registry.policy_for(name)
        policy_payload = policy&.to_h || {
          "name" => name,
          "class" => "unsafe_unknown",
          "risk" => "unknown",
          "strategies" => [],
          "production_rule" => "Unknown gems are not eligible for production",
        }
        strategies = Array(policy_payload["strategies"]).map(&:to_s).sort
        policies[name] = policy_payload.merge(
          "gem" => name,
          "strategy" => primary_lazy_gem_strategy(strategies),
          "strategies" => strategies,
          "boot_require_blocked" => true,
          "high_risk" => policy_payload["risk"] == "high",
        )
      end.sort.to_h
    end

    def self.primary_lazy_gem_strategy(strategies)
      return "lazy_constant" if strategies.include?("lazy_constant")
      return "noop_shim" if strategies.include?("noop_shim")
      return "disabled_in_profile" if strategies.include?("disabled_in_profile")

      strategies.first || "unsupported"
    end

    def self.lazy_constants_for(lazy_gem_policies)
      lazy_gem_policies.each_with_object({}) do |(gem_name, policy), constants|
        next unless Array(policy["strategies"]).include?("lazy_constant")
        next if policy["require"].to_s.empty?

        Array(policy["constants"]).each do |constant|
          constants[constant.to_s] = {
            "gem" => gem_name,
            "require" => policy.fetch("require"),
            "allowed_phases" => Array(policy["allowed_phases"]).map(&:to_s),
            "disallowed_phases" => Array(policy["disallowed_phases"]).map(&:to_s),
          }
        end
      end.sort.to_h
    end

    private_class_method :structured_lazy_gems, :primary_lazy_gem_strategy, :lazy_constants_for

    def self.load(path)
      new(JSON.parse(File.read(path)))
    end

    def write(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, deterministic? ? canonical_json : JSON.pretty_generate(payload))
    end

    def unused_constants
      Array(payload.dig("pruning", "disabled_constants") || payload.fetch("unused_constants"))
    end

    def unused_require_paths
      Array(payload.dig("pruning", "disabled_require_paths") || payload["unused_require_paths"])
    end

    def rails_version
      payload.dig("rails", "version") || payload["rails_version"]
    end

    def schema_version
      payload["schema_version"]
    end

    def profile_id
      ProfileSchema.profile_id(payload)
    end

    def deterministic?
      ProfileSchema.deterministic_schema?(schema_version)
    end

    def canonical_json
      CanonicalJson.dump(payload)
    end

    def approve_production!(approved_by: nil, report: nil, approved_at: Time.now.utc.iso8601)
      payload["safety"] ||= {}
      payload["safety"]["production_allowed"] = true
      payload["safety"]["approved_at"] = approved_at
      payload["safety"]["approved_by"] = approved_by || ENV["RAILS_DEPENDENCY_PRUNER_APPROVED_BY"] || ENV["USER"]
      payload["safety"]["verifier_version"] = RailsDependencyPruner::VERSION
      payload["safety"]["errors"] = Array(report && report["errors"])
      payload["safety"]["warnings"] = Array(report && report["warnings"])
      ProfileSchema.set_profile_id(payload, digest)
      self
    end

    def digest
      digest_payload = if schema_version == LEGACY_DETERMINISTIC_SCHEMA_VERSION && !payload.key?("fingerprints")
        payload.merge("profile_id" => nil)
      else
        ProfileSchema.digest_payload(payload)
      end
      "sha256:#{Digest::SHA256.hexdigest(CanonicalJson.digestible(digest_payload))}"
    end

    def validate!(context)
      ProfileValidator.new(profile: self, context: context).validate!
    end
  end
end
