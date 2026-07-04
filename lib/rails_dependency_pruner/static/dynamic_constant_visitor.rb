# frozen_string_literal: true

require "prism"

require_relative "../constant_definition"

module RailsDependencyPruner
  module Static
    class DynamicConstantVisitor < Prism::Visitor
      attr_reader :references, :matches

      def initialize(relative_path:)
        @relative_path = relative_path
        @references = []
        @matches = []
      end

      def visit_call_node(node)
        case node.name
        when :constantize, :safe_constantize
          record_constantize(node)
        when :const_get, :const_defined?
          record_const_lookup(node)
        end

        super
      end

      private
        def record_constantize(node)
          literal = literal_string(node.receiver)
          if literal
            add_reference(literal, node, kind: node.name, confidence: 1.0)
          else
            add_match(nil, node, kind: node.name, confidence: 0.2, dynamic: true)
          end
        end

        def record_const_lookup(node)
          literal = literal_value(first_argument(node))
          receiver = constant_name(node.receiver)

          if literal
            constant = qualify_lookup(receiver, literal)
            add_reference(constant, node, kind: node.name, confidence: 1.0)
          else
            add_match(receiver, node, kind: node.name, confidence: 0.3, dynamic: true)
          end
        end

        def add_reference(name, node, kind:, confidence:)
          return if name.nil? || name.empty?

          references << RawReference.new(
            name: name,
            namespace: nil,
            path: @relative_path,
            line: node.location.start_line,
          )
          add_match(name, node, kind: kind, confidence: confidence, dynamic: false)
        end

        def add_match(name, node, kind:, confidence:, dynamic:)
          matches << {
            "kind" => kind.to_s,
            "constant" => name,
            "confidence" => confidence,
            "dynamic" => dynamic,
            "path" => @relative_path,
            "line" => node.location.start_line,
          }.compact
        end

        def qualify_lookup(receiver, literal)
          normalized = literal.to_s.delete_prefix("::")
          return normalized if normalized.include?("::")
          return normalized if receiver.nil? || receiver == "Object" || receiver == "Kernel"

          "#{receiver}::#{normalized}"
        end

        def first_argument(node)
          node.arguments&.arguments&.first
        end

        def literal_value(node)
          case node
          when Prism::StringNode, Prism::SymbolNode
            node.unescaped
          end
        end

        def literal_string(node)
          node.unescaped if node.is_a?(Prism::StringNode)
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
