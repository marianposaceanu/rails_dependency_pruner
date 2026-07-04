# frozen_string_literal: true

require "rails/engine"

module RailsDependencyPruner
  class Engine < ::Rails::Engine
    RAILS_8_RANGE = Gem::Requirement.new(">= 8.0", "< 9.0")

    config.rails_dependency_pruner = ActiveSupport::OrderedOptions.new

    initializer "rails_dependency_pruner.config", before: "rails_dependency_pruner.install_guards" do
      config.rails_dependency_pruner.each do |key, value|
        RailsDependencyPruner.public_send("#{key}=", value)
      end
    end

    initializer "rails_dependency_pruner.install_guards", before: :load_config_initializers do |app|
      self.class.validate_rails_version!
      next unless RailsDependencyPruner.enabled

      profile_path = RailsDependencyPruner.profile_path_for(app)
      next unless File.exist?(profile_path)

      profile = Profile.load(profile_path)
      RequireGuard.install!(profile.unused_require_paths)
      GuardInstaller.install!(profile.unused_constants, force: RailsDependencyPruner.force)
    end

    def self.validate_rails_version!
      return if RAILS_8_RANGE.satisfied_by?(Rails.gem_version)

      raise "rails_dependency_pruner supports Rails 8.x only; current Rails is #{Rails.version}"
    end
  end
end
