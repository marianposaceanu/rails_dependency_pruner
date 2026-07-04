# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"

require_relative "app_usage"
require_relative "constant_index"
require_relative "planner"
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
      when "index"
        run_index
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

      def run_audit
        options = parse_options(require_app: true)
        index = ConstantIndex.build(rails_root: options.fetch(:rails_root), frameworks: options.fetch(:frameworks))
        usage = AppUsage.scan(app_root: options.fetch(:app_root), index: index, scan_roots: options.fetch(:scan_roots))
        planner = Planner.new(index: index, usage: usage)

        if options[:write_shim]
          ShimWriter.new(planner.unused_constants).write(options[:write_shim])
        end

        payload = planner.to_h(
          include_tree: options.fetch(:include_tree),
          include_unused: options.fetch(:include_unused),
        )

        if options.fetch(:json)
          puts JSON.pretty_generate(payload)
        else
          print_audit(planner, shim_path: options[:write_shim])
        end

        0
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
        }

        parser = OptionParser.new do |parser|
          parser.banner = "Usage: rails-dependency-pruner [index|audit] [options]"
          parser.on("--rails-root PATH", "Rails source checkout root") { |path| options[:rails_root] = path }
          parser.on("--app PATH", "Rails app root to scan") { |path| options[:app_root] = path }
          parser.on("--scan ROOTS", "Comma-separated app-relative roots to scan") { |roots| options[:scan_roots] = split_csv(roots) }
          parser.on("--frameworks NAMES", "Comma-separated Rails framework directories to scan") { |names| options[:frameworks] = split_csv(names) }
          parser.on("--[no-]tree", "Include dependency tree in JSON output") { |value| options[:include_tree] = value }
          parser.on("--[no-]unused", "Include full unused constants list in JSON output") { |value| options[:include_unused] = value }
          parser.on("--json", "Print JSON output") { options[:json] = true }
          parser.on("--write-shim PATH", "Write a fail-fast shim for unused constants") { |path| options[:write_shim] = path }
          parser.on("-h", "--help", "Print help") do
            puts parser
            exit 0
          end
        end

        parser.parse!(@argv)

        options[:rails_root] ||= ENV["RAILS_ROOT_FOR_PRUNER"]
        raise ArgumentError, "--rails-root is required" if blank?(options[:rails_root])
        raise ArgumentError, "--app is required for audit" if require_app && blank?(options[:app_root])

        options
      end

      def print_index(index)
        payload = index.to_h(include_tree: false)

        puts "Rails dependency index for #{payload.fetch(:rails_root)}"
        puts "Scanned Ruby files: #{payload.fetch(:files_scanned)}"
        puts "Rails constants indexed: #{payload.fetch(:constants_count)}"
        puts "Parse errors: #{payload.fetch(:parse_errors).length}"
        puts
        puts "Constants by component:"
        payload.fetch(:components).each do |component, count|
          puts "  #{component}: #{count}"
        end
      end

      def print_audit(planner, shim_path:)
        payload = planner.to_h(include_tree: false, include_unused: false)

        puts "Rails dependency audit for #{payload.fetch(:app_root)}"
        puts "Rails source: #{payload.fetch(:rails_root)}"
        puts "Rails files scanned: #{payload.fetch(:rails_files_scanned)}"
        puts "App files scanned: #{payload.fetch(:app_files_scanned)}"
        puts "Rails constants indexed: #{payload.fetch(:rails_constants_count)}"
        puts "Direct app Rails constants: #{payload.fetch(:direct_rails_constants_count)}"
        puts "Reachable Rails constants: #{payload.fetch(:used_constants_count)}"
        puts "Unused Rails constants: #{payload.fetch(:unused_constants_count)}"
        puts "Rails parse errors: #{payload.dig(:parse_errors, :rails).length}"
        puts "App parse errors: #{payload.dig(:parse_errors, :app).length}"
        puts
        puts "Top unused namespaces:"
        payload.fetch(:top_unused_namespaces).first(20).each do |namespace, count|
          puts "  #{namespace}: #{count}"
        end
        puts
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

          Required:
            --rails-root PATH
            --app PATH                 Required for audit

          Useful options:
            --json
            --no-tree
            --no-unused
            --write-shim PATH
        HELP
      end
  end
end

