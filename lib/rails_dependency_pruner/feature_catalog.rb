# frozen_string_literal: true

require "yaml"

module RailsDependencyPruner
  class FeatureCatalog
    CONFIG_ROOT = File.expand_path("../../config/rails_dependency_pruner", __dir__)
    CATALOGS_DIR = File.join(CONFIG_ROOT, "catalogs")
    DEFAULT_VERSION = "8.1"
    LEGACY_PATH = File.join(CONFIG_ROOT, "features.yml")
    DEFAULT_PATH = File.join(CATALOGS_DIR, "rails_#{DEFAULT_VERSION.tr(".", "_")}.yml")

    attr_reader :entries, :path, :rails_version

    def initialize(entries, path: nil, rails_version: nil)
      @entries = entries.transform_keys(&:to_s)
      @path = path
      @rails_version = rails_version
    end

    def self.default
      for_rails_version(DEFAULT_VERSION)
    end

    def self.for_rails_version(rails_version)
      version = catalog_version_for(rails_version)
      catalogs[version] ||= load(path_for_catalog_version(version), rails_version: version)
    end

    def self.load(path, rails_version: nil)
      new(YAML.load_file(path) || {}, path: path, rails_version: rails_version)
    end

    def self.path_for_rails_version(rails_version)
      path_for_catalog_version(catalog_version_for(rails_version))
    end

    def self.catalog_version_for(rails_version)
      version = normalize_rails_version(rails_version)
      return version if File.file?(catalog_file(version))

      DEFAULT_VERSION
    end

    def name
      return unless path

      File.basename(path, ".yml")
    end

    def matches_for_pattern(pattern)
      entries.filter_map do |feature, config|
        patterns = patterns_for(config, "dsl", "app_patterns")
        next unless patterns.include?(pattern.to_s)

        match_payload(feature, config).merge(
          "evidence_kind" => "dsl",
          "pattern" => pattern.to_s,
        )
      end
    end

    def matches_for_config_path(config_path)
      entries.filter_map do |feature, config|
        pattern = patterns_for(config, "config", "config_patterns").find do |candidate|
          pattern_matches?(candidate, config_path.to_s)
        end
        next unless pattern

        match_payload(feature, config).merge(
          "evidence_kind" => "config",
          "pattern" => pattern,
          "config_path" => config_path.to_s,
        )
      end
    end

    def matches_for_route_signature(signature)
      entries.filter_map do |feature, config|
        pattern = patterns_for(config, "routes", "route_patterns").find do |candidate|
          pattern_matches?(candidate, signature.to_s)
        end
        next unless pattern

        match_payload(feature, config).merge(
          "evidence_kind" => "route",
          "pattern" => pattern,
          "route_signature" => signature.to_s,
        )
      end
    end

    def to_h
      entries
    end

    private
      def self.catalogs
        @catalogs ||= {}
      end

      def self.path_for_catalog_version(version)
        path = catalog_file(version)
        return path if File.file?(path)

        LEGACY_PATH
      end

      def self.catalog_file(version)
        File.join(CATALOGS_DIR, "rails_#{version.tr(".", "_")}.yml")
      end

      def self.normalize_rails_version(rails_version)
        parts = rails_version.to_s.scan(/\d+/)
        return DEFAULT_VERSION if parts.empty?

        [parts.fetch(0), parts.fetch(1, "0")].join(".")
      end

      def patterns_for(config, *keys)
        keys.flat_map { |key| Array(config[key]) }.map(&:to_s).uniq
      end

      def match_payload(feature, config)
        {
          "feature" => feature,
          "framework" => config["framework"],
          "railties" => Array(config["railties"]).map(&:to_s).sort,
          "constants" => Array(config["constants"]).map(&:to_s).sort,
          "coverage_required" => Array(config["coverage_required"]).map(&:to_s).sort,
          "negative_rules" => Array(config["negative_rules"]),
        }
      end

      def pattern_matches?(pattern, value)
        return value.start_with?(pattern.delete_suffix("*")) if pattern.end_with?("*")

        pattern == value
      end
  end
end
