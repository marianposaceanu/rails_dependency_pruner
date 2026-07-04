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
    assert_includes planner.unused_features, "activerecord/lib/active_record/orphan_feature.rb"
    assert_includes planner.unused_require_paths, "active_record/orphan_feature"
    refute_includes planner.unused_require_paths, "active_record/base"
  end

  def test_index_defaults_to_installed_rails_8_gems
    stdout, stderr, status = Open3.capture3(
      RUBY,
      ROOT.join("exe/rails-dependency-pruner").to_s,
      "index",
      "--frameworks",
      "railties",
      "--json",
      "--no-tree",
      chdir: ROOT.to_s,
    )

    assert status.success?, stderr

    payload = JSON.parse(stdout)
    assert_match(/\A8\./, payload.fetch("rails_version"))
    assert_match(/rails 8\./, payload.dig("source", "label"))
    assert_operator payload.fetch("constants_count"), :>, 0
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
      profile_path = File.join(dir, "profile.json")
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
        "--write-profile",
        profile_path,
        "--write-shim",
        shim_path,
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal FAKE_APP_ROOT.to_s, payload.fetch("app_root")
      assert_equal FAKE_RAILS_ROOT.to_s, payload.dig("source", "label")
      assert_operator payload.fetch("unused_constants_count"), :>, 0
      assert_includes payload.fetch("unused_constants"), "ActiveRecord::UnusedRecordFeature"
      assert_includes payload.fetch("unused_require_paths"), "active_record/orphan_feature"
      assert File.exist?(profile_path)
      assert File.exist?(shim_path)

      profile = JSON.parse(File.read(profile_path))
      assert_includes profile.fetch("unused_constants"), "ActiveRecord::UnusedRecordFeature"
      assert_includes profile.fetch("unused_require_paths"), "active_record/orphan_feature"

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

      require_stdout, require_stderr, require_status = Open3.capture3(
        RUBY,
        "-e",
        <<~RUBY
          require #{shim_path.dump}

          begin
            require "active_record/orphan_feature"
          rescue RailsDependencyPrunerShim::DisabledConstantError => error
            abort unless error.message.include?("active_record/orphan_feature")
            puts "require guarded"
          end
        RUBY
      )

      assert require_status.success?, require_stderr
      assert_equal "require guarded\n", require_stdout
    end
  end

  def test_cli_writes_byte_stable_deterministic_profile
    Dir.mktmpdir("rails_dependency_pruner_deterministic") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "Gemfile.lock"), "GEM\n  specs:\n    rails (8.1.3)\n")

      first_profile = File.join(dir, "first.json")
      second_profile = File.join(dir, "second.json")

      [first_profile, second_profile].each do |profile_path|
        _stdout, stderr, status = Open3.capture3(
          RUBY,
          ROOT.join("exe/rails-dependency-pruner").to_s,
          "audit",
          "--rails-root",
          FAKE_RAILS_ROOT.to_s,
          "--frameworks",
          "actionpack,activerecord",
          "--app",
          app_root,
          "--write-profile",
          profile_path,
          "--deterministic",
          "--json",
          "--no-tree",
          "--no-unused",
          chdir: ROOT.to_s,
        )

        assert status.success?, stderr
      end

      assert_equal File.read(first_profile), File.read(second_profile)

      profile = RailsDependencyPruner::Profile.load(first_profile)
      assert_equal 2, profile.schema_version
      assert_match(/\Asha256:/, profile.profile_id)
      assert_equal profile.digest, profile.profile_id
      assert_includes profile.unused_require_paths, "active_record/orphan_feature"

      stdout, stderr, status = validate_profile(profile_path: first_profile, app_root: app_root)
      assert status.success?, stderr
      assert_includes stdout, "Profile valid"
    end
  end

  def test_profile_validate_rejects_changed_app_source
    Dir.mktmpdir("rails_dependency_pruner_stale_app") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      profile_path = File.join(dir, "profile.json")
      write_deterministic_profile(profile_path: profile_path, app_root: app_root)

      File.open(File.join(app_root, "app/controllers/application_controller.rb"), "a") do |file|
        file.puts "# invalidate profile"
      end

      _stdout, stderr, status = validate_profile(profile_path: profile_path, app_root: app_root)
      refute status.success?
      assert_includes stderr, "app.files_digest mismatch"
    end
  end

  def test_profile_validate_rejects_changed_gemfile_lock
    Dir.mktmpdir("rails_dependency_pruner_stale_lock") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "Gemfile.lock"), "GEM\n  specs:\n    rails (8.1.3)\n")
      profile_path = File.join(dir, "profile.json")
      write_deterministic_profile(profile_path: profile_path, app_root: app_root)

      File.write(File.join(app_root, "Gemfile.lock"), "GEM\n  specs:\n    rails (8.1.4)\n")

      _stdout, stderr, status = validate_profile(profile_path: profile_path, app_root: app_root)
      refute status.success?
      assert_includes stderr, "bundler.gemfile_lock_digest mismatch"
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
    assert_equal 1, payload.fetch("runtime_memory").length
    assert_equal 1048576, payload.dig("runtime_memory_summary", "object_sizes", "T_STRING")
    assert_equal "ActionController::UnusedControllerFeature", payload.dig("runtime_memory_summary", "rails_class_instance_sizes", 0, "name")
  end

  def test_runtime_recorder_writes_runtime_evidence
    Dir.mktmpdir("rails_dependency_pruner_runtime") do |dir|
      output = File.join(dir, "runtime.json")
      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT" => output,
          "RAILS_DEPENDENCY_PRUNER_TRACE_CALLS" => "1",
          "RAILS_DEPENDENCY_PRUNER_OBJECTSPACE" => "1",
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
      assert payload.dig("memory", "object_sizes", "T_STRING")
      assert payload.dig("memory", "rails_class_instance_sizes").any? { |entry| entry.fetch("name") == "ActiveRecord::Base" }
    end
  end

  def test_engine_installs_guards_from_profile
    Dir.mktmpdir("rails_dependency_pruner_engine") do |dir|
      profile_path = File.join(dir, "profile.json")
      File.write(profile_path, JSON.pretty_generate(
        "unused_constants" => ["ActiveRecord::PrunedThing"],
        "unused_require_paths" => ["active_record/pruned_thing"],
      ))

      stdout, stderr, status = Open3.capture3(
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-e",
        <<~RUBY
          require "rails"
          require "rails_dependency_pruner"

          APP_ROOT = #{dir.dump}
          PROFILE_PATH = #{profile_path.dump}

          module ActiveRecord; end

          class PrunerTestApp < Rails::Application
            config.root = APP_ROOT
            config.eager_load = false
            config.secret_key_base = "test"
            config.rails_dependency_pruner.enabled = true
            config.rails_dependency_pruner.profile_path = PROFILE_PATH
          end

          PrunerTestApp.initialize!

          begin
            ActiveRecord::PrunedThing.new
          rescue RailsDependencyPruner::DisabledConstantError => error
            abort unless error.message.include?("ActiveRecord::PrunedThing.new")
            puts "engine guarded"
          end
        RUBY
      )

      assert status.success?, stderr
      assert_equal "engine guarded\n", stdout
    end
  end

  private
    def write_deterministic_profile(profile_path:, app_root:)
      _stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "audit",
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--app",
        app_root,
        "--write-profile",
        profile_path,
        "--deterministic",
        "--json",
        "--no-tree",
        "--no-unused",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr
    end

    def validate_profile(profile_path:, app_root:)
      Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "profile",
        "validate",
        "--profile",
        profile_path,
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        chdir: ROOT.to_s,
      )
    end
end
