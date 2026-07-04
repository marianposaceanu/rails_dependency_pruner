# frozen_string_literal: true

require "set"

module RailsDependencyPruner
  class ProfileVerifier
    UNIVERSAL_DYNAMIC_CONSTANT_RECEIVERS = %w[Kernel Object].freeze

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
  end
end
