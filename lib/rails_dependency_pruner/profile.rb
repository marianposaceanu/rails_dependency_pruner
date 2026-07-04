# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module RailsDependencyPruner
  class Profile
    SCHEMA_VERSION = 1

    attr_reader :payload

    def initialize(payload)
      @payload = payload
    end

    def self.from_planner(planner)
      new(
        "schema_version" => SCHEMA_VERSION,
        "generated_at" => Time.now.utc.iso8601,
        "rails_version" => planner.index.source.version,
        "source" => planner.index.source.to_h,
        "app_root" => planner.usage.app_root.to_s,
        "rails_constants_count" => planner.index.definitions.length,
        "direct_rails_constants_count" => planner.usage.direct_rails_constants.length,
        "runtime_rails_constants_count" => planner.runtime_constants.length,
        "used_constants_count" => planner.used_constants.length,
        "unused_constants_count" => planner.unused_constants.length,
        "unused_features_count" => planner.unused_features.length,
        "unused_constants" => planner.unused_constants.to_a.sort,
        "unused_features" => planner.unused_features,
        "unused_require_paths" => planner.unused_require_paths,
        "runtime_memory" => planner.runtime_memory,
        "runtime_memory_summary" => planner.runtime_memory_summary.to_h,
      )
    end

    def self.load(path)
      new(JSON.parse(File.read(path)))
    end

    def write(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(payload))
    end

    def unused_constants
      Array(payload.fetch("unused_constants"))
    end

    def unused_require_paths
      Array(payload["unused_require_paths"])
    end

    def rails_version
      payload["rails_version"]
    end
  end
end
