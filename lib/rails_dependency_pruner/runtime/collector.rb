# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"

require_relative "../coverage_manifest"

module RailsDependencyPruner
  module Runtime
    class Collector
      RAILS_GEM_NAMES = %w[
        actioncable
        actionmailbox
        actionmailer
        actionpack
        actiontext
        actionview
        activejob
        activemodel
        activerecord
        activestorage
        activesupport
        railties
      ].freeze

      DEFAULT_SCRIPT = <<~'RUBY'
        app_root = ARGV.fetch(0)
        require File.join(app_root, "config/application")
        if defined?(RailsDependencyPruner::RuntimeRecorder)
          RailsDependencyPruner::RuntimeRecorder.snapshot!("after_application_load")
        end
      RUBY

      INSTALLED_RAILS_ROOTS_SCRIPT = <<~'RUBY'
        roots = ARGV.filter_map do |name|
          spec = Gem.loaded_specs[name]
          spec&.full_gem_path
        end
        puts roots.uniq.join(File::PATH_SEPARATOR)
      RUBY

      attr_reader :app_root, :output_path, :coverage_path, :command, :rails_root

      def initialize(app_root:, output_path:, coverage_path: nil, command: nil, rails_root: nil)
        @app_root = Pathname.new(app_root).expand_path
        @output_path = Pathname.new(output_path).expand_path
        @coverage_path = coverage_path && resolve_app_path(coverage_path)
        @command = command
        @rails_root = rails_root
      end

      def run
        FileUtils.mkdir_p(output_path.dirname)
        stdout, stderr, status = run_command

        {
          "status" => status.success? && output_path.file? ? "ok" : "error",
          "exitstatus" => status.exitstatus,
          "output_path" => output_path.to_s,
          "coverage" => coverage_payload,
          "command" => command_payload,
          "stdout" => stdout,
          "stderr" => stderr,
        }
      end

      private
        def run_command
          if command
            Open3.capture3(environment, command, chdir: app_root.to_s)
          else
            Open3.capture3(environment, *default_command, chdir: app_root.to_s)
          end
        end

        def default_command
          ruby_command + ["-e", DEFAULT_SCRIPT, app_root.to_s]
        end

        def ruby_command
          app_root.join("Gemfile").file? ? ["bundle", "exec", "ruby"] : [Gem.ruby]
        end

        def environment
          {
            "BUNDLE_GEMFILE" => bundle_gemfile,
            "RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT" => output_path.to_s,
            "RAILS_DEPENDENCY_PRUNER_RAILS_ROOT" => rails_roots_env,
            "RAILS_DEPENDENCY_PRUNER_SNAPSHOTS" => "1",
            "RAILS_DEPENDENCY_PRUNER_TRACE_REQUIRES" => "1",
            "RUBYLIB" => ruby_lib,
            "RUBYOPT" => rubyopt,
          }.compact
        end

        def bundle_gemfile
          path = app_root.join("Gemfile")
          path.to_s if path.file?
        end

        def ruby_lib
          [File.expand_path("../..", __dir__), ENV["RUBYLIB"]].compact.reject(&:empty?).join(File::PATH_SEPARATOR)
        end

        def rubyopt
          [ENV["RUBYOPT"], "-rrails_dependency_pruner/runtime_recorder"].compact.reject(&:empty?).join(" ")
        end

        def rails_roots_env
          explicit_rails_roots_env || installed_rails_roots_env
        end

        def explicit_rails_roots_env
          return if rails_root.nil? || rails_root.empty?

          rails_root.split(File::PATH_SEPARATOR).map do |path|
            resolve_app_path(path)
          end.join(File::PATH_SEPARATOR)
        end

        def installed_rails_roots_env
          return unless app_root.join("Gemfile").file?

          stdout, _stderr, status = Open3.capture3(
            { "BUNDLE_GEMFILE" => bundle_gemfile }.compact,
            "bundle",
            "exec",
            "ruby",
            "-e",
            INSTALLED_RAILS_ROOTS_SCRIPT,
            *RAILS_GEM_NAMES,
            chdir: app_root.to_s,
          )
          roots = stdout.strip
          roots if status.success? && !roots.empty?
        end

        def coverage_payload
          return unless coverage_path

          CoverageManifest.load(coverage_path).to_h
        end

        def command_payload
          command || default_command.join(" ")
        end

        def resolve_app_path(path)
          pathname = Pathname.new(path)
          pathname.absolute? ? pathname.expand_path : app_root.join(pathname).expand_path
        end
    end
  end
end
