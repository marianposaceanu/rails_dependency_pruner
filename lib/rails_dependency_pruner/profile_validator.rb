# frozen_string_literal: true

require_relative "profile_schema"

module RailsDependencyPruner
  class ProfileValidator
    ValidationError = Class.new(StandardError)

    attr_reader :profile, :context

    def initialize(profile:, context:)
      @profile = profile
      @context = context
    end

    def validate!
      errors = validation_errors
      raise ValidationError, errors.join("\n") unless errors.empty?

      true
    end

    def validation_errors
      errors = []

      unless ProfileSchema.deterministic_schema?(profile.schema_version)
        errors << "profile schema #{profile.schema_version || "(missing)"} is not deterministic schema 2 or 3"
        return errors
      end

      if profile.profile_id != profile.digest
        errors << "profile_id mismatch: expected #{profile.digest}, got #{profile.profile_id || "(missing)"}"
      end

      compare(errors, "ruby.version", profile.payload.dig("ruby", "version"), context.ruby_context.fetch("version"))
      compare(errors, "ruby.platform", profile.payload.dig("ruby", "platform"), context.ruby_context.fetch("platform"))
      compare(errors, "rails.version", profile.payload.dig("rails", "version"), context.rails_context.fetch("version"))
      compare(errors, "rails.frameworks", profile.payload.dig("rails", "frameworks"), context.rails_context.fetch("frameworks"))
      compare(errors, "rails.source_digest", profile.payload.dig("rails", "source_digest"), context.rails_context.fetch("source_digest"))
      compare(errors, "bundler.gemfile_lock_digest", profile.payload.dig("bundler", "gemfile_lock_digest"), context.bundler_context.fetch("gemfile_lock_digest"))
      compare(errors, "app.files_digest", profile.payload.dig("app", "files_digest"), context.app_context.fetch("files_digest"))
      compare(errors, "app.rails_env", profile.payload.dig("app", "rails_env"), context.app_context.fetch("rails_env"))
      compare(errors, "analysis.scan_roots", profile.payload.dig("analysis", "scan_roots"), context.analysis_context.fetch("scan_roots"))
      compare(errors, "evidence.runtime_evidence_digests", profile.payload.dig("evidence", "runtime_evidence_digests"), context.evidence_context.fetch("runtime_evidence_digests"))
      compare(errors, "evidence.coverage_manifest_digest", profile.payload.dig("evidence", "coverage_manifest_digest"), context.evidence_context.fetch("coverage_manifest_digest"))
      compare(errors, "evidence.workloads", profile.payload.dig("evidence", "workloads"), context.evidence_context.fetch("workloads"))
      validate_v3!(errors) if profile.schema_version == 3

      errors
    end

    private
      def validate_v3!(errors)
        compare(errors, "tool.name", profile.payload.dig("tool", "name"), context.tool_context.fetch("name"))
        compare(errors, "tool.version", profile.payload.dig("tool", "version"), context.tool_context.fetch("version"))
        compare(errors, "tool.git_sha", profile.payload.dig("tool", "git_sha"), context.tool_context.fetch("git_sha"))
        compare(errors, "environment.ruby_version", profile.payload.dig("environment", "ruby_version"), context.environment_context.fetch("ruby_version"))
        compare(errors, "environment.rails_version", profile.payload.dig("environment", "rails_version"), context.environment_context.fetch("rails_version"))
        compare(errors, "environment.bundler_version", profile.payload.dig("environment", "bundler_version"), context.environment_context.fetch("bundler_version"))
        compare(errors, "environment.platform", profile.payload.dig("environment", "platform"), context.environment_context.fetch("platform"))
        compare(errors, "environment.rails_env", profile.payload.dig("environment", "rails_env"), context.environment_context.fetch("rails_env"))
        compare(errors, "environment.bundle_without", profile.payload.dig("environment", "bundle_without"), context.environment_context.fetch("bundle_without"))
        compare(errors, "environment.bundle_with", profile.payload.dig("environment", "bundle_with"), context.environment_context.fetch("bundle_with"))
        context.fingerprints_context.each do |key, value|
          next if key == "profile_id"

          compare(errors, "fingerprints.#{key}", profile.payload.dig("fingerprints", key), value)
        end
        compare(errors, "overrides", Array(profile.payload["overrides"]), context.safety_overrides_context)
      end

      def compare(errors, key, expected, actual)
        return if expected == actual

        errors << "#{key} mismatch: expected #{expected.inspect}, got #{actual.inspect}"
      end
  end
end
