# frozen_string_literal: true

require "json"
require "set"

module RailsDependencyPruner
  module EarlyBoot
    DEFAULT_PROFILE_PATH = "config/rails_dependency_pruner_profile.json"

    module_function

    def install!(
      profile_path: ENV["RAILS_DEPENDENCY_PRUNER_PROFILE"] || DEFAULT_PROFILE_PATH,
      output_path: ENV["RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT"],
      mode: ENV["RAILS_DEPENDENCY_PRUNER_MODE"],
      disabled: ENV["RAILS_DEPENDENCY_PRUNER_DISABLE"] == "1"
    )
      return false if disabled || @installed
      return false unless File.exist?(profile_path)

      payload = JSON.parse(File.read(profile_path))
      @mode = (mode || payload["mode"] || "shadow").to_s
      return false unless @mode == "shadow"

      @disabled_require_paths = disabled_require_paths(payload)
      @events = []
      @output_path = output_path
      Kernel.prepend(RequireShadow)
      at_exit { write! } if @output_path
      @installed = true
    end

    def shadow_require(path, caller_location)
      return unless disabled_require_path?(path)

      @events << {
        "path" => path.to_s,
        "caller_path" => caller_location&.path,
        "caller_line" => caller_location&.lineno,
        "caller_label" => caller_location&.label,
        "mode" => @mode,
        "action" => "would_block",
      }.compact
    end

    def disabled_require_path?(path)
      @disabled_require_paths&.include?(normalize(path))
    end

    def write!
      return unless @output_path

      File.write(
        @output_path,
        JSON.pretty_generate(
          "mode" => @mode,
          "events" => @events,
          "events_count" => @events.length,
        ),
      )
    end

    def disabled_require_paths(payload)
      paths = Array(payload.dig("pruning", "disabled_require_paths") || payload["unused_require_paths"])
      paths.flat_map do |path|
        normalized = normalize(path)
        [normalized, normalized.delete_suffix(".rb")]
      end.to_set
    end

    def normalize(path)
      path.to_s
    end

    module RequireShadow
      def require(path)
        RailsDependencyPruner::EarlyBoot.shadow_require(path, caller_locations(1, 1).first)
        super
      end
    end
  end
end

RailsDependencyPruner::EarlyBoot.install!
