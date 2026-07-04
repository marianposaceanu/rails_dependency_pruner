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

        append_profile(lines)
        append_variants(lines)
        append_deltas(lines)
        lines << "RSS is reported from the measured process. Compare it with loaded-feature and GC-slot deltas before claiming a memory win."
        lines << ""
        lines.join("\n")
      end

      private
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
          lines << ""
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
