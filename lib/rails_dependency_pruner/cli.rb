# frozen_string_literal: true

require "json"
require "fileutils"
require "optparse"
require "pathname"

require_relative "app_usage"
require_relative "apply/boot_plan_patch"
require_relative "boot_prune_planner"
require_relative "constant_index"
require_relative "planner"
require_relative "profile"
require_relative "profile_context"
require_relative "profile_validator"
require_relative "measurement/runner"
require_relative "runtime_evidence"
require_relative "shim_writer"

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
      when "index"
        run_index
      when "explain"
        run_explain
      when "measure"
        run_measure
      when "profile"
        run_profile
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
        options = parse_options(require_app: false)
        index = ConstantIndex.build(rails_root: options.fetch(:rails_root), frameworks: options.fetch(:frameworks))
        payload = index.to_h(include_tree: options.fetch(:include_tree))

        if options.fetch(:json)
          puts JSON.pretty_generate(payload)
        else
          print_index(index)
        end

        0
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
        options = parse_measure_boot_options
        report = Measurement::Runner.new(
          app_root: options.fetch(:app_root),
          variants: options.fetch(:variants),
          runs: options.fetch(:runs),
        ).run

        if options[:output_path]
          FileUtils.mkdir_p(File.dirname(options[:output_path]))
          File.write(options[:output_path], JSON.pretty_generate(report))
        end

        if options.fetch(:json)
          puts JSON.pretty_generate(report)
        else
          print_measurement(report, output_path: options[:output_path])
        end

        0
      end

      def run_apply
        subcommand = @argv.shift || "help"

        case subcommand
        when "boot-plan"
          run_apply_boot_plan
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
        options = parse_apply_boot_plan_options
        Profile.load(options.fetch(:profile_path))

        index = ConstantIndex.build(rails_root: options.fetch(:rails_root), frameworks: options.fetch(:frameworks))
        usage = AppUsage.scan(app_root: options.fetch(:app_root), index: index, scan_roots: options.fetch(:scan_roots))
        runtime_evidence = runtime_evidence_for(options.fetch(:runtime_evidence_paths), index)
        planner = Planner.new(index: index, usage: usage, runtime_evidence: runtime_evidence)
        boot_plan = BootPrunePlanner.new(planner).plan

        if options[:write_patch]
          Apply::BootPlanPatch.new(app_root: options.fetch(:app_root), boot_plan: boot_plan).write(options[:write_patch])
        end

        if options.fetch(:json)
          puts JSON.pretty_generate(boot_plan.to_h)
        else
          print_boot_plan(boot_plan, patch_path: options[:write_patch])
        end

        0
      end

      def run_explain
        options = parse_options(require_app: true)
        target = @argv.shift
        raise ArgumentError, "CONSTANT is required" if blank?(target)

        index = ConstantIndex.build(rails_root: options.fetch(:rails_root), frameworks: options.fetch(:frameworks))
        usage = AppUsage.scan(app_root: options.fetch(:app_root), index: index, scan_roots: options.fetch(:scan_roots))
        runtime_evidence = runtime_evidence_for(options.fetch(:runtime_evidence_paths), index)
        planner = Planner.new(index: index, usage: usage, runtime_evidence: runtime_evidence)
        explanation = planner.explain_constant(target)

        if options.fetch(:json)
          puts JSON.pretty_generate(explanation)
        else
          print_explanation(explanation)
        end

        0
      end

      def run_audit
        options = parse_options(require_app: true)
        index = ConstantIndex.build(rails_root: options.fetch(:rails_root), frameworks: options.fetch(:frameworks))
        usage = AppUsage.scan(app_root: options.fetch(:app_root), index: index, scan_roots: options.fetch(:scan_roots))
        runtime_evidence = runtime_evidence_for(options.fetch(:runtime_evidence_paths), index)
        planner = Planner.new(index: index, usage: usage, runtime_evidence: runtime_evidence)

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
          print_audit(planner, profile_path: options[:write_profile], shim_path: options[:write_shim])
        end

        0
      end

      def run_profile
        subcommand = @argv.shift || "help"

        case subcommand
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

      def run_profile_validate
        options = parse_profile_options
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

      def parse_options(require_app:)
        options = {
          app_root: nil,
          rails_root: nil,
          scan_roots: AppUsage::DEFAULT_SCAN_ROOTS,
          frameworks: ConstantIndex::DEFAULT_FRAMEWORKS,
          include_tree: true,
          include_unused: true,
          json: false,
          write_shim: nil,
          write_profile: nil,
          deterministic: false,
          mode: "guard",
          coverage_path: nil,
          runtime_evidence_paths: [],
        }

        parser = OptionParser.new do |parser|
          parser.banner = "Usage: rails-dependency-pruner [index|audit] [options]"
          parser.on("--rails-root PATH", "Rails source checkout root for fixture/dev analysis") { |path| options[:rails_root] = path }
          parser.on("--app PATH", "Rails app root to scan") { |path| options[:app_root] = path }
          parser.on("--scan ROOTS", "Comma-separated app-relative roots to scan") { |roots| options[:scan_roots] = split_csv(roots) }
          parser.on("--frameworks NAMES", "Comma-separated Rails framework directories to scan") { |names| options[:frameworks] = split_csv(names) }
          parser.on("--[no-]tree", "Include dependency tree in JSON output") { |value| options[:include_tree] = value }
          parser.on("--[no-]unused", "Include full unused constants list in JSON output") { |value| options[:include_unused] = value }
          parser.on("--json", "Print JSON output") { options[:json] = true }
          parser.on("--runtime-evidence PATHS", "Comma-separated runtime evidence JSON files") { |paths| options[:runtime_evidence_paths] = split_csv(paths) }
          parser.on("--coverage PATH", "Coverage manifest used for deterministic profile context") { |path| options[:coverage_path] = path }
          parser.on("--write-profile PATH", "Write a Rails engine profile for unused constants") { |path| options[:write_profile] = path }
          parser.on("--deterministic", "Write schema 2 deterministic profile when used with --write-profile") { options[:deterministic] = true }
          parser.on("--mode MODE", "Profile mode for deterministic profiles") { |mode| options[:mode] = mode }
          parser.on("--write-shim PATH", "Write a fail-fast shim for unused constants") { |path| options[:write_shim] = path }
          parser.on("-h", "--help", "Print help") do
            puts parser
            exit 0
          end
        end

        parser.parse!(@argv)

        options[:rails_root] ||= ENV["RAILS_ROOT_FOR_PRUNER"]
        raise ArgumentError, "--app is required for audit" if require_app && blank?(options[:app_root])

        options
      end

      def parse_profile_options
        options = {
          app_root: nil,
          rails_root: nil,
          scan_roots: AppUsage::DEFAULT_SCAN_ROOTS,
          frameworks: ConstantIndex::DEFAULT_FRAMEWORKS,
          profile_path: nil,
          coverage_path: nil,
          runtime_evidence_paths: [],
        }

        parser = OptionParser.new do |parser|
          parser.banner = "Usage: rails-dependency-pruner profile validate [options]"
          parser.on("--profile PATH", "Profile to validate") { |path| options[:profile_path] = path }
          parser.on("--app PATH", "Rails app root") { |path| options[:app_root] = path }
          parser.on("--rails-root PATH", "Rails source checkout root for fixture/dev analysis") { |path| options[:rails_root] = path }
          parser.on("--scan ROOTS", "Comma-separated app-relative roots to scan") { |roots| options[:scan_roots] = split_csv(roots) }
          parser.on("--frameworks NAMES", "Comma-separated Rails framework directories to scan") { |names| options[:frameworks] = split_csv(names) }
          parser.on("--runtime-evidence PATHS", "Comma-separated runtime evidence JSON files") { |paths| options[:runtime_evidence_paths] = split_csv(paths) }
          parser.on("--coverage PATH", "Coverage manifest used for deterministic profile context") { |path| options[:coverage_path] = path }
          parser.on("-h", "--help", "Print help") do
            puts parser
            exit 0
          end
        end

        parser.parse!(@argv)

        options[:rails_root] ||= ENV["RAILS_ROOT_FOR_PRUNER"]
        raise ArgumentError, "--profile is required" if blank?(options[:profile_path])
        raise ArgumentError, "--app is required" if blank?(options[:app_root])

        options
      end

      def parse_apply_boot_plan_options
        options = {
          app_root: nil,
          rails_root: nil,
          scan_roots: AppUsage::DEFAULT_SCAN_ROOTS,
          frameworks: ConstantIndex::DEFAULT_FRAMEWORKS,
          profile_path: nil,
          runtime_evidence_paths: [],
          write_patch: nil,
          json: false,
        }

        parser = OptionParser.new do |parser|
          parser.banner = "Usage: rails-dependency-pruner apply boot-plan [options]"
          parser.on("--profile PATH", "Profile used for review context") { |path| options[:profile_path] = path }
          parser.on("--app PATH", "Rails app root") { |path| options[:app_root] = path }
          parser.on("--rails-root PATH", "Rails source checkout root for fixture/dev analysis") { |path| options[:rails_root] = path }
          parser.on("--scan ROOTS", "Comma-separated app-relative roots to scan") { |roots| options[:scan_roots] = split_csv(roots) }
          parser.on("--frameworks NAMES", "Comma-separated Rails framework directories to scan") { |names| options[:frameworks] = split_csv(names) }
          parser.on("--runtime-evidence PATHS", "Comma-separated runtime evidence JSON files") { |paths| options[:runtime_evidence_paths] = split_csv(paths) }
          parser.on("--write-patch PATH", "Write a reviewed boot-plan patch") { |path| options[:write_patch] = path }
          parser.on("--json", "Print JSON output") { options[:json] = true }
          parser.on("-h", "--help", "Print help") do
            puts parser
            exit 0
          end
        end

        parser.parse!(@argv)

        options[:rails_root] ||= ENV["RAILS_ROOT_FOR_PRUNER"]
        raise ArgumentError, "--profile is required" if blank?(options[:profile_path])
        raise ArgumentError, "--app is required" if blank?(options[:app_root])

        options
      end

      def parse_measure_boot_options
        options = {
          app_root: nil,
          variants: %w[baseline],
          runs: 5,
          output_path: nil,
          json: false,
        }

        parser = OptionParser.new do |parser|
          parser.banner = "Usage: rails-dependency-pruner measure boot [options]"
          parser.on("--app PATH", "Rails app root") { |path| options[:app_root] = path }
          parser.on("--variants NAMES", "Comma-separated variant names") { |names| options[:variants] = split_csv(names) }
          parser.on("--runs N", Integer, "Runs per variant") { |runs| options[:runs] = runs }
          parser.on("--output PATH", "Write measurement JSON") { |path| options[:output_path] = path }
          parser.on("--json", "Print JSON output") { options[:json] = true }
          parser.on("-h", "--help", "Print help") do
            puts parser
            exit 0
          end
        end

        parser.parse!(@argv)

        raise ArgumentError, "--app is required" if blank?(options[:app_root])
        raise ArgumentError, "--runs must be positive" unless options.fetch(:runs).positive?
        raise ArgumentError, "--variants must not be empty" if options.fetch(:variants).empty?

        options
      end

      def print_index(index)
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

      def print_audit(planner, profile_path:, shim_path:)
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
        print_runtime_memory(planner.runtime_memory_summary)
        puts
        puts "Profile written to: #{profile_path}" if profile_path
        puts "Shim written to: #{shim_path}" if shim_path
        puts "Use --json for the full dependency tree and constant lists."
      end

      def split_csv(value)
        value.split(",").map(&:strip).reject(&:empty?)
      end

      def blank?(value)
        value.nil? || value.to_s.empty?
      end

      def help
        <<~HELP
          Usage: rails-dependency-pruner [index|audit] [options]

          Commands:
            index  Build a Rails constant dependency tree
            audit  Scan an app and find unused Rails constants
            apply boot-plan  Write a reviewed patch replacing rails/all
            explain CONSTANT  Explain why a Rails constant is used or unused
            measure boot  Measure boot memory in fresh processes
            profile validate  Validate a deterministic profile against current inputs

          Required:
            --app PATH                 Required for audit

          Useful options:
            --json
            --no-tree
            --no-unused
            --rails-root PATH          Optional checkout override; installed Rails 8.x gems are used by default
            --runtime-evidence PATHS
            --coverage PATH
            --write-profile PATH
            --deterministic
            --mode MODE
            --write-shim PATH
        HELP
      end

      def profile_help
        <<~HELP
          Usage: rails-dependency-pruner profile validate [options]

          Required:
            --profile PATH
            --app PATH

          Useful options:
            --rails-root PATH          Optional checkout override; installed Rails 8.x gems are used by default
            --scan ROOTS
            --frameworks NAMES
            --runtime-evidence PATHS
            --coverage PATH
        HELP
      end

      def apply_help
        <<~HELP
          Usage: rails-dependency-pruner apply boot-plan [options]

          Required:
            --profile PATH
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

      def print_runtime_memory(summary)
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

      def print_explanation(explanation)
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

      def print_boot_plan(boot_plan, patch_path:)
        puts "Required frameworks:"
        boot_plan.required_frameworks.each { |framework| puts "  #{framework}" }
        puts
        puts "Pruned frameworks:"
        boot_plan.pruned_frameworks.each { |framework| puts "  #{framework}" }
        puts
        puts "Patch written to: #{patch_path}" if patch_path
      end

      def print_measurement(report, output_path:)
        report.fetch("variants").each do |variant, summary|
          puts "#{variant}: #{summary.fetch("status")}"
          next unless summary.fetch("status") == "ok"

          puts "  RSS median: #{summary.fetch("rss_kb_median")} KB"
          puts "  Rails loaded features median: #{summary.fetch("rails_loaded_features_median")}"
          puts "  GC live slots median: #{summary.fetch("gc_heap_live_slots_median")}"
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
      end
  end
end
