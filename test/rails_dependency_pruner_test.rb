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

  def test_dependency_graph_matches_current_used_constant_closure
    index = RailsDependencyPruner::ConstantIndex.build(
      rails_root: FAKE_RAILS_ROOT,
      frameworks: %w[actionpack activerecord],
    )
    usage = RailsDependencyPruner::AppUsage.scan(app_root: FAKE_APP_ROOT, index: index)
    planner = RailsDependencyPruner::Planner.new(index: index, usage: usage)

    assert_equal planner.used_constants, planner.graph_used_constants

    graph = planner.dependency_graph
    base_file_id = graph.file_id("activerecord/lib/active_record/base.rb")
    base_constant_id = graph.constant_id("ActiveRecord::Base")
    orphan_require_id = graph.require_path_id("active_record/orphan_feature")

    assert graph.nodes.key?(base_file_id)
    assert graph.nodes.key?(graph.constant_id("ActiveRecord::Base"))
    assert graph.nodes.key?(orphan_require_id)
    assert graph.edges.any? { |edge| edge.from == base_file_id && edge.to == base_constant_id && edge.type == :defines }
    assert graph.edges.any? { |edge| edge.from == base_file_id && edge.to == orphan_require_id && edge.type == :requires }
    assert graph.edges.any? { |edge| edge.from == graph.constant_id("ActiveRecord::Base") && edge.to == graph.constant_id("ActiveRecord::Persistence") }

    explanation = planner.explain_constant("ActiveRecord::Base")
    assert_equal "used", explanation.fetch("decision")
    assert_equal "static", explanation.fetch("seed")
    assert_equal "activerecord", explanation.fetch("component")
    assert_equal ["constant:ActiveRecord::Base"], explanation.fetch("reachability_path").map { |entry| entry.fetch("node") }

    unused = planner.explain_constant("ActiveRecord::UnusedRecordFeature")
    assert_equal "unused", unused.fetch("decision")
    assert_empty unused.fetch("reachability_path")
  end

  def test_cli_explains_constant_usage_as_json
    stdout, stderr, status = Open3.capture3(
      RUBY,
      ROOT.join("exe/rails-dependency-pruner").to_s,
      "explain",
      "--rails-root",
      FAKE_RAILS_ROOT.to_s,
      "--frameworks",
      "actionpack,activerecord",
      "--app",
      FAKE_APP_ROOT.to_s,
      "--json",
      "ActiveRecord::UnusedRecordFeature",
      chdir: ROOT.to_s,
    )

    assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal "ActiveRecord::UnusedRecordFeature", payload.fetch("constant")
      assert_equal "unused", payload.fetch("decision")
      assert_equal "activerecord", payload.fetch("component")
    assert_equal "constant", payload.dig("graph", "node", "type")
  end

  def test_feature_catalog_dsl_rules_keep_framework_constants
    Dir.mktmpdir("rails_dependency_pruner_features") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(
        File.join(app_root, "app/models/catalog_post.rb"),
        <<~RUBY,
          class CatalogPost < ApplicationRecord
            belongs_to :user
            has_one_attached :cover
            has_rich_text :body
          end

          class CatalogMailer < ActionMailer::Base
            def welcome
              mail(to: "user@example.test")
            end
          end

          class CatalogJob < ActiveJob::Base
            queue_as :default
          end

          class CatalogChannel < ActionCable::Channel::Base
            def subscribed
              stream_from "catalog"
            end
          end
        RUBY
      )

      index = RailsDependencyPruner::ConstantIndex.build(
        rails_root: FAKE_RAILS_ROOT,
        frameworks: %w[
          actioncable
          actionmailer
          activejob
          activerecord
          activestorage
          actiontext
        ],
      )
      usage = RailsDependencyPruner::AppUsage.scan(app_root: app_root, index: index)
      planner = RailsDependencyPruner::Planner.new(index: index, usage: usage)

      assert_includes usage.direct_rails_constants, "ActiveRecord::Base"
      assert_includes usage.direct_rails_constants, "ActiveStorage::Blob"
      assert_includes usage.direct_rails_constants, "ActionText::RichText"
      assert_includes usage.direct_rails_constants, "ActionMailer::Base"
      assert_includes usage.direct_rails_constants, "ActiveJob::Base"
      assert_includes usage.direct_rails_constants, "ActionCable::Channel::Base"

      features = usage.feature_matches.map { |match| match.fetch("feature") }
      assert_includes features, "active_record"
      assert_includes features, "active_storage"
      assert_includes features, "action_text"
      assert_includes features, "action_mailer"
      assert_includes features, "active_job"
      assert_includes features, "action_cable"

      refute_includes planner.unused_constants, "ActiveStorage::Blob"
      refute_includes planner.unused_constants, "ActionText::RichText"
    end
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

  def test_profile_diff_reports_pruning_changes
    Dir.mktmpdir("rails_dependency_pruner_profile_diff") do |dir|
      old_profile = File.join(dir, "old.json")
      new_profile = File.join(dir, "new.json")
      File.write(old_profile, JSON.pretty_generate(
        "schema_version" => 1,
        "unused_constants" => ["ActiveRecord::OldThing"],
        "unused_require_paths" => ["active_record/old_thing"],
      ))
      File.write(new_profile, JSON.pretty_generate(
        "schema_version" => 1,
        "unused_constants" => ["ActiveRecord::NewThing"],
        "unused_require_paths" => ["active_record/new_thing"],
      ))

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "profile",
        "diff",
        "--old",
        old_profile,
        "--new",
        new_profile,
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal true, payload.fetch("changed")
      assert_includes payload.dig("pruning_changes", "disabled_constants", "added"), "ActiveRecord::NewThing"
      assert_includes payload.dig("pruning_changes", "disabled_constants", "removed"), "ActiveRecord::OldThing"
      assert_includes payload.dig("pruning_changes", "disabled_require_paths", "added"), "active_record/new_thing"
      assert_includes payload.dig("pruning_changes", "disabled_require_paths", "removed"), "active_record/old_thing"
    end
  end

  def test_profile_diff_reports_equivalent_profiles
    Dir.mktmpdir("rails_dependency_pruner_profile_diff_same") do |dir|
      old_profile = File.join(dir, "old.json")
      new_profile = File.join(dir, "new.json")
      payload = {
        "schema_version" => 2,
        "profile_id" => "sha256:same",
        "pruning" => {
          "disabled_constants" => ["ActiveRecord::Thing"],
          "disabled_require_paths" => ["active_record/thing"],
        },
      }
      File.write(old_profile, JSON.pretty_generate(payload))
      File.write(new_profile, JSON.pretty_generate(payload))

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "profile",
        "diff",
        "--old",
        old_profile,
        "--new",
        new_profile,
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr
      assert_includes stdout, "Profiles are equivalent"
    end
  end

  def test_verify_accepts_current_deterministic_profile
    Dir.mktmpdir("rails_dependency_pruner_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      profile_path = File.join(dir, "profile.json")
      write_deterministic_profile(profile_path: profile_path, app_root: app_root)

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "verify",
        "--profile",
        profile_path,
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal true, payload.fetch("verified")
      assert_equal true, payload.fetch("production_allowed")
      assert_empty payload.fetch("errors")
    end
  end

  def test_verify_rejects_v1_profile_for_production_gate
    Dir.mktmpdir("rails_dependency_pruner_verify_v1") do |dir|
      profile_path = File.join(dir, "profile.json")
      File.write(profile_path, JSON.pretty_generate(
        "schema_version" => 1,
        "unused_constants" => [],
      ))

      stdout, _stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "verify",
        "--profile",
        profile_path,
        "--app",
        FAKE_APP_ROOT.to_s,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_equal false, payload.fetch("verified")
      assert payload.fetch("errors").any? { |error| error.include?("schema 1") }
    end
  end

  def test_verify_production_requires_coverage_manifest
    Dir.mktmpdir("rails_dependency_pruner_verify_production") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      profile_path = File.join(dir, "profile.json")
      write_deterministic_profile(profile_path: profile_path, app_root: app_root)

      stdout, _stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "verify",
        "--profile",
        profile_path,
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_equal false, payload.fetch("verified")
      assert_includes payload.fetch("errors"), "production verify requires a coverage manifest digest"
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
    assert_includes payload.fetch("unused_require_path_provenance").map { |entry| entry.fetch("require_path") }, "active_record/orphan_feature"
    assert_equal 1, payload.fetch("runtime_memory").length
    assert_equal 1048576, payload.dig("runtime_memory_summary", "object_sizes", "T_STRING")
    assert_equal "ActionController::UnusedControllerFeature", payload.dig("runtime_memory_summary", "rails_class_instance_sizes", 0, "name")
  end

  def test_runtime_recorder_writes_runtime_evidence
    Dir.mktmpdir("rails_dependency_pruner_runtime") do |dir|
      output = File.join(dir, "runtime.json")
      runtime_feature = File.join(dir, "runtime_feature.rb")
      File.write(runtime_feature, "module ActiveRecord; class RuntimeRequiredFeature; end; end\n")
      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT" => output,
          "RAILS_DEPENDENCY_PRUNER_TRACE_CALLS" => "1",
          "RAILS_DEPENDENCY_PRUNER_TRACE_REQUIRES" => "1",
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

          $LOAD_PATH.unshift(#{dir.dump})
          require "runtime_feature"
          load #{runtime_feature.dump}
          ActiveRecord::Base.new.persisted?
        RUBY
      )

      assert status.success?, stderr
      assert_empty stdout

      payload = JSON.parse(File.read(output))
      assert_includes payload.fetch("defined_constants"), "ActiveRecord::Base"
      assert_includes payload.fetch("called_constants"), "ActiveRecord::Base"
      assert payload.fetch("called_methods").any? { |entry| entry.fetch("method_id") == "persisted?" }
      assert payload.fetch("require_events").any? { |entry| entry.fetch("path") == "runtime_feature" && entry["caller_line"] }
      assert payload.fetch("load_events").any? { |entry| entry.fetch("path") == runtime_feature && entry["caller_line"] }
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

  def test_early_boot_shadow_records_would_block_require_without_blocking
    Dir.mktmpdir("rails_dependency_pruner_early_boot") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      feature_path = File.join(dir, "blocked_feature.rb")
      File.write(feature_path, "BLOCKED_FEATURE_LOADED = true\n")
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "shadow",
        "pruning" => {
          "disabled_require_paths" => ["blocked_feature"],
        },
      ))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "shadow",
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-e",
        <<~RUBY,
          $LOAD_PATH.unshift(#{dir.dump})
          require "rails_dependency_pruner/early_boot"
          require "blocked_feature"
          puts BLOCKED_FEATURE_LOADED
        RUBY
      )

      assert status.success?, stderr
      assert_equal "true\n", stdout

      payload = JSON.parse(File.read(output_path))
      assert_equal "shadow", payload.fetch("mode")
      assert_equal 1, payload.fetch("events_count")
      assert_equal "blocked_feature", payload.dig("events", 0, "path")
      assert_equal "would_block", payload.dig("events", 0, "action")
    end
  end

  def test_early_boot_can_be_disabled_by_environment
    Dir.mktmpdir("rails_dependency_pruner_early_disabled") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      feature_path = File.join(dir, "blocked_feature.rb")
      File.write(feature_path, "BLOCKED_FEATURE_LOADED = true\n")
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "shadow",
        "pruning" => {
          "disabled_require_paths" => ["blocked_feature"],
        },
      ))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_DISABLE" => "1",
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-e",
        <<~RUBY,
          $LOAD_PATH.unshift(#{dir.dump})
          require "rails_dependency_pruner/early_boot"
          require "blocked_feature"
          puts BLOCKED_FEATURE_LOADED
        RUBY
      )

      assert status.success?, stderr
      assert_equal "true\n", stdout
      refute File.exist?(output_path)
    end
  end

  def test_early_boot_prune_mode_blocks_disabled_require
    Dir.mktmpdir("rails_dependency_pruner_early_blocking") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      feature_path = File.join(dir, "blocked_feature.rb")
      File.write(feature_path, "BLOCKED_FEATURE_LOADED = true\n")
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "boot_prune",
        "pruning" => {
          "disabled_require_paths" => ["blocked_feature"],
        },
      ))

      _stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "boot_prune",
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-e",
        <<~RUBY,
          $LOAD_PATH.unshift(#{dir.dump})
          require "rails_dependency_pruner/early_boot"
          require "blocked_feature"
        RUBY
      )

      refute status.success?
      assert_includes stderr, "blocked_feature is disabled by rails_dependency_pruner early boot"

      payload = JSON.parse(File.read(output_path))
      assert_equal "blocked", payload.dig("events", 0, "action")
    end
  end

  def test_early_boot_production_mode_requires_allowed_profile
    Dir.mktmpdir("rails_dependency_pruner_early_production") do |dir|
      profile_path = File.join(dir, "profile.json")
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "production",
        "safety" => {
          "production_allowed" => false,
        },
        "pruning" => {
          "disabled_require_paths" => ["blocked_feature"],
        },
      ))

      _stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "production",
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-e",
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
        RUBY
      )

      refute status.success?
      assert_includes stderr, "production mode requires safety.production_allowed=true"
    end
  end

  def test_apply_boot_plan_writes_review_patch_for_rails_all
    Dir.mktmpdir("rails_dependency_pruner_boot_plan") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      application_path = File.join(app_root, "config/application.rb")
      File.write(application_path, <<~RUBY)
        # frozen_string_literal: true

        require "rails/all"
      RUBY
      profile_path = File.join(dir, "profile.json")
      patch_path = File.join(dir, "boot_plan.patch")
      File.write(profile_path, JSON.pretty_generate("schema_version" => 1, "unused_constants" => []))

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "apply",
        "boot-plan",
        "--profile",
        profile_path,
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,actionview,activejob,activemodel,activerecord",
        "--write-patch",
        patch_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("required_frameworks"), "activerecord"
      assert_includes payload.fetch("required_frameworks"), "activemodel"
      assert_includes payload.fetch("required_frameworks"), "actionpack"
      assert_includes payload.fetch("required_frameworks"), "actionview"
      assert_includes payload.fetch("pruned_frameworks"), "activejob"

      patch = File.read(patch_path)
      assert_includes patch, "-require \"rails/all\""
      assert_includes patch, "+require \"rails\""
      assert_includes patch, "+require \"active_record/railtie\""
      assert_includes patch, "+# require \"active_job/railtie\" # pruned by rails_dependency_pruner"
      assert_includes File.read(application_path), "require \"rails/all\""
    end
  end

  def test_apply_boot_plan_comments_explicit_pruned_framework_requires
    Dir.mktmpdir("rails_dependency_pruner_explicit_boot_plan") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      application_path = File.join(app_root, "config/application.rb")
      File.write(application_path, <<~RUBY)
        # frozen_string_literal: true

        require "rails"
        require "active_record/railtie"
        require "active_job/railtie"
      RUBY
      profile_path = File.join(dir, "profile.json")
      patch_path = File.join(dir, "boot_plan.patch")
      File.write(profile_path, JSON.pretty_generate("schema_version" => 1, "unused_constants" => []))

      _stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "apply",
        "boot-plan",
        "--profile",
        profile_path,
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "activejob,activemodel,activerecord",
        "--write-patch",
        patch_path,
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      patch = File.read(patch_path)
      assert_includes patch, "-require \"active_job/railtie\""
      assert_includes patch, "+# require \"active_job/railtie\""
      assert_includes File.read(application_path), "require \"active_job/railtie\""
    end
  end

  def test_measure_boot_reports_process_memory
    Dir.mktmpdir("rails_dependency_pruner_measure") do |dir|
      report_path = File.join(dir, "measurement.json")
      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "measure",
        "boot",
        "--app",
        FAKE_APP_ROOT.to_s,
        "--variants",
        "baseline,boot_prune",
        "--runs",
        "1",
        "--output",
        report_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal "ok", payload.dig("variants", "baseline", "status")
      assert_equal "ok", payload.dig("variants", "boot_prune", "status")
      assert_operator payload.dig("variants", "baseline", "rss_kb_median"), :>, 0
      assert payload.dig("deltas", "boot_prune").key?("rss_kb")
      assert File.exist?(report_path)
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
