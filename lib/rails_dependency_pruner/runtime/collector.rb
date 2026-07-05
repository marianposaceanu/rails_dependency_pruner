# frozen_string_literal: true

require "fileutils"
require "json"
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
        require "json"

        def runtime_request_entries
          JSON.parse(ENV.fetch("RAILS_DEPENDENCY_PRUNER_RUNTIME_REQUESTS", "[]"))
        rescue JSON::ParserError
          []
        end

        def runtime_snapshot!(phase)
          return unless defined?(RailsDependencyPruner::RuntimeRecorder)

          RailsDependencyPruner::RuntimeRecorder.snapshot!(phase)
        end

        def initialize_rails_app!
          return unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          return if Rails.application.respond_to?(:initialized?) && Rails.application.initialized?

          Rails.application.initialize!
        end

        def collect_request_runtime(request_entries)
          return [] if request_entries.empty?
          return [] unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

          require "rack/mock"
          initialize_rails_app!
          request = Rack::MockRequest.new(Rails.application)
          request_entries.map do |entry|
            method = entry.fetch("method", "GET").to_s.upcase
            path = entry.fetch("path")
            response = request.request(method, path, "HTTP_HOST" => "example.org", "HTTPS" => "on")
            runtime_snapshot!("after_request:#{method} #{path}")
            {
              "method" => method,
              "path" => path,
              "status" => response.status,
              "bytes" => response.body.bytesize,
              "location" => response["Location"],
            }.compact
          rescue => error
            runtime_snapshot!("after_request_error:#{method} #{path}")
            {
              "method" => method,
              "path" => path,
              "error" => error.class.name,
              "message" => error.message,
            }
          end
        end

        app_root = ARGV.fetch(0)
        request_entries = runtime_request_entries
        require File.join(app_root, "config/application")
        initialize_rails_app! unless request_entries.empty?
        runtime_snapshot!("after_application_load")
        requests = collect_request_runtime(request_entries)
        puts JSON.generate("requests" => requests) unless requests.empty?
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
          "requests" => request_summary(stdout),
          "stdout" => stdout,
          "stderr" => stderr,
        }.compact
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
            "RAILS_DEPENDENCY_PRUNER_RUNTIME_REQUESTS" => runtime_requests_json,
            "RAILS_DEPENDENCY_PRUNER_RAILS_ROOT" => rails_roots_env,
            "RAILS_DEPENDENCY_PRUNER_SNAPSHOTS" => "1",
            "RAILS_DEPENDENCY_PRUNER_TRACE_REQUIRES" => "1",
            "RAILS_ENV" => coverage_rails_env,
            "RACK_ENV" => coverage_rails_env,
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

        def coverage_manifest
          @coverage_manifest ||= coverage_path && CoverageManifest.load(coverage_path)
        end

        def coverage_rails_env
          value = coverage_manifest&.rails_env.to_s
          value.empty? ? nil : value
        end

        def runtime_requests_json
          return if command

          entries = Array(coverage_manifest&.request_entries)
          return if entries.empty?

          JSON.generate(entries)
        end

        def request_summary(stdout)
          stdout.lines.reverse_each do |line|
            candidate = line.strip
            next unless candidate.start_with?("{")

            payload = JSON.parse(candidate)
            requests = payload["requests"]
            return requests if requests.is_a?(Array)
          rescue JSON::ParserError
            next
          end

          nil
        end

        def command_payload
          command || (ruby_command + ["-e", "<runtime collect default>", app_root.to_s]).join(" ")
        end

        def resolve_app_path(path)
          pathname = Pathname.new(path)
          pathname.absolute? ? pathname.expand_path : app_root.join(pathname).expand_path
        end
    end
  end
end
