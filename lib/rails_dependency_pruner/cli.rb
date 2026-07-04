# frozen_string_literal: true

require "json"
require "fileutils"
require "pathname"

require_relative "app_usage"
require_relative "apply/boot_plan_patch"
require_relative "apply/early_boot_patch"
require_relative "boot_prune_planner"
require_relative "boot_plan_explainer"
require_relative "constant_index"
require_relative "doctor"
require_relative "planner"
require_relative "profile"
require_relative "profile_context"
require_relative "profile_diff"
require_relative "profile_explainer"
require_relative "profile_verifier"
require_relative "profile_validator"
require_relative "measurement/runner"
require_relative "runtime_evidence"
require_relative "shim_writer"
require_relative "cli/options"
require_relative "cli/printer"

module RailsDependencyPruner
  class CLI
    def initialize(argv)
      @argv = argv.dup
    end

    def run
      command = @argv.shift || "audit"

      case command
      when "audit"
        run_audit
      when "apply"
        run_apply
      when "doctor"
        run_doctor
      when "index"
        run_index
      when "explain"
        run_explain
      when "measure"
        run_measure
      when "plan"
        run_plan
      when "profile"
        run_profile
      when "verify"
        run_verify
      when "why-kept"
        run_explain
      when "help", "-h", "--help"
        puts help
        0
      else
        warn "Unknown command: #{command}"
        warn help
        1
      end
    rescue OptionParser::ParseError, ArgumentError => error
      warn error.message
      1
    end

    private
      def run_index
        options = options_parser.audit(require_app: false)
        index = ConstantIndex.build(rails_root: options.fetch(:rails_root), frameworks: options.fetch(:frameworks))
        payload = index.to_h(include_tree: options.fetch(:include_tree))

        if options.fetch(:json)
          puts JSON.pretty_generate(payload)
        else
          printer.index(index)
        end

        0
      end

      def run_doctor
        options = options_parser.doctor
        report = Doctor.new(app_root: options.fetch(:app_root)).report

        if options.fetch(:json)
          puts JSON.pretty_generate(report)
        else
          printer.doctor(report)
        end

        0
      end

      def run_verify
        options = options_parser.verify
        profile = Profile.load(options.fetch(:profile_path))
        index = ConstantIndex.build(rails_root: options.fetch(:rails_root), frameworks: options.fetch(:frameworks))
        usage = AppUsage.scan(app_root: options.fetch(:app_root), index: index, scan_roots: options.fetch(:scan_roots))
        context = ProfileContext.build(
          app_root: options.fetch(:app_root),
          rails_root: options.fetch(:rails_root),
          scan_roots: options.fetch(:scan_roots),
          frameworks: options.fetch(:frameworks),
          runtime_evidence_paths: options.fetch(:runtime_evidence_paths),
          coverage_path: options[:coverage_path],
        )
        report = ProfileVerifier.new(
          profile: profile,
          context: context,
          index: index,
          usage: usage,
          production: options.fetch(:production),
        ).verify
        if options.fetch(:approve_production)
          report["profile_approved"] = false
          if report.fetch("verified")
            profile.approve_production!
            profile.write(options.fetch(:profile_path))
            report["profile_approved"] = true
            report["profile"]["profile_id"] = profile.profile_id
            report["profile"]["production_allowed"] = true
          end
        end

        if options.fetch(:json)
          puts JSON.pretty_generate(report)
        else
          printer.verify(report)
        end

        report.fetch("verified") ? 0 : 1
      end

      def run_measure
        subcommand = @argv.shift || "help"

        case subcommand
        when "boot"
          run_measure_boot
        when "help", "-h", "--help"
          puts measure_help
          0
        else
          warn "Unknown measure command: #{subcommand}"
          warn measure_help
          1
        end
      end

      def run_measure_boot
        options = options_parser.measure_boot
        report = Measurement::Runner.new(
          app_root: options.fetch(:app_root),
          variants: options.fetch(:variants),
          runs: options.fetch(:runs),
          profile_path: options[:profile_path],
        ).run

        if options[:output_path]
          FileUtils.mkdir_p(File.dirname(options[:output_path]))
          File.write(options[:output_path], JSON.pretty_generate(report))
        end

        if options.fetch(:json)
          puts JSON.pretty_generate(report)
        else
          printer.measurement(report, output_path: options[:output_path])
        end

        0
      end

      def run_plan
        options = options_parser.plan
        planner = build_planner(options)
        boot_plan = BootPrunePlanner.new(planner).plan
        explanations = BootPlanExplainer.new(planner: planner, boot_plan: boot_plan).explanations
        profile = Profile.deterministic_from_planner(
          planner,
          runtime_evidence_paths: options.fetch(:runtime_evidence_paths),
          coverage_path: options[:coverage_path],
          mode: "boot_prune",
          boot_plan: boot_plan,
          explanations: explanations,
        )
        profile.write(options.fetch(:profile_path))

        if options[:patch_path]
          Apply::BootPlanPatch.new(app_root: options.fetch(:app_root), boot_plan: boot_plan).write(options[:patch_path])
        end

        report = {
          "profile_path" => options.fetch(:profile_path),
          "profile_id" => profile.profile_id,
          "mode" => profile.payload.fetch("mode"),
          "patch_path" => options[:patch_path],
          "boot_plan" => boot_plan.to_h,
        }.compact

        if options.fetch(:json)
          puts JSON.pretty_generate(report)
        else
          printer.plan(report)
        end

        0
      end

      def run_apply
        subcommand = @argv.shift || "help"

        case subcommand
        when "boot-plan"
          run_apply_boot_plan
        when "early-boot-shim"
          run_apply_early_boot_shim
        when "help", "-h", "--help"
          puts apply_help
          0
        else
          warn "Unknown apply command: #{subcommand}"
          warn apply_help
          1
        end
      end

      def run_apply_boot_plan
        options = options_parser.apply_boot_plan
        Profile.load(options.fetch(:profile_path))

        planner = build_planner(options)
        boot_plan = BootPrunePlanner.new(planner).plan

        if options[:write_patch]
          Apply::BootPlanPatch.new(app_root: options.fetch(:app_root), boot_plan: boot_plan).write(options[:write_patch])
        end

        if options.fetch(:json)
          puts JSON.pretty_generate(boot_plan.to_h)
        else
          printer.boot_plan(boot_plan, patch_path: options[:write_patch])
        end

        0
      end

      def run_apply_early_boot_shim
        options = options_parser.apply_early_boot_shim
        patch = Apply::EarlyBootPatch.new(app_root: options.fetch(:app_root))

        if options[:write_patch]
          patch.write(options[:write_patch])
        end

        report = patch.to_h
        report["patch_path"] = options[:write_patch] if options[:write_patch]

        if options.fetch(:json)
          puts JSON.pretty_generate(report)
        else
          printer.early_boot_patch(report)
        end

        0
      end

      def run_explain
        options = options_parser.explain
        target = @argv.shift
        raise ArgumentError, "TARGET is required" if blank?(target)

        explanation = if options[:profile_path]
          ProfileExplainer.new(profile: Profile.load(options.fetch(:profile_path))).explain(target)
        else
          build_planner(options).explain_constant(target)
        end

        if options.fetch(:json)
          puts JSON.pretty_generate(explanation)
        elsif options[:profile_path]
          printer.profile_explanation(explanation)
        else
          printer.explanation(explanation)
        end

        0
      end

      def run_audit
        options = options_parser.audit(require_app: true)
        planner = build_planner(options)

        if options[:write_profile]
          profile = if options.fetch(:deterministic)
            Profile.deterministic_from_planner(
              planner,
              runtime_evidence_paths: options.fetch(:runtime_evidence_paths),
              coverage_path: options[:coverage_path],
              mode: options.fetch(:mode),
            )
          else
            Profile.from_planner(planner)
          end

          profile.write(options[:write_profile])
        end

        if options[:write_shim]
          ShimWriter.new(planner.unused_constants, require_paths: planner.unused_require_paths).write(options[:write_shim])
        end

        payload = planner.to_h(
          include_tree: options.fetch(:include_tree),
          include_unused: options.fetch(:include_unused),
        )

        if options.fetch(:json)
          puts JSON.pretty_generate(payload)
        else
          printer.audit(planner, profile_path: options[:write_profile], shim_path: options[:write_shim])
        end

        0
      end

      def run_profile
        subcommand = @argv.shift || "help"

        case subcommand
        when "build"
          run_profile_build
        when "diff"
          run_profile_diff
        when "validate"
          run_profile_validate
        when "help", "-h", "--help"
          puts profile_help
          0
        else
          warn "Unknown profile command: #{subcommand}"
          warn profile_help
          1
        end
      end

      def run_profile_build
        options = options_parser.profile_build
        planner = build_planner(options)
        boot_plan = boot_plan_for_profile(options.fetch(:mode), planner)
        explanations = boot_plan && BootPlanExplainer.new(planner: planner, boot_plan: boot_plan).explanations
        profile = Profile.deterministic_from_planner(
          planner,
          runtime_evidence_paths: options.fetch(:runtime_evidence_paths),
          coverage_path: options[:coverage_path],
          mode: options.fetch(:mode),
          boot_plan: boot_plan,
          explanations: explanations,
        )
        profile.write(options.fetch(:write_path))

        if options.fetch(:json)
          puts JSON.pretty_generate(profile.payload)
        else
          puts "Profile written to: #{options.fetch(:write_path)}"
          puts "Profile id: #{profile.profile_id}"
        end

        0
      end

      def run_profile_diff
        options = options_parser.profile_diff
        diff = ProfileDiff.new(
          old_profile: Profile.load(options.fetch(:old_profile_path)),
          new_profile: Profile.load(options.fetch(:new_profile_path)),
        ).to_h

        if options.fetch(:json)
          puts JSON.pretty_generate(diff)
        else
          printer.profile_diff(diff)
        end

        0
      end

      def run_profile_validate
        options = options_parser.profile_validate
        profile = Profile.load(options.fetch(:profile_path))
        context = ProfileContext.build(
          app_root: options.fetch(:app_root),
          rails_root: options.fetch(:rails_root),
          scan_roots: options.fetch(:scan_roots),
          frameworks: options.fetch(:frameworks),
          runtime_evidence_paths: options.fetch(:runtime_evidence_paths),
          coverage_path: options[:coverage_path],
        )

        profile.validate!(context)
        puts "Profile valid: #{options.fetch(:profile_path)}"
        0
      rescue ProfileValidator::ValidationError => error
        warn error.message
        1
      end

      def options_parser
        @options_parser ||= Options.new(@argv)
      end

      def printer
        @printer ||= Printer.new
      end

      def blank?(value)
        value.nil? || value.to_s.empty?
      end

      def help
        <<~HELP
          Usage: rails-dependency-pruner plan [options]
                 rails-dependency-pruner COMMAND [options]

          Commands:
            plan  Build a deterministic profile and optional boot-plan patch
            index  Build a Rails constant dependency tree
            audit  Scan an app and find unused Rails constants
            apply boot-plan  Write a reviewed patch replacing rails/all
            apply early-boot-shim  Write a reviewed config/boot.rb shim patch
            doctor  Print production-readiness recommendations
            explain TARGET  Explain a constant/framework/require decision
            measure boot  Measure boot memory in fresh processes
            profile build  Build a deterministic profile
            profile validate  Validate a deterministic profile against current inputs
            verify  Validate profile and app safety gates
            why-kept TARGET  Alias for explain TARGET

          Common path:
            rails-dependency-pruner plan
            rails-dependency-pruner plan --coverage config/pruner_coverage.yml --patch tmp/pruner-boot-plan.patch
            rails-dependency-pruner explain ActiveStorage --profile config/rails_dependency_pruner_profile.json

          Plan options:
            --app PATH                 Defaults to current directory
            --profile PATH             Defaults to config/rails_dependency_pruner_profile.json
            --patch PATH
            --coverage PATH
            --runtime-evidence PATHS
            --json
        HELP
      end

      def profile_help
        <<~HELP
          Usage:
            rails-dependency-pruner profile build --app . --write config/rails_dependency_pruner_profile.json
            rails-dependency-pruner profile validate [options]
            rails-dependency-pruner profile diff --old old.json --new new.json

          Build required:
            --app PATH
            --write PATH

          Validate required:
            --profile PATH
            --app PATH

          Diff required:
            --old PATH
            --new PATH

          Useful options:
            --rails-root PATH          Optional checkout override; installed Rails 8.x gems are used by default
            --scan ROOTS
            --frameworks NAMES
            --runtime-evidence PATHS
            --coverage PATH
            --json
        HELP
      end

      def apply_help
        <<~HELP
          Usage: rails-dependency-pruner apply boot-plan [options]
                 rails-dependency-pruner apply early-boot-shim [options]

          Boot-plan required:
            --profile PATH
            --app PATH

          Early-boot-shim required:
            --app PATH

          Useful options:
            --write-patch PATH
            --rails-root PATH          Optional checkout override; installed Rails 8.x gems are used by default
            --scan ROOTS
            --frameworks NAMES
            --runtime-evidence PATHS
            --json
        HELP
      end

      def measure_help
        <<~HELP
          Usage: rails-dependency-pruner measure boot [options]

          Required:
            --app PATH

          Useful options:
            --profile PATH
            --variants baseline,boot_prune
            --runs N
            --output PATH
            --json
        HELP
      end

      def runtime_evidence_for(paths, index)
        return if paths.empty?

        RuntimeEvidence.new(paths: paths, index: index)
      end

      def build_planner(options)
        index = ConstantIndex.build(rails_root: options.fetch(:rails_root), frameworks: options.fetch(:frameworks))
        usage = AppUsage.scan(app_root: options.fetch(:app_root), index: index, scan_roots: options.fetch(:scan_roots))
        runtime_evidence = runtime_evidence_for(options.fetch(:runtime_evidence_paths), index)
        Planner.new(index: index, usage: usage, runtime_evidence: runtime_evidence)
      end

      def boot_plan_for_profile(mode, planner)
        return unless mode == "boot_prune"

        BootPrunePlanner.new(planner).plan
      end
  end
end
