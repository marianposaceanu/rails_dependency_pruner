# frozen_string_literal: true

module RailsDependencyPruner
  module Measurement
    class AblationReport
      attr_reader :payload

      def initialize(payload)
        @payload = payload
      end

      def to_markdown
        lines = [
          "# Rails Dependency Pruner Ablation",
          "",
        ]

        append_context(lines)
        append_summary(lines)
        append_rails_memory_buckets(lines)
        append_object_buckets(lines)
        append_transform_sets(lines)
        lines << "RSS is process memory. Rails feature buckets and Ruby object counts are attribution signals, not byte-exact ownership."
        lines << ""
        lines.join("\n")
      end

      private
        def append_context(lines)
          source_profile = payload.fetch("source_profile", {})
          lines << "- Target: `#{payload.fetch("target")}`"
          lines << "- Source profile: `#{source_profile["profile_id"] || "(none)"}`"
          lines << "- Profile path: `#{source_profile["path"]}`" if source_profile["path"]
          lines << "- Coverage: `#{payload["coverage_path"]}`" if payload["coverage_path"]
          request_paths = Array(payload["request_paths"])
          lines << "- Request paths: #{list(request_paths)}" unless request_paths.empty?
          lines << ""
        end

        def append_summary(lines)
          lines << "## Summary"
          lines << ""
          lines << "| variant | status | transforms | RSS median | RSS saved | saved | boot ms | first req ms | p95 req ms | warm p95 ms | Rails features | GC slots | T_STRING |"
          lines << "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
          payload.fetch("variants", {}).each do |variant, summary|
            delta = delta_for(variant)
            lines << [
              table_cell(variant),
              table_cell(summary.fetch("status")),
              transform_ids_for(variant).length,
              kb(summary["rss_kb_median"]),
              saved_kb(delta["rss_kb"]),
              saved_percent(delta["rss_kb"]),
              ms(summary["boot_time_ms_median"]),
              ms(summary["first_request_duration_ms_median"]),
              ms(summary["request_duration_ms_p95_median"]),
              ms(summary["warmed_request_duration_ms_p95_median"]),
              signed(delta["rails_loaded_features"]),
              signed(delta["gc_heap_live_slots"]),
              signed(delta.dig("object_counts", "T_STRING")),
            ].join(" | ").then { |row| "| #{row} |" }
          end
          lines << ""
        end

        def append_rails_memory_buckets(lines)
          deltas = payload.fetch("deltas", {})
          return if deltas.empty?

          lines << "## Rails Memory Buckets"
          lines << ""
          lines << "Loaded Rails files are grouped by framework gem. This shows which framework buckets shrink when a variant is active."
          lines << ""
          lines << "| variant | largest Rails feature reductions |"
          lines << "| --- | --- |"
          deltas.each do |variant, delta|
            reductions = top_reductions(delta.fetch("rails_loaded_features_by_framework", {}))
            lines << "| #{table_cell(variant)} | #{table_cell(reductions)} |"
          end
          lines << ""
        end

        def append_object_buckets(lines)
          deltas = payload.fetch("deltas", {})
          return if deltas.empty?

          lines << "## Ruby Object Buckets"
          lines << ""
          lines << "These are live Ruby heap object type deltas after a GC, useful for spotting whether a win mostly came from strings, arrays, hashes, or ordinary objects."
          lines << ""
          lines << "| variant | largest object reductions |"
          lines << "| --- | --- |"
          deltas.each do |variant, delta|
            reductions = top_object_reductions(delta.fetch("object_counts", {}))
            lines << "| #{table_cell(variant)} | #{table_cell(reductions)} |"
          end
          lines << ""
        end

        def append_transform_sets(lines)
          variants = Array(payload["ablation_variants"])
          return if variants.empty?

          lines << "## Transform Sets"
          lines << ""
          lines << "| variant | what it tests | transforms |"
          lines << "| --- | --- | --- |"
          variants.each do |variant|
            lines << [
              table_cell(variant.fetch("name")),
              table_cell(variant.fetch("description")),
              table_cell(list(variant.fetch("transform_ids", []))),
            ].join(" | ").then { |row| "| #{row} |" }
          end
          lines << ""
        end

        def delta_for(variant)
          return {} if variant == "baseline"

          payload.fetch("deltas", {}).fetch(variant, {})
        end

        def transform_ids_for(variant)
          definition = Array(payload["ablation_variants"]).find { |entry| entry["name"] == variant }
          Array(definition&.fetch("transform_ids", []))
        end

        def top_reductions(values)
          reductions = values.select { |_key, value| value.to_f.negative? }
            .sort_by { |_key, value| value }
            .first(5)
          return "`none`" if reductions.empty?

          reductions.map { |key, value| "`#{key}` #{signed(value)}" }.join(", ")
        end

        def top_object_reductions(values)
          top_reductions(values.reject { |key, _value| %w[FREE TOTAL].include?(key) })
        end

        def list(values)
          values = Array(values)
          return "`none`" if values.empty?

          values.map { |value| "`#{value}`" }.join(", ")
        end

        def table_cell(value)
          value.to_s.gsub("|", "\\|")
        end

        def kb(number)
          return "" if number.nil?

          "`#{number} KB`"
        end

        def saved_kb(delta)
          return "" if delta.nil?

          "`#{-delta} KB`"
        end

        def saved_percent(delta)
          baseline = payload.dig("variants", "baseline", "rss_kb_median")
          return "" if delta.nil? || baseline.nil? || baseline.zero?

          format("`%.1f%%`", (-delta.to_f / baseline) * 100)
        end

        def ms(number)
          return "" if number.nil?

          "`#{format("%.1f", number)} ms`"
        end

        def signed(number)
          return "" if number.nil?

          number.positive? ? "+#{number}" : number.to_s
        end
    end
  end
end
