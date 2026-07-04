# frozen_string_literal: true

module RailsDependencyPruner
  ConstantDefinition = Struct.new(
    :name,
    :kind,
    :component,
    :path,
    :line,
    :superclass,
    :raw_references,
    :dependencies,
    keyword_init: true,
  ) do
    def to_h
      {
        name: name,
        kind: kind,
        component: component,
        path: path,
        line: line,
        superclass: superclass,
        dependencies: dependencies.to_a.sort,
      }.compact
    end
  end

  RawReference = Struct.new(:name, :namespace, :path, :line, keyword_init: true) do
    def to_h
      {
        name: name,
        namespace: namespace,
        path: path,
        line: line,
      }.compact
    end
  end
end

