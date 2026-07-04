# frozen_string_literal: true

require "prism"
require "set"

require_relative "constant_definition"

module RailsDependencyPruner
  class SourceVisitor < Prism::Visitor
    attr_reader :definitions, :references

    def initialize(path:, relative_path:, component: nil)
      @path = path
      @relative_path = relative_path
      @component = component
      @definitions = {}
      @references = []
      @owner_stack = []
      @namespace_stack = []
    end

    def visit_class_node(node)
      visit_definition(:class, node.constant_path, node.superclass, node.body)
    end

    def visit_module_node(node)
      visit_definition(:module, node.constant_path, nil, node.body)
    end

    def visit_constant_path_node(node)
      record_reference(safe_full_name(node), node)
    end

    def visit_constant_read_node(node)
      record_reference(node.name.to_s, node)
    end

    def visit_constant_write_node(node)
      if class_or_module_constructor?(node.value)
        name = definition_name(node.name.to_s, node)
        add_definition(name, :constant, node, nil)
      end

      super
    end

    private
      def visit_definition(kind, constant_node, superclass_node, body_node)
        raw_name = constant_name(constant_node)
        name = definition_name(raw_name, constant_node)
        superclass = constant_name(superclass_node)

        add_definition(name, kind, constant_node, superclass)

        @owner_stack << name
        @namespace_stack << name
        record_reference(superclass, superclass_node) if superclass
        superclass_node&.accept(self)
        body_node&.accept(self)
      ensure
        @namespace_stack.pop
        @owner_stack.pop
      end

      def add_definition(name, kind, node, superclass)
        return if name.nil? || name.empty?

        @definitions[name] ||= ConstantDefinition.new(
          name: name,
          kind: kind.to_s,
          component: @component,
          path: @relative_path,
          line: node.location.start_line,
          superclass: superclass,
          raw_references: Set.new,
          dependencies: Set.new,
        )
      end

      def record_reference(name, node)
        return if name.nil? || name.empty?

        reference = RawReference.new(
          name: name,
          namespace: current_namespace,
          path: @relative_path,
          line: node.location.start_line,
        )

        @references << reference

        owner = current_owner
        @definitions[owner]&.raw_references&.add(reference) if owner
      end

      def definition_name(raw_name, node)
        return if raw_name.nil? || raw_name.empty?

        normalized = raw_name.delete_prefix("::")
        return normalized if raw_name.start_with?("::")

        namespace = current_namespace
        return normalized unless namespace
        return normalized if normalized.start_with?("#{namespace.split("::").first}::")

        "#{namespace}::#{normalized}"
      end

      def constant_name(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          safe_full_name(node)
        end
      end

      def safe_full_name(node)
        node.full_name
      rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
        nil
      end

      def current_owner
        @owner_stack.last
      end

      def current_namespace
        @namespace_stack.last
      end

      def class_or_module_constructor?(node)
        return false unless node.is_a?(Prism::CallNode)

        receiver = node.receiver
        node.name == :new &&
          receiver.is_a?(Prism::ConstantReadNode) &&
          %i[Class Module].include?(receiver.name)
      end
  end
end
