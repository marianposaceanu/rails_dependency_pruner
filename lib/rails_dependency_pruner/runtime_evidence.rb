# frozen_string_literal: true

require "json"
require "pathname"
require "set"

module RailsDependencyPruner
  class RuntimeEvidence
    attr_reader :paths, :index

    def initialize(paths:, index:)
      @paths = paths
      @index = index
    end

    def constants
      @constants ||= begin
        constants = Set.new

        payloads.each do |payload|
          explicit_constants(payload).each do |constant|
            constants << constant if index.names.include?(constant)
          end

          loaded_feature_constants(payload).each do |constant|
            constants << constant
          end
        end

        constants
      end
    end

    def to_h
      {
        paths: paths,
        constants_count: constants.length,
        constants: constants.to_a.sort,
        memory: memory,
        require_events: require_events,
        load_events: load_events,
      }
    end

    def memory
      payloads.filter_map { |payload| payload["memory"] }
    end

    def require_events
      payloads.flat_map { |payload| Array(payload["require_events"]) }
    end

    def load_events
      payloads.flat_map { |payload| Array(payload["load_events"]) }
    end

    private
      def payloads
        @payloads ||= paths.map do |path|
          JSON.parse(File.read(path))
        end
      end

      def explicit_constants(payload)
        [
          payload["constants"],
          payload["defined_constants"],
          payload["called_constants"],
          payload["rails_constants"],
          called_method_constants(payload),
        ].compact.flatten.map { |constant| normalize_constant_name(constant) }.compact
      end

      def called_method_constants(payload)
        Array(payload["called_methods"]).filter_map do |method|
          method["defined_class"] || method["owner"]
        end
      end

      def loaded_feature_constants(payload)
        Array(payload["loaded_features"]).flat_map do |feature|
          relative = relative_rails_path(feature)
          next [] unless relative

          definitions_by_path.fetch(relative, []).map(&:name)
        end
      end

      def definitions_by_path
        @definitions_by_path ||= index.definitions.values.group_by(&:path)
      end

      def relative_rails_path(feature)
        path = Pathname.new(feature)
        return feature unless path.absolute?

        index.relative_path_for(path)
      rescue Errno::ENOENT
        nil
      end

      def normalize_constant_name(value)
        value.to_s.delete_prefix("::").sub(/\A#<Class:/, "").delete_suffix(">")
      end
  end
end
