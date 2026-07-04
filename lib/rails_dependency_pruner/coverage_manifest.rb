# frozen_string_literal: true

require "pathname"
require "yaml"

require_relative "source_digest"

module RailsDependencyPruner
  class CoverageManifest
    WORKLOAD_KEYS = %w[
      boot
      routes
      jobs
      mailers
      cable
      rake_tasks
      custom_commands
    ].freeze

    attr_reader :path, :payload

    def initialize(path:, payload:)
      @path = Pathname.new(path).expand_path
      @payload = deep_stringify(payload)
    end

    def self.load(path)
      pathname = Pathname.new(path)
      raise ArgumentError, "coverage manifest not found: #{pathname}" unless pathname.file?

      payload = YAML.safe_load(File.read(pathname), aliases: false) || {}
      raise ArgumentError, "coverage manifest must be a YAML mapping" unless payload.is_a?(Hash)

      new(path: pathname, payload: payload)
    rescue Psych::SyntaxError => error
      raise ArgumentError, "coverage manifest is invalid YAML: #{error.message}"
    end

    def digest
      SourceDigest.file(path)
    end

    def rails_env
      payload["rails_env"]
    end

    def eager_load
      value = payload.dig("boot", "eager_load")
      return value if value == true || value == false
    end

    def workloads
      explicit = Array(payload["workloads"]).map(&:to_s)
      detected = WORKLOAD_KEYS.select { |key| present?(payload[key]) }

      (explicit + detected).uniq.sort
    end

    def to_h
      {
        "path" => path.to_s,
        "digest" => digest,
        "rails_env" => rails_env,
        "eager_load" => eager_load,
        "workloads" => workloads,
      }
    end

    private
      def present?(value)
        case value
        when nil, false
          false
        when String
          !value.empty?
        when Array, Hash
          !value.empty?
        else
          true
        end
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
