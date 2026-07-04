# frozen_string_literal: true

module RailsDependencyPruner
  module Measurement
    class Report
      attr_reader :payload

      def initialize(payload)
        @payload = payload
      end

      def to_markdown
        lines = [
          "# Rails Dependency Pruner Measurement",
          "",
        ]

        append_target(lines)
        append_profile(lines)
        append_variants(lines)
        append_framework_features(lines)
        append_deltas(lines)
        append_framework_deltas(lines)
        lines << "RSS is reported from the measured process. Compare it with loaded-feature and GC-slot deltas before claiming a memory win."
        lines << ""
        lines.join("\n")
      end

      private
        def append_target(lines)
          target = payload["target"]
          return unless target

          lines << "- Target: `#{target}`"
          skip_railties = Array(payload["skip_railties"])
          lines << "- Skip railties: #{list(skip_railties)}" unless skip_railties.empty?
          request_paths = Array(payload["request_paths"])
          lines << "- Request paths: #{list(request_paths)}" unless request_paths.empty?
          lines << ""
        end

        def append_profile(lines)
          profile = payload["profile"]
          return unless profile

          lines << "## Profile"
          lines << ""
          lines << "- Path: `#{profile.fetch("path")}`"
          lines << "- Profile id: `#{profile.fetch("profile_id") || "(none)"}`"
          lines << "- Mode: `#{profile["mode"] || "(none)"}`"
          lines << "- Disabled frameworks: #{list(profile.fetch("disabled_frameworks", []))}"
          lines << "- Disabled railties: #{list(profile.fetch("disabled_railties", []))}"
          lines << "- Disabled require paths: `#{profile.fetch("disabled_require_paths_count", 0)}`"
          lines << "- Disabled constants: `#{profile.fetch("disabled_constants_count", 0)}`"
          append_extreme_boot(lines, profile["extreme_boot"])
          lines << ""
        end

        def append_extreme_boot(lines, extreme_boot)
          return if extreme_boot.nil? || extreme_boot.empty?

          lines << "- Disable eager load: `#{extreme_boot["disable_eager_load"] == true}`"
          lines << "- Skip railties: #{list(extreme_boot["skip_railties"])}"
          lines << "- Lazy require paths: #{list(extreme_boot["lazy_require_paths"])}"
          lines << "- Lazy gems: #{list(extreme_boot["lazy_gems"])}"
          lines << "- Config namespace stubs: #{list(extreme_boot["config_namespace_stubs"])}"
        end

        def append_variants(lines)
          lines << "## Variants"
          lines << ""
          lines << "| variant | status | runs | RSS median | RSS min | RSS max | loaded features | Rails features | GC live slots |"
          lines << "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
          payload.fetch("variants", {}).each do |variant, summary|
            lines << [
              table_cell(variant),
              table_cell(summary.fetch("status")),
              summary.fetch("successful_runs", 0),
              kb(summary["rss_kb_median"]),
              kb(summary["rss_kb_min"]),
              kb(summary["rss_kb_max"]),
              value(summary["loaded_features_median"]),
              value(summary["rails_loaded_features_median"]),
              value(summary["gc_heap_live_slots_median"]),
            ].join(" | ").then { |row| "| #{row} |" }
          end
          lines << ""
        end

        def append_framework_features(lines)
          frameworks = payload.fetch("variants", {}).values.flat_map do |summary|
            summary.fetch("rails_loaded_features_by_framework_median", {}).keys
          end.uniq.sort
          return if frameworks.empty?

          lines << "## Rails Features By Framework"
          lines << ""
          lines << "| variant | #{frameworks.join(" | ")} |"
          lines << "| --- | #{frameworks.map { "---:" }.join(" | ")} |"
          payload.fetch("variants", {}).each do |variant, summary|
            counts = summary.fetch("rails_loaded_features_by_framework_median", {})
            row = [table_cell(variant)] + frameworks.map { |framework| value(counts[framework]) }
            lines << "| #{row.join(" | ")} |"
          end
          lines << ""
        end

        def append_deltas(lines)
          deltas = payload.fetch("deltas", {})
          return if deltas.empty?

          lines << "## Deltas Vs Baseline"
          lines << ""
          lines << "| variant | RSS | loaded features | Rails features | GC live slots |"
          lines << "| --- | ---: | ---: | ---: | ---: |"
          deltas.each do |variant, delta|
            lines << [
              table_cell(variant),
              signed_kb(delta["rss_kb"]),
              signed(delta["loaded_features"]),
              signed(delta["rails_loaded_features"]),
              signed(delta["gc_heap_live_slots"]),
            ].join(" | ").then { |row| "| #{row} |" }
          end
          lines << ""
        end

        def append_framework_deltas(lines)
          deltas = payload.fetch("deltas", {})
          frameworks = deltas.values.flat_map do |delta|
            delta.fetch("rails_loaded_features_by_framework", {}).keys
          end.uniq.sort
          return if frameworks.empty?

          lines << "## Rails Feature Deltas By Framework"
          lines << ""
          lines << "| variant | #{frameworks.join(" | ")} |"
          lines << "| --- | #{frameworks.map { "---:" }.join(" | ")} |"
          deltas.each do |variant, delta|
            counts = delta.fetch("rails_loaded_features_by_framework", {})
            row = [table_cell(variant)] + frameworks.map { |framework| signed(counts[framework]) }
            lines << "| #{row.join(" | ")} |"
          end
          lines << ""
        end

        def list(values)
          values = Array(values)
          return "`none`" if values.empty?

          values.map { |value| "`#{value}`" }.join(", ")
        end

        def table_cell(value)
          value.to_s.gsub("|", "\\|")
        end

        def value(number)
          return "" if number.nil?

          number.to_s
        end

        def kb(number)
          return "" if number.nil?

          "`#{number} KB`"
        end

        def signed(number)
          return "" if number.nil?

          number.positive? ? "+#{number}" : number.to_s
        end

        def signed_kb(number)
          return "" if number.nil?

          "`#{signed(number)} KB`"
        end
    end
  end
end
