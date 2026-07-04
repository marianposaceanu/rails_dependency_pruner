# frozen_string_literal: true

require "yaml"

module RailsDependencyPruner
  class GemPolicyRegistry
    DEFAULT_PATH = File.expand_path("../../config/rails_dependency_pruner/gem_policies.yml", __dir__)

    Policy = Struct.new(:name, :gem_class, :risk, :strategies, :production_rule, keyword_init: true) do
      def to_h
        {
          "name" => name,
          "class" => gem_class,
          "risk" => risk,
          "strategies" => Array(strategies).sort,
          "production_rule" => production_rule,
        }
      end
    end

    attr_reader :path

    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    def self.default
      @default ||= new
    end

    def policy_for(name)
      policies[name.to_s]
    end

    def registered?(name)
      policies.key?(name.to_s)
    end

    def names
      policies.keys.sort
    end

    def to_h
      policies.transform_values(&:to_h).sort.to_h
    end

    private
      def policies
        @policies ||= load_policies
      end

      def load_policies
        payload = YAML.safe_load(File.read(path), aliases: false)
        raise ArgumentError, "gem policy registry must be a YAML mapping" unless payload.is_a?(Hash)

        payload.each_with_object({}) do |(name, config), policies|
          raise ArgumentError, "gem policy for #{name} must be a YAML mapping" unless config.is_a?(Hash)

          policies[name.to_s] = Policy.new(
            name: name.to_s,
            gem_class: required_string(config, "class", name),
            risk: required_string(config, "risk", name),
            strategies: Array(config["strategies"]).map(&:to_s).reject(&:empty?),
            production_rule: required_string(config, "production_rule", name),
          )
        end.sort.to_h
      end

      def required_string(config, key, name)
        value = config[key].to_s
        raise ArgumentError, "gem policy for #{name} missing #{key}" if value.empty?

        value
      end
  end
end
