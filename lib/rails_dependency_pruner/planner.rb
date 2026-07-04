# frozen_string_literal: true

require "set"

require_relative "constant_resolver"
require_relative "graph/constant_graph_builder"
require_relative "runtime_memory_summary"

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

    def seed_constants
      usage.direct_rails_constants | runtime_constants
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
        runtime_memory: runtime_memory,
        runtime_memory_summary: runtime_memory_summary.to_h,
        top_unused_namespaces: unused_by_namespace,
      }

      payload[:used_constants] = used_constants.to_a.sort
      payload[:unused_constants] = unused_constants.to_a.sort if include_unused
      payload[:unused_features] = unused_features if include_unused
      payload[:unused_require_paths] = unused_require_paths if include_unused
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
      dependency_graph.reachable_from(seed_constants).map { |id| id.delete_prefix("constant:") }.to_set
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
  end
end
