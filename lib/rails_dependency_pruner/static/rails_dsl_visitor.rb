# frozen_string_literal: true

require "prism"

require_relative "../constant_definition"

module RailsDependencyPruner
  module Static
    class RailsDslVisitor < Prism::Visitor
      attr_reader :references, :matches

      def initialize(relative_path:, catalog:)
        @relative_path = relative_path
        @catalog = catalog
        @references = []
        @matches = []
      end

      def visit_call_node(node)
        record_matches(node)
        super
      end

      private
        def record_matches(node)
          @catalog.matches_for_pattern(node.name).each do |match|
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
  end
end
