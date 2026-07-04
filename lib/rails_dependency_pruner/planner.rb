# frozen_string_literal: true

require "set"
require "pathname"

require "prism"

require_relative "constant_resolver"
require_relative "graph/constant_graph_builder"
require_relative "runtime_memory_summary"
require_relative "static/require_visitor"

module RailsDependencyPruner
  class Planner
    attr_reader :index, :usage, :runtime_evidence

    def initialize(index:, usage:, runtime_evidence: nil)
      @index = index
      @usage = usage
      @runtime_evidence = runtime_evidence
    end

    def used_constants
      @used_constants ||= begin
        resolver = ConstantResolver.new(index.names)
        used = Set.new
        queue = seed_constants.to_a

        until queue.empty?
          constant = queue.shift
          next if used.include?(constant)

          used << constant

          resolver.parent_constants(constant).each do |parent|
            queue << parent unless used.include?(parent)
          end

          index.definitions.fetch(constant)&.dependencies&.each do |dependency|
            queue << dependency unless used.include?(dependency)
          end

          file_peer_constants(constant).each do |dependency|
            queue << dependency unless used.include?(dependency)
          end

          require_dependency_constants(constant).each do |dependency|
            queue << dependency unless used.include?(dependency)
          end
        end

        used
      end
    end

    def unused_constants
      index.names.subtract(used_constants)
    end

    def unused_by_namespace
      unused_constants.group_by { |name| name.split("::").first }.transform_values(&:length).sort.to_h
    end

    def unused_features
      index.definitions.values
        .group_by(&:path)
        .select { |_path, definitions| definitions.all? { |definition| unused_constants.include?(definition.name) } }
        .keys
        .sort
    end

    def unused_require_paths
      unused_features.filter_map do |path|
        path.split("/lib/", 2).last&.delete_suffix(".rb")
      end.sort
    end

    def unused_require_path_provenance
      unused_features.filter_map do |path|
        require_path = path.split("/lib/", 2).last&.delete_suffix(".rb")
        next unless require_path

        definitions = definitions_by_path.fetch(path)

        {
          "require_path" => require_path,
          "file" => path,
          "component" => definitions.first.component,
          "constants" => definitions.map(&:name).sort,
          "reason" => "all constants defined in this Rails file are outside the app dependency closure",
        }
      end.sort_by { |entry| entry.fetch("require_path") }
    end

    def seed_constants
      usage.direct_rails_constants | usage.direct_rails_require_constants | runtime_constants
    end

    def runtime_constants
      runtime_evidence&.constants || Set.new
    end

    def to_h(include_tree: true, include_unused: true)
      payload = {
        rails_root: index.rails_root.to_s,
        rails_version: index.source.version,
        source: index.source.to_h,
        app_root: usage.app_root.to_s,
        rails_constants_count: index.definitions.length,
        app_files_scanned: usage.to_h.fetch(:files_scanned),
        rails_files_scanned: index.to_h(include_tree: false).fetch(:files_scanned),
        parse_errors: {
          rails: index.parse_errors,
          app: usage.parse_errors,
        },
        direct_rails_constants_count: usage.direct_rails_constants.length,
        runtime_rails_constants_count: runtime_constants.length,
        used_constants_count: used_constants.length,
        unused_constants_count: unused_constants.length,
        unused_features_count: unused_features.length,
        direct_rails_constants: usage.direct_rails_constants.to_a.sort,
        runtime_rails_constants: runtime_constants.to_a.sort,
        feature_matches: usage.feature_matches,
        config_matches: usage.sorted_config_matches,
        route_matches: usage.sorted_route_matches,
        dynamic_matches: usage.sorted_dynamic_matches,
        require_matches: usage.sorted_require_matches,
        runtime_memory: runtime_memory,
        runtime_memory_summary: runtime_memory_summary.to_h,
        runtime_rails_application: runtime_rails_application,
        runtime_event_summary: runtime_event_summary,
        runtime_evidence_limits: runtime_evidence_limits,
        runtime_evidence_truncation: runtime_evidence_truncation,
        top_unused_namespaces: unused_by_namespace,
      }

      payload[:used_constants] = used_constants.to_a.sort
      payload[:unused_constants] = unused_constants.to_a.sort if include_unused
      payload[:unused_features] = unused_features if include_unused
      payload[:unused_require_paths] = unused_require_paths if include_unused
      payload[:unused_require_path_provenance] = unused_require_path_provenance if include_unused
      if include_tree
        payload[:dependency_tree] = index.dependency_tree.sort.to_h
        payload[:dependency_graph] = dependency_graph.to_h
      end
      payload
    end

    def dependency_graph
      @dependency_graph ||= Graph::ConstantGraphBuilder.new(index).build
    end

    def graph_used_constants
      dependency_graph.reachable_from(seed_constants).filter_map do |id|
        id.delete_prefix("constant:") if id.start_with?("constant:")
      end.to_set
    end

    def explain_constant(name)
      resolver = ConstantResolver.new(index.names)
      resolved = resolver.resolve(name, nil) || name
      id = dependency_graph.constant_id(resolved)
      definition = index.definitions[resolved]
      seed_kind = seed_kind_for(resolved)
      used = used_constants.include?(resolved)

      {
        "query" => name,
        "constant" => resolved,
        "decision" => used ? "used" : "unused",
        "seed" => seed_kind,
        "defined" => !definition.nil?,
        "path" => definition&.path,
        "component" => definition&.component,
        "dependencies" => definition ? definition.dependencies.to_a.sort : [],
        "used_by" => used_by(resolved),
        "reachability_path" => used ? dependency_graph.path_from(seed_constants, id) : [],
        "graph" => dependency_graph.explain(id),
      }
    end

    def runtime_memory
      runtime_evidence&.memory || []
    end

    def runtime_memory_summary
      @runtime_memory_summary ||= RuntimeMemorySummary.new(runtime_memory)
    end

    def runtime_evidence_limits
      runtime_evidence&.limits || []
    end

    def runtime_evidence_truncation
      runtime_evidence&.truncation || {}
    end

    def runtime_rails_application
      runtime_evidence&.rails_application || []
    end

    def runtime_event_summary
      runtime_evidence&.event_summary || {
        "files_count" => 0,
        "events_count" => 0,
        "expected_events_count" => 0,
        "unexpected_events_count" => 0,
        "files" => [],
      }
    end

    private
      def seed_kind_for(constant)
        return "static" if usage.direct_rails_constants.include?(constant)
        return "runtime" if runtime_constants.include?(constant)
      end

      def used_by(constant)
        index.definitions.values.filter_map do |definition|
          next unless used_constants.include?(definition.name)
          next unless definition.dependencies.include?(constant)

          definition.name
        end.sort
      end

      def definitions_by_path
        @definitions_by_path ||= index.definitions.values.group_by(&:path)
      end

      def file_peer_constants(constant)
        definition = index.definitions.fetch(constant, nil)
        return [] unless definition

        definitions_by_path.fetch(definition.path, []).map(&:name)
      end

      def definitions_by_require_path
        @definitions_by_require_path ||= index.definitions.values.each_with_object({}) do |definition, result|
          require_path = definition.path.split("/lib/", 2).last&.delete_suffix(".rb")
          next unless require_path

          result[require_path] ||= []
          result[require_path] << definition
        end
      end

      def require_dependency_constants(constant)
        definition = index.definitions.fetch(constant, nil)
        return [] unless definition

        rails_require_references_by_file.fetch(definition.path, []).flat_map do |reference|
          next [] if reference.kind == :autoload

          constants_for_require_reference(reference, from_path: definition.path)
        end
      end

      def rails_require_references_by_file
        @rails_require_references_by_file ||= index.source.ruby_files.each_with_object({}) do |path, result|
          relative = index.source.relative_path(path)
          parse_result = Prism.parse_file(path.to_s)
          next unless parse_result.success?

          visitor = Static::RequireVisitor.new(relative_path: relative)
          parse_result.value.accept(visitor)
          result[relative] = visitor.references
        end
      end

      def constants_for_require_reference(reference, from_path:)
        case reference.kind
        when :require, :load
          constants_for_require_path(reference.target)
        when :require_relative
          constants_for_relative_require(reference.target, from_path: from_path)
        else
          []
        end
      end

      def constants_for_require_path(path)
        target = path.to_s.delete_suffix(".rb")
        definitions = definitions_by_require_path.fetch(target, [])
        definitions += definitions_by_path.fetch(path.to_s, [])
        definitions += definitions_by_path.fetch("#{target}.rb", [])
        definitions.map(&:name)
      end

      def constants_for_relative_require(target, from_path:)
        relative = Pathname.new(from_path).dirname.join(target.to_s).cleanpath.to_s
        relative = "#{relative}.rb" unless relative.end_with?(".rb")

        definitions_by_path.fetch(relative, []).map(&:name)
      end
  end
end
