# frozen_string_literal: true

require "pathname"

module RailsDependencyPruner
  class Doctor
    attr_reader :app_root

    def initialize(app_root:)
      @app_root = Pathname.new(app_root).expand_path
    end

    def report
      {
        "app_root" => app_root.to_s,
        "recommendations" => recommendations,
      }
    end

    def recommendations
      @recommendations ||= [
        ruby_version_recommendation,
        rails_all_recommendation,
        autoload_paths_recommendation,
        autoload_lib_recommendation,
      ].compact
    end

    private
      def ruby_version_recommendation
        ruby_version_path = app_root.join(".ruby-version")
        return unless ruby_version_path.file?

        expected = ruby_version_path.read.strip
        return if expected.empty? || expected == RUBY_VERSION

        recommendation(
          "ruby_version_mismatch",
          "warning",
          "Current Ruby does not match .ruby-version",
          "Expected #{expected}, current #{RUBY_VERSION}. Boot measurement may fail until the exact Ruby is installed.",
        )
      end

      def rails_all_recommendation
        return unless application_source.match?(/^\s*require\s+["']rails\/all["']\s*$/)

        recommendation(
          "replace_rails_all",
          "warning",
          "Replace rails/all with explicit framework railties",
          "Run apply boot-plan and review the generated patch before committing.",
        )
      end

      def autoload_paths_recommendation
        return if application_source.include?("config.add_autoload_paths_to_load_path = false")

        recommendation(
          "disable_autoload_paths_load_path",
          "info",
          "Set config.add_autoload_paths_to_load_path = false",
          "This avoids adding autoload paths to Ruby's $LOAD_PATH and can reduce require lookup and Bootsnap work.",
        )
      end

      def autoload_lib_recommendation
        return unless app_root.join("lib").directory?
        return if application_source.include?("config.autoload_lib(")

        ignored_dirs = app_root.join("lib").children.select(&:directory?).map { |path| path.basename.to_s }.sort
        return if ignored_dirs.empty?

        recommendation(
          "use_autoload_lib_ignore",
          "info",
          "Consider config.autoload_lib(ignore:) for non-code lib directories",
          "Candidate lib directories: #{ignored_dirs.join(", ")}.",
        )
      end

      def application_source
        @application_source ||= begin
          path = app_root.join("config/application.rb")
          path.file? ? path.read : ""
        end
      end

      def recommendation(id, severity, title, detail)
        {
          "id" => id,
          "severity" => severity,
          "title" => title,
          "detail" => detail,
        }
      end
  end
end
