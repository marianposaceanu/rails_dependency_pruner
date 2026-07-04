# frozen_string_literal: true

module RailsDependencyPruner
  class ProfileVerifier
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

      {
        "verified" => errors.empty?,
        "production_allowed" => errors.empty?,
        "errors" => errors,
        "warnings" => warnings,
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
  end
end
