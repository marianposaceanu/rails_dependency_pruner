# frozen_string_literal: true

require "set"

module RailsDependencyPruner
  module RequireGuard
    module Hook
      def require(path)
        RailsDependencyPruner::RequireGuard.check!(path)
        super
      end
    end

    class << self
      attr_reader :disabled_paths

      def install!(paths)
        @disabled_paths = normalized_paths(paths)
        return if @disabled_paths.empty? || @installed

        Kernel.prepend(Hook)
        @installed = true
      end

      def check!(path)
        return unless disabled?(path)

        raise DisabledConstantError, "#{path} is disabled by RailsDependencyPruner"
      end

      def disabled?(path)
        disabled_paths&.include?(normalize(path))
      end

      private

      def normalized_paths(paths)
        paths.flat_map do |path|
          normalized = normalize(path)
          [normalized, normalized.delete_suffix(".rb")]
        end.to_set
      end

      def normalize(path)
        path.to_s
      end
    end
  end
end
