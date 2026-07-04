# frozen_string_literal: true

require "pathname"
require "rubygems"

module RailsDependencyPruner
  class RailsSource
    FRAMEWORK_GEMS = {
      "actioncable" => "actioncable",
      "actionmailbox" => "actionmailbox",
      "actionmailer" => "actionmailer",
      "actionpack" => "actionpack",
      "actiontext" => "actiontext",
      "actionview" => "actionview",
      "activejob" => "activejob",
      "activemodel" => "activemodel",
      "activerecord" => "activerecord",
      "activestorage" => "activestorage",
      "activesupport" => "activesupport",
      "railties" => "railties",
    }.freeze

    RAILS_8_REQUIREMENT = Gem::Requirement.new(">= 8.0", "< 9.0")

    attr_reader :frameworks, :paths, :version, :label

    def initialize(frameworks:, paths:, version:, label:)
      @frameworks = frameworks
      @paths = paths
      @version = version
      @label = label
    end

    def self.installed_rails_8(frameworks:)
      rails_spec = find_rails_8_spec("rails")
      paths = frameworks.to_h do |framework|
        gem_name = FRAMEWORK_GEMS.fetch(framework) do
          raise ArgumentError, "Unknown Rails framework: #{framework}"
        end

        spec = find_rails_8_spec(gem_name)
        [framework, Pathname.new(spec.full_gem_path)]
      end

      new(
        frameworks: frameworks,
        paths: paths,
        version: rails_spec.version.to_s,
        label: "rails #{rails_spec.version}",
      )
    end

    def self.checkout(rails_root:, frameworks:)
      root = Pathname.new(rails_root).expand_path

      new(
        frameworks: frameworks,
        paths: frameworks.to_h { |framework| [framework, root.join(framework)] },
        version: nil,
        label: root.to_s,
      )
    end

    def ruby_files
      @ruby_files ||= frameworks.flat_map do |framework|
        root = paths.fetch(framework)
        lib_root = root.join("lib")
        next [] unless lib_root.exist?

        Pathname.glob(lib_root.join("**/*.rb").to_s).sort.reject do |path|
          relative_path = relative_path(path, framework)
          relative_path.include?("/test/") ||
            relative_path.include?("/dummy/") ||
            relative_path.include?("/templates/")
        end
      end
    end

    def component_for(path)
      expanded = Pathname.new(path).expand_path
      paths.find { |_framework, root| under?(expanded, root) }&.first
    end

    def relative_path(path, framework = component_for(path))
      root = paths.fetch(framework)
      "#{framework}/#{Pathname.new(path).expand_path.relative_path_from(root).to_s}"
    end

    def relative_path_for(path)
      expanded = Pathname.new(path).expand_path
      framework = component_for(expanded)
      return unless framework

      relative_path(expanded, framework)
    rescue ArgumentError, Errno::ENOENT
      nil
    end

    def to_h
      {
        label: label,
        version: version,
        frameworks: frameworks,
        paths: paths.transform_values(&:to_s),
      }
    end

    def self.find_rails_8_spec(name)
      loaded = Gem.loaded_specs[name]
      return loaded if loaded && RAILS_8_REQUIREMENT.satisfied_by?(loaded.version)

      spec = Gem::Specification.find_all_by_name(name)
        .select { |candidate| RAILS_8_REQUIREMENT.satisfied_by?(candidate.version) }
        .max_by(&:version)

      raise ArgumentError, "#{name} >= 8.0, < 9.0 is required" unless spec

      spec
    end

    private_class_method :find_rails_8_spec

    private
      def under?(path, root)
        path.to_s.start_with?("#{root.expand_path}/")
      end
  end
end
