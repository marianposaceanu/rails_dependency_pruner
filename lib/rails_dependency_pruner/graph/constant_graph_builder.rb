# frozen_string_literal: true

require_relative "dependency_graph"
require_relative "../constant_resolver"
require_relative "../static/require_visitor"

module RailsDependencyPruner
  module Graph
    class ConstantGraphBuilder
      attr_reader :index

      def initialize(index)
        @index = index
      end

      def build
        DependencyGraph.new.tap do |graph|
          add_file_nodes(graph)
          add_nodes(graph)
          add_file_edges(graph)
          add_require_edges(graph)
          add_edges(graph)
        end
      end

      private
        def add_file_nodes(graph)
          index.source.ruby_files.each do |path|
            relative = index.source.relative_path(path)
            graph.add_node(
              type: :file,
              name: relative,
              path: relative,
              component: index.source.component_for(path),
            )
          end
        end

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

        def add_file_edges(graph)
          index.definitions.values.each do |definition|
            graph.add_edge(
              from: graph.file_id(definition.path),
              to: graph.constant_id(definition.name),
              type: :defines,
              source: definition.path,
              confidence: 1.0,
              metadata: {
                "line" => definition.line,
              },
            )
          end
        end

        def add_require_edges(graph)
          index.source.ruby_files.each do |path|
            relative = index.source.relative_path(path)
            result = Prism.parse_file(path.to_s)
            next unless result.success?

            visitor = Static::RequireVisitor.new(relative_path: relative)
            result.value.accept(visitor)

            visitor.references.each do |reference|
              graph.add_node(type: :require_path, name: reference.target)
              graph.add_edge(
                from: graph.file_id(relative),
                to: graph.require_path_id(reference.target),
                type: edge_type_for(reference.kind),
                source: relative,
                confidence: 1.0,
                metadata: {
                  "line" => reference.line,
                  "kind" => reference.kind.to_s,
                },
              )
            end
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

        def edge_type_for(kind)
          case kind
          when :load
            :loads
          when :autoload
            :autoloads
          else
            :requires
          end
        end
    end
  end
end
