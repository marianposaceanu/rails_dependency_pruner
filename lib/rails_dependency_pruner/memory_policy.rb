# frozen_string_literal: true

module RailsDependencyPruner
  class MemoryPolicy
    AGGREGATE_ABLATION_VARIANTS = %w[
      all_approved_transforms
      all_low_risk_transforms
      baseline
      process_warmup
    ].freeze
    LATENCY_GATES = [
      {
        "name" => "first_request",
        "metric_key" => "first_request_duration_ms_median",
        "max_ms_key" => "max_first_request_latency_regression_ms",
        "max_percent_key" => "max_first_request_latency_regression_percent",
      },
      {
        "name" => "request_p95",
        "metric_key" => "request_duration_ms_p95_median",
        "max_ms_key" => "max_request_p95_latency_regression_ms",
        "max_percent_key" => "max_request_p95_latency_regression_percent",
      },
      {
        "name" => "request_p99",
        "metric_key" => "request_duration_ms_p99_median",
        "max_ms_key" => "max_request_p99_latency_regression_ms",
        "max_percent_key" => "max_request_p99_latency_regression_percent",
      },
      {
        "name" => "warmed_p95",
        "metric_key" => "warmed_request_duration_ms_p95_median",
        "max_ms_key" => "max_warmed_p95_latency_regression_ms",
        "max_percent_key" => "max_warmed_p95_latency_regression_percent",
      },
      {
        "name" => "warmed_p99",
        "metric_key" => "warmed_request_duration_ms_p99_median",
        "max_ms_key" => "max_warmed_p99_latency_regression_ms",
        "max_percent_key" => "max_warmed_p99_latency_regression_percent",
      },
    ].freeze

    attr_reader :policy, :measurement

    def initialize(policy:, measurement:)
      @policy = deep_stringify(policy || {})
      @measurement = deep_stringify(measurement || {})
    end

    def evaluate
      return { "configured" => false, "passed" => true, "errors" => [], "warnings" => [] } if policy.empty?

      errors = []
      warnings = []
      summary = measurement_summary(errors)
      transform_savings = transform_savings_summary
      request_status = request_status_summary(errors, summary)
      unexpected_events = unexpected_event_summary(errors)

      check_total_savings(errors, summary)
      check_reference_profile(errors)
      check_reference_savings(errors, summary)
      check_ablation_variant_statuses(errors)
      check_transform_savings(errors, transform_savings)
      check_latency_regressions(errors, summary)

      result = {
        "configured" => true,
        "passed" => errors.empty?,
        "errors" => errors,
        "warnings" => warnings,
        "measurement" => summary,
        "transform_savings" => transform_savings,
      }
      result["request_status"] = request_status unless request_status.empty?
      result["unexpected_events"] = unexpected_events unless unexpected_events.empty?
      result
    end

    private
      def measurement_summary(errors)
        baseline_variant = policy["baseline_variant"] || "baseline"
        candidate_variant = policy["candidate_variant"] || default_candidate_variant
        baseline = variant_summary(baseline_variant)
        candidate = variant_summary(candidate_variant)

        unless baseline
          errors << "memory policy measurement missing baseline variant: #{baseline_variant}"
          return { "baseline_variant" => baseline_variant, "candidate_variant" => candidate_variant }
        end
        unless candidate
          errors << "memory policy measurement missing candidate variant: #{candidate_variant}"
          return { "baseline_variant" => baseline_variant, "candidate_variant" => candidate_variant }
        end
        unless baseline["status"] == "ok"
          errors << "memory policy baseline variant failed: #{baseline_variant}"
        end
        unless candidate["status"] == "ok"
          errors << "memory policy candidate variant failed: #{candidate_variant}"
        end

        baseline_rss_kb = number(baseline["rss_kb_median"])
        candidate_rss_kb = number(candidate["rss_kb_median"])
        if baseline_rss_kb.nil? || candidate_rss_kb.nil?
          errors << "memory policy measurement missing RSS medians"
          return { "baseline_variant" => baseline_variant, "candidate_variant" => candidate_variant }
        end

        saved_kb = baseline_rss_kb - candidate_rss_kb
        summary = {
          "baseline_variant" => baseline_variant,
          "candidate_variant" => candidate_variant,
          "baseline_rss_kb" => baseline_rss_kb,
          "candidate_rss_kb" => candidate_rss_kb,
          "saved_kb" => saved_kb,
          "saved_mib" => saved_kb / 1024.0,
          "saved_percent" => baseline_rss_kb.positive? ? (saved_kb.to_f / baseline_rss_kb) * 100 : 0.0,
        }
        latency = latency_summary(baseline, candidate)
        summary["latency"] = latency unless latency.empty?
        summary
      end

      def check_total_savings(errors, summary)
        return unless summary.key?("saved_kb")

        min_mib = number(policy["min_total_savings_mib"])
        if min_mib && summary.fetch("saved_mib") < min_mib
          errors << format("memory policy min_total_savings_mib not met: saved %.1f MiB, required %.1f MiB", summary.fetch("saved_mib"), min_mib)
        end

        min_percent = number(policy["min_total_savings_percent"])
        if min_percent && summary.fetch("saved_percent") < min_percent
          errors << format("memory policy min_total_savings_percent not met: saved %.1f%%, required %.1f%%", summary.fetch("saved_percent"), min_percent)
        end
      end

      def check_reference_profile(errors)
        expected = policy["reference_profile_id"].to_s
        return if expected.empty?

        actual = measurement.dig("source_profile", "profile_id") ||
          measurement.dig("profile", "profile_id")
        return if actual == expected

        errors << "memory policy reference_profile_id mismatch: expected #{expected}, got #{actual || "(missing)"}"
      end

      def check_reference_savings(errors, summary)
        percent = number(policy["preserve_at_least_percent_of_reference_savings"])
        return unless percent
        return unless summary.key?("saved_kb")

        reference_kb = reference_savings_kb
        unless reference_kb
          errors << "memory policy preserve_at_least_percent_of_reference_savings requires reference_savings_kb or reference_savings_mib"
          return
        end

        required_kb = reference_kb * (percent / 100.0)
        return if summary.fetch("saved_kb") >= required_kb

        errors << format(
          "memory policy reference savings not preserved: saved %.1f MiB, required %.1f MiB",
          summary.fetch("saved_kb") / 1024.0,
          required_kb / 1024.0,
        )
      end

      def check_transform_savings(errors, transform_savings)
        min_mib = number(policy["min_transform_savings_mib"])
        return unless min_mib

        unless measurement["ablation"] == true
          errors << "memory policy min_transform_savings_mib requires an ablation measurement"
          return
        end

        transform_savings.each do |entry|
          next if entry.fetch("saved_mib") >= min_mib

          errors << format(
            "memory policy min_transform_savings_mib not met for #{entry.fetch("variant")}: saved %.1f MiB, required %.1f MiB",
            entry.fetch("saved_mib"),
            min_mib,
          )
        end
      end

      def check_ablation_variant_statuses(errors)
        return unless measurement["ablation"] == true

        ablation_variants.each do |variant|
          name = variant.fetch("name")
          next if name == "baseline"
          next if Array(variant["transform_ids"]).empty?

          summary = variant_summary(name)
          if summary.nil?
            errors << "memory policy ablation variant missing: #{name}"
          elsif summary["status"] != "ok"
            errors << "memory policy ablation variant failed: #{name}"
          end
        end
      end

      def check_latency_regressions(errors, summary)
        LATENCY_GATES.each do |gate|
          max_ms = number(policy[gate.fetch("max_ms_key")])
          max_percent = number(policy[gate.fetch("max_percent_key")])
          next unless max_ms || max_percent

          metric = summary.dig("latency", gate.fetch("name"))
          unless metric && metric.key?("delta_ms")
            errors << "memory policy #{gate.fetch("name")} latency gate requires #{gate.fetch("metric_key")}"
            next
          end

          if max_ms && metric.fetch("delta_ms") > max_ms
            errors << format(
              "memory policy #{gate.fetch("max_ms_key")} not met: regression %.1f ms, allowed %.1f ms",
              metric.fetch("delta_ms"),
              max_ms,
            )
          end

          next unless max_percent

          delta_percent = metric["delta_percent"]
          unless delta_percent
            errors << "memory policy #{gate.fetch("max_percent_key")} requires positive baseline #{gate.fetch("metric_key")}"
            next
          end
          next if delta_percent <= max_percent

          errors << format(
            "memory policy #{gate.fetch("max_percent_key")} not met: regression %.1f%%, allowed %.1f%%",
            delta_percent,
            max_percent,
          )
        end
      end

      def request_status_summary(errors, measurement_summary)
        return {} unless request_target?

        baseline_variant = measurement_summary["baseline_variant"] || policy["baseline_variant"] || "baseline"
        candidate_variant = measurement_summary["candidate_variant"] || policy["candidate_variant"] || default_candidate_variant
        baseline = variant_summary(baseline_variant)
        return {} unless baseline

        baseline_matrix = baseline.fetch("request_status_matrix", {})
        if baseline_matrix.empty?
          errors << "memory policy request status matrix missing for baseline variant: #{baseline_variant}"
          return {
            "baseline_variant" => baseline_variant,
            "checked_variants" => checked_request_status_variants(candidate_variant),
            "passed" => false,
          }
        end

        checked_variants = checked_request_status_variants(candidate_variant)
        checked_variants.each do |variant|
          compare_request_statuses(errors, baseline_variant, baseline_matrix, variant)
        end

        {
          "baseline_variant" => baseline_variant,
          "checked_variants" => checked_variants,
          "paths" => request_status_paths(baseline_matrix),
          "passed" => errors.none? { |error| error.start_with?("memory policy request") },
        }
      end

      def compare_request_statuses(errors, baseline_variant, baseline_matrix, variant)
        summary = variant_summary(variant)
        if summary.nil?
          errors << "memory policy request status variant missing: #{variant}"
          return
        end

        matrix = summary.fetch("request_status_matrix", {})
        if matrix.empty?
          errors << "memory policy request status matrix missing for variant: #{variant}"
          return
        end

        request_status_paths(baseline_matrix).each do |path|
          baseline_entry = baseline_matrix.fetch(path, {})
          variant_entry = matrix.fetch(path, {})
          baseline_errors = Array(baseline_entry["errors"]).sort
          variant_errors = Array(variant_entry["errors"]).sort
          baseline_statuses = normalized_statuses(baseline_entry["statuses"])
          variant_statuses = normalized_statuses(variant_entry["statuses"])

          unless baseline_errors.empty?
            errors << "memory policy request status baseline #{baseline_variant} has errors for #{path}: #{baseline_errors.join(", ")}"
          end
          unless variant_errors.empty?
            errors << "memory policy request status variant #{variant} has errors for #{path}: #{variant_errors.join(", ")}"
          end
          if baseline_statuses.empty?
            errors << "memory policy request status baseline #{baseline_variant} missing statuses for #{path}"
          elsif variant_statuses.empty?
            errors << "memory policy request status variant #{variant} missing statuses for #{path}"
          elsif variant_statuses != baseline_statuses
            errors << "memory policy request status mismatch for #{variant} #{path}: expected #{baseline_statuses.join(", ")}, got #{variant_statuses.join(", ")}"
          end
        end
      end

      def checked_request_status_variants(candidate_variant)
        names = [candidate_variant.to_s]
        if measurement["ablation"] == true
          names.concat(
            ablation_variants.filter_map do |variant|
              name = variant["name"].to_s
              next if name.empty? || name == "baseline"
              next if Array(variant["transform_ids"]).empty?

              name
            end,
          )
        end
        names.reject(&:empty?).uniq
      end

      def request_status_paths(baseline_matrix)
        configured = Array(measurement["request_paths"]).map(&:to_s).reject(&:empty?)
        return configured unless configured.empty?

        baseline_matrix.keys.sort
      end

      def normalized_statuses(values)
        Array(values).map { |value| Integer(value) }.uniq.sort
      rescue ArgumentError, TypeError
        []
      end

      def request_target?
        measurement["target"] == "requests" || !Array(measurement["request_paths"]).empty?
      end

      def unexpected_event_summary(errors)
        reports = unexpected_event_reports
        return {} if reports.empty?

        reports.each do |report|
          errors << "memory policy measurement has unexpected runtime events in #{report.fetch("source")}: #{report.fetch("count")}"
        end

        {
          "passed" => false,
          "reports" => reports,
        }
      end

      def unexpected_event_reports
        reports = []
        add_unexpected_event_report(reports, "measurement", measurement)
        measurement.fetch("variants", {}).each do |variant, summary|
          add_unexpected_event_report(reports, "variant #{variant}", summary)
        end
        measurement.fetch("runs", {}).each do |variant, runs|
          Array(runs).each_with_index do |run, index|
            add_unexpected_event_report(reports, "run #{variant}[#{index}]", run)
          end
        end
        reports.uniq
      end

      def add_unexpected_event_report(reports, source, payload)
        count = unexpected_event_count(payload)
        return unless count.positive?

        reports << {
          "source" => source,
          "count" => count,
        }
      end

      def unexpected_event_count(payload)
        return 0 unless payload.is_a?(Hash)

        [
          number(payload["unexpected_events_count"]),
          number(payload.dig("runtime_event_summary", "unexpected_events_count")),
          number(payload.dig("counters", "pruner.event.unexpected")),
          Array(payload["unexpected_events"]).length,
        ].compact.map(&:to_i).max || 0
      end

      def transform_savings_summary
        baseline = variant_summary("baseline")
        baseline_rss_kb = number(baseline && baseline["rss_kb_median"])
        return [] unless baseline_rss_kb

        ablation_variants.each_with_object([]) do |variant, rows|
          name = variant.fetch("name")
          next if AGGREGATE_ABLATION_VARIANTS.include?(name)

          transform_ids = Array(variant["transform_ids"])
          next if transform_ids.empty?

          summary = variant_summary(name)
          next unless summary && summary["status"] == "ok"

          rss_kb = number(summary["rss_kb_median"])
          next unless rss_kb

          saved_kb = baseline_rss_kb - rss_kb
          rows << {
            "variant" => name,
            "transform_ids" => transform_ids,
            "rss_kb" => rss_kb,
            "saved_kb" => saved_kb,
            "saved_mib" => saved_kb / 1024.0,
          }
        end
      end

      def default_candidate_variant
        return "all_approved_transforms" if measurement["ablation"] == true

        %w[boot_prune production shadow].find { |name| measurement.fetch("variants", {}).key?(name) } || "boot_prune"
      end

      def variant_summary(name)
        measurement.fetch("variants", {})[name]
      end

      def ablation_variants
        Array(measurement["ablation_variants"]).select { |variant| variant.is_a?(Hash) }
      end

      def reference_savings_kb
        explicit_kb = number(policy["reference_savings_kb"] || policy["reference_total_savings_kb"])
        return explicit_kb if explicit_kb

        explicit_mib = number(policy["reference_savings_mib"] || policy["reference_total_savings_mib"])
        explicit_mib && explicit_mib * 1024.0
      end

      def latency_summary(baseline, candidate)
        LATENCY_GATES.each_with_object({}) do |gate, summary|
          baseline_ms = number(baseline[gate.fetch("metric_key")])
          candidate_ms = number(candidate[gate.fetch("metric_key")])
          next if baseline_ms.nil? && candidate_ms.nil?

          metric = {
            "baseline_ms" => baseline_ms,
            "candidate_ms" => candidate_ms,
          }.compact
          if baseline_ms && candidate_ms
            delta_ms = candidate_ms - baseline_ms
            metric["delta_ms"] = delta_ms
            metric["delta_percent"] = (delta_ms / baseline_ms) * 100.0 if baseline_ms.positive?
          end
          summary[gate.fetch("name")] = metric
        end
      end

      def number(value)
        return value if value.is_a?(Numeric)
        return if value.nil? || value.to_s.empty?

        Float(value)
      rescue ArgumentError, TypeError
        nil
      end

      def deep_stringify(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested), hash|
            hash[key.to_s] = deep_stringify(nested)
          end
        when Array
          value.map { |nested| deep_stringify(nested) }
        else
          value
        end
      end
  end
end
