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

      check_total_savings(errors, summary)
      check_reference_profile(errors)
      check_reference_savings(errors, summary)
      check_transform_savings(errors, transform_savings)
      check_latency_regressions(errors, summary)

      {
        "configured" => true,
        "passed" => errors.empty?,
        "errors" => errors,
        "warnings" => warnings,
        "measurement" => summary,
        "transform_savings" => transform_savings,
      }
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
