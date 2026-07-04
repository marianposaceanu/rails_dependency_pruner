# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module RailsDependencyPruner
  module SourceDigest
    PREFIX = "sha256:"

    module_function

    def file(path)
      pathname = Pathname.new(path)
      return unless pathname.file?

      "#{PREFIX}#{Digest::SHA256.file(pathname).hexdigest}"
    end

    def for_paths(paths, root:)
      root = Pathname.new(root).expand_path
      entries = paths.map do |path|
        pathname = Pathname.new(path).expand_path
        next unless pathname.file?

        [
          pathname.relative_path_from(root).to_s,
          Digest::SHA256.file(pathname).hexdigest,
        ]
      end.compact.sort_by(&:first)

      digest_entries(entries)
    end

    def for_named_paths(paths)
      entries = paths.map do |name, path|
        pathname = Pathname.new(path)
        next unless pathname.file?

        [name.to_s, Digest::SHA256.file(pathname).hexdigest]
      end.compact.sort_by(&:first)

      digest_entries(entries)
    end

    def digest_entries(entries)
      "#{PREFIX}#{Digest::SHA256.hexdigest(JSON.generate(entries))}"
    end
  end
end
