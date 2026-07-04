# frozen_string_literal: true

require "json"
require "set"

require_relative "measurement/memory_probe"

module RailsDependencyPruner
  module RuntimeRecorder
    DEFAULT_PREFIXES = %w[
      AbstractController
      ActionCable
      ActionController
      ActionDispatch
      ActionMailbox
      ActionMailer
      ActionText
      ActionView
      ActiveJob
      ActiveModel
      ActiveRecord
      ActiveStorage
      ActiveSupport
      Arel
      Rails
    ].freeze

    module_function

    def start!(
      output: ENV["RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT"],
      rails_root: ENV["RAILS_DEPENDENCY_PRUNER_RAILS_ROOT"],
      trace_calls: ENV["RAILS_DEPENDENCY_PRUNER_TRACE_CALLS"] == "1",
      trace_requires: ENV["RAILS_DEPENDENCY_PRUNER_TRACE_REQUIRES"] == "1",
      prefixes: DEFAULT_PREFIXES,
      max_called_methods: Integer(ENV.fetch("RAILS_DEPENDENCY_PRUNER_MAX_CALLS", "20000")),
      max_require_events: Integer(ENV.fetch("RAILS_DEPENDENCY_PRUNER_MAX_REQUIRE_EVENTS", "20000")),
      max_load_events: Integer(ENV.fetch("RAILS_DEPENDENCY_PRUNER_MAX_LOAD_EVENTS", "20000")),
      max_snapshots: Integer(ENV.fetch("RAILS_DEPENDENCY_PRUNER_MAX_SNAPSHOTS", "200")),
      record_snapshots: ENV["RAILS_DEPENDENCY_PRUNER_SNAPSHOTS"] == "1"
    )
      return false if output.nil? || output.empty?
      return true if @started

      @started = true
      @output = output
      @rails_root = rails_root
      @prefixes = prefixes
      @called_methods = []
      @called_constants = Set.new
      @require_events = []
      @load_events = []
      @snapshots = []
      @current_phase = ENV.fetch("RAILS_DEPENDENCY_PRUNER_PHASE", "boot")
      @max_called_methods = max_called_methods
      @max_require_events = max_require_events
      @max_load_events = max_load_events
      @max_snapshots = max_snapshots
      @called_methods_truncated = false
      @require_events_truncated = false
      @load_events_truncated = false
      @snapshots_truncated = false
      @record_objectspace = ENV["RAILS_DEPENDENCY_PRUNER_OBJECTSPACE"] == "1"
      @record_snapshots = record_snapshots

      if trace_calls
        @trace = TracePoint.new(:call) do |event|
          record_call(event)
        end
        @trace.enable
      end
      install_require_trace! if trace_requires

      snapshot!("recorder_start") if @record_snapshots
      at_exit do
        snapshot!("recorder_exit") if @record_snapshots
        write!
      end
      true
    end

    def write!
      @trace&.disable
      memory = memory_snapshot if @record_objectspace

      payload = {
        ruby_pid: Process.pid,
        rails_root: @rails_root,
        loaded_features: loaded_features,
        defined_constants: defined_constants,
        called_constants: @called_constants.to_a.sort,
        called_methods: @called_methods,
        require_events: @require_events,
        load_events: @load_events,
        snapshots: @snapshots,
        process_memory: Measurement::MemoryProbe.snapshot,
        limits: limits_payload,
        called_methods_truncated: @called_methods_truncated,
        require_events_truncated: @require_events_truncated,
        load_events_truncated: @load_events_truncated,
        snapshots_truncated: @snapshots_truncated,
      }
      payload[:memory] = memory if @record_objectspace

      File.write(@output, JSON.pretty_generate(payload))
    end

    def snapshot!(phase)
      return false unless @started

      @current_phase = phase.to_s
      if @snapshots.length >= @max_snapshots
        @snapshots_truncated = true
        return false
      end

      snapshot = {
        "phase" => phase.to_s,
        "time" => Process.clock_gettime(Process::CLOCK_MONOTONIC),
        "loaded_features" => loaded_features,
        "defined_constants" => defined_constants,
        "process_memory" => Measurement::MemoryProbe.snapshot,
      }
      snapshot["memory"] = memory_snapshot if @record_objectspace
      @snapshots << snapshot
      true
    end

    def record_call(event)
      return unless rails_path?(event.path)

      defined_class = constant_name(event.defined_class)
      return unless rails_constant?(defined_class)

      @called_constants << defined_class

      if @called_methods.length >= @max_called_methods
        @called_methods_truncated = true
        return
      end

      @called_methods << {
        "defined_class" => defined_class,
        "method_id" => event.method_id.to_s,
        "path" => event.path,
        "line" => event.lineno,
      }
    end

    def loaded_features
      $LOADED_FEATURES.select { |feature| rails_path?(feature) }.sort
    end

    def defined_constants
      ObjectSpace.each_object(Module).filter_map do |mod|
        name = constant_name(mod)
        name if rails_constant?(name)
      end.sort
    end

    def constant_name(object)
      object.name
    rescue NoMethodError
      object.to_s.sub(/\A#<Class:/, "").delete_suffix(">")
    end

    def rails_constant?(name)
      return false if name.nil? || name.empty?

      @prefixes.any? { |prefix| name == prefix || name.start_with?("#{prefix}::") }
    end

    def rails_path?(path)
      return false if path.nil?
      return true if @rails_root.nil? || @rails_root.empty?

      File.expand_path(path).start_with?(File.expand_path(@rails_root))
    end

    def memory_snapshot
      require "objspace"

      {
        object_counts: stringify_keys(ObjectSpace.count_objects),
        object_sizes: stringify_keys(ObjectSpace.count_objects_size),
        rails_class_instance_sizes: rails_class_instance_sizes,
      }
    end

    def record_require(path, caller_location, operation: "require", resolved_path: nil)
      record_event(@require_events, :@require_events_truncated, @max_require_events, path, caller_location, operation: operation, resolved_path: resolved_path)
    end

    def record_load(path, caller_location, operation: "load", resolved_path: nil)
      record_event(@load_events, :@load_events_truncated, @max_load_events, path, caller_location, operation: operation, resolved_path: resolved_path)
    end

    def rails_class_instance_sizes
      ObjectSpace.each_object(Class).filter_map do |klass|
        name = constant_name(klass)
        next unless rails_constant?(name)

        bytes = ObjectSpace.memsize_of_all(klass)
        next if bytes.zero?

        {
          name: name,
          bytes: bytes,
          count: ObjectSpace.each_object(klass).count,
        }
      end.sort_by { |entry| -entry.fetch(:bytes) }.first(200)
    end

    def stringify_keys(hash)
      hash.transform_keys(&:to_s)
    end

    def install_require_trace!
      return if @require_trace_installed

      Kernel.module_eval do
        unless private_method_defined?(:rails_dependency_pruner_runtime_original_require)
          alias_method :rails_dependency_pruner_runtime_original_require, :require

          def require(path)
            RailsDependencyPruner::RuntimeRecorder.record_require(path, caller_locations(1, 1).first)
            rails_dependency_pruner_runtime_original_require(path)
          end

          private :require
        end

        unless private_method_defined?(:rails_dependency_pruner_runtime_original_require_relative)
          alias_method :rails_dependency_pruner_runtime_original_require_relative, :require_relative

          def require_relative(path)
            caller_location = caller_locations(1, 1).first
            resolved_path = if caller_location&.path
              File.expand_path(path.to_s, File.dirname(caller_location.path))
            end
            RailsDependencyPruner::RuntimeRecorder.record_require(
              path,
              caller_location,
              operation: "require_relative",
              resolved_path: resolved_path,
            )
            if resolved_path
              rails_dependency_pruner_runtime_original_require(resolved_path)
            else
              rails_dependency_pruner_runtime_original_require_relative(path)
            end
          end

          private :require_relative
        end

        unless private_method_defined?(:rails_dependency_pruner_runtime_original_load)
          alias_method :rails_dependency_pruner_runtime_original_load, :load

          def load(path, wrap = false)
            RailsDependencyPruner::RuntimeRecorder.record_load(path, caller_locations(1, 1).first)
            rails_dependency_pruner_runtime_original_load(path, wrap)
          end

          private :load
        end
      end
      @require_trace_installed = true
    end

    def record_event(events, truncated_flag, max_events, path, caller_location, operation:, resolved_path: nil)
      if events.length >= max_events
        instance_variable_set(truncated_flag, true)
        return
      end

      events << {
        operation: operation,
        path: path.to_s,
        resolved_path: resolved_path,
        phase: @current_phase,
        caller_path: caller_location&.path,
        caller_line: caller_location&.lineno,
        caller_label: caller_location&.label,
      }.compact
    end

    def limits_payload
      {
        called_methods: limit_payload(@called_methods.length, @max_called_methods, @called_methods_truncated),
        require_events: limit_payload(@require_events.length, @max_require_events, @require_events_truncated),
        load_events: limit_payload(@load_events.length, @max_load_events, @load_events_truncated),
        snapshots: limit_payload(@snapshots.length, @max_snapshots, @snapshots_truncated),
      }
    end

    def limit_payload(recorded, max, truncated)
      {
        recorded: recorded,
        max: max,
        truncated: truncated,
      }
    end
  end
end

RailsDependencyPruner::RuntimeRecorder.start!
