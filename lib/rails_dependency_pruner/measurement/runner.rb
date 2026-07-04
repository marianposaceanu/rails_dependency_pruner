# frozen_string_literal: true

require "json"
require "open3"

module RailsDependencyPruner
  module Measurement
    class Runner
      BOOT_SCRIPT = <<~'RUBY'
        require "json"
        require "rails_dependency_pruner/measurement/memory_probe"

        app_root = ARGV.fetch(0)
        require File.join(app_root, "config/application")
        GC.start
        puts JSON.generate(RailsDependencyPruner::Measurement::MemoryProbe.snapshot)
      RUBY

      attr_reader :app_root, :variants, :runs

      def initialize(app_root:, variants:, runs:)
        @app_root = app_root
        @variants = variants
        @runs = runs
      end

      def run
        results = variants.to_h do |variant|
          [variant, run_variant(variant)]
        end

        {
          "variants" => summarize_variants(results),
          "runs" => results,
          "deltas" => deltas(results),
        }
      end

      private
        def run_variant(variant)
          runs.times.map do
            run_once(variant)
          end
        end

        def run_once(variant)
          env = {
            "RAILS_DEPENDENCY_PRUNER_MEASURE_VARIANT" => variant,
            "RUBYLIB" => ruby_lib,
          }
          command = ruby_command + ["-e", BOOT_SCRIPT, app_root]
          stdout, stderr, status = Open3.capture3(env, *command, chdir: app_root)

          if status.success?
            parse_successful_run(stdout, stderr)
          else
            {
              "status" => "error",
              "exitstatus" => status.exitstatus,
              "stdout" => stdout,
              "stderr" => stderr,
            }
          end
        end

        def parse_successful_run(stdout, stderr)
          payload = JSON.parse(stdout)
          required_keys = %w[rss_kb loaded_features rails_loaded_features gc_heap_live_slots]
          missing_keys = required_keys.reject { |key| payload.key?(key) }
          unless missing_keys.empty?
            return {
              "status" => "error",
              "stdout" => stdout,
              "stderr" => "measurement payload missing #{missing_keys.join(", ")}\n#{stderr}",
            }
          end

          payload.merge(
            "status" => "ok",
            "stderr" => stderr,
          )
        rescue JSON::ParserError => error
          {
            "status" => "error",
            "stdout" => stdout,
            "stderr" => "#{error.message}\n#{stderr}",
          }
        end

        def ruby_command
          File.exist?(File.join(app_root, "Gemfile")) ? ["bundle", "exec", "ruby"] : [Gem.ruby]
        end

        def ruby_lib
          File.expand_path("../..", __dir__)
        end

        def summarize_variants(results)
          results.to_h do |variant, runs|
            successful = runs.select { |run| run["status"] == "ok" }
            [variant, summarize(successful)]
          end
        end

        def summarize(runs)
          runs = runs.select { |run| run["status"] == "ok" }
          return { "status" => "error", "successful_runs" => 0 } if runs.empty?

          {
            "status" => "ok",
            "successful_runs" => runs.length,
            "rss_kb_median" => median(runs.map { |run| run.fetch("rss_kb") }),
            "rss_kb_min" => runs.map { |run| run.fetch("rss_kb") }.min,
            "rss_kb_max" => runs.map { |run| run.fetch("rss_kb") }.max,
            "loaded_features_median" => median(runs.map { |run| run.fetch("loaded_features") }),
            "rails_loaded_features_median" => median(runs.map { |run| run.fetch("rails_loaded_features") }),
            "gc_heap_live_slots_median" => median(runs.map { |run| run.fetch("gc_heap_live_slots") }),
          }
        end

        def deltas(results)
          baseline = summarize(results.fetch("baseline", []))
          return {} unless baseline["status"] == "ok"

          results.reject { |variant, _runs| variant == "baseline" }.to_h do |variant, runs|
            summary = summarize(runs)
            next [variant, { "status" => "error" }] unless summary["status"] == "ok"

            [variant, {
              "rss_kb" => summary.fetch("rss_kb_median") - baseline.fetch("rss_kb_median"),
              "loaded_features" => summary.fetch("loaded_features_median") - baseline.fetch("loaded_features_median"),
              "rails_loaded_features" => summary.fetch("rails_loaded_features_median") - baseline.fetch("rails_loaded_features_median"),
              "gc_heap_live_slots" => summary.fetch("gc_heap_live_slots_median") - baseline.fetch("gc_heap_live_slots_median"),
            }]
          end.compact.to_h
        end

        def median(values)
          sorted = values.sort
          midpoint = sorted.length / 2
          return sorted.fetch(midpoint) if sorted.length.odd?

          (sorted.fetch(midpoint - 1) + sorted.fetch(midpoint)) / 2.0
        end
    end
  end
end
