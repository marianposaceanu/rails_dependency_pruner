# frozen_string_literal: true

require "json"
require "fileutils"
require "pathname"

require_relative "../boot_plan"
require_relative "../coverage_template"
require_relative "../profile"
require_relative "boot_plan_patch"
require_relative "early_boot_patch"

module RailsDependencyPruner
  module Apply
    class RolloutPatch
      PROFILE_TARGET = "config/rails_dependency_pruner_profile.json"
      COVERAGE_TARGET = "config/pruner_coverage.yml"
      PRODUCTION_ENV_TARGET = "config/environments/production.rb"

      attr_reader :app_root, :profile_path, :coverage_path, :profile_target, :coverage_target, :rails_env

      def initialize(app_root:, profile_path:, coverage_path: nil, profile_target: PROFILE_TARGET, coverage_target: COVERAGE_TARGET, rails_env: CoverageTemplate::DEFAULT_RAILS_ENV)
        @app_root = Pathname.new(app_root).expand_path
        @profile_path = Pathname.new(profile_path).expand_path
        @coverage_path = coverage_path && Pathname.new(coverage_path).expand_path
        @profile_target = profile_target.to_s
        @coverage_target = coverage_target.to_s
        @rails_env = rails_env.to_s
      end

      def write(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end

      def to_h
        {
          "profile_id" => profile.profile_id,
          "profile_source" => profile_path.to_s,
          "profile_target" => profile_target,
          "coverage_source" => coverage_source_label,
          "coverage_target" => coverage_target,
          "rails_env" => rails_env,
          "sections" => sections,
        }
      end

      def source
        patch_entries.map { |_section, patch_source| patch_source }.join("\n")
      end

      private
        def profile
          @profile ||= Profile.load(profile_path)
        end

        def boot_plan
          payload = profile.payload["boot_plan"]
          return nil unless payload.is_a?(Hash) && !payload.empty?

          BootPlan.new(
            required_frameworks: Array(payload["required_frameworks"]),
            pruned_frameworks: Array(payload["pruned_frameworks"]),
            autoload_ignores: Array(payload["autoload_ignores"]),
            eager_load_ignores: Array(payload["eager_load_ignores"]),
          )
        end

        def boot_plan_patch_source
          return nil unless boot_plan

          source = BootPlanPatch.new(app_root: app_root, boot_plan: boot_plan).source
          return nil if source.include?("no boot-plan patch generated")

          source
        end

        def early_boot_patch_source
          source = EarlyBootPatch.new(app_root: app_root).source
          return nil if source.include?("no early-boot shim patch generated")

          source
        end

        def production_config_patch_source
          path = app_root.join(PRODUCTION_ENV_TARGET)
          return file_patch(PRODUCTION_ENV_TARGET, production_config_source) unless path.file?

          lines = File.readlines(path, chomp: true)
          return nil if lines.any? { |line| line.include?("rails_dependency_pruner") }

          configure_index = lines.index { |line| line.match?(/\A\s*Rails\.application\.configure\s+do\b/) }
          return nil unless configure_index

          line_number = configure_index + 2
          [
            "--- a/#{PRODUCTION_ENV_TARGET}",
            "+++ b/#{PRODUCTION_ENV_TARGET}",
            "@@ -#{line_number},0 +#{line_number},3 @@",
            "+  # rails_dependency_pruner: enable the reviewed production profile.",
            "+  config.rails_dependency_pruner.enabled = true",
            "+  config.rails_dependency_pruner.profile_path = Rails.root.join(#{profile_target.dump})",
            "",
          ].join("\n")
        end

        def production_config_source
          <<~RUBY
            # frozen_string_literal: true

            Rails.application.configure do
              # rails_dependency_pruner: enable the reviewed production profile.
              config.rails_dependency_pruner.enabled = true
              config.rails_dependency_pruner.profile_path = Rails.root.join(#{profile_target.dump})
            end
          RUBY
        end

        def profile_source
          profile.deterministic? ? profile.canonical_json : "#{JSON.pretty_generate(profile.payload)}\n"
        end

        def coverage_source
          if coverage_path
            File.read(coverage_path)
          else
            CoverageTemplate.new(app_root: app_root, rails_env: rails_env).to_yaml
          end
        end

        def coverage_source_label
          coverage_path ? coverage_path.to_s : "generated_template"
        end

        def file_patch(relative, new_content)
          path = app_root.join(relative)
          return nil if path.file? && File.read(path) == new_content

          new_lines = patch_lines(new_content)
          if path.file?
            replace_file_patch(relative, patch_lines(File.read(path)), new_lines)
          else
            add_file_patch(relative, new_lines)
          end
        end

        def replace_file_patch(relative, old_lines, new_lines)
          [
            "--- a/#{relative}",
            "+++ b/#{relative}",
            "@@ -1,#{old_lines.length} +1,#{new_lines.length} @@",
            *old_lines.map { |line| "-#{line}" },
            *new_lines.map { |line| "+#{line}" },
            "",
          ].join("\n")
        end

        def add_file_patch(relative, lines)
          [
            "--- /dev/null",
            "+++ b/#{relative}",
            "@@ -0,0 +1,#{lines.length} @@",
            *lines.map { |line| "+#{line}" },
            "",
          ].join("\n")
        end

        def patch_lines(content)
          content.lines(chomp: true)
        end

        def sections
          patch_entries.map(&:first)
        end

        def patch_entries
          @patch_entries ||= [
            ["boot_plan", boot_plan_patch_source],
            ["early_boot_shim", early_boot_patch_source],
            ["production_config", production_config_patch_source],
            ["profile", file_patch(profile_target, profile_source)],
            ["coverage_manifest", file_patch(coverage_target, coverage_source)],
          ].select { |_section, patch_source| patch_source && !patch_source.empty? }
        end
    end
  end
end
