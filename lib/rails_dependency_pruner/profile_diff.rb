# frozen_string_literal: true

module RailsDependencyPruner
  class ProfileDiff
    PRUNING_KEYS = %w[
      disabled_frameworks
      disabled_railties
      disabled_initializers
      disabled_require_paths
      disabled_constants
      autoload_ignores
      eager_load_ignores
    ].freeze

    CONTEXT_KEYS = %w[
      schema_version
      profile_id
      mode
      ruby
      rails
      bundler
      app
      analysis
      evidence
      tool
      environment
      fingerprints
      transforms
      expected_events
      unexpected_event_policy
      lazy_constants
      memory_policy
      safety_policy
      overrides
      safety
      summary
    ].freeze

    attr_reader :old_profile, :new_profile, :semantic

    def initialize(old_profile:, new_profile:, semantic: false)
      @old_profile = old_profile
      @new_profile = new_profile
      @semantic = semantic
    end

    def to_h
      {
        "changed" => changed?,
        "semantic" => semantic,
        "context_changes" => context_changes,
        "pruning_changes" => pruning_changes,
      }
    end

    def changed?
      !context_changes.empty? || pruning_changes.values.any? do |change|
        !change.fetch("added").empty? || !change.fetch("removed").empty?
      end
    end

    def context_changes
      CONTEXT_KEYS.filter_map do |key|
        old_value = old_context.fetch(key, nil)
        new_value = new_context.fetch(key, nil)
        next if old_value == new_value

        {
          "key" => key,
          "old" => old_value,
          "new" => new_value,
        }
      end
    end

    def pruning_changes
      PRUNING_KEYS.to_h do |key|
        old_values = Array(old_pruning[key]).map(&:to_s).sort
        new_values = Array(new_pruning[key]).map(&:to_s).sort

        [
          key,
          {
            "added" => new_values - old_values,
            "removed" => old_values - new_values,
            "old_count" => old_values.length,
            "new_count" => new_values.length,
          },
        ]
      end
    end

    private
      def old_context
        @old_context ||= context_for(old_profile.payload)
      end

      def new_context
        @new_context ||= context_for(new_profile.payload)
      end

      def old_pruning
        @old_pruning ||= pruning_for(old_profile.payload)
      end

      def new_pruning
        @new_pruning ||= pruning_for(new_profile.payload)
      end

      def context_for(payload)
        context = CONTEXT_KEYS.to_h do |key|
          [key, payload[key]]
        end
        return context unless semantic

        semantic_context(context)
      end

      def semantic_context(context)
        context = deep_dup(context)
        context["profile_id"] = nil
        context.dig("fingerprints")&.delete("profile_id")
        context.dig("safety")&.delete("production_allowed")
        context.dig("safety")&.delete("approved_at")
        context.dig("safety")&.delete("approved_by")
        context.dig("safety")&.delete("verifier_version")
        context.dig("safety")&.delete("errors")
        context.dig("safety")&.delete("warnings")
        context
      end

      def pruning_for(payload)
        pruning = payload["pruning"] || {}
        {
          "disabled_frameworks" => pruning["disabled_frameworks"],
          "disabled_railties" => pruning["disabled_railties"],
          "disabled_initializers" => pruning["disabled_initializers"],
          "disabled_require_paths" => pruning["disabled_require_paths"] || payload["unused_require_paths"],
          "disabled_constants" => pruning["disabled_constants"] || payload["unused_constants"],
          "autoload_ignores" => pruning["autoload_ignores"],
          "eager_load_ignores" => pruning["eager_load_ignores"],
        }
      end

      def deep_dup(value)
        case value
        when Hash
          value.transform_values { |nested| deep_dup(nested) }
        when Array
          value.map { |nested| deep_dup(nested) }
        else
          value
        end
      end
  end
end
