# frozen_string_literal: true

require "pathname"
require "set"

require "prism"

require_relative "constant_resolver"
require_relative "feature_catalog"
require_relative "static/rails_dsl_visitor"
require_relative "source_visitor"

module RailsDependencyPruner
  class AppUsage
    DEFAULT_SCAN_ROOTS = %w[app config lib].freeze

    attr_reader :app_root, :index, :scan_roots, :references, :feature_matches, :parse_errors

    def initialize(app_root:, index:, scan_roots: DEFAULT_SCAN_ROOTS, feature_catalog: FeatureCatalog.default)
      @app_root = Pathname.new(app_root).expand_path
      @index = index
      @scan_roots = scan_roots
      @feature_catalog = feature_catalog
      @references = []
      @feature_matches = []
      @parse_errors = []
    end

    def self.scan(...)
      new(...).tap(&:scan)
    end

    def scan
      ruby_files.each do |path|
        result = Prism.parse_file(path.to_s)

        unless result.success?
          @parse_errors << { path: relative(path), errors: result.errors.map(&:message) }
          next
        end

        visitor = SourceVisitor.new(path: path, relative_path: relative(path))
        result.value.accept(visitor)
        references.concat(visitor.references)

        dsl_visitor = Static::RailsDslVisitor.new(relative_path: relative(path), catalog: @feature_catalog)
        result.value.accept(dsl_visitor)
        references.concat(dsl_visitor.references)
        feature_matches.concat(dsl_visitor.matches)
      end

      self
    end

    def rails_references
      resolver = ConstantResolver.new(index.names)

      references.filter_map do |reference|
        resolved = resolver.resolve(reference.name, reference.namespace)
        next unless resolved

        {
          constant: resolved,
          raw: reference.name,
          path: reference.path,
          line: reference.line,
        }
      end
    end

    def direct_rails_constants
      rails_references.map { |reference| reference.fetch(:constant) }.to_set
    end

    def to_h
      {
        app_root: app_root.to_s,
        scan_roots: scan_roots,
        files_scanned: ruby_files.length,
        parse_errors: parse_errors,
        direct_rails_constants_count: direct_rails_constants.length,
        direct_rails_constants: direct_rails_constants.to_a.sort,
        references: rails_references,
        feature_matches: feature_matches.sort_by { |match| [match.fetch("path"), match.fetch("line"), match.fetch("feature")] },
      }
    end

    private
      def ruby_files
        @ruby_files ||= scan_roots.flat_map do |root|
          full_root = app_root.join(root)
          next [] unless full_root.exist?

          Pathname.glob(full_root.join("**/*.rb").to_s).sort.reject do |path|
            relative_path = relative(path)
            relative_path.start_with?("tmp/") ||
              relative_path.start_with?("vendor/bundle/") ||
              relative_path.start_with?("node_modules/")
          end
        end
      end

      def relative(path)
        path.relative_path_from(app_root).to_s
      end
  end
end
