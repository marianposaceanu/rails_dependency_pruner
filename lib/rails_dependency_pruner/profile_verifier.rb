# frozen_string_literal: true

require "set"
require "pathname"
require "date"

require_relative "boot_plan"
require_relative "coverage_manifest"
require_relative "memory_policy"
require_relative "runtime_framework_matcher"
require_relative "safety_policy"
require_relative "transform_registry"

module RailsDependencyPruner
  class ProfileVerifier
    UNIVERSAL_DYNAMIC_CONSTANT_RECEIVERS = %w[Kernel Object].freeze
    ACTIVE_STORAGE_ATTACHMENT_PATTERNS = %w[has_many_attached has_one_attached].freeze
    COVERAGE_WORKLOAD_REQUIREMENTS = {
      "actioncable" => %w[cable],
      "actionmailbox" => %w[routes],
      "actionmailer" => %w[mailers],
      "actiontext" => %w[action_text],
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
    STRUCTURED_LAZY_GEM_REQUIRED_FIELDS = %w[
      boot_require_blocked
      class
      gem
      production_rule
      risk
      strategy
      strategies
    ].freeze
    EXTERNAL_INTEGRATION_GEM_CLASSES = %w[
      middleware_integration
      railtie_integration
      sdk_integration
    ].freeze
    MEASUREMENT_TARGETS = %w[application environment requests].freeze
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

    attr_reader :profile, :context, :index, :usage, :production, :measurement, :measurements

    def initialize(profile:, context:, index:, usage:, production: false, measurement: nil, measurements: nil)
      @profile = profile
      @context = context
      @index = index
      @usage = usage
      @production = production
      @measurement = measurement
      @measurements = measurements ? Array(measurements) : Array(measurement)
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
        transform_contract_gaps.each do |gap|
          errors << "production verify found incomplete transform contract: #{format_transform_contract_gap(gap)}"
        end
        truncated_runtime_evidence.each do |name|
          errors << "production verify found truncated runtime evidence: #{name}"
        end
        unexpected_runtime_events.each do |event|
          errors << "production verify found unexpected runtime event: #{format_runtime_event(event)}"
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
        catalog_coverage_gaps.each do |gap|
          errors << "production verify missing catalog coverage workload: #{format_catalog_coverage_gap(gap)}"
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
        unsupported_lazy_constant_policies.each do |policy|
          errors << "production verify found unsupported lazy constant policy: #{format_unsupported_lazy_constant_policy(policy)}"
        end
        structured_lazy_gem_policy_gaps.each do |gap|
          errors << "production verify missing structured lazy gem policy: #{format_structured_lazy_gem_policy_gap(gap)}"
        end
        external_integration_gaps.each do |gap|
          errors << "production verify missing external integration proof: #{format_external_integration_gap(gap)}"
        end
        lazy_gem_direct_usage_gaps.each do |gap|
          errors << "production verify missing lazy gem direct-use proof: #{format_lazy_gem_direct_usage_gap(gap)}"
        end
        lazy_constant_policy_gaps.each do |gap|
          errors << "production verify missing lazy constant policy: #{format_lazy_constant_policy_gap(gap)}"
        end
        safety_policy_gaps.each do |gap|
          errors << "production verify weak safety policy: #{format_safety_policy_gap(gap)}"
        end
        rollback_evidence_gaps.each do |gap|
          errors << "production verify missing rollback proof: #{format_rollback_evidence_gap(gap)}"
        end
        canary_evidence_gaps.each do |gap|
          errors << "production verify insufficient canary proof: #{format_canary_evidence_gap(gap)}"
        end
        high_risk_transform_gaps.each do |gap|
          errors << "production verify missing high-risk transform proof: #{format_high_risk_transform_gap(gap)}"
        end
        disabled_framework_runtime_matches.each do |match|
          errors << "production verify found disabled framework runtime evidence: #{format_runtime_framework_match(match)}"
        end
        measurement_context_gaps.each do |gap|
          errors << "production verify measurement context mismatch: #{format_measurement_context_gap(gap)}"
        end
        measurement_suite_gaps.each do |gap|
          errors << "production verify measurement suite mismatch: #{format_measurement_suite_gap(gap)}"
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
          "unexpected_runtime_events" => unexpected_runtime_events,
          "dynamic_boot_require_matches" => dynamic_boot_require_risks,
          "dynamic_constantization_matches" => dynamic_constantization_risks,
          "coverage_workload_gaps" => coverage_workload_gaps,
          "catalog_coverage_gaps" => catalog_coverage_gaps,
          "extreme_boot_workload_gaps" => extreme_boot_workload_gaps,
          "missing_profile_transforms" => missing_profile_transforms,
          "unknown_profile_transforms" => unknown_profile_transforms,
          "transform_contract_gaps" => transform_contract_gaps,
          "extreme_boot_static_matches" => extreme_boot_static_matches,
          "unsupported_lazy_require_paths" => unsupported_lazy_require_paths,
          "unsupported_lazy_gems" => unsupported_lazy_gems,
          "unsupported_lazy_constant_policies" => unsupported_lazy_constant_policies,
          "structured_lazy_gem_policy_gaps" => structured_lazy_gem_policy_gaps,
          "external_integration_gaps" => external_integration_gaps,
          "lazy_gem_direct_usage_gaps" => lazy_gem_direct_usage_gaps,
          "lazy_constant_policy_gaps" => lazy_constant_policy_gaps,
          "safety_policy_gaps" => safety_policy_gaps,
          "rollback_evidence_gaps" => rollback_evidence_gaps,
          "canary_evidence_gaps" => canary_evidence_gaps,
          "high_risk_transform_gaps" => high_risk_transform_gaps,
          "disabled_framework_runtime_matches" => disabled_framework_runtime_matches,
          "measurement_context_gaps" => measurement_context_gaps,
          "measurement_suite_gaps" => measurement_suite_gaps,
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
        end.reject do |match|
          safety_override_for?("dynamic_require_load", match)
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

      def runtime_event_summary
        profile.payload.dig("summary", "runtime_event_summary") ||
          profile.payload["runtime_event_summary"] ||
          {}
      end

      def unexpected_runtime_events
        @unexpected_runtime_events ||= begin
          files = Array(runtime_event_summary["files"])
          events = files.flat_map { |file| Array(file["unexpected_events"]) }
          if events.empty? && runtime_event_summary["unexpected_events_count"].to_i.positive?
            events << {
              "event_id" => "runtime_evidence",
              "unexpected_events_count" => runtime_event_summary["unexpected_events_count"],
            }
          end
          events
        end
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

      def catalog_coverage_gaps
        @catalog_coverage_gaps ||= catalog_coverage_targets.flat_map do |target|
          framework = target.fetch("framework")
          catalog_static_matches(framework).filter_map do |match|
            required_workloads = catalog_required_workloads(match)
            missing_workloads = required_workloads - coverage_workloads
            next if missing_workloads.empty?

            {
              "source" => "feature_catalog",
              "target" => target.fetch("target"),
              "target_kind" => target.fetch("target_kind"),
              "framework" => framework,
              "feature" => match.fetch("feature"),
              "evidence_kind" => match.fetch("evidence_kind"),
              "pattern" => match["pattern"],
              "path" => match.fetch("path"),
              "line" => match.fetch("line"),
              "required_workloads" => required_workloads,
              "missing_workloads" => missing_workloads,
              "negative_rules" => Array(match["negative_rules"]),
            }
          end
        end.uniq.sort_by do |gap|
          [
            gap.fetch("target"),
            gap.fetch("feature"),
            gap.fetch("path"),
            gap.fetch("line").to_i,
            gap.fetch("pattern").to_s,
          ]
        end
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

      def transform_contract_gaps
        @transform_contract_gaps ||= TransformRegistry.transform_contract_gaps(profile.payload)
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

      def structured_lazy_gem_policy_gaps
        @structured_lazy_gem_policy_gaps ||= Array(extreme_boot["lazy_gems"]).filter_map do |name|
          next unless TransformRegistry.lazy_gem_supported?(name)

          expected = TransformRegistry.lazy_gem_policy(name) || {}
          actual = profile.payload.dig("lazy_gems", name)
          unless actual.is_a?(Hash)
            next({
              "gem" => name,
              "missing_fields" => ["lazy_gems.#{name}"],
              "mismatched_fields" => [],
            })
          end

          missing_fields = structured_lazy_gem_missing_fields(actual, expected)
          mismatched_fields = structured_lazy_gem_mismatched_fields(name, actual, expected)
          next if missing_fields.empty? && mismatched_fields.empty?

          {
            "gem" => name,
            "missing_fields" => missing_fields,
            "mismatched_fields" => mismatched_fields,
          }
        end.sort_by { |gap| gap.fetch("gem") }
      end

      def lazy_constant_policy_gaps
        @lazy_constant_policy_gaps ||= lazy_constant_policy_requirements.filter_map do |requirement|
          constant = requirement.fetch("constant")
          actual = profile.payload.dig("lazy_constants", constant)
          unless actual.is_a?(Hash)
            next({
              "constant" => constant,
              "gem" => requirement.fetch("gem"),
              "missing_fields" => ["lazy_constants.#{constant}"],
              "mismatched_fields" => [],
            })
          end

          missing_fields = lazy_constant_missing_fields(actual)
          mismatched_fields = lazy_constant_mismatched_fields(actual, requirement.fetch("policy"))
          next if missing_fields.empty? && mismatched_fields.empty?

          {
            "constant" => constant,
            "gem" => requirement.fetch("gem"),
            "missing_fields" => missing_fields,
            "mismatched_fields" => mismatched_fields,
          }
        end.sort_by { |gap| [gap.fetch("gem"), gap.fetch("constant")] }
      end

      def unsupported_lazy_constant_policies
        @unsupported_lazy_constant_policies ||= begin
          expected_constants = lazy_constant_policy_requirements.map { |requirement| requirement.fetch("constant") }.to_set
          policies = profile.payload["lazy_constants"]
          if policies.is_a?(Hash)
            policies.filter_map do |constant, policy|
              constant = constant.to_s
              next if expected_constants.include?(constant)

              {
                "constant" => constant,
                "gem" => policy.is_a?(Hash) ? policy["gem"].to_s : nil,
                "allowed_constants" => expected_constants.to_a.sort,
              }
            end.sort_by { |policy| [policy["gem"].to_s, policy.fetch("constant")] }
          else
            []
          end
        end
      end

      def external_integration_gaps
        @external_integration_gaps ||= Array(extreme_boot["lazy_gems"]).filter_map do |name|
          policy = profile.payload.dig("lazy_gems", name)
          next unless external_integration_policy?(policy)
          next if coverage_manifest&.external_integration_reviewed?(name)

          {
            "gem" => name,
            "requirement" => "external_integrations.#{name}",
            "actual" => coverage_manifest&.external_integration_status(name),
            "accepted_statuses" => CoverageManifest::EXTERNAL_INTEGRATION_REVIEW_STATUSES,
          }
        end.sort_by { |gap| gap.fetch("gem") }
      end

      def lazy_gem_direct_usage_gaps
        @lazy_gem_direct_usage_gaps ||= Array(extreme_boot["lazy_gems"]).filter_map do |name|
          policy = profile.payload.dig("lazy_gems", name)
          next unless lazy_constant_policy?(policy)

          constants = Array(policy["constants"]).map(&:to_s).reject(&:empty?)
          matches = direct_lazy_gem_static_matches(constants)
          next if matches.empty?
          next if coverage_manifest&.lazy_gem_reviewed?(name)

          {
            "gem" => name,
            "requirement" => "lazy_gems.#{name}",
            "actual" => coverage_manifest&.lazy_gem_status(name),
            "accepted_statuses" => CoverageManifest::LAZY_GEM_REVIEW_STATUSES,
            "matches" => matches,
          }
        end.sort_by { |gap| gap.fetch("gem") }
      end

      def high_risk_transform_gaps
        @high_risk_transform_gaps ||= begin
          gaps = []

          if extreme_boot["disable_eager_load"] == true
            missing = disable_eager_load_latency_policy_gaps
            gaps << high_risk_gap("disable_eager_load", "latency_policy", missing) unless missing.empty?
            missing = disable_eager_load_request_measurement_gaps
            gaps << high_risk_gap("disable_eager_load", "request_measurement", missing) unless missing.empty?
            missing = disable_eager_load_feature_delta_gaps
            gaps << high_risk_gap("disable_eager_load", "loaded_feature_delta", missing) unless missing.empty?
            missing = disable_eager_load_request_event_gaps
            gaps << high_risk_gap("disable_eager_load", "request_event_recording", missing) unless missing.empty?
            missing = disable_eager_load_declared_workload_gaps
            gaps << high_risk_gap("disable_eager_load", "declared_workload_coverage", missing) unless missing.empty?
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

          if Array(extreme_boot["skip_railties"]).map(&:to_s).include?("active_storage/engine")
            missing = active_storage_action_coverage_gaps
            gaps << high_risk_gap("skip_railtie:active_storage/engine", "active_storage_action_coverage", missing) unless missing.empty?
          end

          gaps.sort_by { |gap| gap.fetch("transform_id") }
        end
      end

      def rollback_evidence_gaps
        @rollback_evidence_gaps ||= begin
          manifest = coverage_manifest
          manifest_version = manifest ? manifest.version.to_i : 1

          if manifest_version < 2 || manifest.rollback_tested?
            []
          else
            [
              {
                "requirement" => "rollback.disable_env_tested",
                "expected" => true,
                "env_var" => "RAILS_DEPENDENCY_PRUNER_DISABLE",
              },
            ]
          end
        end
      end

      def canary_evidence_gaps
        @canary_evidence_gaps ||= begin
          manifest = coverage_manifest
          manifest_version = manifest ? manifest.version.to_i : 1
          if manifest_version < 2
            []
          else
            evidence = manifest.canary_evidence
            if evidence.empty?
              [
                {
                  "requirement" => "canary",
                  "expected" => "reviewed canary evidence",
                  "actual" => "missing",
                },
              ]
            elsif evidence["reviewed"] != true
              [
                {
                  "requirement" => "canary.review_required",
                  "expected" => false,
                  "actual" => true,
                },
              ]
            else
              gaps = []
              unless evidence["unexpected_events_count"] == 0
                gaps << {
                  "requirement" => "canary.unexpected_events_count",
                  "expected" => 0,
                  "actual" => evidence["unexpected_events_count"],
                }
              end
              unless evidence["sample_passed"] == true
                gaps << {
                  "requirement" => "canary.duration_or_request_count",
                  "expected" => {
                    "duration_seconds" => evidence["min_duration_seconds"],
                    "request_count" => evidence["min_request_count"],
                  },
                  "actual" => {
                    "duration_seconds" => evidence["duration_seconds"],
                    "request_count" => evidence["request_count"],
                  },
                }
              end
              gaps
            end
          end
        end
      end

      def safety_policy_gaps
        @safety_policy_gaps ||= begin
          policy = profile.payload["safety_policy"]
          if policy.nil? && profile.schema_version.to_i < 3
            []
          else
            SafetyPolicy.gaps(policy)
          end
        end
      end

      def structured_lazy_gem_missing_fields(actual, expected)
        required_fields = STRUCTURED_LAZY_GEM_REQUIRED_FIELDS.dup
        required_fields << "require" if expected.key?("require")
        required_fields << "constants" if expected.key?("constants")
        required_fields << "allowed_phases" if expected.key?("allowed_phases")
        required_fields << "disallowed_phases" if expected.key?("disallowed_phases")

        required_fields.select do |field|
          value = actual[field]
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
      end

      def structured_lazy_gem_mismatched_fields(name, actual, expected)
        expected_payload = expected.merge(
          "gem" => name,
          "strategy" => primary_lazy_gem_strategy(Array(expected["strategies"]).map(&:to_s)),
          "strategies" => Array(expected["strategies"]).map(&:to_s).sort,
          "boot_require_blocked" => true,
          "high_risk" => expected["risk"] == "high",
        )

        expected_payload.keys.select do |field|
          next false unless actual.key?(field)

          normalized_lazy_gem_value(actual[field]) != normalized_lazy_gem_value(expected_payload[field])
        end.sort
      end

      def primary_lazy_gem_strategy(strategies)
        return "lazy_constant" if strategies.include?("lazy_constant")
        return "noop_shim" if strategies.include?("noop_shim")
        return "disabled_in_profile" if strategies.include?("disabled_in_profile")

        strategies.first || "unsupported"
      end

      def normalized_lazy_gem_value(value)
        value.is_a?(Array) ? value.map(&:to_s).sort : value
      end

      def lazy_constant_policy_requirements
        Array(extreme_boot["lazy_gems"]).flat_map do |name|
          policy = profile.payload.dig("lazy_gems", name)
          next [] unless policy.is_a?(Hash)
          next [] unless Array(policy["strategies"]).map(&:to_s).include?("lazy_constant")
          next [] if policy["require"].to_s.empty?

          Array(policy["constants"]).map do |constant|
            {
              "constant" => constant.to_s,
              "gem" => name,
              "policy" => {
                "gem" => name,
                "require" => policy.fetch("require"),
                "allowed_phases" => Array(policy["allowed_phases"]).map(&:to_s),
                "disallowed_phases" => Array(policy["disallowed_phases"]).map(&:to_s),
              },
            }
          end
        end
      end

      def lazy_constant_missing_fields(actual)
        %w[gem require allowed_phases disallowed_phases].select do |field|
          !actual.key?(field) || actual[field].nil?
        end
      end

      def lazy_constant_mismatched_fields(actual, expected)
        expected.keys.select do |field|
          next false unless actual.key?(field)

          normalized_lazy_gem_value(actual[field]) != normalized_lazy_gem_value(expected[field])
        end.sort
      end

      def external_integration_policy?(policy)
        policy.is_a?(Hash) && EXTERNAL_INTEGRATION_GEM_CLASSES.include?(policy["class"].to_s)
      end

      def lazy_constant_policy?(policy)
        policy.is_a?(Hash) && Array(policy["strategies"]).map(&:to_s).include?("lazy_constant")
      end

      def direct_lazy_gem_static_matches(constants)
        constants = constants.to_set
        usage.references.filter_map do |reference|
          path = reference.path.to_s
          next unless static_path_relevant?(path)

          constant = reference.name.to_s.delete_prefix("::")
          top_level = constant.split("::").first
          next unless constants.include?(top_level)

          {
            "constant" => constant,
            "path" => path,
            "line" => reference.line,
          }
        end.uniq.sort_by { |match| [match.fetch("path"), match.fetch("line").to_i, match.fetch("constant")] }
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

      def action_text_static_usage?
        @action_text_static_usage ||= (usage.feature_matches + usage.config_matches).any? do |match|
          match["framework"] == "actiontext" && static_path_relevant?(match.fetch("path"))
        end
      end

      def catalog_coverage_targets
        disabled_targets = disabled_frameworks.map do |framework|
          {
            "target" => framework,
            "target_kind" => "disabled_framework",
            "framework" => framework,
          }
        end

        skipped_targets = Array(extreme_boot["skip_railties"]).filter_map do |railtie|
          framework = RAILTIE_FRAMEWORKS[railtie]
          next unless framework

          {
            "target" => railtie,
            "target_kind" => "skip_railtie",
            "framework" => framework,
          }
        end

        (disabled_targets + skipped_targets).uniq
      end

      def catalog_static_matches(framework)
        (usage.feature_matches + usage.config_matches + usage.route_matches).select do |match|
          static_path_relevant?(match.fetch("path")) && match["framework"] == framework
        end
      end

      def catalog_required_workloads(match)
        Array(match["coverage_required"]).map do |workload|
          CoverageManifest.normalize_workload_key(workload)
        end.uniq.sort
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

      def disable_eager_load_request_measurement_gaps
        return [] unless disable_eager_load_latency_policy_gaps.empty?

        measurement&.fetch("target", nil) == "requests" ? [] : ["measurement.target=requests"]
      end

      def disable_eager_load_feature_delta_gaps
        return [] unless disable_eager_load_latency_policy_gaps.empty?
        return [] unless measurement&.fetch("target", nil) == "requests"

        candidate = memory_policy_candidate_variant
        required = {
          "measurement.variants.baseline.loaded_features_median" => measurement.dig("variants", "baseline", "loaded_features_median"),
          "measurement.variants.baseline.rails_loaded_features_median" => measurement.dig("variants", "baseline", "rails_loaded_features_median"),
          "measurement.variants.#{candidate}.loaded_features_median" => measurement.dig("variants", candidate, "loaded_features_median"),
          "measurement.variants.#{candidate}.rails_loaded_features_median" => measurement.dig("variants", candidate, "rails_loaded_features_median"),
          "measurement.deltas.#{candidate}.loaded_features" => measurement.dig("deltas", candidate, "loaded_features"),
          "measurement.deltas.#{candidate}.rails_loaded_features" => measurement.dig("deltas", candidate, "rails_loaded_features"),
          "measurement.deltas.#{candidate}.rails_loaded_features_by_framework" => measurement.dig("deltas", candidate, "rails_loaded_features_by_framework"),
        }

        required.filter_map do |key, value|
          key if value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
      end

      def disable_eager_load_request_event_gaps
        return [] unless disable_eager_load_latency_policy_gaps.empty?
        return [] unless measurement&.fetch("target", nil) == "requests"
        return [] unless disable_eager_load_feature_delta_gaps.empty?

        candidate = memory_policy_candidate_variant
        required = {
          "measurement.variants.#{candidate}.events_count" => measurement.dig("variants", candidate, "events_count"),
          "measurement.variants.#{candidate}.expected_events_count" => measurement.dig("variants", candidate, "expected_events_count"),
          "measurement.variants.#{candidate}.unexpected_events_count" => measurement.dig("variants", candidate, "unexpected_events_count"),
        }

        required.filter_map do |key, value|
          key if value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
      end

      def memory_policy_candidate_variant
        policy = profile.payload["memory_policy"]
        configured = policy["candidate_variant"].to_s if policy.is_a?(Hash)
        return configured unless configured.nil? || configured.empty?
        return "all_approved_transforms" if measurement["ablation"] == true

        %w[boot_prune production shadow].find { |name| measurement.fetch("variants", {}).key?(name) } || "boot_prune"
      end

      def disable_eager_load_declared_workload_gaps
        gaps = []
        gaps.concat(declared_entry_coverage_gaps("jobs", declared_job_classes, coverage_manifest&.job_classes))
        gaps.concat(declared_entry_coverage_gaps("mailers", declared_mailer_actions, coverage_manifest&.mailer_actions))
        gaps.concat(declared_entry_coverage_gaps("channels", declared_channel_classes, coverage_manifest&.channel_classes))
        gaps.concat(declared_entry_coverage_gaps("inbound_email", declared_mailbox_classes, coverage_manifest&.inbound_email_mailboxes))
        gaps.concat(declared_entry_coverage_gaps("action_text", declared_action_text_declarations, coverage_manifest&.action_text_declarations))
        gaps.concat(declared_entry_coverage_gaps("attachments", declared_active_storage_declarations, coverage_manifest&.active_storage_declarations))
        gaps.concat(declared_entry_coverage_gaps("rake_tasks", declared_rake_tasks, coverage_manifest&.rake_tasks))
        gaps << "jobs" if declared_job_classes.empty? && app_path_has_ruby_files?("app/jobs") && !coverage_workloads.include?("jobs")
        gaps << "mailers" if declared_mailer_actions.empty? && app_path_has_ruby_files?("app/mailers") && !coverage_workloads.include?("mailers")
        gaps << "cable" if declared_channel_classes.empty? && app_path_has_ruby_files?("app/channels") && !coverage_workloads.include?("cable")
        gaps << "inbound_email" if declared_mailbox_classes.empty? && app_path_has_ruby_files?("app/mailboxes") && !coverage_workloads.include?("inbound_email")
        gaps << "attachments" if active_storage_attachment_static_usage? && !coverage_workloads.include?("attachments")
        gaps << "action_text" if declared_action_text_declarations.empty? && action_text_static_usage? && !coverage_workloads.include?("action_text")
        gaps << "rake_tasks" if declared_rake_tasks.empty? && rake_task_static_usage? && !coverage_workloads.include?("rake_tasks")
        gaps.concat(mounted_app_request_coverage_gaps)

        gaps.uniq.sort
      end

      def active_storage_vips_proof_gaps
        return [] unless active_storage_attachment_static_usage?
        return [] if high_risk_override?("stub:active_storage_vips_analyzer")

        active_storage_action_coverage_gaps
      end

      def active_storage_action_coverage_gaps
        return [] unless active_storage_attachment_static_usage?

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

      def safety_override_for?(kind, match)
        safety_overrides.any? do |override|
          safety_override_kind_matches?(override, kind) &&
            override_paths_match?(override, match.fetch("path"))
        end
      end

      def safety_overrides
        @safety_overrides ||= Array(profile.payload["overrides"]).filter_map do |override|
          normalize_safety_override(override)
        end
      end

      def normalize_safety_override(override)
        return unless override.is_a?(Hash)

        id = override["id"].to_s.strip
        reason = override["reason"].to_s.strip
        owner = override["owner"].to_s.strip
        expires_at = parse_date(override["expires_at"])
        paths = Array(override["paths"]).map { |path| normalize_override_path(path) }.reject(&:empty?).uniq.sort
        return if id.empty? || reason.empty? || owner.empty? || expires_at.nil? || expires_at <= Date.today || paths.empty?

        override.merge(
          "id" => id,
          "reason" => reason,
          "owner" => owner,
          "expires_at" => expires_at.iso8601,
          "paths" => paths,
        )
      end

      def safety_override_kind_matches?(override, kind)
        declared = Array(
          override["risk"] ||
          override["risks"] ||
          override["kind"] ||
          override["kinds"] ||
          override["category"] ||
          override["categories"],
        ).map(&:to_s).reject(&:empty?)
        declared.empty? || declared.include?(kind)
      end

      def override_paths_match?(override, risk_path)
        normalized_risk_path = normalize_override_path(risk_path)
        Array(override["paths"]).any? do |path|
          path = normalize_override_path(path)
          if path.end_with?("/*")
            normalized_risk_path.start_with?(path.delete_suffix("/*") + "/")
          elsif path.end_with?("/")
            normalized_risk_path.start_with?(path)
          else
            normalized_risk_path == path
          end
        end
      end

      def normalize_override_path(path)
        path = path.to_s.strip.delete_prefix("./")
        return path if path.empty?

        pathname = Pathname.new(path)
        return path unless pathname.absolute?

        pathname.expand_path.relative_path_from(usage.app_root).to_s
      rescue ArgumentError
        path
      end

      def parse_date(value)
        return value if value.is_a?(Date)
        return if value.nil? || value.to_s.empty?

        Date.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def coverage_manifest
        context.coverage_manifest
      end

      def app_path_has_ruby_files?(relative_path)
        root = usage.app_root.join(relative_path)
        return false unless root.directory?

        Pathname.glob(root.join("**/*.rb").to_s).any?
      end

      def declared_entry_coverage_gaps(workload, declared_entries, covered_entries)
        declared_entries = Array(declared_entries).map(&:to_s).reject(&:empty?).uniq.sort
        return [] if declared_entries.empty?

        covered_entries = Array(covered_entries).map(&:to_s).reject(&:empty?).uniq.to_set
        declared_entries.reject { |entry| covered_entries.include?(entry) }.map { |entry| "#{workload}.#{entry}" }
      end

      def declared_job_classes
        @declared_job_classes ||= class_names_under("app/jobs")
      end

      def declared_mailer_actions
        @declared_mailer_actions ||= class_files_under("app/mailers").flat_map do |path|
          class_name = class_name_in(path)
          method_names(path).map { |method_name| class_name ? "#{class_name}##{method_name}" : method_name }
        end.uniq.sort
      end

      def declared_channel_classes
        @declared_channel_classes ||= class_names_under("app/channels")
      end

      def declared_mailbox_classes
        @declared_mailbox_classes ||= class_names_under("app/mailboxes")
      end

      def declared_action_text_declarations
        @declared_action_text_declarations ||= class_files_under("app").flat_map do |path|
          relative = path.relative_path_from(usage.app_root).to_s
          path.readlines.filter_map.with_index(1) do |line, line_number|
            name = line[/\bhas_rich_text\s+[:"']?([A-Za-z0-9_]+)/, 1]
            next if name.to_s.empty?

            owner = class_name_near(path, line_number)
            owner ? "#{owner}##{name}" : "#{relative}:#{name}"
          end
        end.uniq.sort
      end

      def declared_active_storage_declarations
        @declared_active_storage_declarations ||= class_files_under("app").flat_map do |path|
          relative = path.relative_path_from(usage.app_root).to_s
          path.readlines.filter_map.with_index(1) do |line, line_number|
            name = line[/\bhas_(?:one|many)_attached\s+[:"']?([A-Za-z0-9_]+)/, 1]
            next if name.to_s.empty?

            owner = class_name_near(path, line_number)
            owner ? "#{owner}##{name}" : "#{relative}:#{name}"
          end
        end.uniq.sort
      end

      def declared_rake_tasks
        @declared_rake_tasks ||= rake_task_files.flat_map { |path| rake_tasks_in(path) }.uniq.sort
      end

      def class_names_under(relative_path)
        class_files_under(relative_path).filter_map { |path| class_name_in(path) }.uniq.sort
      end

      def class_files_under(relative_path)
        root = usage.app_root.join(relative_path)
        return [] unless root.directory?

        Pathname.glob(root.join("**/*.rb").to_s).select(&:file?).sort
      end

      def class_name_in(path)
        path.readlines.each do |line|
          match = line.match(/^\s*class\s+([A-Z][A-Za-z0-9_:]*)/)
          return match[1] if match
        end
        nil
      end

      def class_name_near(path, line_number)
        path.readlines.first(line_number).reverse_each do |line|
          match = line.match(/^\s*class\s+([A-Z][A-Za-z0-9_:]*)/)
          return match[1] if match
        end
        nil
      end

      def method_names(path)
        path.readlines.filter_map do |line|
          match = line.match(/^\s*def\s+([a-z_][A-Za-z0-9_!?=]*)/)
          next unless match

          name = match[1]
          name unless name.end_with?("=")
        end
      end

      def rake_task_static_usage?
        rake_task_files.any? { |path| rake_task_file_declares_task?(path) }
      end

      def rake_task_files
        @rake_task_files ||= (
          [usage.app_root.join("Rakefile")] +
            Pathname.glob(usage.app_root.join("lib/tasks/**/*.rake").to_s)
        ).select(&:file?).uniq.sort
      end

      def rake_task_file_declares_task?(path)
        path.readlines.any? { |line| line.match?(/\A\s*(?:namespace|task)\b/) }
      end

      def rake_tasks_in(path)
        namespace_stack = []
        depth = 0

        path.readlines.filter_map do |line|
          source = line.strip
          namespace = rake_namespace_name(source)
          namespace_stack << { "name" => namespace, "depth" => depth } if namespace

          task_name = rake_task_name(source)
          task = if task_name
            if task_name.include?(":") || namespace_stack.empty?
              task_name
            else
              "#{namespace_stack.map { |entry| entry.fetch("name") }.join(":")}:#{task_name}"
            end
          end

          depth = rake_depth_after(source, depth)
          namespace_stack.pop while namespace_stack.any? && namespace_stack.last.fetch("depth") >= depth
          task
        end
      end

      def rake_namespace_name(source)
        match = source.match(/\A\s*namespace\s+(?::([A-Za-z0-9_]+)|["']([^"']+)["'])/)
        match && (match[1] || match[2])
      end

      def rake_task_name(source)
        match = source.match(/\A\s*task\s+(?::([A-Za-z0-9_]+)|["']([^"']+)["']|([A-Za-z0-9_]+)\s*:)/)
        match && (match[1] || match[2] || match[3])
      end

      def rake_depth_after(source, depth)
        next_depth = depth + source.scan(/\bdo\b/).length
        next_depth -= 1 if source.match?(/\Aend\b/)
        [next_depth, 0].max
      end

      def mounted_app_request_coverage_gaps
        mounted_app_routes.filter_map do |route|
          requirement = "requests.GET #{route.fetch("path")}"
          next if coverage_manifest&.request_covered?(method: "GET", path: route.fetch("path"))

          requirement
        end
      end

      def mounted_app_routes
        @mounted_app_routes ||= route_files.flat_map do |path|
          relative = path.relative_path_from(usage.app_root).to_s
          path.readlines.filter_map.with_index(1) do |line, line_number|
            next unless line.match?(/\bmount\b/)

            mount_path = mounted_app_path(line)
            next if mount_path.to_s.empty?

            {
              "path" => mount_path,
              "source" => "#{relative}:#{line_number}",
            }
          end
        end.uniq { |route| route.fetch("path") }.sort_by { |route| route.fetch("path") }
      end

      def route_files
        @route_files ||= Pathname.glob(usage.app_root.join("config/routes{.rb,/**/*.rb}").to_s).select(&:file?).sort
      end

      def mounted_app_path(source)
        path = source[/,\s*at:\s*["']([^"']+)["']/, 1] ||
          source[/=>\s*["']([^"']+)["']/, 1]
        return if path.to_s.empty?

        path.start_with?("/") ? path : "/#{path}"
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
            "kind" => match["evidence_kind"] == "route" ? "route" : "feature",
            "name" => match["feature"],
            "pattern" => match["pattern"],
            "path" => match.fetch("path"),
            "line" => match.fetch("line"),
            "catalog_railties" => Array(match["railties"]),
            "coverage_required" => Array(match["coverage_required"]),
            "negative_rules" => Array(match["negative_rules"]),
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

      def measurement_context_gaps
        @measurement_context_gaps ||= begin
          if measurement.nil?
            []
          else
            gaps = []
            target_gap = measurement_target_gap
            gaps << target_gap if target_gap

            expected_profile_id = profile.profile_id
            actual_profile_id = measurement_profile_id
            if expected_profile_id && (actual_profile_id.to_s.empty? || actual_profile_id != expected_profile_id)
              gaps << {
                "requirement" => "measurement.profile_id",
                "expected" => expected_profile_id,
                "actual" => actual_profile_id,
              }
            end

            expected_coverage_digest = profile.payload.dig("evidence", "coverage_manifest_digest")
            actual_coverage_digest = measurement.dig("coverage", "digest")
            if expected_coverage_digest && (actual_coverage_digest.to_s.empty? || actual_coverage_digest != expected_coverage_digest)
              gaps << {
                "requirement" => "measurement.coverage.digest",
                "expected" => expected_coverage_digest,
                "actual" => actual_coverage_digest,
              }
            end

            expected_rails_env = profile.payload.dig("environment", "rails_env")
            actual_rails_env = measurement.dig("coverage", "rails_env")
            if expected_rails_env && (actual_rails_env.to_s.empty? || actual_rails_env != expected_rails_env)
              gaps << {
                "requirement" => "measurement.coverage.rails_env",
                "expected" => expected_rails_env,
                "actual" => actual_rails_env,
              }
            end
            gaps.concat(measurement_coverage_workload_gaps(expected_coverage_digest, actual_coverage_digest))
            gaps.concat(measurement_request_path_gaps(expected_coverage_digest, actual_coverage_digest))
            gaps
          end
        end
      end

      def measurement_suite_gaps
        @measurement_suite_gaps ||= begin
          if measurements.length <= 1
            []
          else
            gaps = []
            targets = measurements.map { |payload| payload["target"].to_s }.reject(&:empty?).uniq.sort
            missing_targets = %w[environment requests] - targets
            unless missing_targets.empty?
              gaps << {
                "requirement" => "measurement_suite.targets",
                "expected" => %w[environment requests],
                "actual" => targets,
                "missing" => missing_targets,
              }
            end

            measurements.each_with_index do |payload, index|
              gaps.concat(measurement_suite_context_gaps(payload, index))
            end
            gaps
          end
        end
      end

      def measurement_suite_context_gaps(payload, index)
        gaps = []
        target = payload["target"].to_s
        unless MEASUREMENT_TARGETS.include?(target)
          gaps << measurement_suite_gap(index, payload, "measurement.target", MEASUREMENT_TARGETS, target.empty? ? nil : target)
        end

        expected_profile_id = profile.profile_id
        actual_profile_id = measurement_profile_id(payload)
        if expected_profile_id && (actual_profile_id.to_s.empty? || actual_profile_id != expected_profile_id)
          gaps << measurement_suite_gap(index, payload, "measurement.profile_id", expected_profile_id, actual_profile_id)
        end

        expected_coverage_digest = profile.payload.dig("evidence", "coverage_manifest_digest")
        actual_coverage_digest = payload.dig("coverage", "digest")
        if expected_coverage_digest && (actual_coverage_digest.to_s.empty? || actual_coverage_digest != expected_coverage_digest)
          gaps << measurement_suite_gap(index, payload, "measurement.coverage.digest", expected_coverage_digest, actual_coverage_digest)
        end

        expected_rails_env = profile.payload.dig("environment", "rails_env")
        actual_rails_env = payload.dig("coverage", "rails_env")
        if expected_rails_env && (actual_rails_env.to_s.empty? || actual_rails_env != expected_rails_env)
          gaps << measurement_suite_gap(index, payload, "measurement.coverage.rails_env", expected_rails_env, actual_rails_env)
        end

        gaps.concat(measurement_suite_coverage_workload_gaps(payload, index, expected_coverage_digest, actual_coverage_digest))
        gaps.concat(measurement_suite_request_path_gaps(payload, index, expected_coverage_digest, actual_coverage_digest))
        gaps
      end

      def measurement_suite_coverage_workload_gaps(payload, index, expected_coverage_digest, actual_coverage_digest)
        return [] unless expected_coverage_digest && actual_coverage_digest == expected_coverage_digest

        expected_workloads = coverage_manifest_workloads
        return [] if expected_workloads.empty?

        actual_workloads = measurement_coverage_workloads(payload)
        missing_workloads = expected_workloads - actual_workloads
        return [] if missing_workloads.empty?

        [
          measurement_suite_gap(index, payload, "measurement.coverage.workloads", expected_workloads, actual_workloads).merge(
            "missing" => missing_workloads,
          ),
        ]
      end

      def measurement_suite_request_path_gaps(payload, index, expected_coverage_digest, actual_coverage_digest)
        return [] unless expected_coverage_digest && actual_coverage_digest == expected_coverage_digest
        return [] unless measurement_request_workload?(payload)

        expected_paths = coverage_manifest_request_paths
        return [] if expected_paths.empty?

        actual_paths = measurement_request_paths(payload)
        missing_paths = expected_paths - actual_paths
        return [] if missing_paths.empty?

        [
          measurement_suite_gap(index, payload, "measurement.request_paths", expected_paths, actual_paths).merge(
            "missing" => missing_paths,
          ),
        ]
      end

      def measurement_suite_gap(index, payload, requirement, expected, actual)
        {
          "measurement_index" => index,
          "measurement_target" => payload["target"],
          "requirement" => requirement,
          "expected" => expected,
          "actual" => actual,
        }
      end

      def measurement_profile_id(payload = measurement)
        payload.dig("source_profile", "profile_id") ||
          payload.dig("profile", "profile_id")
      end

      def measurement_target_gap
        actual_target = measurement["target"].to_s
        return if MEASUREMENT_TARGETS.include?(actual_target)

        {
          "requirement" => "measurement.target",
          "expected" => MEASUREMENT_TARGETS,
          "actual" => actual_target.empty? ? nil : actual_target,
        }
      end

      def measurement_coverage_workload_gaps(expected_coverage_digest, actual_coverage_digest)
        return [] unless expected_coverage_digest && actual_coverage_digest == expected_coverage_digest

        expected_workloads = coverage_manifest_workloads
        return [] if expected_workloads.empty?

        actual_workloads = measurement_coverage_workloads
        missing_workloads = expected_workloads - actual_workloads
        return [] if missing_workloads.empty?

        [
          {
            "requirement" => "measurement.coverage.workloads",
            "expected" => expected_workloads,
            "actual" => actual_workloads,
            "missing" => missing_workloads,
          },
        ]
      end

      def measurement_request_path_gaps(expected_coverage_digest, actual_coverage_digest)
        return [] unless expected_coverage_digest && actual_coverage_digest == expected_coverage_digest
        return [] unless measurement_request_workload?

        expected_paths = coverage_manifest_request_paths
        return [] if expected_paths.empty?

        actual_paths = measurement_request_paths
        missing_paths = expected_paths - actual_paths
        return [] if missing_paths.empty?

        [
          {
            "requirement" => "measurement.request_paths",
            "expected" => expected_paths,
            "actual" => actual_paths,
            "missing" => missing_paths,
          },
        ]
      end

      def measurement_request_workload?(payload = measurement)
        payload["target"] == "requests"
      end

      def coverage_manifest_workloads
        Array(coverage_manifest&.workloads).map(&:to_s).uniq.sort
      end

      def measurement_coverage_workloads(payload = measurement)
        Array(payload.dig("coverage", "workloads"))
          .map { |workload| CoverageManifest.normalize_workload_key(workload) }
          .reject(&:empty?)
          .uniq
          .sort
      end

      def coverage_manifest_request_paths
        Array(coverage_manifest&.request_entries).map { |entry| entry.fetch("path") }.uniq.sort
      end

      def measurement_request_paths(payload = measurement)
        paths = Array(payload["request_paths"]).map(&:to_s).reject(&:empty?)
        if paths.empty?
          paths = payload.fetch("variants", {}).values.flat_map do |summary|
            summary.fetch("request_status_matrix", {}).keys
          end
        end
        paths.uniq.sort
      end

      def dynamic_constantization_risks
        @dynamic_constantization_risks ||= begin
          namespaces = pruned_namespaces
          if namespaces.empty?
            []
          else
            usage.sorted_dynamic_matches.select do |match|
              match["dynamic"] && dynamic_constantization_risk?(match, namespaces)
            end.reject do |match|
              safety_override_for?("dynamic_constantization", match)
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

      def format_runtime_event(event)
        event["event_id"] ||
          [
            event["mode"],
            event["phase"],
            event["action"],
            event["path"] || event["matched_path"] || event["gem"] || event["constant"],
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

      def format_structured_lazy_gem_policy_gap(gap)
        parts = []
        missing = Array(gap["missing_fields"])
        mismatched = Array(gap["mismatched_fields"])
        parts << "missing #{missing.join(", ")}" unless missing.empty?
        parts << "mismatched #{mismatched.join(", ")}" unless mismatched.empty?

        "#{gap.fetch("gem")} #{parts.join("; ")}"
      end

      def format_lazy_constant_policy_gap(gap)
        parts = []
        missing = Array(gap["missing_fields"])
        mismatched = Array(gap["mismatched_fields"])
        parts << "missing #{missing.join(", ")}" unless missing.empty?
        parts << "mismatched #{mismatched.join(", ")}" unless mismatched.empty?

        "#{gap.fetch("constant")} for #{gap.fetch("gem")} #{parts.join("; ")}"
      end

      def format_unsupported_lazy_constant_policy(policy)
        gem = policy["gem"].to_s.empty? ? "unknown gem" : policy["gem"]

        "#{policy.fetch("constant")} for #{gem}"
      end

      def format_external_integration_gap(gap)
        actual = gap["actual"].to_s.empty? ? "missing" : gap["actual"]
        "#{gap.fetch("gem")} requires #{gap.fetch("requirement")} reviewed status; got #{actual}"
      end

      def format_lazy_gem_direct_usage_gap(gap)
        actual = gap["actual"].to_s.empty? ? "missing" : gap["actual"]
        first_match = gap.fetch("matches").first
        location = [first_match.fetch("path"), first_match.fetch("line")].join(":")

        "#{gap.fetch("gem")} requires #{gap.fetch("requirement")} reviewed status for #{first_match.fetch("constant")} at #{location}; got #{actual}"
      end

      def format_catalog_coverage_gap(gap)
        evidence = [
          gap.fetch("feature"),
          gap["pattern"],
          gap.fetch("path"),
          gap.fetch("line"),
        ].compact.join(":")

        "#{gap.fetch("target")} #{evidence} requires #{gap.fetch("missing_workloads").join(", ")}"
      end

      def format_measurement_context_gap(gap)
        if gap["requirement"] == "measurement.target"
          actual = gap["actual"].to_s.empty? ? "missing" : gap["actual"]
          return "measurement.target expected #{Array(gap.fetch("expected")).join(", ")}, got #{actual}"
        end

        if gap["requirement"] == "measurement.coverage.workloads"
          return "measurement.coverage.workloads missing reviewed workloads #{Array(gap["missing"]).join(", ")}"
        end

        if gap["requirement"] == "measurement.request_paths"
          return "measurement.request_paths missing reviewed paths #{Array(gap["missing"]).join(", ")}"
        end

        actual = gap["actual"].to_s.empty? ? "missing" : gap["actual"]
        "#{gap.fetch("requirement")} expected #{gap.fetch("expected")}, got #{actual}"
      end

      def format_measurement_suite_gap(gap)
        if gap["requirement"] == "measurement_suite.targets"
          return "measurement suite missing targets #{Array(gap["missing"]).join(", ")}"
        end

        actual = gap["actual"].to_s.empty? ? "missing" : gap["actual"]
        target = gap["measurement_target"].to_s.empty? ? "unknown target" : gap["measurement_target"]
        "measurement #{gap.fetch("measurement_index")} #{target} #{gap.fetch("requirement")} expected #{gap.fetch("expected")}, got #{actual}"
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

      def format_transform_contract_gap(gap)
        "#{gap.fetch("transform_id")} missing #{gap.fetch("missing_fields").join(", ")}"
      end

      def format_rollback_evidence_gap(gap)
        "#{gap.fetch("requirement")} must be true for #{gap.fetch("env_var")}"
      end

      def format_canary_evidence_gap(gap)
        case gap.fetch("requirement")
        when "canary"
          "canary section is required for v2 production coverage"
        when "canary.review_required"
          "canary.review_required must be false"
        when "canary.unexpected_events_count"
          actual = gap["actual"].nil? ? "missing" : gap["actual"]
          "canary.unexpected_events_count must be 0, got #{actual}"
        when "canary.duration_or_request_count"
          expected = gap.fetch("expected")
          actual = gap.fetch("actual")
          "canary requires duration_seconds >= #{expected.fetch("duration_seconds")} or request_count >= #{expected.fetch("request_count")}; got duration_seconds=#{actual["duration_seconds"] || "missing"}, request_count=#{actual["request_count"] || "missing"}"
        else
          gap.fetch("requirement")
        end
      end

      def format_safety_policy_gap(gap)
        "#{gap.fetch("key")} expected #{gap.fetch("expected")}, got #{gap.fetch("actual")}"
      end
  end
end
