# frozen_string_literal: true

require "prism"

module RailsDependencyPruner
  module Static
    RequireReference = Struct.new(:kind, :target, :path, :line, keyword_init: true) do
      def to_h
        {
          "kind" => kind.to_s,
          "target" => target,
          "path" => path,
          "line" => line,
        }
      end
    end

    class RequireVisitor < Prism::Visitor
      attr_reader :references, :matches

      def initialize(relative_path:)
        @relative_path = relative_path
        @references = []
        @matches = []
      end

      def visit_call_node(node)
        record_require(node)
        super
      end

      private
        def record_require(node)
          return unless require_call?(node)

          target = literal_target(node)
          if target
            references << RequireReference.new(
              kind: node.name,
              target: target,
              path: @relative_path,
              line: node.location.start_line,
            )
          end

          matches << {
            "kind" => node.name.to_s,
            "target" => target,
            "confidence" => target ? 1.0 : 0.3,
            "dynamic" => target.nil?,
            "path" => @relative_path,
            "line" => node.location.start_line,
          }.compact
        end

        def literal_target(node)
          arguments = node.arguments&.arguments || []
          argument = node.name == :autoload ? arguments[1] : arguments[0]

          literal_require_target(argument)
        end

        def require_call?(node)
          return false unless %i[require require_relative load autoload].include?(node.name)

          case node.name
          when :autoload
            node.receiver.nil?
          else
            node.receiver.nil? || kernel_receiver?(node.receiver)
          end
        end

        def literal_require_target(node)
          case node
          when Prism::StringNode
            node.unescaped
          when Prism::CallNode
            literal_call_target(node)
          end
        end

        def literal_call_target(node)
          if node.name == :to_s && empty_arguments?(node)
            return literal_require_target(node.receiver)
          end

          return unless node.name == :join && rails_root_receiver?(node.receiver)

          parts = node.arguments&.arguments&.map { |argument| literal_require_target(argument) }
          return unless parts&.all?

          File.join(parts)
        end

        def kernel_receiver?(node)
          node.is_a?(Prism::ConstantReadNode) && node.name == :Kernel
        end

        def rails_root_receiver?(node)
          node.is_a?(Prism::CallNode) &&
            node.name == :root &&
            empty_arguments?(node) &&
            node.receiver.is_a?(Prism::ConstantReadNode) &&
            node.receiver.name == :Rails
        end

        def empty_arguments?(node)
          node.arguments.nil? || node.arguments.arguments.empty?
        end
    end
  end
end
