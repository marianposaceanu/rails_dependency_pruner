# frozen_string_literal: true

require "optparse"

module RailsDependencyPruner
  class CLI
    class Options
      attr_reader :argv

      def initialize(argv)
        @argv = argv
      end

      def audit(require_app:)
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

        parser.parse!(argv)

        options[:rails_root] ||= ENV["RAILS_ROOT_FOR_PRUNER"]
        raise ArgumentError, "--app is required for audit" if require_app && blank?(options[:app_root])

        options
      end

      def profile_validate
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

        parser.parse!(argv)
        options[:rails_root] ||= ENV["RAILS_ROOT_FOR_PRUNER"]
        raise ArgumentError, "--profile is required" if blank?(options[:profile_path])
        raise ArgumentError, "--app is required" if blank?(options[:app_root])

        options
      end

      def profile_build
        options = {
          app_root: nil,
          rails_root: nil,
          scan_roots: AppUsage::DEFAULT_SCAN_ROOTS,
          frameworks: ConstantIndex::DEFAULT_FRAMEWORKS,
          runtime_evidence_paths: [],
          coverage_path: nil,
          mode: "guard",
          write_path: nil,
          json: false,
        }

        parser = OptionParser.new do |parser|
          parser.banner = "Usage: rails-dependency-pruner profile build [options]"
          parser.on("--app PATH", "Rails app root") { |path| options[:app_root] = path }
          parser.on("--rails-root PATH", "Rails source checkout root for fixture/dev analysis") { |path| options[:rails_root] = path }
          parser.on("--scan ROOTS", "Comma-separated app-relative roots to scan") { |roots| options[:scan_roots] = split_csv(roots) }
          parser.on("--frameworks NAMES", "Comma-separated Rails framework directories to scan") { |names| options[:frameworks] = split_csv(names) }
          parser.on("--runtime-evidence PATHS", "Comma-separated runtime evidence JSON files") { |paths| options[:runtime_evidence_paths] = split_csv(paths) }
          parser.on("--coverage PATH", "Coverage manifest used for deterministic profile context") { |path| options[:coverage_path] = path }
          parser.on("--mode MODE", "Profile mode") { |mode| options[:mode] = mode }
          parser.on("--write PATH", "Write deterministic profile") { |path| options[:write_path] = path }
          parser.on("--json", "Print JSON output") { options[:json] = true }
          parser.on("-h", "--help", "Print help") do
            puts parser
            exit 0
          end
        end

        parser.parse!(argv)
        options[:rails_root] ||= ENV["RAILS_ROOT_FOR_PRUNER"]
        raise ArgumentError, "--app is required" if blank?(options[:app_root])
        raise ArgumentError, "--write is required" if blank?(options[:write_path])

        options
      end

      def explain
        options = {
          app_root: nil,
          rails_root: nil,
          scan_roots: AppUsage::DEFAULT_SCAN_ROOTS,
          frameworks: ConstantIndex::DEFAULT_FRAMEWORKS,
          runtime_evidence_paths: [],
          profile_path: nil,
          json: false,
        }

        parser = OptionParser.new do |parser|
          parser.banner = "Usage: rails-dependency-pruner explain TARGET [options]"
          parser.on("--profile PATH", "Read explanation from an existing profile") { |path| options[:profile_path] = path }
          parser.on("--app PATH", "Rails app root to scan when --profile is not used") { |path| options[:app_root] = path }
          parser.on("--rails-root PATH", "Rails source checkout root for fixture/dev analysis") { |path| options[:rails_root] = path }
          parser.on("--scan ROOTS", "Comma-separated app-relative roots to scan") { |roots| options[:scan_roots] = split_csv(roots) }
          parser.on("--frameworks NAMES", "Comma-separated Rails framework directories to scan") { |names| options[:frameworks] = split_csv(names) }
          parser.on("--runtime-evidence PATHS", "Comma-separated runtime evidence JSON files") { |paths| options[:runtime_evidence_paths] = split_csv(paths) }
          parser.on("--json", "Print JSON output") { options[:json] = true }
          parser.on("-h", "--help", "Print help") do
            puts parser
            exit 0
          end
        end

        parser.parse!(argv)
        options[:rails_root] ||= ENV["RAILS_ROOT_FOR_PRUNER"]
        raise ArgumentError, "--app is required when --profile is not used" if blank?(options[:profile_path]) && blank?(options[:app_root])

        options
      end

      def plan
        options = {
          app_root: Dir.pwd,
          rails_root: nil,
          scan_roots: AppUsage::DEFAULT_SCAN_ROOTS,
          frameworks: ConstantIndex::DEFAULT_FRAMEWORKS,
          runtime_evidence_paths: [],
          coverage_path: nil,
          profile_path: nil,
          patch_path: nil,
          json: false,
        }

        parser = OptionParser.new do |parser|
          parser.banner = "Usage: rails-dependency-pruner plan [options]"
          parser.on("--app PATH", "Rails app root; defaults to current directory") { |path| options[:app_root] = path }
          parser.on("--profile PATH", "Write deterministic profile; defaults to config/rails_dependency_pruner_profile.json") { |path| options[:profile_path] = path }
          parser.on("--write PATH", "Alias for --profile") { |path| options[:profile_path] = path }
          parser.on("--patch PATH", "Write a reviewed boot-plan patch") { |path| options[:patch_path] = path }
          parser.on("--rails-root PATH", "Rails source checkout root for fixture/dev analysis") { |path| options[:rails_root] = path }
          parser.on("--scan ROOTS", "Comma-separated app-relative roots to scan") { |roots| options[:scan_roots] = split_csv(roots) }
          parser.on("--frameworks NAMES", "Comma-separated Rails framework directories to scan") { |names| options[:frameworks] = split_csv(names) }
          parser.on("--runtime-evidence PATHS", "Comma-separated runtime evidence JSON files") { |paths| options[:runtime_evidence_paths] = split_csv(paths) }
          parser.on("--coverage PATH", "Coverage manifest used for deterministic profile context") { |path| options[:coverage_path] = path }
          parser.on("--json", "Print JSON output") { options[:json] = true }
          parser.on("-h", "--help", "Print help") do
            puts parser
            exit 0
          end
        end

        parser.parse!(argv)
        options[:rails_root] ||= ENV["RAILS_ROOT_FOR_PRUNER"]
        options[:app_root] = File.expand_path(options.fetch(:app_root))
        options[:profile_path] = app_relative_path(
          options.fetch(:app_root),
          options[:profile_path] || "config/rails_dependency_pruner_profile.json",
        )
        options[:patch_path] = app_relative_path(options.fetch(:app_root), options[:patch_path]) if options[:patch_path]

        options
      end

      def profile_diff
        options = {
          old_profile_path: nil,
          new_profile_path: nil,
          json: false,
        }

        parser = OptionParser.new do |parser|
          parser.banner = "Usage: rails-dependency-pruner profile diff [options]"
          parser.on("--old PATH", "Previous profile") { |path| options[:old_profile_path] = path }
          parser.on("--new PATH", "New profile") { |path| options[:new_profile_path] = path }
          parser.on("--json", "Print JSON output") { options[:json] = true }
          parser.on("-h", "--help", "Print help") do
            puts parser
            exit 0
          end
        end

        parser.parse!(argv)
        raise ArgumentError, "--old is required" if blank?(options[:old_profile_path])
        raise ArgumentError, "--new is required" if blank?(options[:new_profile_path])

        options
      end

      def verify
        options = {
          app_root: nil,
          rails_root: nil,
          scan_roots: AppUsage::DEFAULT_SCAN_ROOTS,
          frameworks: ConstantIndex::DEFAULT_FRAMEWORKS,
          profile_path: nil,
          coverage_path: nil,
          runtime_evidence_paths: [],
          production: false,
          json: false,
        }

        parser = OptionParser.new do |parser|
          parser.banner = "Usage: rails-dependency-pruner verify [options]"
          parser.on("--profile PATH", "Profile to verify") { |path| options[:profile_path] = path }
          parser.on("--app PATH", "Rails app root") { |path| options[:app_root] = path }
          parser.on("--rails-root PATH", "Rails source checkout root for fixture/dev analysis") { |path| options[:rails_root] = path }
          parser.on("--scan ROOTS", "Comma-separated app-relative roots to scan") { |roots| options[:scan_roots] = split_csv(roots) }
          parser.on("--frameworks NAMES", "Comma-separated Rails framework directories to scan") { |names| options[:frameworks] = split_csv(names) }
          parser.on("--runtime-evidence PATHS", "Comma-separated runtime evidence JSON files") { |paths| options[:runtime_evidence_paths] = split_csv(paths) }
          parser.on("--coverage PATH", "Coverage manifest used for deterministic profile context") { |path| options[:coverage_path] = path }
          parser.on("--production", "Require production verification gates") { options[:production] = true }
          parser.on("--json", "Print JSON output") { options[:json] = true }
          parser.on("-h", "--help", "Print help") do
            puts parser
            exit 0
          end
        end

        parser.parse!(argv)
        options[:rails_root] ||= ENV["RAILS_ROOT_FOR_PRUNER"]
        raise ArgumentError, "--profile is required" if blank?(options[:profile_path])
        raise ArgumentError, "--app is required" if blank?(options[:app_root])

        options
      end

      def doctor
        options = {
          app_root: nil,
          json: false,
        }

        parser = OptionParser.new do |parser|
          parser.banner = "Usage: rails-dependency-pruner doctor [options]"
          parser.on("--app PATH", "Rails app root") { |path| options[:app_root] = path }
          parser.on("--json", "Print JSON output") { options[:json] = true }
          parser.on("-h", "--help", "Print help") do
            puts parser
            exit 0
          end
        end

        parser.parse!(argv)
        raise ArgumentError, "--app is required" if blank?(options[:app_root])

        options
      end

      def apply_boot_plan
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

        parser.parse!(argv)
        options[:rails_root] ||= ENV["RAILS_ROOT_FOR_PRUNER"]
        raise ArgumentError, "--profile is required" if blank?(options[:profile_path])
        raise ArgumentError, "--app is required" if blank?(options[:app_root])

        options
      end

      def apply_early_boot_shim
        options = {
          app_root: nil,
          write_patch: nil,
          json: false,
        }

        parser = OptionParser.new do |parser|
          parser.banner = "Usage: rails-dependency-pruner apply early-boot-shim [options]"
          parser.on("--app PATH", "Rails app root") { |path| options[:app_root] = path }
          parser.on("--write-patch PATH", "Write a reviewed config/boot.rb patch") { |path| options[:write_patch] = path }
          parser.on("--json", "Print JSON output") { options[:json] = true }
          parser.on("-h", "--help", "Print help") do
            puts parser
            exit 0
          end
        end

        parser.parse!(argv)
        raise ArgumentError, "--app is required" if blank?(options[:app_root])

        options
      end

      def measure_boot
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

        parser.parse!(argv)
        raise ArgumentError, "--app is required" if blank?(options[:app_root])
        raise ArgumentError, "--runs must be positive" unless options.fetch(:runs).positive?
        raise ArgumentError, "--variants must not be empty" if options.fetch(:variants).empty?

        options
      end

      private
        def split_csv(value)
          value.split(",").map(&:strip).reject(&:empty?)
        end

        def app_relative_path(app_root, path)
          File.absolute_path(path, app_root)
        end

        def blank?(value)
          value.nil? || value.to_s.empty?
        end
    end
  end
end
