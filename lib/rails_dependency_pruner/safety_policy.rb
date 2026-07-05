# frozen_string_literal: true

module RailsDependencyPruner
  class SafetyPolicy
    DEFAULTS = {
      "unknown_dynamic_require" => "reject",
      "unknown_dynamic_load" => "reject",
      "unknown_dynamic_constantize" => "reject_if_pruned_namespace_possible",
      "runtime_evidence_truncated" => "reject",
      "missing_coverage_section" => "reject_for_related_transform",
      "unclassified_lazy_gem" => "reject",
      "high_risk_transform_without_explicit_proof" => "reject",
      "unexpected_boot_event" => "reject",
      "unexpected_request_event_in_canary" => "reject",
      "stale_fingerprint" => "reject",
      "missing_profile_id" => "reject",
    }.freeze

    class << self
      def defaults
        DEFAULTS.dup
      end

      def normalize(policy)
        defaults.merge(deep_stringify(policy || {}))
      end

      def gaps(policy)
        normalized = deep_stringify(policy || {})
        DEFAULTS.filter_map do |key, expected|
          actual = normalized[key]
          next if actual == expected

          {
            "key" => key,
            "expected" => expected,
            "actual" => actual || "(missing)",
          }
        end
      end

      private
        def deep_stringify(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, nested), hash|
              hash[key.to_s] = deep_stringify(nested)
            end
          when Array
            value.map { |nested| deep_stringify(nested) }
          else
            value
          end
        end
    end
  end
end
