# frozen_string_literal: true

module RailsDependencyPruner
  class ProfileExplainer
    attr_reader :profile

    def initialize(profile:)
      @profile = profile
    end

    def explain(target)
      target = target.to_s
      return explain_require(target.delete_prefix("require:")) if target.start_with?("require:")

      normalized = normalize_framework(target)
      explanation = explanations[normalized] || explanations[target]

      if explanation
        framework_explanation(target, normalized, explanation)
      elsif disabled_constant = matching_disabled_constant(target)
        disabled_constant_explanation(target, disabled_constant)
      else
        unknown_explanation(target)
      end
    end

    private
      def explain_require(require_path)
        decision =
          if disabled_railties.include?(require_path)
            "pruned"
          elsif disabled_require_paths.include?(require_path)
            "disabled"
          elsif required_railties.include?(require_path)
            "kept"
          else
            "unknown"
          end

        {
          "query" => "require:#{require_path}",
          "target" => require_path,
          "target_type" => "require_path",
          "decision" => decision,
          "reason" => require_reason(decision),
          "evidence" => require_evidence(require_path),
        }
      end

      def framework_explanation(query, framework, explanation)
        decision = explanation.fetch("decision")

        {
          "query" => query,
          "target" => framework,
          "target_type" => "framework",
          "decision" => decision == "disable_framework" ? "pruned" : "kept",
          "reason" => framework_reason(decision),
          "evidence" => explanation,
        }
      end

      def disabled_constant_explanation(query, constant)
        {
          "query" => query,
          "target" => constant,
          "target_type" => "constant",
          "decision" => "disabled",
          "reason" => "constant is listed in profile pruning.disabled_constants",
          "evidence" => {
            "constant" => constant,
          },
        }
      end

      def unknown_explanation(query)
        {
          "query" => query,
          "target" => query,
          "target_type" => "unknown",
          "decision" => "unknown",
          "reason" => "profile has no matching framework, require path, or disabled constant evidence",
          "evidence" => {},
        }
      end

      def normalize_framework(target)
        value = target.to_s.delete("_").downcase
        framework_aliases.fetch(value, target.to_s)
      end

      def framework_aliases
        @framework_aliases ||= frameworks.each_with_object({}) do |framework, aliases|
          aliases[framework.delete("_")] = framework
          aliases[framework] = framework
          aliases[framework.sub(/^action/, "action_")] = framework
          aliases[framework.sub(/^active/, "active_")] = framework
        end.merge(
          "activestorage" => "activestorage",
          "active_storage" => "activestorage",
          "actiontext" => "actiontext",
          "action_text" => "actiontext",
          "actioncable" => "actioncable",
          "action_cable" => "actioncable",
          "actionmailbox" => "actionmailbox",
          "action_mailbox" => "actionmailbox",
          "actionmailer" => "actionmailer",
          "action_mailer" => "actionmailer",
          "activerecord" => "activerecord",
          "active_record" => "activerecord",
          "activejob" => "activejob",
          "active_job" => "activejob",
          "actionpack" => "actionpack",
          "action_pack" => "actionpack",
          "actionview" => "actionview",
          "action_view" => "actionview",
          "activesupport" => "activesupport",
          "active_support" => "activesupport",
          "railties" => "railties",
        )
      end

      def frameworks
        (explanations.keys + Array(profile.payload.dig("rails", "frameworks"))).map(&:to_s).uniq
      end

      def matching_disabled_constant(target)
        disabled_constants.find do |constant|
          constant == target || constant.start_with?("#{target}::")
        end
      end

      def require_evidence(require_path)
        {
          "required_railties" => required_railties.include?(require_path) ? [require_path] : [],
          "disabled_railties" => disabled_railties.include?(require_path) ? [require_path] : [],
          "disabled_require_paths" => disabled_require_paths.include?(require_path) ? [require_path] : [],
        }
      end

      def require_reason(decision)
        case decision
        when "kept"
          "require path is listed in profile boot_plan.required_railties"
        when "pruned"
          "require path is listed in profile pruning.disabled_railties"
        when "disabled"
          "require path is listed in profile pruning.disabled_require_paths"
        else
          "profile has no matching require-path decision"
        end
      end

      def framework_reason(decision)
        case decision
        when "disable_framework"
          "framework is listed in profile pruning.disabled_frameworks"
        else
          "framework is required by the profile boot plan"
        end
      end

      def explanations
        profile.payload.fetch("explanations", {})
      end

      def required_railties
        Array(profile.payload.dig("boot_plan", "required_railties"))
      end

      def disabled_railties
        Array(profile.payload.dig("pruning", "disabled_railties"))
      end

      def disabled_require_paths
        Array(profile.payload.dig("pruning", "disabled_require_paths"))
      end

      def disabled_constants
        Array(profile.payload.dig("pruning", "disabled_constants") || profile.payload["unused_constants"])
      end
  end
end
