# frozen_string_literal: true

require "json"
require "set"

module RailsDependencyPruner
  module EarlyBoot
    DEFAULT_PROFILE_PATH = "config/rails_dependency_pruner_profile.json"
    DisabledRequireError = Class.new(StandardError)
    UnsafeProfileError = Class.new(StandardError)

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
      return false unless %w[shadow boot_prune production].include?(@mode)
      validate_profile_safety!(payload)

      @disabled_require_paths = disabled_require_paths(payload)
      @events = []
      @output_path = output_path
      Kernel.prepend(RequireShadow)
      at_exit { write! } if @output_path
      @installed = true
    end

    def shadow_require(path, caller_location)
      return unless disabled_require_path?(path)

      event = {
        "path" => path.to_s,
        "caller_path" => caller_location&.path,
        "caller_line" => caller_location&.lineno,
        "caller_label" => caller_location&.label,
        "mode" => @mode,
        "action" => blocking? ? "blocked" : "would_block",
      }.compact
      @events << event

      raise DisabledRequireError, "#{path} is disabled by rails_dependency_pruner early boot" if blocking?
    end

    def disabled_require_path?(path)
      @disabled_require_paths&.include?(normalize(path))
    end

    def blocking?
      %w[boot_prune production].include?(@mode)
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

    def validate_profile_safety!(payload)
      return unless @mode == "production"
      return if payload.dig("safety", "production_allowed") == true

      raise UnsafeProfileError, "rails_dependency_pruner production mode requires safety.production_allowed=true"
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
