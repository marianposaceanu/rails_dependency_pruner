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
require_relative "transform_registry"
require_relative "measurement/report"
require_relative "measurement/runner"
require_relative "runtime/collector"
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
      when "approve"
        run_verify(usage: "approve", default_production: true, default_approve_production: true)
      when "audit"
        run_audit
      when "check"
        run_verify(usage: "check")
      when "diff"
        run_profile_diff(usage: "diff")
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
      when "patch"
        run_apply_boot_plan(usage: "patch")
      when "plan"
        run_plan
      when "profile"
        run_profile
      when "runtime"
        run_runtime
      when "shim"
        run_apply_early_boot_shim(usage: "shim")
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

      def run_verify(usage: "verify", default_production: false, default_approve_production: false)
        options = options_parser.verify(
          usage: usage,
          default_production: default_production,
          default_approve_production: default_approve_production,
        )
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
        subcommand = @argv.first

        case subcommand
        when "boot"
          @argv.shift
          run_measure_boot
        when nil
          puts measure_help
          0
        when /\A-/
          run_measure_boot
        when "help", "-h", "--help"
          @argv.shift
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
          target: options.fetch(:target),
          skip_railties: options.fetch(:skip_railties),
          request_paths: options.fetch(:request_paths),
        ).run

        if options[:output_path]
          FileUtils.mkdir_p(File.dirname(options[:output_path]))
          File.write(options[:output_path], JSON.pretty_generate(report))
        end
        if options[:markdown_path]
          FileUtils.mkdir_p(File.dirname(options[:markdown_path]))
          File.write(options[:markdown_path], Measurement::Report.new(report).to_markdown)
        end

        if options.fetch(:json)
          puts JSON.pretty_generate(report)
        else
          printer.measurement(
            report,
            output_path: options[:output_path],
            markdown_path: options[:markdown_path],
          )
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
          extreme_boot: extreme_boot_options(options),
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
          "extreme_boot" => profile.payload.fetch("extreme_boot"),
          "transforms" => profile.payload.fetch("transforms"),
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

      def run_apply_boot_plan(usage: "apply boot-plan")
        options = options_parser.apply_boot_plan(usage: usage)
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

      def run_apply_early_boot_shim(usage: "apply early-boot-shim")
        options = options_parser.apply_early_boot_shim(usage: usage)
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

      def run_runtime
        subcommand = @argv.shift || "help"

        case subcommand
        when "collect"
          run_runtime_collect
        when "help", "-h", "--help"
          puts runtime_help
          0
        else
          warn "Unknown runtime command: #{subcommand}"
          warn runtime_help
          1
        end
      end

      def run_runtime_collect
        options = options_parser.runtime_collect
        report = Runtime::Collector.new(
          app_root: options.fetch(:app_root),
          output_path: options.fetch(:output_path),
          coverage_path: options[:coverage_path],
          command: options[:command],
          rails_root: options[:rails_root],
        ).run

        if options.fetch(:json)
          puts JSON.pretty_generate(report)
        else
          printer.runtime_collect(report)
        end

        report.fetch("status") == "ok" ? 0 : 1
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
          extreme_boot: extreme_boot_options(options),
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

      def run_profile_diff(usage: "profile diff")
        options = options_parser.profile_diff(usage: usage)
        diff = ProfileDiff.new(
          old_profile: Profile.load(options.fetch(:old_profile_path)),
          new_profile: Profile.load(options.fetch(:new_profile_path)),
          semantic: options.fetch(:semantic),
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

          Common flow:
            plan     Build the profile and optional boot-plan patch
            check    Verify a profile against the current app
            approve  Run production checks and mark the profile production-ready
            patch    Write the reviewed boot-plan patch
            shim     Write the reviewed config/boot.rb shim patch
            measure  Measure boot memory in fresh processes
            runtime  Collect runtime evidence from a workload

          Commands:
            plan            Build a deterministic profile and optional boot-plan patch
            check           Verify a profile and app safety gates
            approve         Same as check --production --approve-production
            patch           Write a reviewed patch replacing rails/all
            shim            Write a reviewed config/boot.rb shim patch
            diff            Compare two profiles
            explain TARGET  Explain a constant/framework/require decision
            measure         Measure boot memory in fresh processes
            runtime         Collect runtime evidence
            doctor          Print production-readiness recommendations
            audit, index    Lower-level scan commands

          Compatibility aliases:
            verify, profile validate, profile diff, apply boot-plan,
            apply early-boot-shim, measure boot

          Common path:
            rails-dependency-pruner plan
            rails-dependency-pruner check --profile config/rails_dependency_pruner_profile.json --app .
            rails-dependency-pruner approve --profile config/rails_dependency_pruner_profile.json --app . --coverage config/pruner_coverage.yml
            rails-dependency-pruner runtime collect --app . --coverage config/pruner_coverage.yml --output tmp/pruner-runtime.json
            rails-dependency-pruner explain ActiveStorage --profile config/rails_dependency_pruner_profile.json

          Plan options:
            --app PATH                 Defaults to current directory
            --profile PATH             Defaults to config/rails_dependency_pruner_profile.json
            --patch PATH
            --coverage PATH
            --runtime-evidence PATHS
            --disable-eager-load
            --skip-railties PATHS
            --json
        HELP
      end

      def profile_help
        <<~HELP
          Usage:
            rails-dependency-pruner profile build --app . --write config/rails_dependency_pruner_profile.json
            rails-dependency-pruner profile validate [options]
            rails-dependency-pruner profile diff --old old.json --new new.json

          Prefer:
            rails-dependency-pruner plan
            rails-dependency-pruner check --profile config/rails_dependency_pruner_profile.json --app .
            rails-dependency-pruner diff --old old.json --new new.json

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
            --disable-eager-load
            --skip-railties PATHS
            --json
        HELP
      end

      def apply_help
        <<~HELP
          Usage: rails-dependency-pruner apply boot-plan [options]
                 rails-dependency-pruner apply early-boot-shim [options]

          Prefer:
            rails-dependency-pruner patch --app . --profile config/rails_dependency_pruner_profile.json --patch tmp/pruner-boot-plan.patch
            rails-dependency-pruner shim --app . --patch tmp/pruner-early-boot.patch

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
          Usage: rails-dependency-pruner measure [options]
                 rails-dependency-pruner measure boot [options]

          Required:
            --app PATH

          Useful options:
            --profile PATH
            --variants baseline,boot_prune,no_eager_load,no_eager_load_skip_railties
            --runs N
            --target application|environment|requests
            --skip-railties PATHS
            --request-paths PATHS
            --output PATH
            --markdown PATH
            --json
        HELP
      end

      def runtime_help
        <<~HELP
          Usage: rails-dependency-pruner runtime collect [options]

          Required:
            --app PATH
            --output PATH

          Useful options:
            --coverage PATH
            --command COMMAND
            --rails-root PATH
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

      def extreme_boot_options(options)
        {
          disable_eager_load: options.fetch(:disable_eager_load, false),
          skip_railties: options.fetch(:skip_railties, []),
          lazy_require_paths: options.fetch(:lazy_require_paths, []),
          lazy_gems: options.fetch(:lazy_gems, []),
        }
      end
  end
end
