# frozen_string_literal: true

module RailsDependencyPruner
  class CLI
    class Printer
      def index(index)
        payload = index.to_h(include_tree: false)

        puts "Rails dependency index for #{payload.dig(:source, :label)}"
        puts "Rails version: #{payload.fetch(:rails_version) || "(checkout override)"}"
        puts "Scanned Ruby files: #{payload.fetch(:files_scanned)}"
        puts "Rails constants indexed: #{payload.fetch(:constants_count)}"
        puts "Parse errors: #{payload.fetch(:parse_errors).length}"
        puts
        puts "Constants by component:"
        payload.fetch(:components).each do |component, count|
          puts "  #{component}: #{count}"
        end
      end

      def audit(planner, profile_path:, shim_path:)
        payload = planner.to_h(include_tree: false, include_unused: false)

        puts "Rails dependency audit for #{payload.fetch(:app_root)}"
        puts "Rails source: #{payload.dig(:source, :label)}"
        puts "Rails root: #{payload.fetch(:rails_root)}" unless blank?(payload.fetch(:rails_root))
        puts "Rails files scanned: #{payload.fetch(:rails_files_scanned)}"
        puts "App files scanned: #{payload.fetch(:app_files_scanned)}"
        puts "Rails constants indexed: #{payload.fetch(:rails_constants_count)}"
        puts "Direct app Rails constants: #{payload.fetch(:direct_rails_constants_count)}"
        puts "Runtime Rails constants: #{payload.fetch(:runtime_rails_constants_count)}"
        puts "Reachable Rails constants: #{payload.fetch(:used_constants_count)}"
        puts "Unused Rails constants: #{payload.fetch(:unused_constants_count)}"
        puts "Unused Rails feature files: #{payload.fetch(:unused_features_count)}"
        puts "Rails parse errors: #{payload.dig(:parse_errors, :rails).length}"
        puts "App parse errors: #{payload.dig(:parse_errors, :app).length}"
        puts
        puts "Top unused namespaces:"
        payload.fetch(:top_unused_namespaces).first(20).each do |namespace, count|
          puts "  #{namespace}: #{count}"
        end
        runtime_memory(planner.runtime_memory_summary)
        puts
        puts "Profile written to: #{profile_path}" if profile_path
        puts "Shim written to: #{shim_path}" if shim_path
        puts "Use --json for the full dependency tree and constant lists."
      end

      def runtime_memory(summary)
        return if summary.empty?

        puts
        puts "Top runtime object memory:"
        summary.object_sizes.first(10).each do |type, bytes|
          puts "  #{type}: #{bytes} bytes"
        end

        return if summary.rails_class_instance_sizes.empty?

        puts
        puts "Top Rails class instance memory:"
        summary.rails_class_instance_sizes.first(10).each do |entry|
          puts "  #{entry.fetch("name")}: #{entry.fetch("bytes")} bytes / #{entry.fetch("count")} objects"
        end
      end

      def explanation(explanation)
        puts "#{explanation.fetch("constant")}: #{explanation.fetch("decision")}"
        puts "Seed: #{explanation.fetch("seed") || "no"}"
        puts "Defined: #{explanation.fetch("defined")}"
        puts "Component: #{explanation.fetch("component") || "(unknown)"}"
        puts "Path: #{explanation.fetch("path") || "(unknown)"}"

        unless explanation.fetch("dependencies").empty?
          puts
          puts "Dependencies:"
          explanation.fetch("dependencies").first(20).each do |dependency|
            puts "  #{dependency}"
          end
        end

        unless explanation.fetch("used_by").empty?
          puts
          puts "Used by:"
          explanation.fetch("used_by").first(20).each do |constant|
            puts "  #{constant}"
          end
        end

        return if explanation.fetch("reachability_path").empty?

        puts
        puts "Reachability path:"
        explanation.fetch("reachability_path").each do |entry|
          via = entry["via"] ? " via #{entry["via"]}" : ""
          puts "  #{entry.fetch("node")}#{via}"
        end
      end

      def profile_explanation(explanation)
        puts "#{explanation.fetch("target")}: #{explanation.fetch("decision")}"
        puts "Type: #{explanation.fetch("target_type")}"
        puts "Reason: #{explanation.fetch("reason")}"

        evidence = explanation.fetch("evidence")
        return if evidence.empty?

        if evidence["positive_evidence"]&.any?
          puts
          puts "Positive evidence:"
          evidence.fetch("positive_evidence").first(20).each { |entry| puts "  #{entry}" }
        end

        if evidence["negative_evidence"]&.any?
          puts
          puts "Negative evidence:"
          evidence.fetch("negative_evidence").first(20).each { |entry| puts "  #{entry}" }
        end

        puts
        puts "Railtie: #{evidence.fetch("railtie")}" if evidence["railtie"]
      end

      def boot_plan(boot_plan, patch_path:)
        puts "Required frameworks:"
        boot_plan.required_frameworks.each { |framework| puts "  #{framework}" }
        puts
        puts "Pruned frameworks:"
        boot_plan.pruned_frameworks.each { |framework| puts "  #{framework}" }
        puts
        puts "Patch written to: #{patch_path}" if patch_path
      end

      def plan(report)
        boot_plan = report.fetch("boot_plan")

        puts "Profile written to: #{report.fetch("profile_path")}"
        puts "Profile id: #{report.fetch("profile_id")}"
        puts "Mode: #{report.fetch("mode")}"
        puts
        puts "Required frameworks:"
        boot_plan.fetch("required_frameworks").each { |framework| puts "  #{framework}" }
        puts
        puts "Pruned frameworks:"
        boot_plan.fetch("pruned_frameworks").each { |framework| puts "  #{framework}" }
        puts
        puts "Patch written to: #{report.fetch("patch_path")}" if report["patch_path"]
      end

      def early_boot_patch(report)
        puts "Early boot shim: #{report.fetch("status")}"
        puts "Target: #{report.fetch("target")}"
        puts "Env var: #{report.fetch("env_var")}"
        puts "Reason: #{report.fetch("reason")}" if report["reason"]
        puts "Patch written to: #{report.fetch("patch_path")}" if report["patch_path"]
      end

      def measurement(report, output_path:, markdown_path: nil)
        if report["profile"]
          profile = report.fetch("profile")
          puts "Profile: #{profile.fetch("profile_id") || "(no id)"}"
          puts "Profile path: #{profile.fetch("path")}"
          puts
        end

        report.fetch("variants").each do |variant, summary|
          puts "#{variant}: #{summary.fetch("status")}"
          next unless summary.fetch("status") == "ok"

          puts "  RSS median: #{summary.fetch("rss_kb_median")} KB"
          puts "  Rails loaded features median: #{summary.fetch("rails_loaded_features_median")}"
          puts "  GC live slots median: #{summary.fetch("gc_heap_live_slots_median")}"
          framework_features = summary.fetch("rails_loaded_features_by_framework_median", {})
          unless framework_features.empty?
            puts "  Rails features by framework:"
            framework_features.each do |framework, count|
              puts "    #{framework}: #{count}"
            end
          end
        end

        unless report.fetch("deltas").empty?
          puts
          puts "Deltas vs baseline:"
          report.fetch("deltas").each do |variant, delta|
            puts "  #{variant}: #{delta}"
          end
        end

        puts
        puts "Report written to: #{output_path}" if output_path
        puts "Markdown written to: #{markdown_path}" if markdown_path
      end

      def profile_diff(diff)
        unless diff.fetch("changed")
          puts "Profiles are equivalent"
          return
        end

        unless diff.fetch("context_changes").empty?
          puts "Context changes:"
          diff.fetch("context_changes").each do |change|
            puts "  #{change.fetch("key")}: #{short_value(change.fetch("old"))} -> #{short_value(change.fetch("new"))}"
          end
        end

        puts
        puts "Pruning changes:"
        diff.fetch("pruning_changes").each do |key, change|
          next if change.fetch("added").empty? && change.fetch("removed").empty?

          puts "  #{key}: #{change.fetch("old_count")} -> #{change.fetch("new_count")}"
          change.fetch("added").first(20).each { |value| puts "    + #{value}" }
          change.fetch("removed").first(20).each { |value| puts "    - #{value}" }
        end
      end

      def verify(report)
        puts "Verified: #{report.fetch("verified")}"
        puts "Production allowed: #{report.fetch("production_allowed")}"
        puts "Profile approved: #{report.fetch("profile_approved")}" if report.key?("profile_approved")

        unless report.fetch("errors").empty?
          puts
          puts "Errors:"
          report.fetch("errors").each { |error| puts "  #{error}" }
        end

        rails_errors = report.dig("parse_errors", "rails").length
        app_errors = report.dig("parse_errors", "app").length
        puts
        puts "Rails parse errors: #{rails_errors}"
        puts "App parse errors: #{app_errors}"
      end

      def doctor(report)
        recommendations = report.fetch("recommendations")
        if recommendations.empty?
          puts "No doctor recommendations"
          return
        end

        puts "Doctor recommendations:"
        recommendations.each do |recommendation|
          puts "  [#{recommendation.fetch("severity")}] #{recommendation.fetch("id")}: #{recommendation.fetch("title")}"
          puts "    #{recommendation.fetch("detail")}"
        end
      end

      private
        def short_value(value)
          case value
          when Hash
            "{#{value.keys.sort.join(", ")}}"
          when Array
            "[#{value.length} entries]"
          else
            value.inspect
          end
        end

        def blank?(value)
          value.nil? || value.to_s.empty?
        end
    end
  end
end
