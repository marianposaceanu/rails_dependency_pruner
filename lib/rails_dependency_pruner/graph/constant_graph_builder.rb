# frozen_string_literal: true

require_relative "dependency_graph"
require_relative "../constant_resolver"

module RailsDependencyPruner
  module Graph
    class ConstantGraphBuilder
      attr_reader :index

      def initialize(index)
        @index = index
      end

      def build
        DependencyGraph.new.tap do |graph|
          add_nodes(graph)
          add_edges(graph)
        end
      end

      private
        def add_nodes(graph)
          index.definitions.values.each do |definition|
            graph.add_node(
              type: :constant,
              name: definition.name,
              path: definition.path,
              component: definition.component,
              metadata: {
                "line" => definition.line,
              },
            )
          end
        end

        def add_edges(graph)
          resolver = ConstantResolver.new(index.names)

          index.definitions.each_value do |definition|
            from = graph.constant_id(definition.name)

            resolver.parent_constants(definition.name).each do |parent|
              graph.add_edge(
                from: from,
                to: graph.constant_id(parent),
                type: :namespace_parent,
                source: definition.path,
                confidence: 1.0,
              )
            end

            definition.dependencies.sort.each do |dependency|
              graph.add_edge(
                from: from,
                to: graph.constant_id(dependency),
                type: :references,
                source: definition.path,
                confidence: 1.0,
              )
            end
          end
        end
    end
  end
end
