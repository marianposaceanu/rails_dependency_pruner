# frozen_string_literal: true

module RailsDependencyPruner
  module Graph
    Edge = Struct.new(:from, :to, :type, :source, :confidence, :metadata, keyword_init: true) do
      def to_h
        {
          "from" => from,
          "to" => to,
          "type" => type.to_s,
          "source" => source,
          "confidence" => confidence,
          "metadata" => metadata || {},
        }
      end
    end
  end
end
