# frozen_string_literal: true

require "fileutils"
require "pathname"

module RailsDependencyPruner
  module Apply
    class BootPlanPatch
      attr_reader :app_root, :boot_plan

      def initialize(app_root:, boot_plan:)
        @app_root = Pathname.new(app_root).expand_path
        @boot_plan = boot_plan
      end

      def write(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end

      def source
        relative = "config/application.rb"
        path = app_root.join(relative)
        lines = File.readlines(path, chomp: true)
        line_index = lines.index { |line| line.match?(/\A\s*require\s+["']rails\/all["']\s*\z/) }
        return rails_all_patch(relative, lines, line_index) if line_index

        explicit_require_patch(relative, lines)
      end

      private
        def rails_all_patch(relative, lines, line_index)
        original = lines.fetch(line_index)
        replacement = boot_plan.replacement_lines

        [
          "--- a/#{relative}",
          "+++ b/#{relative}",
          "@@ -#{line_index + 1},1 +#{line_index + 1},#{replacement.length} @@",
          "-#{original}",
          *replacement.map { |line| "+#{line}" },
          "",
        ].join("\n")
      end

        def explicit_require_patch(relative, lines)
          replacements = explicit_replacements(lines)
          return no_change_patch(relative) if replacements.empty?

          hunks = replacements.map do |line_index, original, replacement|
            [
              "@@ -#{line_index + 1},1 +#{line_index + 1},2 @@",
              "-#{original}",
              "+# rails_dependency_pruner: pruned by boot plan",
              "+#{replacement}",
            ]
          end

          [
            "--- a/#{relative}",
            "+++ b/#{relative}",
            *hunks.flatten,
            "",
          ].join("\n")
        end

        def explicit_replacements(lines)
          pruned_require_paths = boot_plan.pruned_frameworks.filter_map do |framework|
            BootPlan::RAILTIE_REQUIRE_PATHS[framework]
          end

          lines.each_with_index.filter_map do |line, index|
            require_path = pruned_require_paths.find do |path|
              line.match?(/\A\s*require\s+#{Regexp.escape(path.dump)}\s*\z/)
            end
            next unless require_path

            [index, line, "# #{line}"]
          end
        end

        def no_change_patch(relative)
          [
            "--- a/#{relative}",
            "+++ b/#{relative}",
            "@@ -1,0 +1,2 @@",
            "+# rails_dependency_pruner: no active prunable framework require found",
            "+# no boot-plan patch generated",
            "",
          ].join("\n")
        end
    end
  end
end
