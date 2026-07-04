# frozen_string_literal: true

require "json"
require "set"
require "digest"
require "pathname"

require_relative "canonical_json"

module RailsDependencyPruner
  module EarlyBoot
    DEFAULT_PROFILE_PATH = "config/rails_dependency_pruner_profile.json"
    CONFIG_NAMESPACES = {
      "action_mailbox/engine" => "action_mailbox",
      "action_mailer/railtie" => "action_mailer",
      "active_job/railtie" => "active_job",
      "active_storage/engine" => "active_storage",
    }.freeze
    LAZY_REQUIRE_LOADERS = {
      "action_mailbox/mail_ext" => :install_action_mailbox_mail_ext_lazy_loader!,
    }.freeze
    LAZY_GEM_STUBS = {
      "rack-mini-profiler" => :install_rack_mini_profiler_stub!,
      "ruby-vips" => :install_active_storage_vips_analyzer_stub!,
    }.freeze
    LAZY_GEM_CONSTANTS = {
      "bcrypt" => {
        "require" => "bcrypt",
        "constants" => %w[BCrypt],
      },
      "builder" => {
        "require" => "builder",
        "constants" => %w[Builder],
      },
      "faker" => {
        "require" => "faker",
        "constants" => %w[Faker],
      },
      "htmlentities" => {
        "require" => "htmlentities",
        "constants" => %w[HTMLEntities],
      },
      "nokogiri" => {
        "require" => "nokogiri",
        "constants" => %w[Nokogiri],
      },
      "oauth" => {
        "require" => "oauth",
        "constants" => %w[OAuth],
      },
      "pdf-reader" => {
        "require" => "pdf-reader",
        "constants" => %w[PDF],
      },
      "rotp" => {
        "require" => "rotp",
        "constants" => %w[ROTP],
      },
      "rqrcode" => {
        "require" => "rqrcode",
        "constants" => %w[RQRCode],
      },
      "ruby-vips" => {
        "require" => "vips",
        "constants" => %w[Vips],
      },
      "sentry-rails" => {
        "require" => "sentry-rails",
        "constants" => %w[Sentry],
      },
      "sitemap_generator" => {
        "require" => "sitemap_generator",
        "constants" => %w[SitemapGenerator],
      },
      "svg-graph" => {
        "require" => "SVG/Graph/TimeSeries",
        "constants" => %w[SVG],
      },
    }.freeze
    SUPPORTED_LAZY_GEMS = (
      %w[commonmarker flamegraph memory_profiler parslet stackprof] + LAZY_GEM_CONSTANTS.keys + LAZY_GEM_STUBS.keys
    ).sort.freeze
    MODES = %w[shadow boot_prune canary production].freeze
    SAFETY_MODES = %w[canary production].freeze
    BLOCKING_MODES = %w[boot_prune canary production].freeze
    UNEXPECTED_EVENT_POLICIES = %w[report fail_boot fail_all fail_in_canary_report_in_production].freeze
    DEFAULT_UNEXPECTED_EVENT_POLICY = "fail_boot"
    DisabledRequireError = Class.new(StandardError)
    UnsafeProfileError = Class.new(StandardError)
    UnexpectedEventError = Class.new(StandardError)

    module_function

    def install!(
      profile_path: ENV["RAILS_DEPENDENCY_PRUNER_PROFILE"] || DEFAULT_PROFILE_PATH,
      output_path: ENV["RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT"],
      mode: ENV["RAILS_DEPENDENCY_PRUNER_MODE"],
      expected_profile_id: ENV["RAILS_DEPENDENCY_PRUNER_PROFILE_ID"],
      disabled: ENV["RAILS_DEPENDENCY_PRUNER_DISABLE"] == "1"
    )
      return false if disabled || @installed
      return false unless File.exist?(profile_path)

      payload = JSON.parse(File.read(profile_path))
      @mode = (mode || payload["mode"] || "shadow").to_s
      return false unless MODES.include?(@mode)
      validate_profile_safety!(payload, expected_profile_id: expected_profile_id)

      @profile_id = profile_id(payload)
      @disabled_require_paths = disabled_require_paths(payload)
      @skipped_require_paths = skipped_require_paths(payload)
      @lazy_require_paths = lazy_require_paths(payload)
      @lazy_gems = lazy_gems(payload)
      @loading_lazy_require_paths = Set.new
      @loaded_lazy_require_paths = Set.new
      @loaded_lazy_gems = Set.new
      @attempted_lazy_constants = Set.new
      @disable_eager_load = payload.dig("extreme_boot", "disable_eager_load") == true
      @config_namespace_stubs = config_namespace_stubs(payload)
      @lazy_constant_policies = lazy_constant_policies(payload)
      @expected_events = expected_events(payload)
      @unexpected_event_policy = unexpected_event_policy(payload)
      @events = []
      @output_path = output_path
      @event_log_path = ENV["RAILS_DEPENDENCY_PRUNER_EVENT_LOG"]
      @event_log_stderr = ENV["RAILS_DEPENDENCY_PRUNER_EVENT_STDERR"] == "1"
      install_shadow_hooks!
      install_bundler_require_filter!
      install_lazy_gem_stubs!
      install_lazy_gem_constant_loader!
      at_exit { write! } if @output_path
      @installed = true
    end

    def skip_require(path, caller_location, operation: "require")
      return true if stub_lazy_gem_require(path, caller_location, operation: operation)

      lazy_path = matched_lazy_path(path, caller_location: caller_location)
      if lazy_path && !loading_lazy_require?(lazy_path)
        event = {
          "path" => path.to_s,
          "matched_path" => lazy_path,
          "operation" => operation,
          "caller_path" => caller_location&.path,
          "caller_line" => caller_location&.lineno,
          "caller_label" => caller_location&.label,
          "mode" => @mode,
          "action" => blocking? ? "deferred" : "would_defer",
        }.compact
        record_event(event)
        install_lazy_require_loader!(lazy_path) if blocking?
        return blocking?
      end

      matched_path = matched_skipped_path(path, caller_location: caller_location)
      return false unless matched_path

      event = {
        "path" => path.to_s,
        "matched_path" => matched_path,
        "operation" => operation,
        "caller_path" => caller_location&.path,
        "caller_line" => caller_location&.lineno,
        "caller_label" => caller_location&.label,
        "mode" => @mode,
        "action" => blocking? ? "skipped" : "would_skip",
      }.compact
      record_event(event)
      blocking?
    end

    def stub_lazy_gem_require(path, caller_location, operation:)
      return false unless @lazy_gems&.include?("ruby-vips")
      return false unless path_variants(path, caller_location: caller_location).include?("active_storage/analyzer/image_analyzer/vips")

      event = {
        "path" => path.to_s,
        "matched_path" => "active_storage/analyzer/image_analyzer/vips",
        "operation" => operation,
        "caller_path" => caller_location&.path,
        "caller_line" => caller_location&.lineno,
        "caller_label" => caller_location&.label,
        "mode" => @mode,
        "action" => blocking? ? "stubbed_lazy_gem_require" : "would_stub_lazy_gem_require",
        "gem" => "ruby-vips",
      }.compact
      record_event(event)
      install_active_storage_vips_analyzer_stub! if blocking?
      blocking?
    end

    def shadow_require(path, caller_location, operation: "require")
      matched_path = matched_disabled_path(path, caller_location: caller_location)
      return unless matched_path

      event = {
        "path" => path.to_s,
        "matched_path" => matched_path,
        "operation" => operation,
        "caller_path" => caller_location&.path,
        "caller_line" => caller_location&.lineno,
        "caller_label" => caller_location&.label,
        "mode" => @mode,
        "action" => blocking? ? "blocked" : "would_block",
      }.compact
      record_event(event, enforce: false)

      raise DisabledRequireError, "#{path} is disabled by rails_dependency_pruner early boot" if blocking?
    end

    def disabled_require_path?(path)
      !!matched_disabled_path(path)
    end

    def matched_skipped_path(path, caller_location: nil)
      matched_path(path, @skipped_require_paths, caller_location: caller_location)
    end

    def matched_lazy_path(path, caller_location: nil)
      matched_path(path, @lazy_require_paths, caller_location: caller_location)
    end

    def matched_disabled_path(path, caller_location: nil)
      matched_path(path, @disabled_require_paths, caller_location: caller_location)
    end

    def matched_path(path, paths, caller_location: nil)
      return if paths.nil? || paths.empty?

      path_variants(path, caller_location: caller_location).each do |candidate|
        return candidate if paths.include?(candidate)

        absolute_match = absolute_path_match(candidate, paths)
        return absolute_match if absolute_match
      end

      nil
    end

    def blocking?
      BLOCKING_MODES.include?(@mode)
    end

    def write!
      return unless @output_path

      File.write(
        @output_path,
        JSON.pretty_generate(
          "mode" => @mode,
          "events" => @events,
          "events_count" => @events.length,
          "expected_events_count" => @events.count { |event| event["expected"] == true },
          "unexpected_events_count" => @events.count { |event| event["expected"] == false },
        ),
      )
    end

    def record_event(raw_event, enforce: true)
      event = raw_event.dup
      event["phase"] ||= current_phase
      event["mode"] ||= @mode
      event["pid"] ||= Process.pid
      event["transform_id"] ||= transform_id_for_event(event)
      event["event_id"] ||= event_id_for_event(event)
      event["expected"] = expected_event?(event)
      @events << event
      emit_event(event)
      enforce_event!(event) if enforce
      event
    end

    def emit_event(event)
      payload = telemetry_payload(event)
      emit_active_support_event(payload)
      emit_event_log(payload)
      warn(JSON.generate(payload)) if @event_log_stderr
    end

    def emit_active_support_event(payload)
      return unless defined?(::ActiveSupport::Notifications)

      ::ActiveSupport::Notifications.instrument("event.rails_dependency_pruner", payload)
    end

    def emit_event_log(payload)
      return if @event_log_path.to_s.empty?

      File.open(@event_log_path, "a") do |file|
        file.write(JSON.generate(payload))
        file.write("\n")
      end
    end

    def telemetry_payload(event)
      {
        "component" => "rails_dependency_pruner",
        "profile_id" => @profile_id,
        "mode" => @mode,
        "event" => event["action"],
        "event_id" => event["event_id"],
        "phase" => event["phase"],
        "path" => event["path"],
        "matched_path" => event["matched_path"],
        "gem" => event["gem"],
        "constant" => event["constant"],
        "transform_id" => event["transform_id"],
        "expected" => event["expected"],
        "caller" => caller_string(event),
        "caller_path" => event["caller_path"],
        "caller_line" => event["caller_line"],
        "pid" => event["pid"],
      }.compact
    end

    def caller_string(event)
      return unless event["caller_path"]

      [event["caller_path"], event["caller_line"]].compact.join(":")
    end

    def expected_event?(event)
      Array(@expected_events).any? { |expected| expected_event_matches?(expected, event) }
    end

    def expected_event_matches?(expected, event)
      expected.all? do |key, expected_value|
        case key
        when "path"
          [event["path"], event["matched_path"]].compact.map(&:to_s).include?(expected_value.to_s)
        when "phase"
          (event["phase"] || "boot").to_s == expected_value.to_s
        else
          event[key].to_s == expected_value.to_s
        end
      end
    end

    def enforce_event!(event)
      return unless SAFETY_MODES.include?(@mode)
      return if event["expected"]

      policy = @unexpected_event_policy || DEFAULT_UNEXPECTED_EVENT_POLICY
      return if policy == "report"

      fail_event = case policy
      when "fail_all"
        true
      when "fail_boot"
        event["phase"] == "boot"
      when "fail_in_canary_report_in_production"
        @mode == "canary" || (@mode == "production" && event["phase"] == "boot")
      else
        event["phase"] == "boot"
      end
      return unless fail_event

      raise UnexpectedEventError, "unexpected early boot event #{event.fetch("event_id")} in #{@mode} mode"
    end

    def event_id_for_event(event)
      subject = event["matched_path"] || event["path"] || event["gem"] || event["constant"] || "unknown"
      "#{event.fetch("phase", "boot")}:#{event.fetch("action", "unknown")}:#{subject}"
    end

    def transform_id_for_event(event)
      path = event["matched_path"] || event["path"]
      case event["action"]
      when "skipped", "would_skip"
        "skip_railtie:#{path}" if path
      when "deferred", "would_defer", "loaded_lazy"
        "lazy_require:#{path}" if path
      when "stubbed_lazy_gem_require", "would_stub_lazy_gem_require"
        event["gem"] == "ruby-vips" ? "stub:active_storage_vips_analyzer" : "stub:#{event["gem"]}"
      when "loaded_lazy_gem"
        "lazy_gem:#{event["matched_path"]}" if event["matched_path"]
      when "disallowed_lazy_gem_constant", "unapproved_lazy_gem_constant"
        "lazy_gem:#{event["gem"]}" if event["gem"]
      when "blocked", "would_block"
        "disabled_require:#{path}" if path
      end
    end

    def disabled_require_paths(payload)
      paths = early_boot_require_paths(payload)
      paths += Array(payload.dig("pruning", "disabled_railties"))
      paths.flat_map do |path|
        normalized = normalize(path)
        [normalized, normalized.delete_suffix(".rb")]
      end.to_set
    end

    def skipped_require_paths(payload)
      Array(payload.dig("extreme_boot", "skip_railties")).flat_map do |path|
        normalized = normalize(path)
        [normalized, normalized.delete_suffix(".rb")]
      end.to_set
    end

    def lazy_require_paths(payload)
      Array(payload.dig("extreme_boot", "lazy_require_paths")).filter_map do |path|
        normalized = normalize(path).delete_suffix(".rb")
        normalized if LAZY_REQUIRE_LOADERS.key?(normalized)
      end.to_set
    end

    def lazy_gems(payload)
      Array(payload.dig("extreme_boot", "lazy_gems")).filter_map do |name|
        name = name.to_s
        name if SUPPORTED_LAZY_GEMS.include?(name)
      end.to_set
    end

    def expected_events(payload)
      source = payload["expected_events"]
      source = Array(payload["transforms"]).flat_map { |transform| Array(transform["expected_events"]) } if source.nil?
      Array(source).filter_map do |event|
        next unless event.respond_to?(:each)

        normalized = event.each_with_object({}) do |(key, value), hash|
          hash[key.to_s] = value.to_s unless value.nil?
        end
        normalized["phase"] ||= "boot"
        normalized unless normalized.empty?
      end
    end

    def unexpected_event_policy(payload)
      policy = payload["unexpected_event_policy"].to_s
      UNEXPECTED_EVENT_POLICIES.include?(policy) ? policy : DEFAULT_UNEXPECTED_EVENT_POLICY
    end

    def lazy_constant_policies(payload)
      explicit = payload["lazy_constants"] || payload.dig("extreme_boot", "lazy_constants")
      return explicit_lazy_constant_policies(explicit) if explicit.is_a?(Hash)

      legacy_lazy_constant_policies
    end

    def explicit_lazy_constant_policies(source)
      source.each_with_object({}) do |(constant_name, config), policies|
        constant_name = constant_name.to_s
        next if constant_name.empty? || constant_name.include?("::")

        config = config.is_a?(Hash) ? config : {}
        gem_name = config["gem"].to_s
        builtin = LAZY_GEM_CONSTANTS[gem_name] || {}
        policies[constant_name] = {
          "gem" => gem_name,
          "require" => (config["require"] || builtin["require"]).to_s,
          "allowed_phases" => Array(config["allowed_phases"]).map(&:to_s),
          "disallowed_phases" => Array(config["disallowed_phases"]).map(&:to_s),
          "approved" => @lazy_gems&.include?(gem_name) && !(config["require"] || builtin["require"]).to_s.empty?,
        }
      end
    end

    def legacy_lazy_constant_policies
      Array(@lazy_gems).each_with_object({}) do |gem_name, policies|
        config = LAZY_GEM_CONSTANTS[gem_name]
        next unless config

        Array(config["constants"]).each do |constant_name|
          policies[constant_name.to_s] = {
            "gem" => gem_name,
            "require" => config.fetch("require"),
            "allowed_phases" => [],
            "disallowed_phases" => [],
            "approved" => true,
          }
        end
      end
    end

    def current_phase
      phase = ENV["RAILS_DEPENDENCY_PRUNER_PHASE"].to_s
      phase.empty? ? "boot" : phase
    end

    def phase_allowed?(policy, phase)
      allowed_phases = Array(policy["allowed_phases"])
      disallowed_phases = Array(policy["disallowed_phases"])
      return false if disallowed_phases.include?(phase)
      return true if allowed_phases.empty?

      allowed_phases.include?(phase)
    end

    def config_namespace_stubs(payload)
      explicit = Array(payload.dig("extreme_boot", "config_namespace_stubs"))
      return explicit unless explicit.empty?

      Array(payload.dig("extreme_boot", "skip_railties")).filter_map { |path| CONFIG_NAMESPACES[path] }.uniq.sort
    end

    def early_boot_require_paths(payload)
      paths = Array(payload.dig("pruning", "disabled_require_paths") || payload["unused_require_paths"])
      provenance = Array(payload.dig("pruning", "disabled_require_path_provenance") || payload["unused_require_path_provenance"])
      return paths if provenance.empty?

      pruned_frameworks = Array(payload.dig("boot_plan", "pruned_frameworks") || payload.dig("pruning", "disabled_frameworks")).map(&:to_s).to_set
      provenance_by_path = provenance.group_by { |entry| entry["require_path"].to_s }

      paths.select do |path|
        entries = provenance_by_path[path.to_s]
        next true if entries.nil? || entries.empty?

        entries.any? do |entry|
          component = entry["component"].to_s
          component.empty? || pruned_frameworks.include?(component)
        end
      end
    end

    def normalize(path)
      value = path.to_s
      absolute_path?(value) ? File.expand_path(value) : value.delete_prefix("./")
    end

    def path_variants(path, caller_location: nil)
      raw = path.to_s
      variants = [normalize(raw)]
      if relative_filesystem_path?(raw) && caller_location&.path
        variants << File.expand_path(raw, File.dirname(caller_location.path))
      end
      variants.flat_map { |variant| [variant, variant.delete_suffix(".rb"), require_path_from_absolute(variant)] }.compact.uniq
    end

    def absolute_path_match(path, paths = @disabled_require_paths)
      return unless absolute_path?(path)

      paths.find do |disabled_path|
        path.end_with?("/#{disabled_path}") || path.end_with?("/#{disabled_path}.rb")
      end
    end

    def require_path_from_absolute(path)
      return unless absolute_path?(path)

      marker = "/lib/"
      return unless path.include?(marker)

      path.split(marker).last
    end

    def absolute_path?(path)
      Pathname.new(path.to_s).absolute?
    end

    def relative_filesystem_path?(path)
      path.start_with?("./", "../")
    end

    def validate_profile_safety!(payload, expected_profile_id:)
      return unless SAFETY_MODES.include?(@mode)

      unless payload.dig("safety", "production_allowed") == true
        raise UnsafeProfileError, "rails_dependency_pruner #{@mode} mode requires safety.production_allowed=true"
      end

      expected = profile_digest(payload)
      unless profile_id(payload) == expected
        raise UnsafeProfileError, "rails_dependency_pruner #{@mode} mode requires matching profile_id"
      end
      unless expected_profile_id.to_s == expected
        raise UnsafeProfileError, "rails_dependency_pruner #{@mode} mode requires RAILS_DEPENDENCY_PRUNER_PROFILE_ID=#{expected}"
      end

      true
    end

    def after_require(path)
      install_action_mailbox_mail_ext_lazy_loader! if %w[action_mailbox mail].include?(path.to_s)
      install_bundler_require_filter! if %w[bundler bundler/setup].include?(path.to_s)
      return unless path.to_s == "rails"

      install_rails_extreme_hooks!
    end

    def install_rails_extreme_hooks!
      return if @rails_extreme_hooks_installed
      return unless blocking?
      return unless defined?(::Rails)

      install_config_namespace_stubs!
      install_no_eager_load_railtie! if @disable_eager_load
      @rails_extreme_hooks_installed = true
    end

    def install_config_namespace_stubs!
      namespaces = @config_namespace_stubs
      return if namespaces.empty?
      return unless defined?(::Rails::Application::Configuration)

      require "active_support/ordered_options"
      unless const_defined?(:ConfigOptions, false)
        const_set(:ConfigOptions, Class.new(::ActiveSupport::OrderedOptions) do
          def method_missing(name, *args)
            return super if name.to_s.end_with?("=")

            self[name] ||= self.class.new
          end
        end)
      end

      [::Rails::Application::Configuration, ::Rails::Engine::Configuration].each do |klass|
        namespaces.each do |namespace|
          next if klass.method_defined?(namespace)

          klass.define_method(namespace) do
            @rails_dependency_pruner_config_namespaces ||= {}
            @rails_dependency_pruner_config_namespaces[namespace] ||= RailsDependencyPruner::EarlyBoot::ConfigOptions.new
          end
        end
      end
    end

    def install_lazy_require_loader!(path)
      loader = LAZY_REQUIRE_LOADERS[path.to_s]
      public_send(loader) if loader
    end

    def install_lazy_gem_stubs!
      Array(@lazy_gems).each do |gem_name|
        installer = LAZY_GEM_STUBS[gem_name]
        public_send(installer) if installer
      end
    end

    def loading_lazy_require?(path)
      @loading_lazy_require_paths&.include?(path.to_s)
    end

    def load_lazy_require!(path)
      normalized = normalize(path).delete_suffix(".rb")
      return false if @loaded_lazy_require_paths&.include?(normalized)

      @loading_lazy_require_paths << normalized
      require normalized
      @loaded_lazy_require_paths << normalized
      record_event({
        "path" => normalized,
        "matched_path" => normalized,
        "operation" => "require",
        "mode" => @mode,
        "action" => "loaded_lazy",
      })
      true
    ensure
      @loading_lazy_require_paths&.delete(normalized)
    end

    def install_action_mailbox_mail_ext_lazy_loader!
      return if @action_mailbox_mail_ext_lazy_loader_installed
      return unless @lazy_require_paths&.include?("action_mailbox/mail_ext")
      return unless defined?(::Mail)

      require_path = "action_mailbox/mail_ext"
      singleton_loader = Module.new do
        define_method(:from_source) do |*args, **kwargs, &block|
          RailsDependencyPruner::EarlyBoot.load_lazy_require!(require_path)
          super(*args, **kwargs, &block)
        end
      end
      ::Mail.singleton_class.prepend(singleton_loader)

      if defined?(::Mail::Message)
        message_loader = Module.new do
          %i[
            bcc_addresses
            cc_addresses
            from_address
            recipients
            recipients_addresses
            reply_to_address
            to_addresses
            x_forwarded_to_addresses
            x_original_to_addresses
          ].each do |method_name|
            define_method(method_name) do |*args, **kwargs, &block|
              RailsDependencyPruner::EarlyBoot.load_lazy_require!(require_path)
              super(*args, **kwargs, &block)
            end
          end
        end
        ::Mail::Message.prepend(message_loader)
      end

      if defined?(::Mail::Address)
        address_loader = Module.new do
          define_method(:wrap) do |*args, **kwargs, &block|
            RailsDependencyPruner::EarlyBoot.load_lazy_require!(require_path)
            super(*args, **kwargs, &block)
          end
        end
        ::Mail::Address.singleton_class.prepend(address_loader)
      end

      @action_mailbox_mail_ext_lazy_loader_installed = true
    end

    def install_rack_mini_profiler_stub!
      return if @rack_mini_profiler_stub_installed
      return if defined?(::Rack::MiniProfiler)

      ::Object.const_set(:Rack, Module.new) unless defined?(::Rack)
      config_class = Class.new do
        def method_missing(name, *)
          return nil if name.to_s.end_with?("=")

          nil
        end

        def respond_to_missing?(*)
          true
        end
      end
      stub = Module.new do
        @config = config_class.new

        class << self
          attr_reader :config

          def authorize_request
            nil
          end

          def deauthorize_request
            nil
          end
        end
      end
      ::Rack.const_set(:MiniProfiler, stub)
      @rack_mini_profiler_stub_installed = true
    end

    def install_active_storage_vips_analyzer_stub!
      return false if @active_storage_vips_analyzer_stub_installed
      return false unless defined?(::ActiveStorage::Analyzer::ImageAnalyzer)

      analyzer = ::ActiveStorage::Analyzer::ImageAnalyzer
      analyzer.send(:remove_const, :Vips) if analyzer.const_defined?(:Vips, false)
      analyzer.const_set(:Vips, Class.new(analyzer) do
        def self.accept?(*)
          false
        end
      end)
      @active_storage_vips_analyzer_stub_installed = true
    end

    def install_bundler_require_filter!
      return if @bundler_require_filter_installed
      return if @lazy_gems.nil? || @lazy_gems.empty?
      return unless defined?(::Bundler::Runtime)

      filter = Module.new do
        def require(*groups)
          RailsDependencyPruner::EarlyBoot.filter_bundler_require(@definition) do
            super(*groups)
          end
        end
      end
      ::Bundler::Runtime.prepend(filter)
      @bundler_require_filter_installed = true
    end

    def filter_bundler_require(definition)
      return yield unless blocking?
      return yield if @lazy_gems.nil? || @lazy_gems.empty?

      original_dependencies = definition.dependencies
      lazy_gems = @lazy_gems
      definition.define_singleton_method(:dependencies) do
        original_dependencies.reject { |dependency| lazy_gems.include?(dependency.name) }
      end
      yield
    ensure
      if original_dependencies
        definition.define_singleton_method(:dependencies) { original_dependencies }
      end
    end

    def install_lazy_gem_constant_loader!
      return if @lazy_gem_constant_loader_installed
      return if (@lazy_gems.nil? || @lazy_gems.empty?) && (@lazy_constant_policies.nil? || @lazy_constant_policies.empty?)

      loader = Module.new do
        def const_missing(name)
          caller_location = caller_locations(1, 1).first
          if RailsDependencyPruner::EarlyBoot.load_lazy_gem_for_constant(name, owner: self, caller_location: caller_location)
            return const_get(name) if const_defined?(name, false)
            return Object.const_get(name) if Object.const_defined?(name, false)
          end

          super(name)
        end
      end
      ::Module.prepend(loader)
      @lazy_gem_constant_loader_installed = true
    end

    def load_lazy_gem_for_constant(name, owner: nil, caller_location: nil)
      constant_name = name.to_s
      policy = @lazy_constant_policies&.fetch(constant_name, nil)
      return false unless policy

      gem_name = policy.fetch("gem")
      return true if @loaded_lazy_gems.include?(gem_name)
      return false if @attempted_lazy_constants.include?(constant_name)

      phase = current_phase
      @attempted_lazy_constants << constant_name
      unless policy["approved"]
        record_event(lazy_constant_event(
          action: "unapproved_lazy_gem_constant",
          constant: constant_name,
          owner: owner,
          caller_location: caller_location,
          policy: policy,
          phase: phase,
        ))
        return false
      end

      unless phase_allowed?(policy, phase)
        record_event(lazy_constant_event(
          action: "disallowed_lazy_gem_constant",
          constant: constant_name,
          owner: owner,
          caller_location: caller_location,
          policy: policy,
          phase: phase,
        ))
        return false if SAFETY_MODES.include?(@mode)
      end

      require policy.fetch("require")
      @loaded_lazy_gems << gem_name
      record_event(lazy_constant_event(
        action: "loaded_lazy_gem",
        constant: constant_name,
        owner: owner,
        caller_location: caller_location,
        policy: policy,
        phase: phase,
      ))
      true
    end

    def lazy_constant_event(action:, constant:, owner:, caller_location:, policy:, phase:)
      {
        "path" => policy.fetch("require"),
        "matched_path" => policy.fetch("gem"),
        "operation" => "require",
        "mode" => @mode,
        "phase" => phase,
        "action" => action,
        "constant" => constant,
        "owner" => owner&.name || owner&.to_s,
        "gem" => policy.fetch("gem"),
        "allowed_phases" => Array(policy["allowed_phases"]),
        "disallowed_phases" => Array(policy["disallowed_phases"]),
        "caller_path" => caller_location&.path,
        "caller_line" => caller_location&.lineno,
        "caller_label" => caller_location&.label,
      }.compact
    end

    def install_no_eager_load_railtie!
      return if @no_eager_load_railtie_installed
      return unless defined?(::Rails::Railtie)

      railtie = Class.new(::Rails::Railtie) do
        initializer "rails_dependency_pruner.no_eager_load", before: :eager_load! do |application|
          application.config.eager_load = false
        end
      end
      const_set(:NoEagerLoadRailtie, railtie) unless const_defined?(:NoEagerLoadRailtie, false)
      @no_eager_load_railtie_installed = true
    end

    def profile_digest(payload)
      digest_payload = if payload["schema_version"] == 2 && !payload.key?("fingerprints")
        payload.merge("profile_id" => nil)
      else
        payload.merge(
          "profile_id" => nil,
          "fingerprints" => (payload["fingerprints"] || {}).merge("profile_id" => nil),
        )
      end
      "sha256:#{Digest::SHA256.hexdigest(CanonicalJson.digestible(digest_payload))}"
    end

    def profile_id(payload)
      payload.dig("fingerprints", "profile_id") || payload["profile_id"]
    end

    def install_shadow_hooks!
      return if @require_shadow_installed

      Kernel.module_eval do
        unless private_method_defined?(:rails_dependency_pruner_original_require)
          alias_method :rails_dependency_pruner_original_require, :require

          def require(path)
            return false if RailsDependencyPruner::EarlyBoot.skip_require(path, caller_locations(1, 1).first)

            RailsDependencyPruner::EarlyBoot.shadow_require(path, caller_locations(1, 1).first)
            result = rails_dependency_pruner_original_require(path)
            RailsDependencyPruner::EarlyBoot.after_require(path)
            result
          end

          private :require
        end

        unless private_method_defined?(:rails_dependency_pruner_original_require_relative)
          alias_method :rails_dependency_pruner_original_require_relative, :require_relative

          def require_relative(path)
            caller_location = caller_locations(1, 1).first
            return false if RailsDependencyPruner::EarlyBoot.skip_require(path, caller_location, operation: "require_relative")

            RailsDependencyPruner::EarlyBoot.shadow_require(path, caller_location, operation: "require_relative")
            result = if caller_location&.path
              rails_dependency_pruner_original_require(File.expand_path(path.to_s, File.dirname(caller_location.path)))
            else
              rails_dependency_pruner_original_require_relative(path)
            end
            RailsDependencyPruner::EarlyBoot.after_require(path)
            result
          end

          private :require_relative
        end

        unless private_method_defined?(:rails_dependency_pruner_original_load)
          alias_method :rails_dependency_pruner_original_load, :load

          def load(path, wrap = false)
            return false if RailsDependencyPruner::EarlyBoot.skip_require(path, caller_locations(1, 1).first, operation: "load")

            RailsDependencyPruner::EarlyBoot.shadow_require(path, caller_locations(1, 1).first, operation: "load")
            rails_dependency_pruner_original_load(path, wrap)
          end

          private :load
        end
      end

      @require_shadow_installed = true
    end
  end
end

RailsDependencyPruner::EarlyBoot.install!
