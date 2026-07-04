# frozen_string_literal: true

require "json"

module RailsDependencyPruner
  module CanonicalJson
    module_function

    def dump(value)
      "#{JSON.pretty_generate(canonicalize(value))}\n"
    end

    def digestible(value)
      JSON.generate(canonicalize(value))
    end

    def canonicalize(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.to_h do |key|
          [key, canonicalize(fetch_key(value, key))]
        end
      when Array
        value.map { |entry| canonicalize(entry) }.sort_by { |entry| JSON.generate(entry) }
      else
        value
      end
    end

    def fetch_key(hash, key)
      hash.key?(key) ? hash.fetch(key) : hash.fetch(key.to_sym)
    end
  end
end
