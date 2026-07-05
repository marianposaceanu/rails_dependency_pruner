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
      }
    end

    def memory_policy
      policy = payload["memory_policy"]
      return {} unless policy.is_a?(Hash)

      policy
    end

    def active_storage_actions
      value = payload["active_storage"]
      return [] unless value.is_a?(Hash)
      return [] if value["review_required"] == true

      ACTIVE_STORAGE_ACTIONS.select { |key| value[key] == true }
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

    def rollback_tested?
      rollback = payload["rollback"]
      return false unless rollback.is_a?(Hash)
      return false if rollback["review_required"] == true

      rollback["disable_env_tested"] == true
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

      def normalize_workload_key(key)
        self.class.normalize_workload_key(key)
      end

      def high_risk_override_key(transform_id)
        transform_id.to_s.tr(":-", "__")
      end

      def parse_date(value)
        return value if value.is_a?(Date)
        return if value.nil? || value.to_s.empty?

        Date.iso8601(value.to_s)
      rescue ArgumentError
        nil
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
