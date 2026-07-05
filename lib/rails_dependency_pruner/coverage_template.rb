# frozen_string_literal: true

require "pathname"
require "yaml"

require_relative "doctor"

module RailsDependencyPruner
  class CoverageTemplate
    DEFAULT_RAILS_ENV = "production"
    DEFAULT_RAKE_TASKS = %w[assets:precompile db:migrate].freeze
    DIRECT_USAGE_LAZY_GEMS = {
      "nokogiri" => "nokogiri",
      "sentry" => "sentry-ruby",
      "vips" => "ruby-vips",
    }.freeze

    attr_reader :app_root, :rails_env

    def initialize(app_root:, rails_env: DEFAULT_RAILS_ENV)
      @app_root = Pathname.new(app_root).expand_path
      @rails_env = rails_env.to_s.empty? ? DEFAULT_RAILS_ENV : rails_env.to_s
    end

    def payload
      @payload ||= begin
        document = {
          "version" => 2,
          "rails_env" => rails_env,
          "boot" => {
            "eager_load" => inferred_eager_load,
            "assets_precompile" => true,
            "db_migrate" => true,
          },
        }
        document["routes"] = routes_section if route_files.any?
        document["requests"] = requests_section if request_entries.any?
        document["jobs"] = jobs_section if job_classes.any? || queue_adapter_entries.any?
        document["mailers"] = mailers_section if mailer_actions.any? || mailer_delivery_method_entries.any? || mailer_smtp_setting_entries.any?
        document["channels"] = channels_section if channel_classes.any? || cable_adapter_entries.any?
        document["active_storage"] = active_storage_section
        document["action_text"] = action_text_section
        document["inbound_email"] = review_section("mailboxes" => mailbox_classes) if mailbox_classes.any?
        document["rake_tasks"] = review_section("tasks" => rake_tasks)
        document["external_integrations"] = external_integrations_section if external_integrations.any?
        document["lazy_gems"] = lazy_gems_section if lazy_gem_usage.any?
        document["canary"] = review_section(
          "duration_minutes" => 0,
          "request_count" => 0,
          "unexpected_events_count" => nil,
          "min_duration_minutes" => 60,
          "min_request_count" => 10_000,
        )
        document["rollback"] = review_section(
          "disable_env_tested" => false,
          "env_var" => "RAILS_DEPENDENCY_PRUNER_DISABLE",
        )
        document
      end
    end

    def to_yaml
      YAML.dump(payload)
    end

    private
      def report
        @report ||= Doctor.new(app_root: app_root).report
      end

      def capabilities
        report.fetch("capabilities")
      end

      def review_section(values)
        { "review_required" => true }.merge(values)
      end

      def routes_section
        review_section(
          "include" => "all",
          "files" => route_files,
        )
      end

      def requests_section
        values = { "paths" => request_entries }
        values["web_servers"] = web_server_entries if web_server_entries.any?
        review_section(values)
      end

      def jobs_section
        values = { "classes" => job_classes }
        values["queue_adapters"] = queue_adapter_entries if queue_adapter_entries.any?
        review_section(values)
      end

      def channels_section
        values = { "classes" => channel_classes }
        values["cable_adapters"] = cable_adapter_entries if cable_adapter_entries.any?
        review_section(values)
      end

      def mailers_section
        values = { "actions" => mailer_actions }
        values["delivery_methods"] = mailer_delivery_method_entries if mailer_delivery_method_entries.any?
        values["smtp_settings"] = mailer_smtp_setting_entries if mailer_smtp_setting_entries.any?
        review_section(values)
      end

      def active_storage_section
        declarations = Array(capabilities.dig("active_storage", "declarations"))
        {
          "review_required" => declarations.any?,
          "declarations_expected" => declarations.any?,
          "configured_services" => active_storage_configured_services,
          "service_definitions" => active_storage_service_definitions,
          "declarations" => declarations.map do |entry|
            {
              "class" => entry["class"],
              "kind" => entry["kind"],
              "name" => entry["name"],
              "path" => entry["path"],
              "line" => entry["line"],
            }.compact
          end,
          "upload" => false,
          "analyze" => false,
          "variant" => false,
          "preview" => false,
          "representation" => false,
          "attachment_read" => false,
        }
      end

      def action_text_section
        declarations = Array(capabilities.dig("action_text", "declarations"))
        {
          "review_required" => declarations.any?,
          "rich_text_expected" => declarations.any?,
          "declarations" => declarations.map do |entry|
            {
              "class" => entry["class"],
              "name" => entry["name"],
              "path" => entry["path"],
              "line" => entry["line"],
            }.compact
          end,
        }
      end

      def external_integrations_section
        external_integrations.to_h do |name|
          policy = integration_policy_for(name)
          values = {
            "status" => "review",
          }
          if policy
            values["class"] = policy["class"]
            values["risk"] = policy["risk"]
            values["strategies"] = Array(policy["strategies"])
            values["production_rule"] = policy["production_rule"]
          else
            values["unclassified"] = true
          end

          [name, review_section(values)]
        end
      end

      def lazy_gems_section
        lazy_gem_usage.to_h do |gem_name, usage|
          [
            gem_name,
            review_section(
              "status" => "review",
              "constants" => usage.fetch("constants"),
              "matches" => usage.fetch("matches"),
            ),
          ]
        end
      end

      def inferred_eager_load
        environment_source[/^\s*config\.eager_load\s*=\s*(true|false)\b/, 1] == "true"
      end

      def environment_source
        path = app_root.join("config/environments/#{rails_env}.rb")
        path.file? ? path.read : ""
      end

      def route_files
        Array(capabilities.dig("routes", "files"))
      end

      def request_entries
        @request_entries ||= begin
          entries = Array(capabilities.dig("routes", "calls")).filter_map do |entry|
            request = route_request_entry(entry)
            [entry, request] if request
          end
          regular_entries = entries.reject { |entry, _request| entry["call"].to_s == "mount" }.map(&:last).first(20)
          mount_entries = entries.select { |entry, _request| entry["call"].to_s == "mount" }.map(&:last)

          (regular_entries + mount_entries).uniq { |entry| [entry.fetch("method"), entry.fetch("path")] }
        end
      end

      def route_request_entry(entry)
        call = entry["call"].to_s
        source = entry["source"].to_s
        method = request_method_for(call, source)
        path = request_path_for(call, source)
        return unless method && path

        {
          "method" => method,
          "path" => path,
          "expected_status" => 200,
          "source" => "#{entry.fetch("path")}:#{entry.fetch("line")}",
        }
      end

      def request_method_for(call, source)
        return "GET" if call == "root"
        return "GET" if call == "mount"
        return "ANY" if call == "match"

        return call.upcase if %w[delete get patch post put].include?(call)
        source[/\bvia:\s*:([a-z_]+)/, 1]&.upcase
      end

      def request_path_for(call, source)
        return "/" if call == "root"
        return mount_path_for(source) if call == "mount"

        path = source[/\b#{Regexp.escape(call)}\s+["']([^"']+)["']/, 1]
        return unless path

        path.start_with?("/") ? path : "/#{path}"
      end

      def mount_path_for(source)
        path = source[/,\s*at:\s*["']([^"']+)["']/, 1] ||
          source[/=>\s*["']([^"']+)["']/, 1]
        return unless path

        path.start_with?("/") ? path : "/#{path}"
      end

      def job_classes
        Array(capabilities.dig("jobs", "classes"))
      end

      def web_server_entries
        Array(capabilities["web_servers"]).map do |entry|
          {
            "server" => entry["server"],
            "gem" => entry["gem"],
            "present" => entry["present"],
            "config_path" => entry["config_path"],
            "mode" => entry["mode"],
            "clustered" => entry["clustered"],
            "workers" => puma_setting_entry(entry["workers"]),
            "threads" => puma_setting_entry(entry["threads"]),
            "preload_app" => puma_flag_entry(entry["preload_app"]),
            "plugins" => Array(entry["plugins"]).map { |plugin| puma_plugin_entry(plugin) },
            "class" => entry["class"],
            "risk" => entry["risk"],
            "coverage_required" => Array(entry["coverage_required"]).map(&:to_s),
            "production_rule" => entry["production_rule"],
          }.compact
        end
      end

      def puma_setting_entry(entry)
        return unless entry.is_a?(Hash)

        {
          "value" => entry["value"],
          "raw" => entry["raw"],
          "path" => entry["path"],
          "line" => entry["line"],
        }.compact
      end

      def puma_flag_entry(entry)
        return unless entry.is_a?(Hash)

        {
          "value" => entry["value"],
          "path" => entry["path"],
          "line" => entry["line"],
        }.compact
      end

      def puma_plugin_entry(entry)
        {
          "name" => entry["name"],
          "path" => entry["path"],
          "line" => entry["line"],
        }.compact
      end

      def active_storage_configured_services
        Array(capabilities.dig("active_storage", "configured_services")).map do |entry|
          {
            "environment" => entry["environment"],
            "service" => entry["service"],
            "adapter" => entry["adapter"],
            "class" => entry["class"],
            "risk" => entry["risk"],
            "coverage_required" => Array(entry["coverage_required"]).map(&:to_s),
            "path" => entry["path"],
            "line" => entry["line"],
            "definition_path" => entry["definition_path"],
            "definition_line" => entry["definition_line"],
          }.compact
        end
      end

      def active_storage_service_definitions
        Array(capabilities.dig("active_storage", "service_definitions")).map do |entry|
          {
            "name" => entry["name"],
            "adapter" => entry["adapter"],
            "class" => entry["class"],
            "risk" => entry["risk"],
            "coverage_required" => Array(entry["coverage_required"]).map(&:to_s),
            "path" => entry["path"],
            "line" => entry["line"],
          }.compact
        end
      end

      def queue_adapter_entries
        Array(capabilities["active_job_queue_adapters"]).map do |entry|
          {
            "adapter" => entry["adapter"],
            "gem" => entry["gem"],
            "class" => entry["class"],
            "risk" => entry["risk"],
            "coverage_required" => Array(entry["coverage_required"]).map(&:to_s),
            "path" => entry["path"],
            "line" => entry["line"],
            "production_rule" => entry["production_rule"],
          }.compact
        end
      end

      def mailer_actions
        mailer_files.flat_map do |path|
          class_name = class_name_in(path)
          method_names(path).map { |method_name| class_name ? "#{class_name}##{method_name}" : method_name }
        end.uniq.sort
      end

      def mailer_files
        Array(capabilities.dig("mailers", "files")).map { |path| app_root.join(path) }
      end

      def mailer_delivery_method_entries
        Array(capabilities.dig("mailers", "delivery_methods")).map do |entry|
          {
            "environment" => entry["environment"],
            "method" => entry["method"],
            "class" => entry["class"],
            "risk" => entry["risk"],
            "coverage_required" => Array(entry["coverage_required"]).map(&:to_s),
            "path" => entry["path"],
            "line" => entry["line"],
          }.compact
        end
      end

      def mailer_smtp_setting_entries
        Array(capabilities.dig("mailers", "smtp_settings")).map do |entry|
          {
            "environment" => entry["environment"],
            "class" => entry["class"],
            "risk" => entry["risk"],
            "coverage_required" => Array(entry["coverage_required"]).map(&:to_s),
            "path" => entry["path"],
            "line" => entry["line"],
          }.compact
        end
      end

      def channel_classes
        Array(capabilities.dig("channels", "classes"))
      end

      def cable_adapter_entries
        Array(capabilities["action_cable_adapters"]).map do |entry|
          {
            "environment" => entry["environment"],
            "adapter" => entry["adapter"],
            "gem" => entry["gem"],
            "class" => entry["class"],
            "risk" => entry["risk"],
            "coverage_required" => Array(entry["coverage_required"]).map(&:to_s),
            "path" => entry["path"],
            "line" => entry["line"],
            "production_rule" => entry["production_rule"],
          }.compact
        end
      end

      def mailbox_classes
        class_files("app/mailboxes").filter_map { |path| class_name_in(path) }.uniq.sort
      end

      def external_integrations
        Array(capabilities["integrations"])
      end

      def integration_policy_for(name)
        integration_policies.find { |policy| policy["gem"] == name }
      end

      def integration_policies
        @integration_policies ||= Array(capabilities["integration_gem_policies"])
      end

      def rake_tasks
        discovered = Array(capabilities.dig("rake_tasks", "tasks")).map { |task| task["name"].to_s }.reject(&:empty?)
        (DEFAULT_RAKE_TASKS + discovered.sort).uniq
      end

      def lazy_gem_usage
        @lazy_gem_usage ||= begin
          usage = capabilities.fetch("direct_gem_usage", {})
          DIRECT_USAGE_LAZY_GEMS.filter_map do |usage_key, gem_name|
            payload = usage[usage_key]
            next unless payload.is_a?(Hash) && payload["present"] == true

            [gem_name, payload]
          end
        end
      end

      def class_files(relative_root)
        root = app_root.join(relative_root)
        return [] unless root.directory?

        Pathname.glob(root.join("**/*.rb").to_s).select(&:file?).sort
      end

      def class_name_in(path)
        path.readlines.each do |line|
          match = line.match(/^\s*class\s+([A-Z][A-Za-z0-9_:]*)/)
          return match[1] if match
        end
        nil
      end

      def method_names(path)
        path.readlines.filter_map do |line|
          match = line.match(/^\s*def\s+([a-z_][A-Za-z0-9_!?=]*)/)
          next unless match

          name = match[1]
          name unless name.end_with?("=")
        end
      end
  end
end
