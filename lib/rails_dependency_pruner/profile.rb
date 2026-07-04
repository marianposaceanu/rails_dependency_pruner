# frozen_string_literal: true

require "json"
require "fileutils"
require "digest"
require "time"

require_relative "canonical_json"
require_relative "profile_context"
require_relative "profile_validator"

module RailsDependencyPruner
  class Profile
    SCHEMA_VERSION = 1
    DETERMINISTIC_SCHEMA_VERSION = 2

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
        "dynamic_matches" => planner.usage.sorted_dynamic_matches,
        "runtime_memory" => planner.runtime_memory,
        "runtime_memory_summary" => planner.runtime_memory_summary.to_h,
      )
    end

    def self.deterministic_from_planner(planner, runtime_evidence_paths: [], coverage_path: nil, mode: "guard")
      context = ProfileContext.from_planner(
        planner,
        runtime_evidence_paths: runtime_evidence_paths,
        coverage_path: coverage_path,
      )
      payload = {
        "schema_version" => DETERMINISTIC_SCHEMA_VERSION,
        "profile_id" => nil,
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
        "dynamic_matches" => planner.usage.sorted_dynamic_matches,
        "summary" => {
          "rails_constants_count" => planner.index.definitions.length,
          "direct_rails_constants_count" => planner.usage.direct_rails_constants.length,
          "runtime_rails_constants_count" => planner.runtime_constants.length,
          "used_constants_count" => planner.used_constants.length,
          "unused_constants_count" => planner.unused_constants.length,
          "unused_features_count" => planner.unused_features.length,
          "runtime_memory_summary" => planner.runtime_memory_summary.to_h,
        },
        "pruning" => {
          "disabled_frameworks" => [],
          "disabled_railties" => [],
          "disabled_initializers" => [],
          "disabled_require_paths" => planner.unused_require_paths,
          "disabled_require_path_provenance" => planner.unused_require_path_provenance,
          "disabled_constants" => planner.unused_constants.to_a.sort,
          "autoload_ignores" => [],
          "eager_load_ignores" => [],
        },
        "safety" => {
          "always_keep" => [],
          "manual_keep" => [],
          "confidence_threshold" => 0.98,
          "production_allowed" => false,
          "failure_mode" => "raise",
        },
        "explanations" => {},
      }

      new(payload).tap do |profile|
        profile.payload["profile_id"] = profile.digest
      end
    end

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
      payload["profile_id"]
    end

    def deterministic?
      schema_version == DETERMINISTIC_SCHEMA_VERSION
    end

    def canonical_json
      CanonicalJson.dump(payload)
    end

    def digest
      digest_payload = payload.merge("profile_id" => nil)
      "sha256:#{Digest::SHA256.hexdigest(CanonicalJson.digestible(digest_payload))}"
    end

    def validate!(context)
      ProfileValidator.new(profile: self, context: context).validate!
    end
  end
end
