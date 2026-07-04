# frozen_string_literal: true

require "pathname"
require "set"

require "prism"

require_relative "constant_resolver"
require_relative "feature_catalog"
require_relative "static/config_visitor"
require_relative "static/dynamic_constant_visitor"
require_relative "static/rails_dsl_visitor"
require_relative "static/require_visitor"
require_relative "static/route_visitor"
require_relative "source_visitor"

module RailsDependencyPruner
  class AppUsage
    DEFAULT_SCAN_ROOTS = %w[app config lib].freeze

    attr_reader :app_root, :index, :scan_roots, :references, :require_references, :feature_matches, :config_matches, :route_matches, :dynamic_matches, :require_matches, :parse_errors

    def initialize(app_root:, index:, scan_roots: DEFAULT_SCAN_ROOTS, feature_catalog: FeatureCatalog.default)
      @app_root = Pathname.new(app_root).expand_path
      @index = index
      @scan_roots = scan_roots
      @feature_catalog = feature_catalog
      @references = []
      @require_references = []
      @feature_matches = []
      @config_matches = []
      @route_matches = []
      @dynamic_matches = []
      @require_matches = []
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

        config_visitor = Static::ConfigVisitor.new(relative_path: relative(path), catalog: @feature_catalog)
        result.value.accept(config_visitor)
        references.concat(config_visitor.references)
        config_matches.concat(config_visitor.matches)

        route_visitor = Static::RouteVisitor.new(relative_path: relative(path), catalog: @feature_catalog)
        result.value.accept(route_visitor)
        references.concat(route_visitor.references)
        route_matches.concat(route_visitor.matches)

        dynamic_visitor = Static::DynamicConstantVisitor.new(relative_path: relative(path))
        result.value.accept(dynamic_visitor)
        references.concat(dynamic_visitor.references)
        dynamic_matches.concat(dynamic_visitor.matches)

        require_visitor = Static::RequireVisitor.new(relative_path: relative(path))
        result.value.accept(require_visitor)
        require_references.concat(require_visitor.references)
        require_matches.concat(require_visitor.matches)
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

    def direct_rails_require_constants
      rails_require_references.flat_map do |reference|
        constants_for_require_path(reference.target)
      end.to_set
    end

    def rails_require_references
      require_references.select do |reference|
        constants_for_require_path(reference.target).any?
      end
    end

    def sorted_dynamic_matches
      dynamic_matches.sort_by { |match| [match.fetch("path"), match.fetch("line"), match.fetch("kind"), match["constant"].to_s] }
    end

    def sorted_require_matches
      require_matches.sort_by { |match| [match.fetch("path"), match.fetch("line"), match.fetch("kind"), match["target"].to_s] }
    end

    def sorted_config_matches
      config_matches.sort_by { |match| [match.fetch("path"), match.fetch("line"), match.fetch("feature"), match.fetch("config_path")] }
    end

    def sorted_route_matches
      route_matches.sort_by { |match| [match.fetch("path"), match.fetch("line"), match.fetch("feature"), match.fetch("route_signature")] }
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
        config_matches: sorted_config_matches,
        route_matches: sorted_route_matches,
        dynamic_matches: sorted_dynamic_matches,
        require_matches: sorted_require_matches,
      }
    end

    private
      def constants_for_require_path(path)
        definitions_by_require_path.fetch(path.to_s.delete_suffix(".rb"), []).map(&:name)
      end

      def definitions_by_require_path
        @definitions_by_require_path ||= index.definitions.values.each_with_object({}) do |definition, result|
          require_path = definition.path.split("/lib/", 2).last&.delete_suffix(".rb")
          next unless require_path

          result[require_path] ||= []
          result[require_path] << definition
        end
      end

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
