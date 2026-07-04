# frozen_string_literal: true

require_relative "lib/rails_dependency_pruner/version"

Gem::Specification.new do |spec|
  spec.name = "rails_dependency_pruner"
  spec.version = RailsDependencyPruner::VERSION
  spec.authors = ["Marian"]
  spec.email = []

  spec.summary = "Static Rails constant dependency analysis and guard shim generation"
  spec.description = "Builds a Rails constant dependency tree, scans app usage, and writes experimental guard shims for unused Rails constants."
  spec.homepage = "https://github.com/marianposaceanu/rails_dependency_pruner"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    Dir["README.md", "LICENSE.txt", "Rakefile", "Gemfile", "lib/**/*.rb", "exe/*", "test/**/*.rb"]
  end
  spec.bindir = "exe"
  spec.executables = ["rails-dependency-pruner"]
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", "~> 1.0"
end
