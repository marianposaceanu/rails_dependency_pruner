# frozen_string_literal: true

module RailsDependencyPruner
  module Graph
    Node = Struct.new(:id, :type, :name, :path, :component, :metadata, keyword_init: true) do
      def to_h
        {
          "id" => id,
          "type" => type.to_s,
          "name" => name,
          "path" => path,
          "component" => component,
          "metadata" => metadata || {},
        }
      end
    end
  end
end
