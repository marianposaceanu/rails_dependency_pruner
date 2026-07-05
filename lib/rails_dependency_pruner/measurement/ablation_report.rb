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
        append_process_memory(lines)
        append_rails_memory_buckets(lines)
        append_object_buckets(lines)
        append_object_memory_buckets(lines)
        append_transform_sets(lines)
        lines << "RSS is process memory. PSS/USS appear on Linux when available. macOS physical footprint appears when `RAILS_DEPENDENCY_PRUNER_PROCESS_MEMORY_DETAILS=1` is set. Object memory appears when `--object-memory` is set. Rails feature buckets and Ruby object counts are attribution signals, not byte-exact ownership."
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
          lines << "| variant | status | assessment | transforms | events | unexpected | RSS median | RSS saved | saved | boot ms | first req ms | p95 req ms | warm p95 ms | Rails features | GC slots | T_STRING |"
          lines << "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
          payload.fetch("variants", {}).each do |variant, summary|
            delta = delta_for(variant)
            lines << [
              table_cell(variant),
              table_cell(summary.fetch("status")),
              table_cell(assessment_for(variant)),
              transform_ids_for(variant).length,
              value(summary["events_count"]),
              value(summary["unexpected_events_count"]),
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

        def append_process_memory(lines)
          rows = payload.fetch("variants", {}).filter_map do |variant, summary|
            memory = summary.fetch("process_memory_median", {})
            delta = delta_for(variant).fetch("process_memory", {})
            next if memory.empty?

            [
              table_cell(variant),
              kb(memory["rss_kb"]),
              saved_kb(delta["rss_kb"]),
              kb(memory["pss_kb"]),
              saved_kb(delta["pss_kb"]),
              kb(memory["uss_kb"]),
              saved_kb(delta["uss_kb"]),
              kb(memory["physical_footprint_kb"]),
              saved_kb(delta["physical_footprint_kb"]),
            ]
          end
          return if rows.empty?

          lines << "## Process Memory"
          lines << ""
          lines << "| variant | RSS | RSS saved | PSS | PSS saved | USS | USS saved | physical footprint | footprint saved |"
          lines << "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
          rows.each do |row|
            lines << "| #{row.join(" | ")} |"
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

        def append_object_memory_buckets(lines)
          rows = payload.fetch("deltas", {}).filter_map do |variant, delta|
            classes = delta.fetch("object_memsize_by_class", {})
            types = delta.fetch("object_memsize_by_type", {})
            next if classes.empty? && types.empty?

            [
              table_cell(variant),
              table_cell(top_memory_reductions(classes)),
              table_cell(top_memory_reductions(types)),
            ]
          end
          return if rows.empty?

          lines << "## Ruby Object Memory Buckets"
          lines << ""
          lines << "These are ObjectSpace memsize deltas by Ruby class and object type. Use them to spot which Ruby heap classes moved when a transform is active."
          lines << ""
          lines << "| variant | largest class reductions | largest type reductions |"
          lines << "| --- | --- | --- |"
          rows.each do |row|
            lines << "| #{row.join(" | ")} |"
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

        def assessment_for(variant)
          assessment = Array(payload.dig("memory_policy", "ablation_assessment")).find do |entry|
            entry["variant"] == variant
          end
          assessment&.fetch("classification", nil).to_s
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

        def top_memory_reductions(values)
          reductions = values.reject { |key, _value| %w[FREE TOTAL].include?(key) }
            .select { |_key, value| value.to_f.negative? }
            .sort_by { |_key, value| value.to_f }
            .first(5)
          return "`none`" if reductions.empty?

          reductions.map { |key, value| "`#{key}` #{signed_bytes(value)}" }.join(", ")
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

        def signed_bytes(number)
          return "" if number.nil?

          "`#{format("%+.1f", number.to_f / 1024.0)} KiB`"
        end
    end
  end
end
