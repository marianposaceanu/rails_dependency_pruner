# frozen_string_literal: true

require "set"

require_relative "boot_plan"

module RailsDependencyPruner
  class BootPrunePlanner
    FRAMEWORK_DEPENDENCIES = {
      "activerecord" => %w[activemodel],
      "activestorage" => %w[activejob activerecord activemodel],
      "actionmailbox" => %w[actionpack activejob activerecord activestorage activemodel],
      "actionmailer" => %w[actionpack actionview activejob],
      "actiontext" => %w[actionpack actionview activerecord activestorage activemodel],
      "actioncable" => %w[actionpack],
      "actionpack" => %w[actionview],
    }.freeze

    ALWAYS_KEEP = %w[activesupport railties].freeze
    COMPONENT_NEUTRAL_CONSTANTS = %w[Rails].freeze
    FRAMEWORK_APP_PATHS = {
      "actioncable" => %w[app/channels],
      "actionmailbox" => %w[app/mailboxes],
      "actionmailer" => %w[app/mailers],
      "activejob" => %w[app/jobs],
    }.freeze

    attr_reader :planner

    def initialize(planner)
      @planner = planner
    end

    def plan
      BootPlan.new(
        required_frameworks: required_frameworks.to_a,
        pruned_frameworks: pruned_frameworks.to_a,
        autoload_ignores: pruned_app_paths,
        eager_load_ignores: pruned_app_paths,
      )
    end

    def required_frameworks
      @required_frameworks ||= begin
        required = Set.new(ALWAYS_KEEP)
        planner.used_constants.each do |constant|
          next if COMPONENT_NEUTRAL_CONSTANTS.include?(constant)

          definition = planner.index.definitions[constant]
          required << definition.component if definition&.component
        end

        expand_dependencies(required)
      end
    end

    def pruned_frameworks
      planner.index.frameworks.to_set.subtract(required_frameworks)
    end

    private
      def pruned_app_paths
        pruned_frameworks.flat_map do |framework|
          FRAMEWORK_APP_PATHS.fetch(framework, []).select do |path|
            planner.usage.app_root.join(path).directory?
          end
        end.sort
      end

      def expand_dependencies(required)
        queue = required.to_a

        until queue.empty?
          framework = queue.shift
          FRAMEWORK_DEPENDENCIES.fetch(framework, []).each do |dependency|
            next if required.include?(dependency)

            required << dependency
            queue << dependency
          end
        end

        required
      end
  end
end
