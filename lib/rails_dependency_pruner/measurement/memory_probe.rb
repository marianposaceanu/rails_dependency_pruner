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
        process_memory = process_memory_snapshot
        {
          "rss_kb" => process_memory.fetch("rss_kb"),
          "process_memory" => process_memory,
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

      def process_memory_snapshot
        memory = { "rss_kb" => rss_kb }
        memory.merge!(linux_smaps_rollup_memory)
        if detailed_process_memory? && RUBY_PLATFORM.include?("darwin")
          memory["physical_footprint_kb"] = macos_physical_footprint_kb
        end
        memory.compact
      end

      def detailed_process_memory?
        ENV["RAILS_DEPENDENCY_PRUNER_PROCESS_MEMORY_DETAILS"] == "1"
      end

      def linux_smaps_rollup_memory(path = "/proc/self/smaps_rollup")
        return {} unless File.file?(path)

        parse_linux_smaps_rollup(File.read(path))
      rescue Errno::EACCES, Errno::ENOENT
        {}
      end

      def parse_linux_smaps_rollup(content)
        memory = {}
        content.each_line do |line|
          case line
          when /\APss:\s+(\d+)\s+kB/i
            memory["pss_kb"] = Regexp.last_match(1).to_i
          when /\APrivate_Clean:\s+(\d+)\s+kB/i
            memory["private_clean_kb"] = Regexp.last_match(1).to_i
          when /\APrivate_Dirty:\s+(\d+)\s+kB/i
            memory["private_dirty_kb"] = Regexp.last_match(1).to_i
          end
        end

        if memory.key?("private_clean_kb") || memory.key?("private_dirty_kb")
          memory["uss_kb"] = memory.fetch("private_clean_kb", 0) + memory.fetch("private_dirty_kb", 0)
        end
        memory
      end

      def macos_physical_footprint_kb(pid = Process.pid)
        output = `vmmap -summary #{pid} 2>/dev/null`
        parse_macos_physical_footprint_kb(output)
      rescue Errno::ENOENT
        nil
      end

      def parse_macos_physical_footprint_kb(output)
        line = output.to_s.each_line.find { |candidate| candidate.start_with?("Physical footprint:") }
        return unless line

        parse_memory_size_kb(line.split(":", 2).last)
      end

      def parse_memory_size_kb(value)
        match = value.to_s.strip.match(/\A([\d.]+)\s*([KMGT])(?:i?B)?\z/i)
        return unless match

        number = match[1].to_f
        multiplier = {
          "K" => 1,
          "M" => 1024,
          "G" => 1024 * 1024,
          "T" => 1024 * 1024 * 1024,
        }.fetch(match[2].upcase)
        (number * multiplier).round
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
