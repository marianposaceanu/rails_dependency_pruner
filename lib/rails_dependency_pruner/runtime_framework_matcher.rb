# frozen_string_literal: true

module RailsDependencyPruner
  class RuntimeFrameworkMatcher
    CONSTANT_PREFIXES = {
      "actioncable" => %w[ActionCable],
      "actionmailbox" => %w[ActionMailbox],
      "actionmailer" => %w[ActionMailer],
      "actionpack" => %w[ActionController ActionDispatch],
      "actiontext" => %w[ActionText],
      "actionview" => %w[ActionView],
      "activejob" => %w[ActiveJob],
      "activemodel" => %w[ActiveModel],
      "activerecord" => %w[ActiveRecord Arel],
      "activestorage" => %w[ActiveStorage],
      "activesupport" => %w[ActiveSupport],
      "railties" => %w[Rails],
    }.freeze

    ROUTE_PATTERNS = {
      "actioncable" => %w[action_cable cable],
      "actionmailbox" => %w[action_mailbox rails_conductor],
      "actiontext" => %w[action_text],
      "activestorage" => %w[active_storage rails_blob rails_representation rails_disk],
    }.freeze

    attr_reader :applications

    def initialize(applications:)
      @applications = Array(applications)
    end

    def matches(frameworks)
      Array(frameworks).flat_map do |framework|
        matches_for_framework(framework.to_s)
      end.sort_by { |match| [match.fetch("framework"), match.fetch("kind"), match["name"].to_s, match["path"].to_s] }
    end

    private
      def matches_for_framework(framework)
        applications.each_with_index.flat_map do |application, index|
          middleware_matches(framework, application, index) + route_matches(framework, application, index)
        end
      end

      def middleware_matches(framework, application, index)
        Array(application["middleware"]).filter_map do |entry|
          name = entry["name"].to_s
          next unless constant_owned_by_framework?(name, framework)

          {
            "framework" => framework,
            "kind" => "middleware",
            "application_index" => index,
            "name" => name,
          }
        end
      end

      def route_matches(framework, application, index)
        Array(application["routes"]).filter_map do |entry|
          next unless route_owned_by_framework?(entry, framework)

          {
            "framework" => framework,
            "kind" => "route",
            "application_index" => index,
            "name" => entry["name"],
            "verb" => entry["verb"],
            "path" => entry["path"],
            "controller" => entry["controller"],
            "action" => entry["action"],
          }.compact
        end
      end

      def constant_owned_by_framework?(name, framework)
        CONSTANT_PREFIXES.fetch(framework, []).any? do |prefix|
          name == prefix || name.start_with?("#{prefix}::")
        end
      end

      def route_owned_by_framework?(entry, framework)
        return generic_actionpack_route?(entry) if framework == "actionpack"

        route_text = [
          entry["name"],
          entry["path"],
          entry["controller"],
          entry["action"],
        ].compact.join(" ").downcase

        ROUTE_PATTERNS.fetch(framework, []).any? { |pattern| route_text.include?(pattern) }
      end

      def generic_actionpack_route?(entry)
        entry.values_at("name", "path", "controller", "action").any? do |value|
          value.to_s != ""
        end
      end
  end
end
