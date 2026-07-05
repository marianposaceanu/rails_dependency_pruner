# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "../memory_policy"
require_relative "../profile"
require_relative "../profile_schema"
require_relative "../transform_registry"
require_relative "runner"

module RailsDependencyPruner
  module Measurement
    class AblationRunner
      Variant = Struct.new(:name, :description, :transform_ids, :profile_kind, keyword_init: true) do
        def to_h
          {
            "name" => name,
            "description" => description,
            "transform_ids" => Array(transform_ids),
            "profile_kind" => profile_kind.to_s,
          }
        end
      end

      attr_reader :app_root, :profile_path, :coverage_path, :runs, :target, :request_paths

      def initialize(app_root:, profile_path:, coverage_path: nil, runs: 5, target: "application", request_paths: [])
        @app_root = File.expand_path(app_root)
        @profile_path = File.expand_path(profile_path)
        @coverage_path = coverage_path && File.expand_path(coverage_path)
        @runs = runs
        @target = target
        @request_paths = Array(request_paths)
      end

      def run
        Dir.mktmpdir("rails_dependency_pruner_ablation") do |dir|
          definitions = variant_definitions
          profile_paths = profile_paths_for(definitions, dir)
          report = Runner.new(
            app_root: app_root,
            variants: definitions.map(&:name),
            runs: runs,
            target: target,
            request_paths: request_paths,
            variant_profile_paths: profile_paths,
          ).run

          report = report.merge(
            "ablation" => true,
            "coverage_path" => coverage_path,
            "source_profile" => source_profile_metadata,
            "ablation_variants" => definitions.map(&:to_h),
          ).compact
          policy = source_profile.payload["memory_policy"]
          if policy.is_a?(Hash) && !policy.empty?
            report["memory_policy"] = MemoryPolicy.new(policy: policy, measurement: report).evaluate
          end
          report
        end
      end

      private
        def profile_paths_for(definitions, dir)
          definitions.each_with_object({}) do |definition, paths|
            case definition.profile_kind
            when :source
              paths[definition.name] = profile_path
            when :generated
              paths[definition.name] = write_profile(
                dir: dir,
                name: definition.name,
                transform_ids: definition.transform_ids,
                keep_pruning: false,
              )
            when :rails_prune_plan
              paths[definition.name] = write_profile(
                dir: dir,
                name: definition.name,
                transform_ids: [],
                keep_pruning: true,
              )
            end
          end
        end

        def variant_definitions
          definitions = [
            Variant.new(
              name: "baseline",
              description: "Boot the app without a pruner profile.",
              transform_ids: [],
              profile_kind: :none,
            ),
            Variant.new(
              name: "process_warmup",
              description: "Boot without a profile, then call Process.warmup before the snapshot when Ruby exposes it.",
              transform_ids: [],
              profile_kind: :none,
            ),
          ]

          add_generated(definitions, "skip_test_railtie_only", "Skip rails/test_unit/railtie during early boot.", ["skip_railtie:rails/test_unit/railtie"])
          add_generated(definitions, "disable_eager_load_only", "Disable Rails eager loading during boot.", ["disable_eager_load"])
          add_generated(definitions, "lazy_gems_only", "Defer approved lazy gems, excluding profiler and Vips stubs.", lazy_gem_transform_ids)
          add_generated(definitions, "rack_mini_profiler_stub_only", "Install the Rack::MiniProfiler lazy-gem shim.", rack_mini_profiler_transform_ids)
          add_generated(definitions, "active_storage_vips_analyzer_stub_only", "Install the Active Storage Vips analyzer lazy-gem shim.", vips_transform_ids)

          unless rails_prune_transform_ids.empty?
            definitions << Variant.new(
              name: "rails_prune_plan_only",
              description: "Apply the profile's Rails framework and railtie prune plan without extreme boot transforms.",
              transform_ids: rails_prune_transform_ids,
              profile_kind: :rails_prune_plan,
            )
          end

          add_generated(definitions, "all_low_risk_transforms", "Apply every source transform marked low risk.", low_risk_transform_ids)

          unless source_transform_ids.empty?
            definitions << Variant.new(
              name: "all_approved_transforms",
              description: "Apply the source profile exactly as approved.",
              transform_ids: source_transform_ids,
              profile_kind: :source,
            )
          end

          definitions
        end

        def add_generated(definitions, name, description, transform_ids)
          transform_ids = available_transform_ids(transform_ids)
          return if transform_ids.empty?

          definitions << Variant.new(
            name: name,
            description: description,
            transform_ids: transform_ids,
            profile_kind: :generated,
          )
        end

        def write_profile(dir:, name:, transform_ids:, keep_pruning:)
          payload = reduced_payload(keep_pruning: keep_pruning)
          apply_transform_ids(payload, transform_ids)
          rebuild_profile!(payload)

          path = File.join(dir, "#{name}.json")
          Profile.new(payload).write(path)
          path
        end

        def reduced_payload(keep_pruning:)
          payload = deep_dup(source_profile.payload)
          payload["mode"] = "boot_prune"
          payload["safety"] ||= {}
          payload["safety"]["production_allowed"] = false
          clear_pruning!(payload) unless keep_pruning
          payload["extreme_boot"] = empty_extreme_boot
          payload
        end

        def clear_pruning!(payload)
          pruning = payload["pruning"] ||= {}
          %w[
            disabled_frameworks
            disabled_railties
            disabled_initializers
            disabled_require_paths
            disabled_require_path_provenance
            disabled_constants
            autoload_ignores
            eager_load_ignores
          ].each { |key| pruning[key] = [] }

          boot_plan = payload["boot_plan"] ||= {}
          %w[pruned_frameworks pruned_railties autoload_ignores eager_load_ignores pruned_lines].each do |key|
            boot_plan[key] = []
          end
        end

        def empty_extreme_boot
          {
            "disable_eager_load" => false,
            "skip_railties" => [],
            "lazy_require_paths" => [],
            "lazy_gems" => [],
            "config_namespace_stubs" => [],
          }
        end

        def apply_transform_ids(payload, transform_ids)
          transform_ids.each do |transform_id|
            case transform_id
            when "disable_eager_load"
              payload.fetch("extreme_boot")["disable_eager_load"] = true
            when "stub:rack_mini_profiler"
              append_extreme(payload, "lazy_gems", "rack-mini-profiler")
            when "stub:active_storage_vips_analyzer"
              append_extreme(payload, "lazy_gems", "ruby-vips")
            when /\Askip_railtie:(.+)\z/
              append_extreme(payload, "skip_railties", Regexp.last_match(1))
            when /\Alazy_require:(.+)\z/
              append_extreme(payload, "lazy_require_paths", Regexp.last_match(1))
            when /\Alazy_gem:(.+)\z/
              append_extreme(payload, "lazy_gems", Regexp.last_match(1))
            when /\Adisable_framework:(.+)\z/
              append_pruning(payload, "disabled_frameworks", Regexp.last_match(1))
              append_boot_plan(payload, "pruned_frameworks", Regexp.last_match(1))
            when /\Aprune_railtie:(.+)\z/
              append_pruning(payload, "disabled_railties", Regexp.last_match(1))
              append_boot_plan(payload, "pruned_railties", Regexp.last_match(1))
            when /\Aignore_autoload_path:(.+)\z/
              append_pruning(payload, "autoload_ignores", Regexp.last_match(1))
              append_boot_plan(payload, "autoload_ignores", Regexp.last_match(1))
            when /\Aignore_eager_load_path:(.+)\z/
              append_pruning(payload, "eager_load_ignores", Regexp.last_match(1))
              append_boot_plan(payload, "eager_load_ignores", Regexp.last_match(1))
            end
          end

          extreme_boot = payload.fetch("extreme_boot")
          extreme_boot["skip_railties"] = normalize_array(extreme_boot["skip_railties"])
          extreme_boot["lazy_require_paths"] = normalize_array(extreme_boot["lazy_require_paths"])
          extreme_boot["lazy_gems"] = normalize_array(extreme_boot["lazy_gems"])
          extreme_boot["config_namespace_stubs"] = extreme_boot.fetch("skip_railties").filter_map do |railtie|
            Profile::EXTREME_CONFIG_NAMESPACES[railtie]
          end.uniq.sort
        end

        def append_extreme(payload, key, value)
          payload.fetch("extreme_boot")[key] = normalize_array(payload.fetch("extreme_boot")[key] + [value])
        end

        def append_pruning(payload, key, value)
          pruning = payload["pruning"] ||= {}
          pruning[key] = normalize_array(Array(pruning[key]) + [value])
        end

        def append_boot_plan(payload, key, value)
          boot_plan = payload["boot_plan"] ||= {}
          boot_plan[key] = normalize_array(Array(boot_plan[key]) + [value])
        end

        def rebuild_profile!(payload)
          payload["profile_id"] = nil
          payload["fingerprints"] ||= {}
          payload["fingerprints"]["profile_id"] = nil
          payload["transforms"] = TransformRegistry.transforms_for_payload(payload)
          payload["expected_events"] = payload.fetch("transforms").flat_map { |transform| Array(transform["expected_events"]) }
          ProfileSchema.set_profile_id(payload, Profile.new(payload).digest)
        end

        def source_profile_metadata
          {
            "path" => profile_path,
            "schema_version" => source_profile.schema_version,
            "profile_id" => source_profile.profile_id,
            "mode" => source_profile.payload["mode"],
            "transforms_count" => source_transform_ids.length,
          }
        end

        def low_risk_transform_ids
          source_transforms.select { |transform| transform["risk"] == "low" }.map { |transform| transform.fetch("id") }
        end

        def lazy_gem_transform_ids
          source_transform_ids.grep(/\Alazy_gem:/).reject do |id|
            %w[lazy_gem:rack-mini-profiler lazy_gem:ruby-vips].include?(id)
          end
        end

        def rack_mini_profiler_transform_ids
          available_transform_ids(%w[lazy_gem:rack-mini-profiler stub:rack_mini_profiler])
        end

        def vips_transform_ids
          available_transform_ids(%w[lazy_gem:ruby-vips stub:active_storage_vips_analyzer])
        end

        def rails_prune_transform_ids
          source_transform_ids.select do |id|
            id.start_with?("disable_framework:") ||
              id.start_with?("prune_railtie:") ||
              id.start_with?("ignore_autoload_path:") ||
              id.start_with?("ignore_eager_load_path:")
          end
        end

        def available_transform_ids(transform_ids)
          transform_ids.select { |id| source_transform_ids.include?(id) }
        end

        def source_transform_ids
          @source_transform_ids ||= source_transforms.map { |transform| transform.fetch("id") }.sort
        end

        def source_transforms
          @source_transforms ||= Array(source_profile.payload["transforms"]).select { |transform| transform.is_a?(Hash) }
        end

        def source_profile
          @source_profile ||= Profile.load(profile_path)
        end

        def deep_dup(value)
          JSON.parse(JSON.generate(value))
        end

        def normalize_array(values)
          Array(values).map(&:to_s).reject(&:empty?).uniq.sort
        end
    end
  end
end
