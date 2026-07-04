# frozen_string_literal: true

require "prism"

require_relative "../constant_definition"

module RailsDependencyPruner
  module Static
    class ConfigVisitor < Prism::Visitor
      attr_reader :references, :matches

      def initialize(relative_path:, catalog:)
        @relative_path = relative_path
        @catalog = catalog
        @references = []
        @matches = []
      end

      def visit_call_node(node)
        record_config_match(node)
        super
      end

      private
        def record_config_match(node)
          config_path = config_path_for(node)
          return unless config_path

          @catalog.matches_for_config_path(config_path).each do |match|
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

        def config_path_for(node)
          chain = call_chain(node)
          config_index = chain.rindex("config")
          return unless config_index

          parts = chain[(config_index + 1)..]
          return if parts.length < 2

          parts.join(".")
        end

        def call_chain(node)
          case node
          when Prism::CallNode
            call_chain(node.receiver) + [node.name.to_s.delete_suffix("=")]
          when Prism::ConstantReadNode
            [node.name.to_s]
          else
            []
          end
        end
    end
  end
end
