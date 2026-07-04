# frozen_string_literal: true

require "pathname"
require "set"

require "prism"

require_relative "constant_resolver"
require_relative "rails_source"
require_relative "source_visitor"

module RailsDependencyPruner
  class ConstantIndex
    DEFAULT_FRAMEWORKS = %w[
      actioncable
      actionmailbox
      actionmailer
      actionpack
      actiontext
      actionview
      activejob
      activemodel
      activerecord
      activestorage
      activesupport
      railties
    ].freeze

    attr_reader :rails_root, :frameworks, :definitions, :parse_errors, :source

    def initialize(rails_root: nil, frameworks: DEFAULT_FRAMEWORKS)
      @frameworks = frameworks
      @source = rails_root ? RailsSource.checkout(rails_root: rails_root, frameworks: frameworks) : RailsSource.installed_rails_8(frameworks: frameworks)
      @rails_root = rails_root && Pathname.new(rails_root).expand_path
      @definitions = {}
      @parse_errors = []
    end

    def self.build(...)
      new(...).tap(&:build)
    end

    def build
      ruby_files.each do |path|
        result = Prism.parse_file(path.to_s)

        unless result.success?
          @parse_errors << { path: relative(path), errors: result.errors.map(&:message) }
          next
        end

        visitor = SourceVisitor.new(
          path: path,
          relative_path: relative(path),
          component: component_for(path),
        )
        result.value.accept(visitor)
        merge_definitions(visitor.definitions)
      end

      resolve_dependencies
      self
    end

    def names
      definitions.keys.to_set
    end

    def dependency_tree
      definitions.transform_values { |definition| definition.dependencies.to_a.sort }
    end

    def to_h(include_tree: true)
      payload = {
        rails_root: rails_root.to_s,
        rails_version: source.version,
        source: source.to_h,
        frameworks: frameworks,
        files_scanned: ruby_files.length,
        parse_errors: parse_errors,
        constants_count: definitions.length,
        components: definitions.values.group_by(&:component).transform_values(&:length).sort.to_h,
      }

      if include_tree
        payload[:constants] = definitions.values.sort_by(&:name).map(&:to_h)
        payload[:dependency_tree] = dependency_tree.sort.to_h
      end

      payload
    end

    private
      def ruby_files
        @ruby_files ||= source.ruby_files
      end

      def merge_definitions(new_definitions)
        new_definitions.each do |name, definition|
          definitions[name] ||= definition
        end
      end

      def resolve_dependencies
        resolver = ConstantResolver.new(names)

        definitions.each_value do |definition|
          raw_dependencies = Set.new
          raw_dependencies << definition.superclass if definition.superclass

          definition.raw_references.each do |reference|
            raw_dependencies << reference.name
          end

          raw_dependencies.each do |raw_name|
            resolved = resolver.resolve(raw_name, definition.name)
            next if resolved.nil? || resolved == definition.name

            definition.dependencies << resolved
          end
        end
      end

      def component_for(path)
        source.component_for(path)
      end

      def relative(path)
        source.relative_path(path)
      end

    public
      def relative_path_for(path)
        source.relative_path_for(path)
      end
  end
end
