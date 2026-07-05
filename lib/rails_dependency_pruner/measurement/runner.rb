# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

require_relative "../profile"

module RailsDependencyPruner
  module Measurement
    class Runner
      BOOT_SCRIPT = <<~'RUBY'
        require "json"
        boot_modes = %w[shadow boot_prune canary production]
        if boot_modes.include?(ENV["RAILS_DEPENDENCY_PRUNER_MODE"]) ||
            boot_modes.include?(ENV["RAILS_DEPENDENCY_PRUNER_MEASURE_VARIANT"])
          require "rails_dependency_pruner/early_boot"
        end
        require "rails_dependency_pruner/measurement/memory_probe"

        CONFIG_NAMESPACES = {
          "action_mailbox/engine" => "action_mailbox",
          "action_mailer/railtie" => "action_mailer",
          "active_job/railtie" => "active_job",
          "active_storage/engine" => "active_storage",
        }.freeze

        def measure_variant
          ENV["RAILS_DEPENDENCY_PRUNER_MEASURE_VARIANT"].to_s
        end

        def measure_target
          ENV["RAILS_DEPENDENCY_PRUNER_MEASURE_TARGET"].to_s
        end

        def request_paths
          JSON.parse(ENV.fetch("RAILS_DEPENDENCY_PRUNER_MEASURE_REQUEST_PATHS", "[]"))
        end

        def monotonic_ms
          Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
        end

        def round_ms(value)
          value&.round(3)
        end

        def percentile(values, percentile)
          return nil if values.empty?

          sorted = values.sort
          rank = (percentile / 100.0) * (sorted.length - 1)
          lower = sorted.fetch(rank.floor)
          upper = sorted.fetch(rank.ceil)
          round_ms(lower + ((upper - lower) * (rank - rank.floor)))
        end

        def no_eager_load_variant?
          %w[no_eager_load no_eager_load_skip_railties].include?(measure_variant)
        end

        def skip_railties_variant?
          %w[skip_railties no_eager_load_skip_railties].include?(measure_variant)
        end

        def skipped_railties
          return [] unless skip_railties_variant?

          ENV.fetch("RAILS_DEPENDENCY_PRUNER_MEASURE_SKIP_RAILTIES", "")
            .split(",")
            .map(&:strip)
            .reject(&:empty?)
        end

        def install_skip_require!(paths)
          return if paths.empty?

          blocked = paths
          Kernel.module_eval do
            unless private_method_defined?(:rails_dependency_pruner_measure_original_require)
              alias_method :rails_dependency_pruner_measure_original_require, :require

              define_method(:require) do |path|
                return false if blocked.include?(path.to_s)

                rails_dependency_pruner_measure_original_require(path)
              end

              private :require
            end
          end
        end

        def install_config_namespace_stubs!(paths)
          namespaces = paths.filter_map { |path| CONFIG_NAMESPACES[path] }.uniq
          return if namespaces.empty?

          require "rails"
          require "active_support/ordered_options"
          unless defined?(RailsDependencyPrunerMeasureOptions)
            Object.const_set(:RailsDependencyPrunerMeasureOptions, Class.new(ActiveSupport::OrderedOptions) do
              def method_missing(name, *args)
                return super if name.to_s.end_with?("=")

                self[name] ||= self.class.new
              end
            end)
          end
          [Rails::Application::Configuration, Rails::Engine::Configuration].each do |klass|
            namespaces.each do |namespace|
              next if klass.method_defined?(namespace)

              klass.define_method(namespace) do
                @rails_dependency_pruner_measure_config_namespaces ||= {}
                @rails_dependency_pruner_measure_config_namespaces[namespace] ||= RailsDependencyPrunerMeasureOptions.new
              end
            end
          end
        end

        app_root = ARGV.fetch(0)
        skipped = skipped_railties
        install_skip_require!(skipped)
        install_config_namespace_stubs!(skipped)

        boot_started_ms = monotonic_ms
        if measure_target == "application"
          require File.join(app_root, "config/application")
        else
          require File.join(app_root, "config/application")
          if no_eager_load_variant?
            Rails.application.initializer("rails_dependency_pruner.measure.no_eager_load", before: :eager_load!) do |application|
              application.config.eager_load = false
            end
          end
          Rails.application.initialize!
        end
        boot_finished_ms = monotonic_ms

        if measure_target == "requests"
          require "rack/mock"
          request = Rack::MockRequest.new(Rails.application)
          requests = request_paths.map do |path|
            request_started_ms = monotonic_ms
            response = request.get(path, "HTTP_HOST" => "example.org", "HTTPS" => "on")
            duration_ms = monotonic_ms - request_started_ms
            {
              "path" => path,
              "status" => response.status,
              "bytes" => response.body.bytesize,
              "location" => response["Location"],
              "duration_ms" => round_ms(duration_ms),
            }.compact
          rescue => error
            duration_ms = monotonic_ms - request_started_ms if request_started_ms
            {
              "path" => path,
              "error" => error.class.name,
              "message" => error.message,
              "duration_ms" => round_ms(duration_ms),
            }
          end
        end

        Process.warmup if measure_variant == "process_warmup" && Process.respond_to?(:warmup)

        GC.start
        snapshot = RailsDependencyPruner::Measurement::MemoryProbe.snapshot
        snapshot["boot_time_ms"] = round_ms(boot_finished_ms - boot_started_ms)
        if measure_target == "requests"
          request_durations = requests.filter_map { |entry| entry["duration_ms"] }
          warmed_request_durations = request_durations.drop(1)
          snapshot["requests"] = requests
          snapshot["first_request_duration_ms"] = request_durations.first
          snapshot["request_duration_ms_p50"] = percentile(request_durations, 50)
          snapshot["request_duration_ms_p95"] = percentile(request_durations, 95)
          snapshot["request_duration_ms_p99"] = percentile(request_durations, 99)
          snapshot["warmed_request_duration_ms_p50"] = percentile(warmed_request_durations, 50)
          snapshot["warmed_request_duration_ms_p95"] = percentile(warmed_request_durations, 95)
          snapshot["warmed_request_duration_ms_p99"] = percentile(warmed_request_durations, 99)
        end
        puts JSON.generate(snapshot)
      RUBY

      TARGETS = %w[application environment requests].freeze

      attr_reader :app_root, :variants, :runs, :profile_path, :target, :skip_railties, :request_paths,
        :variant_profile_paths, :process_memory_details, :object_memory

      def initialize(app_root:, variants:, runs:, profile_path: nil, target: "application", skip_railties: [], request_paths: [], variant_profile_paths: {}, process_memory_details: false, object_memory: false)
        @app_root = File.expand_path(app_root)
        @variants = variants
        @runs = runs
        @profile_path = profile_path && File.expand_path(profile_path)
        @target = target
        @skip_railties = Array(skip_railties)
        @request_paths = Array(request_paths)
        @variant_profile_paths = variant_profile_paths.to_h.transform_keys(&:to_s).transform_values do |path|
          File.expand_path(path)
        end
        @process_memory_details = process_memory_details == true
        @object_memory = object_memory == true
      end

      def run
        results = variants.to_h do |variant|
          [variant, run_variant(variant)]
        end

        report = {
          "target" => target,
          "skip_railties" => skip_railties,
          "variants" => summarize_variants(results),
          "runs" => results,
          "deltas" => deltas(results),
        }
        report["process_memory_details"] = true if process_memory_details
        report["object_memory"] = true if object_memory
        report["request_paths"] = request_paths if target == "requests"
        report["profile"] = profile_metadata if profile_path
        report
      end

      private
        def run_variant(variant)
          runs.times.map do
            run_once(variant)
          end
        end

        def run_once(variant)
          Dir.mktmpdir("rails_dependency_pruner_measure_events") do |dir|
            early_output_path = File.join(dir, "early-boot.json")
            env = env_for(variant)
            env["RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT"] = early_output_path if env["RAILS_DEPENDENCY_PRUNER_PROFILE"]
            command = ruby_command + ["-e", BOOT_SCRIPT, app_root]
            stdout, stderr, status = Open3.capture3(env, *command, chdir: app_root)

            result = if status.success?
              parse_successful_run(stdout, stderr)
            else
              {
                "status" => "error",
                "exitstatus" => status.exitstatus,
                "stdout" => stdout,
                "stderr" => stderr,
              }
            end
            merge_early_boot_summary(result, early_output_path)
          end
        end

        def merge_early_boot_summary(result, path)
          return result unless File.file?(path)

          summary = JSON.parse(File.read(path))
          result["events_count"] = summary["events_count"].to_i if summary.key?("events_count")
          result["expected_events_count"] = summary["expected_events_count"].to_i if summary.key?("expected_events_count")
          result["unexpected_events_count"] = summary["unexpected_events_count"].to_i if summary.key?("unexpected_events_count")
          result["counters"] = summary["counters"] if summary["counters"].is_a?(Hash)
          result["early_boot_event_summary"] = summary.reject { |key, _value| key == "events" }
          result
        rescue JSON::ParserError => error
          result["early_boot_event_summary_error"] = error.message
          result
        end

        def parse_successful_run(stdout, stderr)
          payload = JSON.parse(json_payload(stdout))
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

        def json_payload(stdout)
          stdout.lines.reverse_each do |line|
            candidate = line.strip
            next if candidate.empty?
            next unless candidate.start_with?("{")

            return candidate
          end

          stdout
        end

        def ruby_command
          File.exist?(File.join(app_root, "Gemfile")) ? ["bundle", "exec", "ruby"] : [Gem.ruby]
        end

        def ruby_lib
          File.expand_path("../..", __dir__)
        end

        def env_for(variant)
          variant_profile_path = variant_profile_paths[variant.to_s]
          selected_profile_path = variant_profile_path || profile_path
          env = {
            "RAILS_DEPENDENCY_PRUNER_MEASURE_VARIANT" => variant,
            "RAILS_DEPENDENCY_PRUNER_MEASURE_TARGET" => target,
            "RUBYLIB" => ruby_lib,
          }
          env["RAILS_DEPENDENCY_PRUNER_PROCESS_MEMORY_DETAILS"] = "1" if process_memory_details
          env["RAILS_DEPENDENCY_PRUNER_OBJECT_MEMORY"] = "1" if object_memory
          env["RAILS_DEPENDENCY_PRUNER_MEASURE_SKIP_RAILTIES"] = skip_railties.join(",") if skip_railties_variant?(variant)
          env["RAILS_DEPENDENCY_PRUNER_MEASURE_REQUEST_PATHS"] = JSON.generate(request_paths) if target == "requests"
          env["BUNDLE_GEMFILE"] = File.join(app_root, "Gemfile") if File.exist?(File.join(app_root, "Gemfile"))
          return env unless selected_profile_path

          env["RAILS_DEPENDENCY_PRUNER_PROFILE"] = selected_profile_path
          if %w[shadow boot_prune canary production].include?(variant)
            env["RAILS_DEPENDENCY_PRUNER_MODE"] = variant
            if %w[canary production].include?(variant)
              env["RAILS_DEPENDENCY_PRUNER_PROFILE_ID"] = Profile.load(selected_profile_path).profile_id
            end
          elsif variant_profile_path
            env["RAILS_DEPENDENCY_PRUNER_MODE"] = "boot_prune"
          end
          env
        end

        def skip_railties_variant?(variant)
          %w[skip_railties no_eager_load_skip_railties].include?(variant)
        end

        def profile_metadata
          profile = Profile.load(profile_path)
          pruning = profile.payload.fetch("pruning", {})

          {
            "path" => profile_path,
            "schema_version" => profile.schema_version,
            "profile_id" => profile.profile_id,
            "mode" => profile.payload["mode"],
            "disabled_frameworks" => Array(pruning["disabled_frameworks"]),
            "disabled_railties" => Array(pruning["disabled_railties"]),
            "disabled_require_paths_count" => Array(pruning["disabled_require_paths"]).length,
            "disabled_constants_count" => Array(pruning["disabled_constants"]).length,
            "extreme_boot" => profile.payload["extreme_boot"],
          }
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

          summary = {
            "status" => "ok",
            "successful_runs" => runs.length,
            "rss_kb_median" => median(runs.map { |run| run.fetch("rss_kb") }),
            "rss_kb_min" => runs.map { |run| run.fetch("rss_kb") }.min,
            "rss_kb_max" => runs.map { |run| run.fetch("rss_kb") }.max,
            "process_memory_median" => summarize_numeric_hash(runs, "process_memory"),
            "loaded_features_median" => median(runs.map { |run| run.fetch("loaded_features") }),
            "rails_loaded_features_median" => median(runs.map { |run| run.fetch("rails_loaded_features") }),
            "rails_loaded_features_by_framework_median" => summarize_framework_features(runs),
            "object_counts_median" => summarize_numeric_hash(runs, "object_counts"),
            "gc_heap_live_slots_median" => median(runs.map { |run| run.fetch("gc_heap_live_slots") }),
          }
          object_memsize_by_type = summarize_numeric_hash(runs, "object_memsize_by_type")
          object_memsize_by_class = summarize_numeric_hash(runs, "object_memsize_by_class")
          summary["object_memsize_by_type_median"] = object_memsize_by_type unless object_memsize_by_type.empty?
          summary["object_memsize_by_class_median"] = object_memsize_by_class unless object_memsize_by_class.empty?
          {
            "boot_time_ms_median" => median_for_key(runs, "boot_time_ms"),
            "first_request_duration_ms_median" => median_for_key(runs, "first_request_duration_ms"),
            "request_duration_ms_p50_median" => median_for_key(runs, "request_duration_ms_p50"),
            "request_duration_ms_p95_median" => median_for_key(runs, "request_duration_ms_p95"),
            "request_duration_ms_p99_median" => median_for_key(runs, "request_duration_ms_p99"),
            "warmed_request_duration_ms_p50_median" => median_for_key(runs, "warmed_request_duration_ms_p50"),
            "warmed_request_duration_ms_p95_median" => median_for_key(runs, "warmed_request_duration_ms_p95"),
            "warmed_request_duration_ms_p99_median" => median_for_key(runs, "warmed_request_duration_ms_p99"),
          }.each do |key, value|
            summary[key] = value unless value.nil?
          end

          request_status_matrix = summarize_request_status_matrix(runs)
          summary["request_status_matrix"] = request_status_matrix unless request_status_matrix.empty?
          event_counts = summarize_event_counts(runs)
          summary.merge!(event_counts) unless event_counts.empty?
          summary
        end

        def deltas(results)
          baseline = summarize(results.fetch("baseline", []))
          return {} unless baseline["status"] == "ok"

          results.reject { |variant, _runs| variant == "baseline" }.to_h do |variant, runs|
            summary = summarize(runs)
            next [variant, { "status" => "error" }] unless summary["status"] == "ok"

            delta = {
              "rss_kb" => summary.fetch("rss_kb_median") - baseline.fetch("rss_kb_median"),
              "loaded_features" => summary.fetch("loaded_features_median") - baseline.fetch("loaded_features_median"),
              "rails_loaded_features" => summary.fetch("rails_loaded_features_median") - baseline.fetch("rails_loaded_features_median"),
              "rails_loaded_features_by_framework" => framework_feature_delta(
                baseline.fetch("rails_loaded_features_by_framework_median", {}),
                summary.fetch("rails_loaded_features_by_framework_median", {}),
              ),
              "process_memory" => numeric_hash_delta(
                baseline.fetch("process_memory_median", {}),
                summary.fetch("process_memory_median", {}),
              ),
              "object_counts" => numeric_hash_delta(
                baseline.fetch("object_counts_median", {}),
                summary.fetch("object_counts_median", {}),
              ),
              "gc_heap_live_slots" => summary.fetch("gc_heap_live_slots_median") - baseline.fetch("gc_heap_live_slots_median"),
              "boot_time_ms" => numeric_delta(summary, baseline, "boot_time_ms_median"),
              "first_request_duration_ms" => numeric_delta(summary, baseline, "first_request_duration_ms_median"),
              "request_duration_ms_p95" => numeric_delta(summary, baseline, "request_duration_ms_p95_median"),
              "request_duration_ms_p99" => numeric_delta(summary, baseline, "request_duration_ms_p99_median"),
              "warmed_request_duration_ms_p95" => numeric_delta(summary, baseline, "warmed_request_duration_ms_p95_median"),
              "warmed_request_duration_ms_p99" => numeric_delta(summary, baseline, "warmed_request_duration_ms_p99_median"),
            }.compact
            if baseline.key?("object_memsize_by_type_median") || summary.key?("object_memsize_by_type_median")
              delta["object_memsize_by_type"] = numeric_hash_delta(
                baseline.fetch("object_memsize_by_type_median", {}),
                summary.fetch("object_memsize_by_type_median", {}),
              )
            end
            if baseline.key?("object_memsize_by_class_median") || summary.key?("object_memsize_by_class_median")
              delta["object_memsize_by_class"] = numeric_hash_delta(
                baseline.fetch("object_memsize_by_class_median", {}),
                summary.fetch("object_memsize_by_class_median", {}),
              )
            end

            [variant, delta]
          end.compact.to_h
        end

        def median_for_key(runs, key)
          values = runs.filter_map { |run| run[key] }
          return nil if values.empty?

          median(values)
        end

        def summarize_request_status_matrix(runs)
          paths = []
          matrix = {}
          runs.each do |run|
            Array(run["requests"]).each do |request|
              path = request["path"] || "(unknown)"
              unless matrix.key?(path)
                paths << path
                matrix[path] = { "statuses" => [], "errors" => [] }
              end
              matrix.fetch(path).fetch("statuses") << request["status"] if request.key?("status")
              matrix.fetch(path).fetch("errors") << request["error"] if request.key?("error")
            end
          end

          paths.each_with_object({}) do |path, result|
            entry = matrix.fetch(path)
            path_result = {}
            statuses = entry.fetch("statuses").uniq.sort
            errors = entry.fetch("errors").uniq.sort
            path_result["statuses"] = statuses unless statuses.empty?
            path_result["errors"] = errors unless errors.empty?
            result[path] = path_result unless path_result.empty?
          end
        end

        def summarize_event_counts(runs)
          event_runs = runs.select do |run|
            run.key?("events_count") ||
              run.key?("expected_events_count") ||
              run.key?("unexpected_events_count") ||
              !run.fetch("counters", {}).empty?
          end
          return {} if event_runs.empty?

          summary = {}
          %w[events_count expected_events_count unexpected_events_count].each do |key|
            values = event_runs.filter_map { |run| run[key] }
            summary[key] = values.max unless values.empty?
          end
          counters = summarize_counters(event_runs)
          summary["counters"] = counters unless counters.empty?
          summary
        end

        def summarize_counters(runs)
          keys = runs.flat_map { |run| run.fetch("counters", {}).keys }.uniq.sort
          keys.to_h do |key|
            values = runs.filter_map do |run|
              value = run.fetch("counters", {})[key]
              Integer(value) unless value.nil?
            rescue ArgumentError, TypeError
              nil
            end
            [
              key,
              memory_counter?(key) ? values.max.to_i : values.sum,
            ]
          end
        end

        def memory_counter?(key)
          key.to_s.start_with?("pruner.memory.")
        end

        def numeric_delta(summary, baseline, key)
          return nil unless summary.key?(key) && baseline.key?(key)

          delta = summary.fetch(key) - baseline.fetch(key)
          delta.is_a?(Float) ? delta.round(3) : delta
        end

        def summarize_framework_features(runs)
          frameworks = runs.flat_map { |run| run.fetch("rails_loaded_features_by_framework", {}).keys }.uniq.sort
          frameworks.to_h do |framework|
            values = runs.map { |run| run.fetch("rails_loaded_features_by_framework", {}).fetch(framework, 0) }
            [framework, median(values)]
          end
        end

        def summarize_numeric_hash(runs, key)
          keys = runs.flat_map { |run| run.fetch(key, {}).keys }.uniq.sort
          keys.to_h do |name|
            values = runs.map { |run| run.fetch(key, {}).fetch(name, 0) }
            [name, median(values)]
          end
        end

        def framework_feature_delta(baseline, summary)
          frameworks = (baseline.keys + summary.keys).uniq.sort
          frameworks.to_h do |framework|
            [framework, summary.fetch(framework, 0) - baseline.fetch(framework, 0)]
          end
        end

        def numeric_hash_delta(baseline, summary)
          keys = (baseline.keys + summary.keys).uniq.sort
          keys.to_h do |key|
            [key, summary.fetch(key, 0) - baseline.fetch(key, 0)]
          end
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
