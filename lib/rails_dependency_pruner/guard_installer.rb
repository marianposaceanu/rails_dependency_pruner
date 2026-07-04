# frozen_string_literal: true

module RailsDependencyPruner
  DisabledConstantError = Class.new(StandardError)

  module GuardInstaller
    module_function

    def install!(constants, force: false)
      constants.to_a.sort_by { |name| name.count("::") }.each do |name|
        install_constant(name, force: force)
      end
    end

    def install_constant(name, force:)
      parent, leaf = parent_and_leaf(name)
      return false unless parent

      if parent.const_defined?(leaf, false)
        return false unless force

        parent.__send__(:remove_const, leaf)
      end

      parent.const_set(leaf, guard_for(name))
      true
    end

    def parent_and_leaf(name)
      parts = name.split("::")
      leaf = parts.pop
      parent = Object

      parts.each do |part|
        return [nil, leaf] unless parent.const_defined?(part, false)

        parent = parent.const_get(part, false)
      end

      [parent, leaf]
    end

    def guard_for(name)
      error_class = DisabledConstantError

      Class.new(BasicObject) do
        define_singleton_method(:const_missing) do |missing|
          ::Kernel.raise error_class, "#{name}::#{missing} is disabled by RailsDependencyPruner"
        end

        define_singleton_method(:method_missing) do |method_name, *|
          ::Kernel.raise error_class, "#{name}.#{method_name} is disabled by RailsDependencyPruner"
        end

        define_singleton_method(:respond_to_missing?) { |*, **| false }

        define_method(:initialize) do |*|
          ::Kernel.raise error_class, "#{name}.new is disabled by RailsDependencyPruner"
        end
      end
    end
  end
end
