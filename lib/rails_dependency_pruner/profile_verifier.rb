# frozen_string_literal: true

require "set"

require_relative "runtime_framework_matcher"

module RailsDependencyPruner
  class ProfileVerifier
    UNIVERSAL_DYNAMIC_CONSTANT_RECEIVERS = %w[Kernel Object].freeze
    COVERAGE_WORKLOAD_REQUIREMENTS = {
      "actioncable" => %w[cable],
      "actionmailbox" => %w[routes],
      "actionmailer" => %w[mailers],
      "activejob" => %w[jobs],
      "activestorage" => %w[routes],
    }.freeze

    attr_reader :profile, :context, :index, :usage, :production

    def initialize(profile:, context:, index:, usage:, production: false)
      @profile = profile
      @context = context
      @index = index
      @usage = usage
      @production = production
    end

    def verify
      errors = []
      warnings = []

      validate_profile(errors)
      errors << "Rails parse errors present: #{index.parse_errors.length}" unless index.parse_errors.empty?
      errors << "App parse errors present: #{usage.parse_errors.length}" unless usage.parse_errors.empty?
      if production && profile.payload.dig("evidence", "coverage_manifest_digest").nil?
        errors << "production verify requires a coverage manifest digest"
      end
      if production
        truncated_runtime_evidence.each do |name|
          errors << "production verify found truncated runtime evidence: #{name}"
        end
        dynamic_boot_require_risks.each do |risk|
          errors << "production verify found dynamic require/load risk: #{format_match(risk)}"
        end
        dynamic_constantization_risks.each do |risk|
          errors << "production verify found dynamic constantization risk for pruned constants: #{format_match(risk)}"
        end
        coverage_workload_gaps.each do |gap|
          errors << "production verify missing coverage workload for disabled framework: #{format_coverage_workload_gap(gap)}"
        end
        disabled_framework_runtime_matches.each do |match|
          errors << "production verify found disabled framework runtime evidence: #{format_runtime_framework_match(match)}"
        end
      end

      {
        "verified" => errors.empty?,
        "production_allowed" => errors.empty?,
        "errors" => errors,
        "warnings" => warnings,
        "production_risks" => {
          "truncated_runtime_evidence" => truncated_runtime_evidence,
          "dynamic_boot_require_matches" => dynamic_boot_require_risks,
          "dynamic_constantization_matches" => dynamic_constantization_risks,
          "coverage_workload_gaps" => coverage_workload_gaps,
          "disabled_framework_runtime_matches" => disabled_framework_runtime_matches,
        },
        "profile" => {
          "schema_version" => profile.schema_version,
          "profile_id" => profile.profile_id,
          "rails_version" => profile.rails_version,
          "production_allowed" => profile.payload.dig("safety", "production_allowed"),
        },
        "parse_errors" => {
          "rails" => index.parse_errors,
          "app" => usage.parse_errors,
        },
      }
    end

    private
      def validate_profile(errors)
        profile.validate!(context)
      rescue ProfileValidator::ValidationError => error
        errors.concat(error.message.split("\n"))
      end

      def dynamic_boot_require_risks
        @dynamic_boot_require_risks ||= usage.sorted_require_matches.select do |match|
          match["dynamic"] && boot_critical_path?(match.fetch("path"))
        end
      end

      def truncated_runtime_evidence
        @truncated_runtime_evidence ||= runtime_evidence_truncation.filter_map do |name, truncated|
          name if truncated == true
        end.sort
      end

      def runtime_evidence_truncation
        profile.payload.dig("summary", "runtime_evidence_truncation") ||
          profile.payload["runtime_evidence_truncation"] ||
          {}
      end

      def disabled_framework_runtime_matches
        @disabled_framework_runtime_matches ||= RuntimeFrameworkMatcher.new(
          applications: runtime_rails_applications,
        ).matches(disabled_frameworks)
      end

      def runtime_rails_applications
        Array(
          profile.payload.dig("summary", "runtime_rails_application") ||
            profile.payload["runtime_rails_application"],
        )
      end

      def disabled_frameworks
        Array(profile.payload.dig("pruning", "disabled_frameworks"))
      end

      def coverage_workload_gaps
        @coverage_workload_gaps ||= disabled_frameworks.filter_map do |framework|
          required_workloads = COVERAGE_WORKLOAD_REQUIREMENTS.fetch(framework, [])
          missing_workloads = required_workloads - coverage_workloads
          next if missing_workloads.empty?

          {
            "framework" => framework,
            "required_workloads" => required_workloads,
            "missing_workloads" => missing_workloads,
          }
        end.sort_by { |gap| gap.fetch("framework") }
      end

      def coverage_workloads
        @coverage_workloads ||= Array(profile.payload.dig("evidence", "workloads")).map(&:to_s).sort
      end

      def dynamic_constantization_risks
        @dynamic_constantization_risks ||= begin
          namespaces = pruned_namespaces
          if namespaces.empty?
            []
          else
            usage.sorted_dynamic_matches.select do |match|
              match["dynamic"] && dynamic_constantization_risk?(match, namespaces)
            end
          end
        end
      end

      def dynamic_constantization_risk?(match, pruned_namespaces)
        constant = match["constant"].to_s
        return true if constant.empty?

        namespace = constant.split("::").first
        return true if UNIVERSAL_DYNAMIC_CONSTANT_RECEIVERS.include?(namespace)

        pruned_namespaces.include?(namespace)
      end

      def pruned_namespaces
        @pruned_namespaces ||= profile.unused_constants.map { |constant| constant.split("::").first }.to_set
      end

      def boot_critical_path?(path)
        path.to_s.start_with?("config/") && path.to_s.end_with?(".rb")
      end

      def format_match(match)
        [
          match.fetch("path"),
          match.fetch("line"),
          match.fetch("kind"),
        ].join(":")
      end

      def format_runtime_framework_match(match)
        [
          match.fetch("framework"),
          match.fetch("kind"),
          match["name"] || match["path"] || match["controller"],
        ].compact.join(":")
      end

      def format_coverage_workload_gap(gap)
        "#{gap.fetch("framework")} requires #{gap.fetch("missing_workloads").join(", ")}"
      end
  end
end
