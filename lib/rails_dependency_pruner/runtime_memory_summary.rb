# frozen_string_literal: true

module RailsDependencyPruner
  class RuntimeMemorySummary
    attr_reader :snapshots

    def initialize(snapshots)
      @snapshots = Array(snapshots)
    end

    def empty?
      snapshots.empty?
    end

    def object_sizes
      @object_sizes ||= sort_hash(sum_hash("object_sizes"))
    end

    def rails_class_instance_sizes
      @rails_class_instance_sizes ||= begin
        totals = Hash.new { |hash, name| hash[name] = { "name" => name, "bytes" => 0, "count" => 0 } }

        snapshots.each do |snapshot|
          Array(snapshot["rails_class_instance_sizes"]).each do |entry|
            name = entry["name"].to_s
            next if name.empty?

            totals[name]["bytes"] += integer(entry["bytes"])
            totals[name]["count"] += integer(entry["count"])
          end
        end

        totals.values.sort_by { |entry| [-entry.fetch("bytes"), entry.fetch("name")] }
      end
    end

    def to_h(object_limit: 20, rails_class_limit: 20)
      {
        "object_sizes" => limited_hash(object_sizes, object_limit),
        "rails_class_instance_sizes" => rails_class_instance_sizes.first(rails_class_limit),
      }
    end

    private
      def sum_hash(key)
        snapshots.each_with_object(Hash.new(0)) do |snapshot, totals|
          Hash(snapshot[key]).each do |name, value|
            totals[name.to_s] += integer(value)
          end
        end
      end

      def sort_hash(hash)
        hash.sort_by { |name, bytes| [-bytes, name] }.to_h
      end

      def limited_hash(hash, limit)
        hash.first(limit).to_h
      end

      def integer(value)
        Integer(value || 0)
      rescue ArgumentError, TypeError
        0
      end
  end
end
