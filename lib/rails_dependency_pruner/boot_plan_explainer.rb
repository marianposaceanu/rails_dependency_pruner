# frozen_string_literal: true

require_relative "boot_plan"
require_relative "boot_prune_planner"

module RailsDependencyPruner
  class BootPlanExplainer
    attr_reader :planner, :boot_plan

    def initialize(planner:, boot_plan:)
      @planner = planner
      @boot_plan = boot_plan
    end

    def explanations
      frameworks.each_with_object({}) do |framework, result|
        result[framework] = explanation_for(framework)
      end.sort.to_h
    end

    private
      def frameworks
        (boot_plan.required_frameworks + boot_plan.pruned_frameworks).uniq.sort
      end

      def explanation_for(framework)
        if boot_plan.pruned_frameworks.include?(framework)
          pruned_explanation(framework)
        else
          kept_explanation(framework)
        end
      end

      def kept_explanation(framework)
        evidence = positive_evidence(framework)
        evidence << "always kept for Rails boot" if BootPrunePlanner::ALWAYS_KEEP.include?(framework)
        evidence << "required by selected framework dependencies" if evidence.empty?

        {
          "decision" => "keep_framework",
          "confidence" => 1.0,
          "positive_evidence" => evidence.sort,
          "negative_evidence" => [],
          "blocked_by" => [],
        }.merge(metadata_for(framework))
      end

      def pruned_explanation(framework)
        {
          "decision" => "disable_framework",
          "confidence" => 0.98,
          "positive_evidence" => [],
          "negative_evidence" => [
            "no static framework evidence in scanned app files",
            "no runtime framework evidence in supplied evidence files",
            "not required by selected framework dependencies",
          ],
          "blocked_by" => [],
        }.merge(metadata_for(framework))
      end

      def metadata_for(framework)
        {
          "framework" => framework,
          "railtie" => BootPlan::RAILTIE_REQUIRE_PATHS[framework],
        }.compact
      end

      def positive_evidence(framework)
        [
          *constant_evidence(framework),
          *feature_evidence(framework),
          *config_evidence(framework),
          *route_evidence(framework),
          *runtime_evidence(framework),
        ]
      end

      def constant_evidence(framework)
        planner.usage.direct_rails_constants.filter_map do |constant|
          definition = planner.index.definitions[constant]
          next unless definition&.component == framework

          "static constant #{constant}"
        end
      end

      def feature_evidence(framework)
        planner.usage.feature_matches.filter_map do |match|
          next unless match["framework"] == framework

          "DSL #{match.fetch("pattern")} matched #{match.fetch("feature")}"
        end
      end

      def config_evidence(framework)
        planner.usage.sorted_config_matches.filter_map do |match|
          next unless match["framework"] == framework

          "config #{match.fetch("config_path")}"
        end
      end

      def route_evidence(framework)
        planner.usage.sorted_route_matches.filter_map do |match|
          next unless match["framework"] == framework

          "route #{match.fetch("route_signature")}"
        end
      end

      def runtime_evidence(framework)
        planner.runtime_constants.filter_map do |constant|
          definition = planner.index.definitions[constant]
          next unless definition&.component == framework

          "runtime constant #{constant}"
        end
      end
  end
end
