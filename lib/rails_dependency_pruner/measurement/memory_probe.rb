# frozen_string_literal: true

module RailsDependencyPruner
  module Measurement
    module MemoryProbe
      FRAMEWORK_GEM_MARKERS = {
        "actioncable" => "/gems/actioncable-",
        "actionmailbox" => "/gems/actionmailbox-",
        "actionmailer" => "/gems/actionmailer-",
        "actionpack" => "/gems/actionpack-",
        "actiontext" => "/gems/actiontext-",
        "actionview" => "/gems/actionview-",
        "activejob" => "/gems/activejob-",
        "activemodel" => "/gems/activemodel-",
        "activerecord" => "/gems/activerecord-",
        "activestorage" => "/gems/activestorage-",
        "activesupport" => "/gems/activesupport-",
        "railties" => "/gems/railties-",
      }.freeze

      module_function

      def snapshot
        {
          "rss_kb" => rss_kb,
          "loaded_features" => $LOADED_FEATURES.length,
          "rails_loaded_features" => rails_loaded_features,
          "rails_loaded_features_by_framework" => rails_loaded_features_by_framework,
          "object_counts" => object_counts,
          "gc_heap_live_slots" => GC.stat[:heap_live_slots],
        }
      end

      def rss_kb
        `ps -o rss= -p #{Process.pid}`.to_i
      end

      def rails_loaded_features
        $LOADED_FEATURES.count do |feature|
          feature.include?("/gems/action") ||
            feature.include?("/gems/active") ||
            feature.include?("/gems/railties")
        end
      end

      def rails_loaded_features_by_framework
        FRAMEWORK_GEM_MARKERS.each_with_object({}) do |(framework, marker), counts|
          count = $LOADED_FEATURES.count { |feature| feature.include?(marker) }
          counts[framework] = count if count.positive?
        end.sort.to_h
      end

      def object_counts
        ObjectSpace.count_objects.transform_keys(&:to_s)
      end
    end
  end
end
