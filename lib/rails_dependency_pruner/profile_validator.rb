# frozen_string_literal: true

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

      unless profile.schema_version == 2
        errors << "profile schema #{profile.schema_version || "(missing)"} is not deterministic schema 2"
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

      errors
    end

    private
      def compare(errors, key, expected, actual)
        return if expected == actual

        errors << "#{key} mismatch: expected #{expected.inspect}, got #{actual.inspect}"
      end
  end
end
