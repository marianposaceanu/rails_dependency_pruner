# frozen_string_literal: true

require "set"

require_relative "constant_resolver"

module RailsDependencyPruner
  class Planner
    attr_reader :index, :usage

    def initialize(index:, usage:)
      @index = index
      @usage = usage
    end

    def used_constants
      @used_constants ||= begin
        resolver = ConstantResolver.new(index.names)
        used = Set.new
        queue = usage.direct_rails_constants.to_a

        until queue.empty?
          constant = queue.shift
          next if used.include?(constant)

          used << constant

          resolver.parent_constants(constant).each do |parent|
            queue << parent unless used.include?(parent)
          end

          index.definitions.fetch(constant)&.dependencies&.each do |dependency|
            queue << dependency unless used.include?(dependency)
          end
        end

        used
      end
    end

    def unused_constants
      index.names.subtract(used_constants)
    end

    def unused_by_namespace
      unused_constants.group_by { |name| name.split("::").first }.transform_values(&:length).sort.to_h
    end

    def to_h(include_tree: true, include_unused: true)
      payload = {
        rails_root: index.rails_root.to_s,
        app_root: usage.app_root.to_s,
        rails_constants_count: index.definitions.length,
        app_files_scanned: usage.to_h.fetch(:files_scanned),
        rails_files_scanned: index.to_h(include_tree: false).fetch(:files_scanned),
        parse_errors: {
          rails: index.parse_errors,
          app: usage.parse_errors,
        },
        direct_rails_constants_count: usage.direct_rails_constants.length,
        used_constants_count: used_constants.length,
        unused_constants_count: unused_constants.length,
        direct_rails_constants: usage.direct_rails_constants.to_a.sort,
        top_unused_namespaces: unused_by_namespace,
      }

      payload[:used_constants] = used_constants.to_a.sort
      payload[:unused_constants] = unused_constants.to_a.sort if include_unused
      payload[:dependency_tree] = index.dependency_tree.sort.to_h if include_tree
      payload
    end
  end
end

