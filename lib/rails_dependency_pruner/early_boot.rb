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
      %w[commonmarker flamegraph memory_profiler parslet stackprof] + LAZY_GEM_CONSTANTS.keys
    ).sort.freeze
    DisabledRequireError = Class.new(StandardError)
    UnsafeProfileError = Class.new(StandardError)

    module_function

    def install!(
      profile_path: ENV["RAILS_DEPENDENCY_PRUNER_PROFILE"] || DEFAULT_PROFILE_PATH,
      output_path: ENV["RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT"],
      mode: ENV["RAILS_DEPENDENCY_PRUNER_MODE"],
      disabled: ENV["RAILS_DEPENDENCY_PRUNER_DISABLE"] == "1"
    )
      return false if disabled || @installed
      return false unless File.exist?(profile_path)

      payload = JSON.parse(File.read(profile_path))
      @mode = (mode || payload["mode"] || "shadow").to_s
      return false unless %w[shadow boot_prune production].include?(@mode)
      validate_profile_safety!(payload)

      @disabled_require_paths = disabled_require_paths(payload)
      @skipped_require_paths = skipped_require_paths(payload)
      @lazy_require_paths = lazy_require_paths(payload)
      @lazy_gems = lazy_gems(payload)
      @loading_lazy_require_paths = Set.new
      @loaded_lazy_require_paths = Set.new
      @loaded_lazy_gems = Set.new
      @disable_eager_load = payload.dig("extreme_boot", "disable_eager_load") == true
      @config_namespace_stubs = config_namespace_stubs(payload)
      @events = []
      @output_path = output_path
      install_shadow_hooks!
      install_bundler_require_filter!
      install_lazy_gem_constant_loader!
      at_exit { write! } if @output_path
      @installed = true
    end

    def skip_require(path, caller_location, operation: "require")
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
        @events << event
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
      @events << event
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
      @events << event

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
      %w[boot_prune production].include?(@mode)
    end

    def write!
      return unless @output_path

      File.write(
        @output_path,
        JSON.pretty_generate(
          "mode" => @mode,
          "events" => @events,
          "events_count" => @events.length,
        ),
      )
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

    def validate_profile_safety!(payload)
      return unless @mode == "production"
      unless payload.dig("safety", "production_allowed") == true
        raise UnsafeProfileError, "rails_dependency_pruner production mode requires safety.production_allowed=true"
      end

      expected = profile_digest(payload)
      return if payload["profile_id"] == expected

      raise UnsafeProfileError, "rails_dependency_pruner production mode requires matching profile_id"
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

    def loading_lazy_require?(path)
      @loading_lazy_require_paths&.include?(path.to_s)
    end

    def load_lazy_require!(path)
      normalized = normalize(path).delete_suffix(".rb")
      return false if @loaded_lazy_require_paths&.include?(normalized)

      @loading_lazy_require_paths << normalized
      require normalized
      @loaded_lazy_require_paths << normalized
      @events << {
        "path" => normalized,
        "matched_path" => normalized,
        "operation" => "require",
        "mode" => @mode,
        "action" => "loaded_lazy",
      }
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
      return if @lazy_gems.nil? || @lazy_gems.empty?

      loader = Module.new do
        def const_missing(name)
          if RailsDependencyPruner::EarlyBoot.load_lazy_gem_for_constant(name)
            return const_get(name) if const_defined?(name, false)
            return Object.const_get(name) if Object.const_defined?(name, false)
          end

          super(name)
        end
      end
      ::Module.prepend(loader)
      @lazy_gem_constant_loader_installed = true
    end

    def load_lazy_gem_for_constant(name)
      gem_name, config = LAZY_GEM_CONSTANTS.find do |candidate, candidate_config|
        @lazy_gems&.include?(candidate) && Array(candidate_config["constants"]).include?(name.to_s)
      end
      return false unless gem_name
      return true if @loaded_lazy_gems.include?(gem_name)

      require config.fetch("require")
      @loaded_lazy_gems << gem_name
      @events << {
        "path" => config.fetch("require"),
        "matched_path" => gem_name,
        "operation" => "require",
        "mode" => @mode,
        "action" => "loaded_lazy_gem",
        "constant" => name.to_s,
      }
      true
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
      digest_payload = payload.merge("profile_id" => nil)
      "sha256:#{Digest::SHA256.hexdigest(CanonicalJson.digestible(digest_payload))}"
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
