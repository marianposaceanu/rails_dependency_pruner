# frozen_string_literal: true

require "set"

require_relative "edge"
require_relative "node"

module RailsDependencyPruner
  module Graph
    class DependencyGraph
      attr_reader :nodes, :edges

      def initialize
        @nodes = {}
        @edges = []
      end

      def add_node(type:, name:, path: nil, component: nil, metadata: {})
        id = node_id(type, name)
        nodes[id] ||= Node.new(
          id: id,
          type: type,
          name: name,
          path: path,
          component: component,
          metadata: metadata,
        )
      end

      def add_edge(from:, to:, type:, source:, confidence:, metadata: {})
        edges << Edge.new(
          from: from,
          to: to,
          type: type,
          source: source,
          confidence: confidence,
          metadata: metadata,
        )
      end

      def node_id(type, name)
        "#{type}:#{name}"
      end

      def constant_id(name)
        node_id(:constant, name)
      end

      def file_id(path)
        node_id(:file, path)
      end

      def require_path_id(path)
        node_id(:require_path, path)
      end

      def reachable_from(seeds, edge_filter: nil)
        visited = Set.new
        queue = seeds.map { |seed| normalize_seed(seed) }.compact

        until queue.empty?
          id = queue.shift
          next if visited.include?(id)

          visited << id

          outgoing_edges(id).each do |edge|
            next if edge_filter && !edge_filter.call(edge)
            next if visited.include?(edge.to)

            queue << edge.to
          end
        end

        visited
      end

      def path_from(seeds, target)
        target_id = normalize_seed(target)
        queue = seeds.map { |seed| normalize_seed(seed) }.compact
        previous = {}
        visited = Set.new

        queue.each { |seed| previous[seed] = nil }

        until queue.empty?
          id = queue.shift
          next if visited.include?(id)

          visited << id
          break if id == target_id

          outgoing_edges(id).each do |edge|
            next if previous.key?(edge.to)

            previous[edge.to] = [id, edge]
            queue << edge.to
          end
        end

        return [] unless previous.key?(target_id)

        path = []
        cursor = target_id

        while cursor
          parent, edge = previous[cursor]
          path.unshift({ "node" => cursor, "via" => edge&.type&.to_s })
          cursor = parent
        end

        path
      end

      def explain(node_id)
        node = nodes[node_id] || nodes[normalize_seed(node_id)]
        return unless node

        {
          "node" => node.to_h,
          "outgoing_edges" => outgoing_edges(node.id).map(&:to_h),
          "incoming_edges" => incoming_edges(node.id).map(&:to_h),
        }
      end

      def to_h
        {
          "nodes" => nodes.values.sort_by(&:id).map(&:to_h),
          "edges" => edges.sort_by { |edge| [edge.from, edge.to, edge.type.to_s] }.map(&:to_h),
        }
      end

      private
        def normalize_seed(seed)
          id = seed.to_s
          return id if nodes.key?(id)

          constant_id(id) if nodes.key?(constant_id(id))
        end

        def outgoing_edges(id)
          edges.select { |edge| edge.from == id }
        end

        def incoming_edges(id)
          edges.select { |edge| edge.to == id }
        end
    end
  end
end
