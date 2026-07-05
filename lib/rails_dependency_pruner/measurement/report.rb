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
        append_coverage(lines)
        append_profile(lines)
        append_variants(lines)
        append_process_memory(lines)
        append_request_status_matrix(lines)
        append_framework_features(lines)
        append_deltas(lines)
        append_process_memory_deltas(lines)
        append_framework_deltas(lines)
        append_object_deltas(lines)
        append_object_memory(lines)
        append_object_memory_deltas(lines)
        lines << "RSS is reported from the measured process. PSS/USS appear on Linux when `/proc/self/smaps_rollup` is available. macOS physical footprint appears when `RAILS_DEPENDENCY_PRUNER_PROCESS_MEMORY_DETAILS=1` is set. Object memory appears when `--object-memory` is set. Request timings are in-process Rack mock timings. Compare process memory with loaded-feature and GC-slot deltas before claiming a memory win."
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

        def append_coverage(lines)
          coverage = payload["coverage"]
          return unless coverage

          lines << "- Coverage: `#{coverage.fetch("path")}`"
          lines << "- Coverage digest: `#{coverage.fetch("digest")}`" if coverage["digest"]
          lines << "- Coverage Rails env: `#{coverage.fetch("rails_env")}`" if coverage["rails_env"]
          workloads = Array(coverage["workloads"])
          lines << "- Coverage workloads: #{list(workloads)}" unless workloads.empty?
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
          lines << "| variant | status | runs | events | unexpected | RSS median | RSS min | RSS max | boot ms | first req ms | p95 req ms | warm p95 ms | loaded features | Rails features | GC live slots |"
          lines << "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
          payload.fetch("variants", {}).each do |variant, summary|
            lines << [
              table_cell(variant),
              table_cell(summary.fetch("status")),
              summary.fetch("successful_runs", 0),
              value(summary["events_count"]),
              value(summary["unexpected_events_count"]),
              kb(summary["rss_kb_median"]),
              kb(summary["rss_kb_min"]),
              kb(summary["rss_kb_max"]),
              ms(summary["boot_time_ms_median"]),
              ms(summary["first_request_duration_ms_median"]),
              ms(summary["request_duration_ms_p95_median"]),
              ms(summary["warmed_request_duration_ms_p95_median"]),
              value(summary["loaded_features_median"]),
              value(summary["rails_loaded_features_median"]),
              value(summary["gc_heap_live_slots_median"]),
            ].join(" | ").then { |row| "| #{row} |" }
          end
          lines << ""
        end

        def append_process_memory(lines)
          rows = payload.fetch("variants", {}).filter_map do |variant, summary|
            memory = summary.fetch("process_memory_median", {})
            next if memory.empty?

            [
              table_cell(variant),
              kb(memory["rss_kb"]),
              kb(memory["pss_kb"]),
              kb(memory["uss_kb"]),
              kb(memory["physical_footprint_kb"]),
            ]
          end
          return if rows.empty?

          lines << "## Process Memory"
          lines << ""
          lines << "| variant | RSS | PSS | USS | physical footprint |"
          lines << "| --- | ---: | ---: | ---: | ---: |"
          rows.each do |row|
            lines << "| #{row.join(" | ")} |"
          end
          lines << ""
        end

        def append_request_status_matrix(lines)
          rows = payload.fetch("variants", {}).flat_map do |variant, summary|
            summary.fetch("request_status_matrix", {}).map do |path, result|
              [
                variant,
                path,
                Array(result["statuses"]).join(", "),
                Array(result["errors"]).join(", "),
              ]
            end
          end
          return if rows.empty?

          lines << "## Request Status Matrix"
          lines << ""
          lines << "| variant | path | statuses | errors |"
          lines << "| --- | --- | --- | --- |"
          rows.each do |variant, path, statuses, errors|
            lines << [
              table_cell(variant),
              table_cell(path),
              table_cell(statuses.empty? ? "none" : statuses),
              table_cell(errors.empty? ? "none" : errors),
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
          lines << "| variant | RSS | boot ms | first req ms | p95 req ms | warm p95 ms | loaded features | Rails features | GC live slots |"
          lines << "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
          deltas.each do |variant, delta|
            lines << [
              table_cell(variant),
              signed_kb(delta["rss_kb"]),
              signed_ms(delta["boot_time_ms"]),
              signed_ms(delta["first_request_duration_ms"]),
              signed_ms(delta["request_duration_ms_p95"]),
              signed_ms(delta["warmed_request_duration_ms_p95"]),
              signed(delta["loaded_features"]),
              signed(delta["rails_loaded_features"]),
              signed(delta["gc_heap_live_slots"]),
            ].join(" | ").then { |row| "| #{row} |" }
          end
          lines << ""
        end

        def append_process_memory_deltas(lines)
          rows = payload.fetch("deltas", {}).filter_map do |variant, delta|
            memory = delta.fetch("process_memory", {})
            next if memory.empty?

            [
              table_cell(variant),
              signed_kb(memory["rss_kb"]),
              signed_kb(memory["pss_kb"]),
              signed_kb(memory["uss_kb"]),
              signed_kb(memory["physical_footprint_kb"]),
            ]
          end
          return if rows.empty?

          lines << "## Process Memory Deltas"
          lines << ""
          lines << "| variant | RSS | PSS | USS | physical footprint |"
          lines << "| --- | ---: | ---: | ---: | ---: |"
          rows.each do |row|
            lines << "| #{row.join(" | ")} |"
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

        def append_object_deltas(lines)
          deltas = payload.fetch("deltas", {})
          object_types = deltas.values.flat_map do |delta|
            delta.fetch("object_counts", {}).keys
          end.uniq.sort
          return if object_types.empty?

          selected = %w[T_STRING T_ARRAY T_HASH T_OBJECT T_DATA].select { |type| object_types.include?(type) }
          selected = object_types.first(8) if selected.empty?

          lines << "## Ruby Object Deltas"
          lines << ""
          lines << "| variant | #{selected.join(" | ")} |"
          lines << "| --- | #{selected.map { "---:" }.join(" | ")} |"
          deltas.each do |variant, delta|
            counts = delta.fetch("object_counts", {})
            row = [table_cell(variant)] + selected.map { |type| signed(counts[type]) }
            lines << "| #{row.join(" | ")} |"
          end
          lines << ""
        end

        def append_object_memory(lines)
          rows = payload.fetch("variants", {}).filter_map do |variant, summary|
            classes = summary.fetch("object_memsize_by_class_median", {})
            types = summary.fetch("object_memsize_by_type_median", {})
            next if classes.empty? && types.empty?

            [
              table_cell(variant),
              table_cell(top_memory_classes(classes)),
              table_cell(top_memory_classes(types)),
            ]
          end
          return if rows.empty?

          lines << "## Ruby Object Memory"
          lines << ""
          lines << "| variant | largest classes | largest types |"
          lines << "| --- | --- | --- |"
          rows.each do |row|
            lines << "| #{row.join(" | ")} |"
          end
          lines << ""
        end

        def append_object_memory_deltas(lines)
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

          lines << "## Ruby Object Memory Deltas"
          lines << ""
          lines << "| variant | largest class reductions | largest type reductions |"
          lines << "| --- | --- | --- |"
          rows.each do |row|
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

        def ms(number)
          return "" if number.nil?

          "`#{format("%.1f", number)} ms`"
        end

        def signed(number)
          return "" if number.nil?

          number.positive? ? "+#{number}" : number.to_s
        end

        def signed_kb(number)
          return "" if number.nil?

          "`#{signed(number)} KB`"
        end

        def top_memory_classes(values)
          top = values.reject { |key, _value| %w[FREE TOTAL].include?(key) }
            .sort_by { |_key, value| -value.to_f }
            .first(5)
          return "`none`" if top.empty?

          top.map { |key, value| "`#{key}` #{bytes(value)}" }.join(", ")
        end

        def top_memory_reductions(values)
          top = values.reject { |key, _value| %w[FREE TOTAL].include?(key) }
            .select { |_key, value| value.to_f.negative? }
            .sort_by { |_key, value| value.to_f }
            .first(5)
          return "`none`" if top.empty?

          top.map { |key, value| "`#{key}` #{signed_bytes(value)}" }.join(", ")
        end

        def bytes(number)
          return "" if number.nil?

          "`#{format("%.1f", number.to_f / 1024.0)} KiB`"
        end

        def signed_bytes(number)
          return "" if number.nil?

          "`#{format("%+.1f", number.to_f / 1024.0)} KiB`"
        end

        def signed_ms(number)
          return "" if number.nil?

          "`#{signed_float(number)} ms`"
        end

        def signed_float(number)
          formatted = format("%.1f", number)
          number.positive? ? "+#{formatted}" : formatted
        end
    end
  end
end
