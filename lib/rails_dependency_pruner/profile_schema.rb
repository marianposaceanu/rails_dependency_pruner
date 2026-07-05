# frozen_string_literal: true

require_relative "safety_policy"

module RailsDependencyPruner
  module ProfileSchema
    UNEXPECTED_EVENT_POLICIES = %w[
      report
      fail_boot
      fail_all
      fail_in_canary_report_in_production
    ].freeze

    module_function

    def profile_id(payload)
      payload.dig("fingerprints", "profile_id") || payload["profile_id"]
    end

    def set_profile_id(payload, profile_id)
      payload["profile_id"] = profile_id
      payload["fingerprints"] ||= {}
      payload["fingerprints"]["profile_id"] = profile_id
    end

    def digest_payload(payload)
      payload.merge(
        "profile_id" => nil,
        "fingerprints" => (payload["fingerprints"] || {}).merge("profile_id" => nil),
      )
    end

    def deterministic_schema?(schema_version)
      [2, 3].include?(schema_version)
    end

    def valid_unexpected_event_policy?(policy)
      UNEXPECTED_EVENT_POLICIES.include?(policy.to_s)
    end

    def migrate_v2(payload)
      return payload unless payload["schema_version"] == 2

      migrated = payload.dup
      migrated["schema_version"] = 3
      migrated["tool"] ||= {
        "name" => "rails_dependency_pruner",
        "version" => migrated.dig("analysis", "scanner_version"),
        "git_sha" => nil,
      }
      migrated["environment"] ||= {
        "ruby_version" => migrated.dig("ruby", "version"),
        "rails_version" => migrated.dig("rails", "version"),
        "bundler_version" => migrated.dig("bundler", "version"),
        "platform" => migrated.dig("ruby", "platform"),
        "rails_env" => migrated.dig("app", "rails_env"),
        "bundle_without" => migrated.dig("bundler", "without"),
        "bundle_with" => migrated.dig("bundler", "with"),
      }
      migrated["fingerprints"] ||= {
        "profile_id" => migrated["profile_id"],
        "gemfile_lock_sha256" => migrated.dig("bundler", "gemfile_lock_digest"),
        "source_manifest_sha256" => migrated.dig("app", "files_digest"),
        "coverage_manifest_sha256" => migrated.dig("evidence", "coverage_manifest_digest"),
      }
      migrated["expected_events"] ||= []
      migrated["unexpected_event_policy"] ||= "fail_in_canary_report_in_production"
      migrated["lazy_constants"] ||= {}
      migrated["safety_policy"] ||= SafetyPolicy.defaults
      migrated["overrides"] ||= []
      migrated
    end
  end
end
