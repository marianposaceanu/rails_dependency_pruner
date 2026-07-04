# frozen_string_literal: true

require "rails_dependency_pruner/version"
require "active_support/core_ext/module/attribute_accessors"

require "zeitwerk"
loader = Zeitwerk::Loader.for_gem
loader.setup

module RailsDependencyPruner
  DEFAULT_PROFILE_PATH = "config/rails_dependency_pruner_profile.json"

  mattr_accessor :enabled, default: ENV["RAILS_DEPENDENCY_PRUNER_ENABLED"] == "1"
  mattr_accessor :force, default: ENV["RAILS_DEPENDENCY_PRUNER_FORCE"] == "1"
  mattr_accessor :profile_path

  class << self
    def configure
      yield self
    end

    def reset!
      self.enabled = ENV["RAILS_DEPENDENCY_PRUNER_ENABLED"] == "1"
      self.force = ENV["RAILS_DEPENDENCY_PRUNER_FORCE"] == "1"
      self.profile_path = nil
    end

    def profile_path_for(app)
      profile_path || app.root.join(DEFAULT_PROFILE_PATH)
    end
  end
end

require "rails_dependency_pruner/engine" if defined?(Rails::Engine)
