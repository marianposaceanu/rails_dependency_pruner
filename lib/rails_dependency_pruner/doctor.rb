# frozen_string_literal: true

require "pathname"
require "rbconfig"

require "prism"

require_relative "static/dynamic_constant_visitor"
require_relative "static/require_visitor"

module RailsDependencyPruner
  class Doctor
    SCAN_ROOTS = %w[app config lib engines].freeze
    RAILTIE_FRAMEWORKS = {
      "action_cable/engine" => "actioncable",
      "action_mailbox/engine" => "actionmailbox",
      "action_mailer/railtie" => "actionmailer",
      "action_text/engine" => "actiontext",
      "action_view/railtie" => "actionview",
      "active_job/railtie" => "activejob",
      "active_model/railtie" => "activemodel",
      "active_record/railtie" => "activerecord",
      "active_storage/engine" => "activestorage",
    }.freeze
    ROUTE_CALLS = %w[
      delete
      get
      match
      mount
      patch
      post
      put
      resource
      resources
      root
    ].freeze
    INTEGRATION_GEMS = %w[
      honeybadger
      rack-mini-profiler
      rollbar
      sentry-rails
      sentry-ruby
    ].freeze
    ADAPTER_GEMS = %w[
      bootsnap
      delayed_job
      good_job
      puma
      que
      sidekiq
      spring
    ].freeze
    DIRECT_GEM_USAGE = {
      "vips" => {
        "constants" => %w[Vips],
        "require_paths" => %w[vips],
      },
      "nokogiri" => {
        "constants" => %w[Nokogiri],
        "require_paths" => %w[nokogiri],
      },
      "sentry" => {
        "constants" => %w[Sentry],
        "require_paths" => %w[sentry-ruby sentry-rails],
      },
      "honeybadger" => {
        "constants" => %w[Honeybadger],
        "require_paths" => %w[honeybadger],
      },
      "rollbar" => {
        "constants" => %w[Rollbar],
        "require_paths" => %w[rollbar],
      },
    }.freeze

    attr_reader :app_root

    def initialize(app_root:)
      @app_root = Pathname.new(app_root).expand_path
    end

    def report
      {
        "app_root" => app_root.to_s,
        "runtime" => runtime,
        "capabilities" => capabilities,
        "risks" => risks,
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

      def runtime
        {
          "ruby" => {
            "version" => RUBY_VERSION,
            "platform" => RUBY_PLATFORM,
            "host_cpu" => RbConfig::CONFIG["host_cpu"],
            "host_os" => RbConfig::CONFIG["host_os"],
          },
          "rails_version" => gem_version("rails"),
          "bundler" => {
            "with" => bundler_group("BUNDLE_WITH"),
            "without" => bundler_group("BUNDLE_WITHOUT"),
          },
        }
      end

      def capabilities
        {
          "configured_frameworks" => configured_frameworks,
          "loaded_railties" => loaded_railties,
          "engines" => engines,
          "mounted_rack_apps" => mounted_rack_apps,
          "middleware" => middleware,
          "routes" => routes,
          "jobs" => jobs,
          "mailers" => mailers,
          "channels" => channels,
          "active_storage" => active_storage,
          "action_text" => action_text,
          "rake_tasks" => rake_tasks,
          "direct_gem_usage" => direct_gem_usage,
          "integrations" => integrations,
          "adapters" => adapters,
          "parse_errors" => parse_errors,
        }
      end

      def risks
        {
          "initializers_dynamic_require_load" => initializers_dynamic_require_load,
          "dynamic_constantization" => dynamic_constantization,
        }
      end

      def application_source
        @application_source ||= begin
          path = app_root.join("config/application.rb")
          path.file? ? path.read : ""
        end
      end

      def configured_frameworks
        {
          "rails_all" => application_source.match?(/^\s*require\s+["']rails\/all["']\s*$/),
          "explicit_railties" => loaded_railties,
          "frameworks" => loaded_railties.filter_map { |path| RAILTIE_FRAMEWORKS[path] }.uniq.sort,
        }
      end

      def loaded_railties
        @loaded_railties ||= application_source.scan(/^\s*require\s+["']([^"']+)["']/).flatten.select do |path|
          path == "rails/all" || path.end_with?("/railtie") || path.end_with?("/engine")
        end.uniq.sort
      end

      def engines
        dirs = Pathname.glob(app_root.join("engines/*").to_s).select(&:directory?).map do |path|
          { "name" => path.basename.to_s, "path" => path.relative_path_from(app_root).to_s }
        end
        classes = grep_ruby(/<\s*Rails::Engine\b/).map do |match|
          match.merge("class" => class_name_near(match.fetch("path"), match.fetch("line")))
        end
        { "directories" => dirs, "classes" => classes }
      end

      def mounted_rack_apps
        route_lines.select { |match| match.fetch("source").match?(/\bmount\b/) }.map do |match|
          source = match.fetch("source").sub(/\A.*?\bmount\s+/, "")
          target = source.split(/\s*(?:,|=>|\sat:)\s*/, 2).first.strip
          match.merge("target" => target, "mount_path" => mount_path_for(match.fetch("source"))).compact
        end
      end

      def middleware
        grep_ruby(/\bconfig\.middleware\.(use|insert_before|insert_after|swap|delete)\b/).map do |match|
          operation = match.fetch("source")[/\bconfig\.middleware\.(\w+)/, 1]
          target = match.fetch("source").sub(/\A.*?\bconfig\.middleware\.\w+\s*/, "").strip
          match.merge("operation" => operation, "target" => target)
        end
      end

      def routes
        {
          "files" => route_files.map { |path| path.relative_path_from(app_root).to_s },
          "calls" => route_lines.filter_map do |match|
            name = match.fetch("source")[/\b(#{ROUTE_CALLS.join("|")})\b/, 1]
            match.merge("call" => name) if name
          end,
        }
      end

      def jobs
        class_inventory("app/jobs", /<\s*ApplicationJob\b|<\s*ActiveJob::Base\b|^\s*queue_as\b/)
      end

      def mailers
        class_inventory("app/mailers", /<\s*ApplicationMailer\b|<\s*ActionMailer::Base\b|^\s*mail\b/)
      end

      def channels
        class_inventory("app/channels", /<\s*ApplicationCable::Channel\b|<\s*ActionCable::Channel::Base\b|\bstream_from\b/)
      end

      def rake_tasks
        tasks = rake_task_files.flat_map { |path| rake_tasks_in(path) }
        {
          "files" => rake_task_files.map { |path| path.relative_path_from(app_root).to_s },
          "tasks" => tasks.uniq { |task| task.fetch("name") }.sort_by { |task| task.fetch("name") },
        }
      end

      def active_storage
        declarations = grep_ruby(/\b(has_one_attached|has_many_attached)\b/).map do |match|
          match.merge(
            "kind" => match.fetch("source")[/\b(has_one_attached|has_many_attached)\b/, 1],
            "name" => match.fetch("source")[/\bhas_(?:one|many)_attached\s+[:"']?([A-Za-z0-9_]+)/, 1],
          ).compact
        end
        {
          "declarations" => declarations,
          "declarations_count" => declarations.length,
        }
      end

      def action_text
        declarations = grep_ruby(/\bhas_rich_text\b/).map do |match|
          match.merge(
            "class" => class_name_near(match.fetch("path"), match.fetch("line")),
            "name" => match.fetch("source")[/\bhas_rich_text\s+[:"']?([A-Za-z0-9_]+)/, 1],
          ).compact
        end
        {
          "declarations" => declarations,
          "declarations_count" => declarations.length,
        }
      end

      def direct_gem_usage
        DIRECT_GEM_USAGE.transform_values do |config|
          direct_usage_for(
            constants: config.fetch("constants"),
            require_paths: config.fetch("require_paths"),
          )
        end
      end

      def integrations
        INTEGRATION_GEMS.select { |name| gem_names.include?(name) }.sort
      end

      def adapters
        ADAPTER_GEMS.select { |name| gem_names.include?(name) }.sort
      end

      def initializers_dynamic_require_load
        require_matches.select do |match|
          match["dynamic"] == true && match.fetch("path").start_with?("config/initializers/")
        end
      end

      def dynamic_constantization
        dynamic_matches.select { |match| match["dynamic"] == true }
      end

      def require_matches
        @require_matches ||= source_reports.flat_map do |report|
          next [] unless report[:ast]

          visitor = Static::RequireVisitor.new(relative_path: report.fetch(:relative))
          report.fetch(:ast).accept(visitor)
          visitor.matches
        end.sort_by { |match| [match.fetch("path"), match.fetch("line"), match.fetch("kind")] }
      end

      def dynamic_matches
        @dynamic_matches ||= source_reports.flat_map do |report|
          next [] unless report[:ast]

          visitor = Static::DynamicConstantVisitor.new(relative_path: report.fetch(:relative))
          report.fetch(:ast).accept(visitor)
          visitor.matches
        end.sort_by { |match| [match.fetch("path"), match.fetch("line"), match.fetch("kind")] }
      end

      def parse_errors
        @parse_errors ||= source_reports.filter_map do |report|
          next if report[:ast]

          {
            "path" => report.fetch(:relative),
            "errors" => report.fetch(:errors),
          }
        end
      end

      def source_reports
        @source_reports ||= ruby_files.map do |path|
          result = Prism.parse_file(path.to_s)
          if result.success?
            {
              path: path,
              relative: path.relative_path_from(app_root).to_s,
              ast: result.value,
            }
          else
            {
              path: path,
              relative: path.relative_path_from(app_root).to_s,
              errors: result.errors.map(&:message),
            }
          end
        end
      end

      def ruby_files
        @ruby_files ||= SCAN_ROOTS.flat_map do |root|
          full_root = app_root.join(root)
          next [] unless full_root.exist?

          Pathname.glob(full_root.join("**/*.rb").to_s).select(&:file?)
        end.uniq.sort
      end

      def grep_ruby(pattern)
        ruby_files.flat_map { |path| grep_file(path, pattern) }
      end

      def route_lines
        route_files.flat_map { |path| grep_file(path, /\b(#{ROUTE_CALLS.join("|")})\b/) }
      end

      def route_files
        @route_files ||= Pathname.glob(app_root.join("config/routes{.rb,/**/*.rb}").to_s).select(&:file?).sort
      end

      def rake_task_files
        @rake_task_files ||= (
          [app_root.join("Rakefile")] +
            Pathname.glob(app_root.join("lib/tasks/**/*.rake").to_s)
        ).select(&:file?).uniq.sort
      end

      def grep_file(path, pattern)
        return [] unless path.file?

        relative = path.relative_path_from(app_root).to_s
        path.readlines.filter_map.with_index(1) do |line, line_number|
          next unless line.match?(pattern)

          {
            "path" => relative,
            "line" => line_number,
            "source" => line.strip,
          }
        end
      end

      def rake_tasks_in(path)
        relative = path.relative_path_from(app_root).to_s
        namespace_stack = []
        depth = 0

        path.readlines.filter_map.with_index(1) do |line, line_number|
          source = line.strip
          namespace = rake_namespace_name(source)
          namespace_stack << { "name" => namespace, "depth" => depth } if namespace

          task_name = rake_task_name(source)
          task = if task_name
            full_name = task_name.include?(":") || namespace_stack.empty? ? task_name : "#{namespace_stack.map { |entry| entry.fetch("name") }.join(":")}:#{task_name}"
            {
              "name" => full_name,
              "path" => relative,
              "line" => line_number,
              "source" => source,
            }
          end

          depth = rake_depth_after(source, depth)
          namespace_stack.pop while namespace_stack.any? && namespace_stack.last.fetch("depth") >= depth
          task
        end
      end

      def rake_namespace_name(source)
        match = source.match(/\A\s*namespace\s+(?::([A-Za-z0-9_]+)|["']([^"']+)["'])/)
        match && (match[1] || match[2])
      end

      def rake_task_name(source)
        match = source.match(/\A\s*task\s+(?::([A-Za-z0-9_]+)|["']([^"']+)["']|([A-Za-z0-9_]+)\s*:)/)
        match && (match[1] || match[2] || match[3])
      end

      def rake_depth_after(source, depth)
        next_depth = depth + source.scan(/\bdo\b/).length
        next_depth -= 1 if source.match?(/\Aend\b/)
        [next_depth, 0].max
      end

      def class_inventory(root, pattern)
        root_path = app_root.join(root)
        files = root_path.directory? ? Pathname.glob(root_path.join("**/*.rb").to_s).select(&:file?).sort : []
        {
          "files" => files.map { |path| path.relative_path_from(app_root).to_s },
          "classes" => files.filter_map { |path| class_name_in(path) }.uniq.sort,
          "matches" => files.flat_map { |path| grep_file(path, pattern) },
        }
      end

      def direct_usage_for(constants:, require_paths:)
        constant_pattern = Array(constants).map { |constant| Regexp.escape(constant) }.join("|")
        require_pattern = Array(require_paths).map { |path| Regexp.escape(path) }.join("|")
        pattern = /\b(?:#{constant_pattern})\b|require\s+["'](?:#{require_pattern})["']/
        matches = grep_ruby(pattern)
        {
          "present" => !matches.empty?,
          "constants" => Array(constants).sort,
          "require_paths" => Array(require_paths).sort,
          "matches" => matches,
        }
      end

      def mount_path_for(source)
        path = source[/,\s*at:\s*["']([^"']+)["']/, 1] ||
          source[/=>\s*["']([^"']+)["']/, 1]
        return unless path

        path.start_with?("/") ? path : "/#{path}"
      end

      def class_name_near(relative_path, line)
        path = app_root.join(relative_path)
        return unless path.file?

        path.readlines.first(line).reverse_each do |source|
          match = source.match(/^\s*class\s+([A-Z][A-Za-z0-9_:]*)/)
          return match[1] if match
        end
        nil
      end

      def class_name_in(path)
        path.readlines.each do |line|
          match = line.match(/^\s*class\s+([A-Z][A-Za-z0-9_:]*)/)
          return match[1] if match
        end
        nil
      end

      def gem_names
        @gem_names ||= (gemfile_gems + lockfile_gems).uniq.sort
      end

      def gemfile_gems
        path = app_root.join("Gemfile")
        return [] unless path.file?

        path.read.scan(/^\s*gem\s+["']([^"']+)["']/).flatten
      end

      def lockfile_gems
        path = app_root.join("Gemfile.lock")
        return [] unless path.file?

        path.read.scan(/^\s{4}([A-Za-z0-9_.-]+)\s+\(/).flatten
      end

      def gem_version(name)
        path = app_root.join("Gemfile.lock")
        return unless path.file?

        match = path.read.match(/^\s{4}#{Regexp.escape(name)}\s+\(([^)]+)\)/)
        match && match[1]
      end

      def bundler_group(name)
        return ENV[name] if ENV[name]

        path = app_root.join(".bundle/config")
        return unless path.file?

        path.read[/^\s*#{Regexp.escape(name)}:\s*"?([^"\n]+)"?/, 1]
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
