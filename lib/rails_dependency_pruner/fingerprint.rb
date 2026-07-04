# frozen_string_literal: true

require "pathname"

require_relative "source_digest"

module RailsDependencyPruner
  class Fingerprint
    MATERIAL_PATHS = %w[
      Gemfile
      Gemfile.lock
      .bundle/config
      config/application.rb
      config/boot.rb
      config/environment.rb
    ].freeze
    MATERIAL_GLOBS = %w[
      config/environments/*.rb
      config/initializers/**/*.rb
      config/routes.rb
      config/routes/**/*.rb
      app/**/*.rb
      lib/**/*.rb
      engines/*/app/**/*.rb
      engines/*/config/**/*.rb
    ].freeze

    attr_reader :app_root, :coverage_manifest, :runtime_evidence_paths

    def initialize(app_root:, coverage_manifest: nil, runtime_evidence_paths: [])
      @app_root = Pathname.new(app_root).expand_path
      @coverage_manifest = coverage_manifest
      @runtime_evidence_paths = runtime_evidence_paths.map(&:to_s).sort
    end

    def to_h
      {
        "profile_id" => nil,
        "gemfile_sha256" => file_digest("Gemfile"),
        "gemfile_lock_sha256" => file_digest("Gemfile.lock"),
        "bundler_config_sha256" => file_digest(".bundle/config"),
        "source_manifest_sha256" => SourceDigest.for_paths(material_files, root: app_root),
        "coverage_manifest_sha256" => coverage_manifest&.digest,
        "runtime_evidence_sha256" => runtime_evidence_digest,
        "routes_sha256" => SourceDigest.for_paths(routes_files, root: app_root),
        "initializers_sha256" => SourceDigest.for_paths(initializer_files, root: app_root),
        "application_config_sha256" => SourceDigest.for_paths(application_config_files, root: app_root),
      }
    end

    private
      def file_digest(relative_path)
        SourceDigest.file(app_root.join(relative_path))
      end

      def runtime_evidence_digest
        return SourceDigest.digest_entries([]) if runtime_evidence_paths.empty?

        SourceDigest.for_named_paths(runtime_evidence_paths.map { |path| [Pathname.new(path).basename.to_s, path] })
      end

      def material_files
        @material_files ||= (
          MATERIAL_PATHS.map { |path| app_root.join(path) } +
            MATERIAL_GLOBS.flat_map { |pattern| Pathname.glob(app_root.join(pattern).to_s) }
        ).uniq.select(&:file?).reject { |path| ignored_path?(path) }.sort
      end

      def routes_files
        @routes_files ||= Pathname.glob(app_root.join("config/routes{.rb,/**/*.rb}").to_s).select(&:file?).sort
      end

      def initializer_files
        @initializer_files ||= Pathname.glob(app_root.join("config/initializers/**/*.rb").to_s).select(&:file?).sort
      end

      def application_config_files
        @application_config_files ||= (
          %w[config/application.rb config/boot.rb config/environment.rb].map { |path| app_root.join(path) } +
            Pathname.glob(app_root.join("config/environments/*.rb").to_s)
        ).uniq.select(&:file?).sort
      end

      def ignored_path?(path)
        relative = path.relative_path_from(app_root).to_s
        relative.start_with?("tmp/") ||
          relative.start_with?("vendor/bundle/") ||
          relative.start_with?("node_modules/")
      end
  end
end
