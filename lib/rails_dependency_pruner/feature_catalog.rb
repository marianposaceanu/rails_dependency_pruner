# frozen_string_literal: true

require "yaml"

module RailsDependencyPruner
  class FeatureCatalog
    DEFAULT_PATH = File.expand_path("../../config/rails_dependency_pruner/features.yml", __dir__)

    attr_reader :entries

    def initialize(entries)
      @entries = entries.transform_keys(&:to_s)
    end

    def self.default
      @default ||= load(DEFAULT_PATH)
    end

    def self.load(path)
      new(YAML.load_file(path) || {})
    end

    def matches_for_pattern(pattern)
      entries.filter_map do |feature, config|
        patterns = Array(config["app_patterns"]).map(&:to_s)
        next unless patterns.include?(pattern.to_s)

        {
          "feature" => feature,
          "framework" => config["framework"],
          "pattern" => pattern.to_s,
          "constants" => Array(config["constants"]).map(&:to_s).sort,
        }
      end
    end

    def matches_for_config_path(config_path)
      entries.filter_map do |feature, config|
        pattern = Array(config["config_patterns"]).map(&:to_s).find do |candidate|
          pattern_matches?(candidate, config_path.to_s)
        end
        next unless pattern

        {
          "feature" => feature,
          "framework" => config["framework"],
          "pattern" => pattern,
          "config_path" => config_path.to_s,
          "constants" => Array(config["constants"]).map(&:to_s).sort,
        }
      end
    end

    def to_h
      entries
    end

    private
      def pattern_matches?(pattern, value)
        return value.start_with?(pattern.delete_suffix("*")) if pattern.end_with?("*")

        pattern == value
      end
  end
end
