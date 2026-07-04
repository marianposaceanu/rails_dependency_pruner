# frozen_string_literal: true

require "prism"

require_relative "../constant_definition"

module RailsDependencyPruner
  module Static
    class RouteVisitor < Prism::Visitor
      ROUTE_CALLS = %i[
        constraints
        delete
        direct
        get
        match
        mount
        patch
        post
        put
        redirect
        resolve
        resource
        resources
        root
      ].freeze

      attr_reader :references, :matches

      def initialize(relative_path:, catalog:)
        @relative_path = relative_path
        @catalog = catalog
        @references = []
        @matches = []
      end

      def visit_call_node(node)
        record_route_match(node) if route_file?
        super
      end

      private
        def route_file?
          @relative_path == "config/routes.rb"
        end

        def record_route_match(node)
          return unless ROUTE_CALLS.include?(node.name)

          route_signatures(node).each do |signature|
            @catalog.matches_for_route_signature(signature).each do |match|
              match = match.merge(
                "path" => @relative_path,
                "line" => node.location.start_line,
              )
              @matches << match

              match.fetch("constants").each do |constant|
                @references << RawReference.new(
                  name: constant,
                  namespace: nil,
                  path: @relative_path,
                  line: node.location.start_line,
                )
              end
            end
          end
        end

        def route_signatures(node)
          signatures = ["route:#{node.name}"]

          case node.name
          when :direct
            literal = literal_value(first_argument(node))
            signatures << "direct:#{literal}" if literal
          when :resolve
            literal = literal_value(first_argument(node)) || constant_name(first_argument(node))
            signatures << "resolve:#{literal}" if literal
          when :mount
            target = mount_target(node)
            signature = mount_signature(target)
            signatures << "mount:#{signature}" if signature
          end

          signatures
        end

        def first_argument(node)
          node.arguments&.arguments&.first
        end

        def mount_target(node)
          arguments = node.arguments&.arguments || []
          first = arguments.first

          if first.is_a?(Prism::KeywordHashNode)
            assoc = first.elements.first
            return assoc.key if assoc.is_a?(Prism::AssocNode)
          end

          first unless first.is_a?(Prism::KeywordHashNode)
        end

        def mount_signature(node)
          case node
          when Prism::CallNode
            receiver = constant_name(node.receiver)
            return "#{receiver}.#{node.name}" if receiver
          else
            constant_name(node)
          end
        end

        def literal_value(node)
          case node
          when Prism::StringNode, Prism::SymbolNode
            node.unescaped
          end
        end

        def constant_name(node)
          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            node.full_name
          end
        rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
          nil
        end
    end
  end
end
