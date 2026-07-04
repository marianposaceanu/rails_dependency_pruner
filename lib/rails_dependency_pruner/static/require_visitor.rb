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
          return unless %i[require require_relative load autoload].include?(node.name)

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

          return unless argument.is_a?(Prism::StringNode)

          argument.unescaped
        end
    end
  end
end
