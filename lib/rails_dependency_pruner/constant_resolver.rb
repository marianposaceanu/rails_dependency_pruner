# frozen_string_literal: true

require "set"

module RailsDependencyPruner
  class ConstantResolver
    def initialize(known_constants)
      @known_constants = known_constants.to_set
    end

    def resolve(name, namespace)
      normalized = normalize(name)
      return if normalized.nil? || normalized.empty?

      candidates(normalized, namespace).find { |candidate| @known_constants.include?(candidate) }
    end

    def parent_constants(name)
      parts = name.split("::")
      return [] if parts.length <= 1

      parents = []
      (1...parts.length).each do |length|
        candidate = parts.first(length).join("::")
        parents << candidate if @known_constants.include?(candidate)
      end
      parents
    end

    private
      def normalize(name)
        name&.to_s&.delete_prefix("::")
      end

      def candidates(name, namespace)
        return [name] if name.start_with?("::")

        lexical_namespaces(namespace).flat_map do |scope|
          name.start_with?("#{scope}::") ? name : "#{scope}::#{name}"
        end.push(name).uniq
      end

      def lexical_namespaces(namespace)
        parts = namespace.to_s.split("::").reject(&:empty?)
        namespaces = []

        parts.length.downto(1) do |length|
          namespaces << parts.first(length).join("::")
        end

        namespaces
      end
  end
end
