# frozen_string_literal: true

require "rbconfig"
require "pathname"

require "prism"

require_relative "rails_source"
require_relative "source_digest"
require_relative "version"
require_relative "coverage_manifest"
require_relative "feature_catalog"
require_relative "fingerprint"

module RailsDependencyPruner
  class ProfileContext
    attr_reader :app_root, :rails_source, :scan_roots, :runtime_evidence_paths, :coverage_path, :coverage_manifest, :rails_env

    def initialize(app_root:, rails_source:, scan_roots:, runtime_evidence_paths: [], coverage_path: nil, rails_env: nil)
      @app_root = Pathname.new(app_root).expand_path
      @rails_source = rails_source
      @scan_roots = scan_roots.map(&:to_s).sort
      @runtime_evidence_paths = runtime_evidence_paths.map(&:to_s).sort
      @coverage_path = resolve_app_path(coverage_path)
      @coverage_manifest = @coverage_path && CoverageManifest.load(@coverage_path)
      @rails_env = rails_env || coverage_manifest&.rails_env || ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
    end

    def self.from_planner(planner, runtime_evidence_paths: [], coverage_path: nil)
      new(
        app_root: planner.usage.app_root,
        rails_source: planner.index.source,
        scan_roots: planner.usage.scan_roots,
        runtime_evidence_paths: runtime_evidence_paths,
        coverage_path: coverage_path,
      )
    end

    def self.build(app_root:, rails_root: nil, scan_roots:, frameworks:, runtime_evidence_paths: [], coverage_path: nil)
      rails_source = rails_root ? RailsSource.checkout(rails_root: rails_root, frameworks: frameworks) : RailsSource.installed_rails_8(frameworks: frameworks)

      new(
        app_root: app_root,
        rails_source: rails_source,
        scan_roots: scan_roots,
        runtime_evidence_paths: runtime_evidence_paths,
        coverage_path: coverage_path,
      )
    end

    def to_h
      {
        "ruby" => ruby_context,
        "rails" => rails_context,
        "bundler" => bundler_context,
        "app" => app_context,
        "environment" => environment_context,
        "fingerprints" => fingerprints_context,
        "analysis" => analysis_context,
        "evidence" => evidence_context,
      }
    end

    def ruby_context
      {
        "version" => RUBY_VERSION,
        "engine" => defined?(RUBY_ENGINE) ? RUBY_ENGINE : "ruby",
        "platform" => RUBY_PLATFORM,
        "host_cpu" => RbConfig::CONFIG["host_cpu"],
        "host_os" => RbConfig::CONFIG["host_os"],
      }
    end

    def rails_context
      {
        "version" => rails_source.version,
        "frameworks" => rails_source.frameworks.map(&:to_s).sort,
        "source_digest" => rails_source_digest,
      }
    end

    def bundler_context
      {
        "gemfile_lock_digest" => SourceDigest.file(app_root.join("Gemfile.lock")),
        "version" => bundler_version,
        "with" => ENV["BUNDLE_WITH"],
        "without" => ENV["BUNDLE_WITHOUT"],
        "specs" => bundled_specs,
      }
    end

    def app_context
      {
        "root_digest" => app_files_digest,
        "files_digest" => app_files_digest,
        "rails_env" => rails_env,
        "eager_load" => eager_load?,
      }
    end

    def analysis_context
      {
        "prism_version" => Prism::VERSION,
        "scanner_version" => RailsDependencyPruner::VERSION,
        "scan_roots" => scan_roots,
        "feature_catalog" => feature_catalog_context,
      }
    end

    def tool_context
      {
        "name" => "rails_dependency_pruner",
        "version" => RailsDependencyPruner::VERSION,
        "git_sha" => tool_git_sha,
      }
    end

    def environment_context
      {
        "ruby_version" => ruby_context.fetch("version"),
        "rails_version" => rails_context.fetch("version"),
        "bundler_version" => bundler_version,
        "platform" => ruby_context.fetch("platform"),
        "rails_env" => rails_env,
        "bundle_without" => ENV["BUNDLE_WITHOUT"],
        "bundle_with" => ENV["BUNDLE_WITH"],
      }
    end

    def fingerprints_context
      @fingerprints_context ||= Fingerprint.new(
        app_root: app_root,
        coverage_manifest: coverage_manifest,
        runtime_evidence_paths: runtime_evidence_paths,
      ).to_h
    end

    def evidence_context
      {
        "runtime_evidence_digests" => runtime_evidence_paths.filter_map { |path| SourceDigest.file(path) }.sort,
        "coverage_manifest_digest" => coverage_manifest&.digest,
        "workloads" => coverage_manifest&.workloads || [],
      }
    end

    def memory_policy_context
      coverage_manifest&.memory_policy || {}
    end

    def feature_catalog_context
      catalog = FeatureCatalog.for_rails_version(rails_source.version)

      {
        "name" => catalog.name,
        "rails_version" => catalog.rails_version,
        "digest" => SourceDigest.file(catalog.path),
      }
    end

    def app_files_digest
      @app_files_digest ||= SourceDigest.for_paths(app_source_files, root: app_root)
    end

    def rails_source_digest
      @rails_source_digest ||= SourceDigest.for_named_paths(
        rails_source.ruby_files.map { |path| [rails_source.relative_path(path), path] },
      )
    end

    def app_source_files
      scan_roots.flat_map do |root|
        full_root = app_root.join(root)
        next [] unless full_root.exist?

        Pathname.glob(full_root.join("**/*.rb").to_s).sort.reject do |path|
          relative = path.relative_path_from(app_root).to_s
          relative.start_with?("tmp/") ||
            relative.start_with?("vendor/bundle/") ||
            relative.start_with?("node_modules/")
        end
      end
    end

    def bundled_specs
      names = (["rails"] + RailsSource::FRAMEWORK_GEMS.values).uniq

      names.each_with_object({}) do |name, specs|
        spec = Gem.loaded_specs[name] || Gem::Specification.find_all_by_name(name).max_by(&:version)
        specs[name] = spec.version.to_s if spec
      end.sort.to_h
    end

    def bundler_version
      defined?(Bundler::VERSION) ? Bundler::VERSION : nil
    end

    def tool_git_sha
      ENV["RAILS_DEPENDENCY_PRUNER_TOOL_GIT_SHA"]
    end

    def eager_load?
      manifest_value = coverage_manifest&.eager_load
      return manifest_value unless manifest_value.nil?

      case ENV["RAILS_DEPENDENCY_PRUNER_EAGER_LOAD"]
      when "1", "true"
        true
      when "0", "false"
        false
      end
    end

    private
      def resolve_app_path(path)
        return if path.nil? || path.to_s.empty?

        pathname = Pathname.new(path)
        pathname.absolute? ? pathname.expand_path : app_root.join(pathname).expand_path
      end
  end
end
