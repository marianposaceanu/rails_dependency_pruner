# frozen_string_literal: true

require "pathname"
require "yaml"
require "date"

require_relative "source_digest"

module RailsDependencyPruner
  class CoverageManifest
    WORKLOAD_KEYS = %w[
      boot
      routes
      requests
      attachments
      inbound_email
      jobs
      mailers
      channels
      cable
      active_storage
      action_text
      rake_tasks
      custom_commands
    ].freeze
    WORKLOAD_ALIASES = {
      "active_storage" => "attachments",
      "channels" => "cable",
    }.freeze
    ACTIVE_STORAGE_ACTIONS = %w[
      upload
      analyze
      variant
      preview
      representation
      attachment_read
    ].freeze
    EXTERNAL_INTEGRATION_REVIEW_STATUSES = %w[
      covered
      disabled
      disabled_in_profile
      disabled_in_production
      disabled_in_test_profile
      no_production_dsn
      not_used
    ].freeze
    EXTERNAL_INTEGRATION_ALIASES = {
      "rack-mini-profiler" => %w[rack_mini_profiler],
      "sentry-rails" => %w[sentry],
      "sentry-ruby" => %w[sentry],
    }.freeze
    LAZY_GEM_REVIEW_STATUSES = %w[
      covered
      first_use_covered
      manual_app_use
      not_on_boot_path
      not_on_request_path
    ].freeze
    DEFAULT_CANARY_MIN_DURATION_SECONDS = 3_600
    DEFAULT_CANARY_MIN_REQUEST_COUNT = 10_000

    attr_reader :path, :payload

    def initialize(path:, payload:)
      @path = Pathname.new(path).expand_path
      @payload = deep_stringify(payload)
    end

    def self.load(path)
      pathname = Pathname.new(path)
      raise ArgumentError, "coverage manifest not found: #{pathname}" unless pathname.file?

      payload = YAML.safe_load(File.read(pathname), aliases: false, permitted_classes: [Date]) || {}
      raise ArgumentError, "coverage manifest must be a YAML mapping" unless payload.is_a?(Hash)

      new(path: pathname, payload: payload)
    rescue Psych::SyntaxError => error
      raise ArgumentError, "coverage manifest is invalid YAML: #{error.message}"
    end

    def self.normalize_workload_key(key)
      WORKLOAD_ALIASES.fetch(key.to_s, key.to_s)
    end

    def digest
      SourceDigest.file(path)
    end

    def rails_env
      payload["rails_env"]
    end

    def version
      Integer(payload.fetch("version", 1))
    rescue ArgumentError, TypeError
      1
    end

    def eager_load
      value = payload.dig("boot", "eager_load")
      return value if value == true || value == false
    end

    def workloads
      explicit = Array(payload["workloads"]).map(&:to_s)
      detected = WORKLOAD_KEYS.select { |key| workload_present?(key) }

      (explicit + detected).map { |key| normalize_workload_key(key) }.uniq.sort
    end

    def to_h
      {
        "path" => path.to_s,
        "digest" => digest,
        "version" => version,
        "rails_env" => rails_env,
        "eager_load" => eager_load,
        "workloads" => workloads,
        "rollback_tested" => rollback_tested?,
        "canary_evidence" => canary_evidence,
      }
    end

    def memory_policy
      policy = payload["memory_policy"]
      return {} unless policy.is_a?(Hash)

      policy
    end

    def safety_policy
      policy = payload["safety_policy"]
      return {} unless policy.is_a?(Hash)

      policy
    end

    def safety_overrides(today: Date.today)
      overrides = payload["overrides"]
      return [] unless overrides.is_a?(Array)

      overrides.filter_map { |override| normalize_safety_override(override, today: today) }
    end

    def active_storage_actions
      value = payload["active_storage"]
      return [] unless value.is_a?(Hash)
      return [] if value["review_required"] == true

      ACTIVE_STORAGE_ACTIONS.select { |key| value[key] == true }
    end

    def job_classes
      reviewed_entries("jobs", "classes")
    end

    def mailer_actions
      reviewed_entries("mailers", "actions")
    end

    def channel_classes
      reviewed_entries("channels", "classes")
    end

    def inbound_email_mailboxes
      reviewed_entries("inbound_email", "mailboxes")
    end

    def request_entries
      @request_entries ||= normalized_request_entries(payload["requests"])
    end

    def request_covered?(method:, path:)
      method = method.to_s.upcase
      path = normalize_request_path(path)

      request_entries.any? do |entry|
        entry.fetch("path") == path &&
          (entry.fetch("method") == method || entry.fetch("method") == "ANY")
      end
    end

    def high_risk_override(transform_id, today: Date.today)
      overrides = payload["high_risk_overrides"]
      return unless overrides.is_a?(Hash)

      override = overrides[high_risk_override_key(transform_id)]
      return unless override.is_a?(Hash)

      accepted_by = override["accepted_by"].to_s.strip
      reason = override["reason"].to_s.strip
      expires_at = parse_date(override["expires_at"])
      return if accepted_by.empty? || reason.empty? || expires_at.nil? || expires_at <= today

      override.merge("expires_at" => expires_at.iso8601)
    end

    def external_integration_status(name)
      value = external_integration_value(name)
      case value
      when Hash
        return if value["review_required"] == true

        (
          value["status"] ||
          value["production_behavior"] ||
          value["production_status"] ||
          value["value"]
        ).to_s
      when nil
        nil
      else
        value.to_s
      end
    end

    def external_integration_reviewed?(name)
      EXTERNAL_INTEGRATION_REVIEW_STATUSES.include?(external_integration_status(name))
    end

    def lazy_gem_status(name)
      value = lazy_gem_value(name)
      case value
      when Hash
        return if value["review_required"] == true

        (
          value["status"] ||
          value["coverage"] ||
          value["production_status"] ||
          value["value"]
        ).to_s
      when nil
        nil
      else
        value.to_s
      end
    end

    def lazy_gem_reviewed?(name)
      LAZY_GEM_REVIEW_STATUSES.include?(lazy_gem_status(name))
    end

    def rollback_tested?
      rollback = payload["rollback"]
      return false unless rollback.is_a?(Hash)
      return false if rollback["review_required"] == true

      rollback["disable_env_tested"] == true
    end

    def canary_evidence
      canary = payload["canary"]
      return {} unless canary.is_a?(Hash)

      duration_seconds = duration_seconds_for(canary)
      request_count = integer(canary["request_count"] || canary["requests"])
      unexpected_events_count = integer(canary["unexpected_events_count"] || canary["unexpected_events"])
      min_duration_seconds = duration_seconds_for(canary, prefix: "min_") || DEFAULT_CANARY_MIN_DURATION_SECONDS
      min_request_count = integer(canary["min_request_count"] || canary["min_requests"]) || DEFAULT_CANARY_MIN_REQUEST_COUNT
      reviewed = canary["review_required"] == false

      {
        "reviewed" => reviewed,
        "duration_seconds" => duration_seconds,
        "request_count" => request_count,
        "unexpected_events_count" => unexpected_events_count,
        "min_duration_seconds" => min_duration_seconds,
        "min_request_count" => min_request_count,
        "sample_passed" => sample_passed?(
          duration_seconds: duration_seconds,
          request_count: request_count,
          min_duration_seconds: min_duration_seconds,
          min_request_count: min_request_count,
        ),
        "passed" => reviewed && unexpected_events_count == 0 && sample_passed?(
          duration_seconds: duration_seconds,
          request_count: request_count,
          min_duration_seconds: min_duration_seconds,
          min_request_count: min_request_count,
        ),
      }
    end

    def canary_passed?
      canary_evidence["passed"] == true
    end

    private
      def present?(value)
        case value
        when nil, false
          false
        when String
          !value.empty?
        when Array, Hash
          return false if value.is_a?(Hash) && value["review_required"] == true

          !value.empty?
        else
          true
        end
      end

      def workload_present?(key)
        case key
        when "active_storage"
          active_storage_present?(payload[key])
        else
          present?(payload[key])
        end
      end

      def active_storage_present?(value)
        return false unless value.is_a?(Hash)
        return false if value["review_required"] == true

        ACTIVE_STORAGE_ACTIONS.any? { |key| value[key] == true }
      end

      def reviewed_entries(section, key)
        value = payload[section]
        case value
        when Hash
          return [] if value["review_required"] == true

          Array(value[key]).map(&:to_s).reject(&:empty?).uniq.sort
        when Array
          value.map(&:to_s).reject(&:empty?).uniq.sort
        when String
          value.empty? ? [] : [value]
        else
          []
        end
      end

      def normalized_request_entries(value)
        case value
        when Hash
          return [] if value["review_required"] == true

          if value["method"] || value["path"]
            [normalized_request_entry(value)].compact
          else
            normalized_request_entries(value["paths"] || value["requests"])
          end
        when Array
          value.flat_map { |entry| normalized_request_entries(entry) }
        when String
          [normalized_request_string(value)].compact
        else
          []
        end
      end

      def normalized_request_entry(value)
        path = normalize_request_path(value["path"])
        return if path.empty?

        {
          "method" => value.fetch("method", "GET").to_s.upcase,
          "path" => path,
        }
      end

      def normalized_request_string(value)
        match = value.to_s.strip.match(/\A([A-Za-z]+)\s+(\S+)/)
        return unless match

        {
          "method" => match[1].upcase,
          "path" => normalize_request_path(match[2]),
        }
      end

      def normalize_request_path(path)
        path = path.to_s.strip
        return path if path.empty? || path.start_with?("/")

        "/#{path}"
      end

      def normalize_workload_key(key)
        self.class.normalize_workload_key(key)
      end

      def high_risk_override_key(transform_id)
        transform_id.to_s.tr(":-", "__")
      end

      def external_integration_value(name)
        integrations = payload["external_integrations"]
        return unless integrations.is_a?(Hash)

        external_integration_keys(name).each do |key|
          return integrations[key] if integrations.key?(key)
        end
        nil
      end

      def external_integration_keys(name)
        normalized = name.to_s
        keys = [normalized, normalized.tr("-", "_")]
        keys.concat(EXTERNAL_INTEGRATION_ALIASES.fetch(normalized, []))
        keys.uniq
      end

      def lazy_gem_value(name)
        lazy_gems = payload["lazy_gems"]
        return unless lazy_gems.is_a?(Hash)

        lazy_gem_keys(name).each do |key|
          return lazy_gems[key] if lazy_gems.key?(key)
        end
        nil
      end

      def lazy_gem_keys(name)
        normalized = name.to_s
        [normalized, normalized.tr("-", "_")].uniq
      end

      def normalize_safety_override(override, today:)
        return unless override.is_a?(Hash)

        id = override["id"].to_s.strip
        reason = override["reason"].to_s.strip
        owner = override["owner"].to_s.strip
        expires_at = parse_date(override["expires_at"])
        paths = Array(override["paths"]).map { |path| path.to_s.strip }.reject(&:empty?).uniq.sort
        return if id.empty? || reason.empty? || owner.empty? || expires_at.nil? || expires_at <= today || paths.empty?

        override.merge(
          "id" => id,
          "reason" => reason,
          "owner" => owner,
          "expires_at" => expires_at.iso8601,
          "paths" => paths,
        )
      end

      def parse_date(value)
        return value if value.is_a?(Date)
        return if value.nil? || value.to_s.empty?

        Date.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def duration_seconds_for(payload, prefix: "")
        seconds = integer(payload["#{prefix}duration_seconds"])
        return seconds unless seconds.nil?

        minutes = integer(payload["#{prefix}duration_minutes"])
        return minutes * 60 unless minutes.nil?

        hours = integer(payload["#{prefix}duration_hours"])
        return hours * 3_600 unless hours.nil?
      end

      def integer(value)
        return value if value.is_a?(Integer)
        return if value.nil? || value.to_s.empty?

        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end

      def sample_passed?(duration_seconds:, request_count:, min_duration_seconds:, min_request_count:)
        duration_seconds.to_i >= min_duration_seconds.to_i ||
          request_count.to_i >= min_request_count.to_i
      end

      def deep_stringify(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested), hash|
            hash[key.to_s] = deep_stringify(nested)
          end
        when Array
          value.map { |nested| deep_stringify(nested) }
        else
          value
        end
      end
  end
end
