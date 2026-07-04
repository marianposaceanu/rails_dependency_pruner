# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

require_relative "test_helper"

class RailsDependencyPrunerTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("..").expand_path
  FAKE_RAILS_ROOT = ROOT.join("test/fixtures/fake_rails")
  FAKE_APP_ROOT = ROOT.join("test/fixtures/fake_app")
  RUBY = RbConfig.ruby

  def test_builds_dependency_tree_and_finds_unused_rails_constants
    index = RailsDependencyPruner::ConstantIndex.build(
      rails_root: FAKE_RAILS_ROOT,
      frameworks: %w[actionpack activerecord],
    )
    usage = RailsDependencyPruner::AppUsage.scan(app_root: FAKE_APP_ROOT, index: index)
    planner = RailsDependencyPruner::Planner.new(index: index, usage: usage)

    assert_includes index.definitions.keys, "ActiveRecord::Base"
    assert_includes index.definitions.keys, "ActiveRecord::Relation::Batch"
    refute_includes index.definitions.keys, "Relation::Batch"
    assert_includes index.definitions.keys, "ActionController::Base"
    assert_includes index.dependency_tree.fetch("ActiveRecord::Base"), "ActiveRecord::Persistence"
    assert_includes index.dependency_tree.fetch("ActionController::Base"), "ActionController::Metal"

    assert_includes planner.used_constants, "ActiveRecord"
    assert_includes planner.used_constants, "ActiveRecord::Base"
    assert_includes planner.used_constants, "ActiveRecord::Persistence"
    assert_includes planner.used_constants, "ActionController::Base"
    assert_includes planner.used_constants, "ActionController::Metal"

    assert_includes planner.unused_constants, "ActiveRecord::Relation"
    assert_includes planner.unused_constants, "ActiveRecord::UnusedRecordFeature"
    assert_includes planner.unused_constants, "ActionController::UnusedControllerFeature"
  end

  def test_runtime_evidence_keeps_observed_constants
    index = RailsDependencyPruner::ConstantIndex.build(
      rails_root: FAKE_RAILS_ROOT,
      frameworks: %w[actionpack activerecord],
    )
    usage = RailsDependencyPruner::AppUsage.scan(app_root: FAKE_APP_ROOT, index: index)
    runtime_evidence = RailsDependencyPruner::RuntimeEvidence.new(
      paths: [ROOT.join("test/fixtures/runtime_evidence.json").to_s],
      index: index,
    )
    planner = RailsDependencyPruner::Planner.new(index: index, usage: usage, runtime_evidence: runtime_evidence)

    assert_includes planner.runtime_constants, "ActiveRecord::Relation"
    assert_includes planner.runtime_constants, "ActionController::UnusedControllerFeature"
    assert_includes planner.used_constants, "ActiveRecord::Relation"
    assert_includes planner.used_constants, "ActionController::UnusedControllerFeature"
    refute_includes planner.unused_constants, "ActiveRecord::Relation"
    refute_includes planner.unused_constants, "ActionController::UnusedControllerFeature"
  end

  def test_cli_outputs_json_and_writes_shim
    Dir.mktmpdir("rails_dependency_pruner") do |dir|
      shim_path = File.join(dir, "shim.rb")
      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "audit",
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--app",
        FAKE_APP_ROOT.to_s,
        "--json",
        "--no-tree",
        "--write-shim",
        shim_path,
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal FAKE_APP_ROOT.to_s, payload.fetch("app_root")
      assert_operator payload.fetch("unused_constants_count"), :>, 0
      assert_includes payload.fetch("unused_constants"), "ActiveRecord::UnusedRecordFeature"
      assert File.exist?(shim_path)

      guard_stdout, guard_stderr, guard_status = Open3.capture3(
        RUBY,
        "-e",
        <<~RUBY,
          module ActiveRecord; end
          require #{shim_path.dump}

          begin
            ActiveRecord::UnusedRecordFeature.new
          rescue RailsDependencyPrunerShim::DisabledConstantError => error
            abort unless error.message.include?("ActiveRecord::UnusedRecordFeature.new")
            puts "guarded"
          end
        RUBY
      )

      assert guard_status.success?, guard_stderr
      assert_equal "guarded\n", guard_stdout
    end
  end

  def test_cli_merges_runtime_evidence
    stdout, stderr, status = Open3.capture3(
      RUBY,
      ROOT.join("exe/rails-dependency-pruner").to_s,
      "audit",
      "--rails-root",
      FAKE_RAILS_ROOT.to_s,
      "--frameworks",
      "actionpack,activerecord",
      "--app",
      FAKE_APP_ROOT.to_s,
      "--runtime-evidence",
      ROOT.join("test/fixtures/runtime_evidence.json").to_s,
      "--json",
      "--no-tree",
      chdir: ROOT.to_s,
    )

    assert status.success?, stderr

    payload = JSON.parse(stdout)
    assert_equal 2, payload.fetch("runtime_rails_constants_count")
    assert_includes payload.fetch("runtime_rails_constants"), "ActiveRecord::Relation"
    refute_includes payload.fetch("unused_constants"), "ActiveRecord::Relation"
  end

  def test_runtime_recorder_writes_runtime_evidence
    Dir.mktmpdir("rails_dependency_pruner_runtime") do |dir|
      output = File.join(dir, "runtime.json")
      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT" => output,
          "RAILS_DEPENDENCY_PRUNER_TRACE_CALLS" => "1",
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-rrails_dependency_pruner/runtime_recorder",
        "-e",
        <<~RUBY,
          module ActiveRecord
            class Base
              def persisted?
                true
              end
            end
          end

          ActiveRecord::Base.new.persisted?
        RUBY
      )

      assert status.success?, stderr
      assert_empty stdout

      payload = JSON.parse(File.read(output))
      assert_includes payload.fetch("defined_constants"), "ActiveRecord::Base"
      assert_includes payload.fetch("called_constants"), "ActiveRecord::Base"
      assert payload.fetch("called_methods").any? { |entry| entry.fetch("method_id") == "persisted?" }
    end
  end
end
