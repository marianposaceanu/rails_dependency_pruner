# frozen_string_literal: true

require "set"
require "pathname"

require_relative "boot_plan"
require_relative "coverage_manifest"
require_relative "memory_policy"
require_relative "runtime_framework_matcher"
require_relative "transform_registry"

module RailsDependencyPruner
  class ProfileVerifier
    UNIVERSAL_DYNAMIC_CONSTANT_RECEIVERS = %w[Kernel Object].freeze
    ACTIVE_STORAGE_ATTACHMENT_PATTERNS = %w[has_many_attached has_one_attached].freeze
    COVERAGE_WORKLOAD_REQUIREMENTS = {
      "actioncable" => %w[cable],
      "actionmailbox" => %w[routes],
      "actionmailer" => %w[mailers],
      "activejob" => %w[jobs],
      "activestorage" => %w[routes],
    }.freeze
    EXTREME_BOOT_WORKLOAD_REQUIREMENTS = {
      "action_mailbox/engine" => %w[inbound_email routes],
      "action_mailbox/mail_ext" => %w[inbound_email],
      "action_mailer/railtie" => %w[mailers],
      "active_job/railtie" => %w[jobs],
      "active_storage/engine" => %w[attachments routes],
      "disable_eager_load" => %w[requests],
      "rack-mini-profiler" => %w[requests],
    }.freeze
    SUPPORTED_LAZY_REQUIRE_PATHS = %w[
      action_mailbox/mail_ext
    ].freeze
    EXTREME_BOOT_STATIC_RULES = {
      "action_mailbox/engine" => {
        "paths" => %w[app/mailboxes],
        "constants" => %w[ActionMailbox],
        "framework" => "actionmailbox",
      },
      "action_mailer/railtie" => {
        "paths" => %w[app/mailers],
        "constants" => %w[ActionMailer],
        "framework" => "actionmailer",
      },
      "active_job/railtie" => {
        "paths" => %w[app/jobs],
        "constants" => %w[ActiveJob],
        "framework" => "activejob",
      },
      "active_storage/engine" => {
        "constants" => %w[ActiveStorage],
        "framework" => "activestorage",
      },
    }.freeze
    CONFIG_NAMESPACE_BY_RAILTIE = {
      "action_mailbox/engine" => "action_mailbox",
      "active_storage/engine" => "active_storage",
    }.freeze
    RAILTIE_FRAMEWORKS = BootPlan::RAILTIE_REQUIRE_PATHS.invert.freeze

    attr_reader :profile, :context, :index, :usage, :production, :measurement

    def initialize(profile:, context:, index:, usage:, production: false, measurement: nil)
      @profile = profile
      @context = context
      @index = index
      @usage = usage
      @production = production
      @measurement = measurement
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
        missing_profile_transforms.each do |id|
          errors << "production verify missing registered transform: #{id}"
        end
        unknown_profile_transforms.each do |id|
          errors << "production verify found unknown transform: #{id}"
        end
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
        extreme_boot_workload_gaps.each do |gap|
          errors << "production verify missing coverage workload for extreme boot: #{format_coverage_workload_gap(gap)}"
        end
        extreme_boot_static_matches.each do |match|
          errors << "production verify found extreme boot static evidence: #{format_extreme_boot_static_match(match)}"
        end
        unsupported_lazy_require_paths.each do |path|
          errors << "production verify found unsupported lazy require path: #{path}"
        end
        unsupported_lazy_gems.each do |name|
          errors << "production verify found unsupported lazy gem: #{name}"
        end
        high_risk_transform_gaps.each do |gap|
          errors << "production verify missing high-risk transform proof: #{format_high_risk_transform_gap(gap)}"
        end
        disabled_framework_runtime_matches.each do |match|
          errors << "production verify found disabled framework runtime evidence: #{format_runtime_framework_match(match)}"
        end
        memory_policy_result.fetch("errors").each do |error|
          errors << "production verify #{error}"
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
          "extreme_boot_workload_gaps" => extreme_boot_workload_gaps,
          "missing_profile_transforms" => missing_profile_transforms,
          "unknown_profile_transforms" => unknown_profile_transforms,
          "extreme_boot_static_matches" => extreme_boot_static_matches,
          "unsupported_lazy_require_paths" => unsupported_lazy_require_paths,
          "unsupported_lazy_gems" => unsupported_lazy_gems,
          "high_risk_transform_gaps" => high_risk_transform_gaps,
          "disabled_framework_runtime_matches" => disabled_framework_runtime_matches,
          "memory_policy" => memory_policy_result,
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
        ).matches(disabled_frameworks + extreme_boot_disabled_frameworks)
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

      def extreme_boot
        profile.payload["extreme_boot"] || {}
      end

      def extreme_boot_disabled_frameworks
        @extreme_boot_disabled_frameworks ||= Array(extreme_boot["skip_railties"]).filter_map do |railtie|
          RAILTIE_FRAMEWORKS[railtie]
        end
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

      def extreme_boot_workload_gaps
        @extreme_boot_workload_gaps ||= begin
          gaps = []
          if extreme_boot["disable_eager_load"] == true
            gaps << workload_gap("disable_eager_load", EXTREME_BOOT_WORKLOAD_REQUIREMENTS.fetch("disable_eager_load"))
          end

          Array(extreme_boot["skip_railties"]).each do |railtie|
            required_workloads = extreme_boot_required_workloads(railtie)
            gaps << workload_gap(railtie, required_workloads)
          end
          Array(extreme_boot["lazy_require_paths"]).each do |path|
            required_workloads = extreme_boot_required_workloads(path)
            gaps << workload_gap(path, required_workloads)
          end
          Array(extreme_boot["lazy_gems"]).each do |gem_name|
            required_workloads = extreme_boot_required_workloads(gem_name)
            gaps << workload_gap(extreme_boot_workload_name(gem_name), required_workloads)
          end

          gaps.compact.sort_by { |gap| gap.fetch("framework") }
        end
      end

      def extreme_boot_required_workloads(name)
        required_workloads = EXTREME_BOOT_WORKLOAD_REQUIREMENTS.fetch(name, [])
        if name == "active_storage/engine" && action_mailbox_static_usage?
          required_workloads += %w[inbound_email]
        end
        if name == "ruby-vips" && active_storage_attachment_static_usage? && !high_risk_override?("stub:active_storage_vips_analyzer")
          required_workloads += %w[attachments]
        end

        required_workloads.uniq
      end

      def extreme_boot_workload_name(name)
        case name
        when "rack-mini-profiler"
          "stub:rack_mini_profiler"
        when "ruby-vips"
          "stub:active_storage_vips_analyzer"
        else
          name
        end
      end

      def missing_profile_transforms
        @missing_profile_transforms ||= TransformRegistry.missing_transform_ids(profile.payload)
      end

      def unknown_profile_transforms
        @unknown_profile_transforms ||= TransformRegistry.unknown_transform_ids(profile.payload)
      end

      def unsupported_lazy_require_paths
        @unsupported_lazy_require_paths ||= Array(extreme_boot["lazy_require_paths"]).map(&:to_s).reject do |path|
          SUPPORTED_LAZY_REQUIRE_PATHS.include?(path)
        end.sort
      end

      def unsupported_lazy_gems
        @unsupported_lazy_gems ||= Array(extreme_boot["lazy_gems"]).map(&:to_s).reject do |name|
          TransformRegistry.lazy_gem_supported?(name)
        end.sort
      end

      def high_risk_transform_gaps
        @high_risk_transform_gaps ||= begin
          gaps = []

          if extreme_boot["disable_eager_load"] == true
            missing = disable_eager_load_latency_policy_gaps
            gaps << high_risk_gap("disable_eager_load", "latency_policy", missing) unless missing.empty?
          end

          if Array(extreme_boot["lazy_gems"]).map(&:to_s).include?("ruby-vips")
            missing = active_storage_vips_proof_gaps
            unless missing.empty?
              gaps << high_risk_gap(
                "stub:active_storage_vips_analyzer",
                "active_storage_vips_stub",
                missing,
                alternative: "unexpired high_risk_overrides.stub_active_storage_vips_analyzer",
              )
            end
          end

          gaps.sort_by { |gap| gap.fetch("transform_id") }
        end
      end

      def extreme_boot_static_matches
        @extreme_boot_static_matches ||= begin
          matches = Array(extreme_boot["skip_railties"]).flat_map do |railtie|
            rules = EXTREME_BOOT_STATIC_RULES.fetch(railtie, {})
            path_matches(railtie, Array(rules["paths"])) +
              constant_matches(railtie, Array(rules["constants"])) +
              framework_feature_matches(railtie, rules["framework"])
          end

          matches.uniq.sort_by do |match|
            [match.fetch("railtie"), match.fetch("kind"), match.fetch("path").to_s, match["line"].to_i, match["name"].to_s]
          end
        end
      end

      def action_mailbox_static_usage?
        @action_mailbox_static_usage ||= begin
          rules = EXTREME_BOOT_STATIC_RULES.fetch("action_mailbox/engine")
          (
            path_matches("action_mailbox/engine", Array(rules["paths"])) +
            constant_matches("action_mailbox/engine", Array(rules["constants"])) +
            framework_feature_matches("action_mailbox/engine", rules["framework"])
          ).any?
        end
      end

      def active_storage_attachment_static_usage?
        @active_storage_attachment_static_usage ||= usage.feature_matches.any? do |match|
          match["framework"] == "activestorage" &&
            ACTIVE_STORAGE_ATTACHMENT_PATTERNS.include?(match["pattern"])
        end
      end

      def disable_eager_load_latency_policy_gaps
        missing = []
        unless policy_gate?("max_first_request_latency_regression_ms", "max_first_request_latency_regression_percent")
          missing << "memory_policy.max_first_request_latency_regression_*"
        end
        unless policy_gate?(
          "max_request_p95_latency_regression_ms",
          "max_request_p95_latency_regression_percent",
          "max_warmed_p95_latency_regression_ms",
          "max_warmed_p95_latency_regression_percent",
        )
          missing << "memory_policy.max_request_p95_latency_regression_* or max_warmed_p95_latency_regression_*"
        end
        unless policy_gate?(
          "max_request_p99_latency_regression_ms",
          "max_request_p99_latency_regression_percent",
          "max_warmed_p99_latency_regression_ms",
          "max_warmed_p99_latency_regression_percent",
        )
          missing << "memory_policy.max_request_p99_latency_regression_* or max_warmed_p99_latency_regression_*"
        end

        missing
      end

      def active_storage_vips_proof_gaps
        return [] unless active_storage_attachment_static_usage?
        return [] if high_risk_override?("stub:active_storage_vips_analyzer")

        actions = coverage_manifest&.active_storage_actions || []
        missing_actions = CoverageManifest::ACTIVE_STORAGE_ACTIONS - actions
        missing_actions.map { |action| "active_storage.#{action}" }
      end

      def policy_gate?(*keys)
        policy = profile.payload["memory_policy"]
        return false unless policy.is_a?(Hash)

        keys.any? do |key|
          value = policy[key]
          !value.nil? && !value.to_s.empty?
        end
      end

      def high_risk_override?(transform_id)
        !!coverage_manifest&.high_risk_override(transform_id)
      end

      def coverage_manifest
        context.coverage_manifest
      end

      def path_matches(railtie, paths)
        paths.flat_map do |path|
          root = usage.app_root.join(path)
          next [] unless root.directory?

          Pathname.glob(root.join("**/*.rb").to_s).sort.map do |file|
            {
              "railtie" => railtie,
              "kind" => "path",
              "path" => file.relative_path_from(usage.app_root).to_s,
            }
          end
        end
      end

      def constant_matches(railtie, prefixes)
        usage.rails_references.filter_map do |reference|
          next unless static_path_relevant?(reference.fetch(:path))
          next if config_namespace_stub_reference?(railtie, reference)

          constant = reference.fetch(:constant)
          next unless prefixes.any? { |prefix| constant == prefix || constant.start_with?("#{prefix}::") }

          {
            "railtie" => railtie,
            "kind" => "constant",
            "name" => constant,
            "path" => reference.fetch(:path),
            "line" => reference.fetch(:line),
          }
        end
      end

      def framework_feature_matches(railtie, framework)
        return [] if framework.nil? || framework.empty?

        (usage.feature_matches + usage.route_matches).filter_map do |match|
          next unless static_path_relevant?(match.fetch("path"))
          next unless match["framework"] == framework

          {
            "railtie" => railtie,
            "kind" => match.key?("route_signature") ? "route" : "feature",
            "name" => match["feature"],
            "path" => match.fetch("path"),
            "line" => match.fetch("line"),
          }
        end
      end

      def static_path_relevant?(path)
        match = path.to_s.match(%r{\Aconfig/environments/([^/]+)\.rb\z})
        return true unless match

        match[1] == context.rails_env.to_s
      end

      def config_namespace_stub_reference?(railtie, reference)
        namespace = CONFIG_NAMESPACE_BY_RAILTIE[railtie]
        return false unless namespace
        return false unless Array(extreme_boot["config_namespace_stubs"]).include?(namespace)

        usage.config_matches.any? do |match|
          match["path"] == reference.fetch(:path) &&
            match["line"] == reference.fetch(:line) &&
            match["config_path"].to_s.start_with?("#{namespace}.")
        end
      end

      def workload_gap(name, required_workloads)
        missing_workloads = required_workloads - coverage_workloads
        return if missing_workloads.empty?

        {
          "framework" => name,
          "required_workloads" => required_workloads,
          "missing_workloads" => missing_workloads,
        }
      end

      def coverage_workloads
        @coverage_workloads ||= Array(profile.payload.dig("evidence", "workloads")).map(&:to_s).sort
      end

      def memory_policy_result
        @memory_policy_result ||= begin
          policy = profile.payload["memory_policy"]
          if policy.nil? || policy.empty?
            { "configured" => false, "passed" => true, "errors" => [], "warnings" => [] }
          elsif measurement.nil?
            {
              "configured" => true,
              "passed" => false,
              "errors" => ["memory policy requires --measurement"],
              "warnings" => [],
            }
          else
            MemoryPolicy.new(policy: policy, measurement: measurement).evaluate
          end
        end
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

      def format_extreme_boot_static_match(match)
        if match["kind"] == "path"
          return [
            match.fetch("railtie"),
            match.fetch("kind"),
            match.fetch("path"),
          ].join(":")
        end

        [
          match.fetch("railtie"),
          match.fetch("kind"),
          match["name"] || match["path"],
          match["path"],
          match["line"],
        ].compact.join(":")
      end

      def format_coverage_workload_gap(gap)
        "#{gap.fetch("framework")} requires #{gap.fetch("missing_workloads").join(", ")}"
      end

      def high_risk_gap(transform_id, requirement, missing_requirements, alternative: nil)
        gap = {
          "transform_id" => transform_id,
          "requirement" => requirement,
          "missing_requirements" => missing_requirements,
        }
        gap["alternative"] = alternative if alternative
        gap
      end

      def format_high_risk_transform_gap(gap)
        required = gap.fetch("missing_requirements").join(", ")
        required = "#{required}, or #{gap.fetch("alternative")}" if gap["alternative"]

        "#{gap.fetch("transform_id")} requires #{required}"
      end
  end
end
