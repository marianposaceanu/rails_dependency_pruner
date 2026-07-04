# frozen_string_literal: true

require "json"
require "open3"

require_relative "../profile"

module RailsDependencyPruner
  module Measurement
    class Runner
      BOOT_SCRIPT = <<~'RUBY'
        require "json"
        boot_modes = %w[shadow boot_prune production]
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

        if measure_target == "requests"
          require "rack/mock"
          request = Rack::MockRequest.new(Rails.application)
          requests = request_paths.map do |path|
            response = request.get(path, "HTTP_HOST" => "example.org", "HTTPS" => "on")
            {
              "path" => path,
              "status" => response.status,
              "bytes" => response.body.bytesize,
              "location" => response["Location"],
            }.compact
          rescue => error
            {
              "path" => path,
              "error" => error.class.name,
              "message" => error.message,
            }
          end
        end

        Process.warmup if measure_variant == "process_warmup" && Process.respond_to?(:warmup)

        GC.start
        snapshot = RailsDependencyPruner::Measurement::MemoryProbe.snapshot
        snapshot["requests"] = requests if measure_target == "requests"
        puts JSON.generate(snapshot)
      RUBY

      TARGETS = %w[application environment requests].freeze

      attr_reader :app_root, :variants, :runs, :profile_path, :target, :skip_railties, :request_paths,
        :variant_profile_paths

      def initialize(app_root:, variants:, runs:, profile_path: nil, target: "application", skip_railties: [], request_paths: [], variant_profile_paths: {})
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
          env = env_for(variant)
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
          env["RAILS_DEPENDENCY_PRUNER_MEASURE_SKIP_RAILTIES"] = skip_railties.join(",") if skip_railties_variant?(variant)
          env["RAILS_DEPENDENCY_PRUNER_MEASURE_REQUEST_PATHS"] = JSON.generate(request_paths) if target == "requests"
          env["BUNDLE_GEMFILE"] = File.join(app_root, "Gemfile") if File.exist?(File.join(app_root, "Gemfile"))
          return env unless selected_profile_path

          env["RAILS_DEPENDENCY_PRUNER_PROFILE"] = selected_profile_path
          if %w[shadow boot_prune production].include?(variant)
            env["RAILS_DEPENDENCY_PRUNER_MODE"] = variant
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

          {
            "status" => "ok",
            "successful_runs" => runs.length,
            "rss_kb_median" => median(runs.map { |run| run.fetch("rss_kb") }),
            "rss_kb_min" => runs.map { |run| run.fetch("rss_kb") }.min,
            "rss_kb_max" => runs.map { |run| run.fetch("rss_kb") }.max,
            "loaded_features_median" => median(runs.map { |run| run.fetch("loaded_features") }),
            "rails_loaded_features_median" => median(runs.map { |run| run.fetch("rails_loaded_features") }),
            "rails_loaded_features_by_framework_median" => summarize_framework_features(runs),
            "object_counts_median" => summarize_numeric_hash(runs, "object_counts"),
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
              "rails_loaded_features_by_framework" => framework_feature_delta(
                baseline.fetch("rails_loaded_features_by_framework_median", {}),
                summary.fetch("rails_loaded_features_by_framework_median", {}),
              ),
              "object_counts" => numeric_hash_delta(
                baseline.fetch("object_counts_median", {}),
                summary.fetch("object_counts_median", {}),
              ),
              "gc_heap_live_slots" => summary.fetch("gc_heap_live_slots_median") - baseline.fetch("gc_heap_live_slots_median"),
            }]
          end.compact.to_h
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
