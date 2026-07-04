# frozen_string_literal: true

require "fileutils"
require "pathname"

module RailsDependencyPruner
  module Apply
    class EarlyBootPatch
      TARGET = "config/boot.rb"
      SHIM_REQUIRE = "rails_dependency_pruner/early_boot"
      BUNDLER_REQUIRE = /\A\s*require\s+["']bundler\/setup["']/

      attr_reader :app_root, :env_var

      def initialize(app_root:, env_var: "RAILS_DEPENDENCY_PRUNER_EARLY")
        @app_root = Pathname.new(app_root).expand_path
        @env_var = env_var
      end

      def write(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end

      def to_h
        {
          "target" => TARGET,
          "status" => status,
          "env_var" => env_var,
          "reason" => reason,
        }.compact
      end

      def source
        case status
        when "patch_available"
          insertion_patch
        when "already_installed"
          no_change_patch("early boot shim already installed")
        else
          no_change_patch("require \"bundler/setup\" not found")
        end
      end

      private
        def status
          @status ||= begin
            raise ArgumentError, "#{TARGET} does not exist" unless path.file?

            if lines.any? { |line| line.include?(SHIM_REQUIRE) }
              "already_installed"
            elsif bundler_line_index
              "patch_available"
            else
              "missing_bundler_setup"
            end
          end
        end

        def reason
          case status
          when "already_installed"
            "early boot shim already installed"
          when "missing_bundler_setup"
            "require \"bundler/setup\" not found"
          end
        end

        def insertion_patch
          line_number = bundler_line_index + 2

          [
            "--- a/#{TARGET}",
            "+++ b/#{TARGET}",
            "@@ -#{line_number},0 +#{line_number},1 @@",
            "+#{shim_line}",
            "",
          ].join("\n")
        end

        def no_change_patch(message)
          [
            "--- a/#{TARGET}",
            "+++ b/#{TARGET}",
            "@@ -1,0 +1,2 @@",
            "+# rails_dependency_pruner: #{message}",
            "+# no early-boot shim patch generated",
            "",
          ].join("\n")
        end

        def shim_line
          "require #{SHIM_REQUIRE.dump} if ENV[#{env_var.dump}] == \"1\""
        end

        def bundler_line_index
          @bundler_line_index ||= lines.index { |line| line.match?(BUNDLER_REQUIRE) }
        end

        def lines
          @lines ||= File.readlines(path, chomp: true)
        end

        def path
          app_root.join(TARGET)
        end
    end
  end
end
