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

          traced_feature_constants(payload).each do |constant|
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
        process_memory: process_memory,
        snapshots: snapshots,
        rails_application: rails_application,
        event_summary: event_summary,
        require_events: require_events,
        load_events: load_events,
        limits: limits,
        truncation: truncation,
      }
    end

    def memory
      payloads.filter_map { |payload| payload["memory"] }
    end

    def process_memory
      payloads.filter_map { |payload| payload["process_memory"] }
    end

    def snapshots
      payloads.flat_map { |payload| Array(payload["snapshots"]) }
    end

    def rails_application
      payloads.filter_map do |payload|
        application = payload["rails_application"]
        application unless application.nil? || application.empty?
      end
    end

    def event_summary
      summaries = payloads.filter_map do |payload|
        events = Array(payload["events"])
        next if events.empty? && !payload.key?("events_count") && !payload.key?("unexpected_events_count")

        unexpected_events = events.select { |event| event["expected"] == false }
        {
          "mode" => payload["mode"],
          "events_count" => integer(payload["events_count"]) || events.length,
          "expected_events_count" => integer(payload["expected_events_count"]) || events.count { |event| event["expected"] == true },
          "unexpected_events_count" => integer(payload["unexpected_events_count"]) || unexpected_events.length,
          "unexpected_events" => unexpected_events.map { |event| compact_event(event) },
        }.compact
      end

      {
        "files_count" => summaries.length,
        "events_count" => summaries.sum { |summary| summary.fetch("events_count", 0) },
        "expected_events_count" => summaries.sum { |summary| summary.fetch("expected_events_count", 0) },
        "unexpected_events_count" => summaries.sum { |summary| summary.fetch("unexpected_events_count", 0) },
        "files" => summaries,
      }
    end

    def require_events
      payloads.flat_map { |payload| Array(payload["require_events"]) }
    end

    def load_events
      payloads.flat_map { |payload| Array(payload["load_events"]) }
    end

    def limits
      payloads.map do |payload|
        payload["limits"] || legacy_limits(payload)
      end
    end

    def truncation
      {
        "called_methods" => limits.any? { |limit| limit.dig("called_methods", "truncated") },
        "require_events" => limits.any? { |limit| limit.dig("require_events", "truncated") },
        "load_events" => limits.any? { |limit| limit.dig("load_events", "truncated") },
        "snapshots" => limits.any? { |limit| limit.dig("snapshots", "truncated") },
        "middleware" => limits.any? { |limit| limit.dig("middleware", "truncated") },
        "routes" => limits.any? { |limit| limit.dig("routes", "truncated") },
      }
    end

    private
      def payloads
        @payloads ||= paths.map do |path|
          JSON.parse(File.read(path))
        end
      end

      def integer(value)
        return value if value.is_a?(Integer)
        return if value.nil? || value.to_s.empty?

        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end

      def compact_event(event)
        event.slice(
          "mode",
          "phase",
          "action",
          "event_id",
          "path",
          "matched_path",
          "gem",
          "constant",
          "transform_id",
          "caller_path",
          "caller_line",
        )
      end

      def legacy_limits(payload)
        {
          "called_methods" => {
            "recorded" => Array(payload["called_methods"]).length,
            "max" => nil,
            "truncated" => payload["called_methods_truncated"] == true,
          },
          "require_events" => {
            "recorded" => Array(payload["require_events"]).length,
            "max" => nil,
            "truncated" => payload["require_events_truncated"] == true,
          },
          "load_events" => {
            "recorded" => Array(payload["load_events"]).length,
            "max" => nil,
            "truncated" => payload["load_events_truncated"] == true,
          },
          "snapshots" => {
            "recorded" => Array(payload["snapshots"]).length,
            "max" => nil,
            "truncated" => payload["snapshots_truncated"] == true,
          },
          "middleware" => {
            "recorded" => Array(payload.dig("rails_application", "middleware")).length,
            "max" => nil,
            "truncated" => payload["middleware_truncated"] == true,
          },
          "routes" => {
            "recorded" => Array(payload.dig("rails_application", "routes")).length,
            "max" => nil,
            "truncated" => payload["routes_truncated"] == true,
          },
        }
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
          constants_for_runtime_path(feature)
        end
      end

      def traced_feature_constants(payload)
        (Array(payload["require_events"]) + Array(payload["load_events"])).flat_map do |event|
          constants_for_runtime_path(event["resolved_path"] || event["path"])
        end
      end

      def definitions_by_path
        @definitions_by_path ||= index.definitions.values.group_by(&:path)
      end

      def definitions_by_require_path
        @definitions_by_require_path ||= definitions_by_path.each_with_object({}) do |(path, definitions), result|
          require_path = path.split("/lib/", 2).last&.delete_suffix(".rb")
          next unless require_path

          result[require_path] ||= []
          result[require_path].concat(definitions)
        end
      end

      def constants_for_runtime_path(path)
        runtime_path_candidates(path).flat_map do |candidate|
          path_definitions = definitions_by_path.fetch(candidate, [])
          require_definitions = definitions_by_require_path.fetch(candidate.delete_suffix(".rb"), [])

          (path_definitions + require_definitions).map(&:name)
        end.uniq
      end

      def runtime_path_candidates(path)
        return [] if path.nil? || path.to_s.empty?

        value = path.to_s
        relative = relative_rails_path(value)
        return [] unless relative

        [relative, relative.delete_suffix(".rb")].uniq
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
