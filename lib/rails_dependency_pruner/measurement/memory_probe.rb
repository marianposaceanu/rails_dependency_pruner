# frozen_string_literal: true

module RailsDependencyPruner
  module Measurement
    module MemoryProbe
      module_function

      def snapshot
        {
          "rss_kb" => rss_kb,
          "loaded_features" => $LOADED_FEATURES.length,
          "rails_loaded_features" => rails_loaded_features,
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
    end
  end
end
