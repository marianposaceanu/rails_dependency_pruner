# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "yaml"

require_relative "test_helper"

class RailsDependencyPrunerTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("..").expand_path
  FAKE_RAILS_ROOT = ROOT.join("test/fixtures/fake_rails")
  FAKE_APP_ROOT = ROOT.join("test/fixtures/fake_app")
  REFERENCE_APPS_ROOT = ROOT.join("test/fixtures/apps")
  RUBY = RbConfig.ruby

  def write_measurement_profile(path)
    payload = {
      "schema_version" => 3,
      "profile_id" => nil,
      "fingerprints" => { "profile_id" => nil },
      "mode" => "boot_prune",
      "pruning" => {
        "disabled_frameworks" => ["actiontext"],
        "disabled_railties" => ["action_text/engine"],
        "disabled_initializers" => [],
        "disabled_require_paths" => [],
        "disabled_require_path_provenance" => [],
        "disabled_constants" => [],
        "autoload_ignores" => [],
        "eager_load_ignores" => [],
      },
      "boot_plan" => {
        "pruned_frameworks" => ["actiontext"],
        "pruned_railties" => ["action_text/engine"],
        "autoload_ignores" => [],
        "eager_load_ignores" => [],
      },
      "extreme_boot" => {
        "disable_eager_load" => true,
        "skip_railties" => ["rails/test_unit/railtie"],
        "lazy_require_paths" => [],
        "lazy_gems" => ["builder", "rack-mini-profiler", "ruby-vips"],
        "config_namespace_stubs" => [],
      },
      "safety" => {
        "production_allowed" => false,
      },
      "memory_policy" => {
        "forced_transform_ids" => [],
      },
    }
    payload["transforms"] = RailsDependencyPruner::TransformRegistry.transforms_for_payload(payload)
    payload["expected_events"] = payload.fetch("transforms").flat_map { |transform| Array(transform["expected_events"]) }
    RailsDependencyPruner::ProfileSchema.set_profile_id(payload, RailsDependencyPruner::Profile.new(payload).digest)
    RailsDependencyPruner::Profile.new(payload).write(path)
  end

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
    assert_includes planner.used_constants, "ActiveRecord::Relation"
    assert_includes planner.used_constants, "ActiveRecord::UnusedRecordFeature"
    assert_includes planner.used_constants, "ActiveRecord::OrphanFeature"
    assert_includes planner.used_constants, "ActionController::UnusedControllerFeature"

    refute_includes planner.unused_features, "activerecord/lib/active_record/orphan_feature.rb"
    refute_includes planner.unused_require_paths, "active_record/orphan_feature"
    refute_includes planner.unused_require_paths, "active_record/base"
  end

  def test_reference_app_regression_matrix_matches_expected_boot_plans
    index = RailsDependencyPruner::ConstantIndex.build(
      rails_root: FAKE_RAILS_ROOT,
      frameworks: RailsDependencyPruner::ConstantIndex::DEFAULT_FRAMEWORKS,
    )
    matrix = YAML.safe_load(File.read(REFERENCE_APPS_ROOT.join("matrix.yml")), aliases: false).fetch("apps")

    matrix.each do |name, expectation|
      app_root = REFERENCE_APPS_ROOT.join(name)
      usage = RailsDependencyPruner::AppUsage.scan(app_root: app_root, index: index)
      planner = RailsDependencyPruner::Planner.new(index: index, usage: usage)
      plan = RailsDependencyPruner::BootPrunePlanner.new(planner).plan

      assert_empty usage.parse_errors, name
      assert_equal expectation.fetch("expected_required").sort, plan.required_frameworks, name
      assert_equal expectation.fetch("expected_pruned").sort, plan.pruned_frameworks, name
    end
  end

  def test_reference_observability_fixture_reports_integrations
    stdout, stderr, status = Open3.capture3(
      RUBY,
      ROOT.join("exe/rails-dependency-pruner").to_s,
      "doctor",
      "--app",
      REFERENCE_APPS_ROOT.join("observability_integrations").to_s,
      "--json",
      chdir: ROOT.to_s,
    )

    assert status.success?, stderr

    payload = JSON.parse(stdout)
    assert_equal %w[honeybadger rack-mini-profiler rollbar sentry-rails], payload.dig("capabilities", "integrations")
    assert_equal true, payload.dig("capabilities", "direct_gem_usage", "sentry", "present")
    assert_equal true, payload.dig("capabilities", "direct_gem_usage", "honeybadger", "present")
    assert_equal true, payload.dig("capabilities", "direct_gem_usage", "rollbar", "present")
    assert_equal "use", payload.dig("capabilities", "middleware", 0, "operation")
    assert_equal "Rack::MiniProfiler", payload.dig("capabilities", "middleware", 0, "target")
  end

  def test_app_literal_require_keeps_rails_file_constants
    Dir.mktmpdir("rails_dependency_pruner_static_require") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "config/require_mailer.rb"), "require \"action_mailer/base\"\n")

      index = RailsDependencyPruner::ConstantIndex.build(
        rails_root: FAKE_RAILS_ROOT,
        frameworks: %w[actionmailer actionpack activerecord],
      )
      usage = RailsDependencyPruner::AppUsage.scan(app_root: app_root, index: index)
      planner = RailsDependencyPruner::Planner.new(index: index, usage: usage)

      require_targets = usage.sorted_require_matches.map { |match| match.fetch("target") }
      assert_includes require_targets, "action_mailer/base"
      assert_includes usage.direct_rails_require_constants, "ActionMailer::Base"
      assert_includes planner.used_constants, "ActionMailer::Base"
      refute_includes planner.unused_require_paths, "action_mailer/base"
    end
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
      frameworks: %w[actionmailer actionpack activerecord],
    )
    usage = RailsDependencyPruner::AppUsage.scan(app_root: FAKE_APP_ROOT, index: index)
    runtime_evidence = RailsDependencyPruner::RuntimeEvidence.new(
      paths: [ROOT.join("test/fixtures/runtime_evidence.json").to_s],
      index: index,
    )
    planner = RailsDependencyPruner::Planner.new(index: index, usage: usage, runtime_evidence: runtime_evidence)

    assert_includes planner.runtime_constants, "ActiveRecord::Relation"
    assert_includes planner.runtime_constants, "ActiveRecord::OrphanFeature"
    assert_includes planner.runtime_constants, "ActionMailer"
    assert_includes planner.runtime_constants, "ActionMailer::Base"
    assert_includes planner.runtime_constants, "ActionController::UnusedControllerFeature"
    assert_includes planner.used_constants, "ActiveRecord::Relation"
    assert_includes planner.used_constants, "ActiveRecord::OrphanFeature"
    assert_includes planner.used_constants, "ActionMailer::Base"
    assert_includes planner.used_constants, "ActionController::UnusedControllerFeature"
    refute_includes planner.unused_constants, "ActiveRecord::Relation"
    refute_includes planner.unused_constants, "ActiveRecord::OrphanFeature"
    refute_includes planner.unused_constants, "ActionMailer"
    refute_includes planner.unused_constants, "ActionMailer::Base"
    refute_includes planner.unused_constants, "ActionController::UnusedControllerFeature"
    refute_includes planner.unused_require_paths, "active_record/orphan_feature"
    refute_includes planner.unused_require_paths, "action_mailer/base"
  end

  def test_runtime_evidence_ignores_empty_rails_application_snapshot
    Dir.mktmpdir("rails_dependency_pruner_runtime_evidence") do |dir|
      evidence_path = File.join(dir, "runtime.json")
      File.write(evidence_path, JSON.pretty_generate("rails_application" => {}))

      index = RailsDependencyPruner::ConstantIndex.build(
        rails_root: FAKE_RAILS_ROOT,
        frameworks: %w[actionpack],
      )
      runtime_evidence = RailsDependencyPruner::RuntimeEvidence.new(paths: [evidence_path], index: index)

      assert_empty runtime_evidence.rails_application
    end
  end

  def test_runtime_evidence_summarizes_early_boot_events
    Dir.mktmpdir("rails_dependency_pruner_runtime_events") do |dir|
      evidence_path = File.join(dir, "early.json")
      File.write(evidence_path, JSON.pretty_generate(
        "mode" => "canary",
        "events" => [
          {
            "mode" => "canary",
            "phase" => "boot",
            "action" => "skipped",
            "path" => "rails/test_unit/railtie",
            "event_id" => "boot:skipped:rails/test_unit/railtie",
            "expected" => true,
          },
          {
            "mode" => "canary",
            "phase" => "request",
            "action" => "loaded_lazy_gem",
            "gem" => "ruby-vips",
            "event_id" => "request:loaded_lazy_gem:ruby-vips",
            "expected" => false,
            "caller_path" => "app/models/story_image.rb",
            "caller_line" => 12,
          },
        ],
        "counters" => {
          "pruner.profile.valid" => 1,
          "pruner.event.total" => 2,
          "pruner.event.expected" => 1,
          "pruner.event.unexpected" => 1,
          "pruner.event.skipped_require" => 1,
          "pruner.event.lazy_load" => 1,
          "pruner.memory.baseline_reference_rss_kb" => 100_000,
          "pruner.memory.current_rss_kb" => 50_000,
        },
      ))
      second_evidence_path = File.join(dir, "runtime_events_2.json")
      File.write(second_evidence_path, JSON.pretty_generate(
        "mode" => "canary",
        "events_count" => 0,
        "expected_events_count" => 0,
        "unexpected_events_count" => 0,
        "counters" => {
          "pruner.event.total" => 0,
          "pruner.memory.baseline_reference_rss_kb" => 100_000,
          "pruner.memory.current_rss_kb" => 60_000,
        },
      ))

      index = RailsDependencyPruner::ConstantIndex.build(
        rails_root: FAKE_RAILS_ROOT,
        frameworks: %w[actionpack activerecord],
      )
      runtime_evidence = RailsDependencyPruner::RuntimeEvidence.new(paths: [evidence_path, second_evidence_path], index: index)
      summary = runtime_evidence.event_summary

      assert_equal 2, summary.fetch("files_count")
      assert_equal 2, summary.fetch("events_count")
      assert_equal 1, summary.fetch("expected_events_count")
      assert_equal 1, summary.fetch("unexpected_events_count")
      assert_equal 1, summary.dig("counters", "pruner.profile.valid")
      assert_equal 2, summary.dig("counters", "pruner.event.total")
      assert_equal 1, summary.dig("counters", "pruner.event.unexpected")
      assert_equal 100_000, summary.dig("counters", "pruner.memory.baseline_reference_rss_kb")
      assert_equal 60_000, summary.dig("counters", "pruner.memory.current_rss_kb")
      assert_equal 1, summary.dig("files", 0, "counters", "pruner.event.lazy_load")
      assert_equal 50_000, summary.dig("files", 0, "counters", "pruner.memory.current_rss_kb")
      assert_equal "request:loaded_lazy_gem:ruby-vips", summary.dig("files", 0, "unexpected_events", 0, "event_id")
      assert_equal "app/models/story_image.rb", summary.dig("files", 0, "unexpected_events", 0, "caller_path")
    end
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
    assert graph.edges.any? { |edge| edge.from == base_constant_id && edge.to == base_file_id && edge.type == :defined_in }
    assert graph.edges.any? { |edge| edge.from == base_file_id && edge.to == orphan_require_id && edge.type == :requires }
    assert graph.edges.any? { |edge| edge.from == orphan_require_id && edge.to == graph.file_id("activerecord/lib/active_record/orphan_feature.rb") && edge.type == :resolves_to }
    assert graph.edges.any? { |edge| edge.from == graph.constant_id("ActiveRecord::Base") && edge.to == graph.constant_id("ActiveRecord::Persistence") }

    explanation = planner.explain_constant("ActiveRecord::Base")
    assert_equal "used", explanation.fetch("decision")
    assert_equal "static", explanation.fetch("seed")
    assert_equal "activerecord", explanation.fetch("component")
    assert_equal ["constant:ActiveRecord::Base"], explanation.fetch("reachability_path").map { |entry| entry.fetch("node") }

    same_file = planner.explain_constant("ActiveRecord::UnusedRecordFeature")
    assert_equal "used", same_file.fetch("decision")
    assert_equal [
      "constant:ActiveRecord::Base",
      "file:activerecord/lib/active_record/base.rb",
      "constant:ActiveRecord::UnusedRecordFeature",
    ], same_file.fetch("reachability_path").map { |entry| entry.fetch("node") }
  end

  def test_cli_explains_constant_usage_as_json
    stdout, stderr, status = Open3.capture3(
      RUBY,
      ROOT.join("exe/rails-dependency-pruner").to_s,
      "explain",
      "--rails-root",
      FAKE_RAILS_ROOT.to_s,
      "--frameworks",
      "actionmailer,actionpack,activerecord",
      "--app",
      FAKE_APP_ROOT.to_s,
      "--json",
      "ActionMailer::Base",
      chdir: ROOT.to_s,
    )

    assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal "ActionMailer::Base", payload.fetch("constant")
      assert_equal "unused", payload.fetch("decision")
      assert_equal "actionmailer", payload.fetch("component")
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

      active_storage_match = usage.feature_matches.find { |match| match.fetch("feature") == "active_storage" }
      assert_equal "dsl", active_storage_match.fetch("evidence_kind")
      assert_equal ["active_storage/engine"], active_storage_match.fetch("railties")
      assert_equal ["active_storage"], active_storage_match.fetch("coverage_required")
      assert active_storage_match.fetch("negative_rules").any? { |rule| rule.fetch("evidence") == "has_one_attached" }
      assert_equal "rails_8_1", usage.to_h.dig(:feature_catalog, :name)

      refute_includes planner.unused_constants, "ActiveStorage::Blob"
      refute_includes planner.unused_constants, "ActionText::RichText"
    end
  end

  def test_feature_catalog_loads_versioned_rails_catalogs
    rails81 = RailsDependencyPruner::FeatureCatalog.for_rails_version("8.1.3")
    rails80 = RailsDependencyPruner::FeatureCatalog.for_rails_version(Gem::Version.new("8.0.4"))
    fallback = RailsDependencyPruner::FeatureCatalog.for_rails_version("9.0.0")

    assert_equal "rails_8_1", rails81.name
    assert_equal "8.1", rails81.rails_version
    assert_equal "rails_8_0", rails80.name
    assert_equal "8.0", rails80.rails_version
    assert_equal "rails_8_1", fallback.name
    assert_equal "8.1", fallback.rails_version
    assert_includes rails81.to_h.keys, "active_storage"
    assert_includes rails81.to_h.dig("active_storage", "constants"), "ActiveStorage::Blob"
    assert_equal ["active_storage/engine"], rails81.to_h.dig("active_storage", "railties")
    assert_equal ["has_many_attached", "has_one_attached"], rails81.to_h.dig("active_storage", "dsl")
    assert_equal ["active_storage"], rails81.to_h.dig("active_storage", "coverage_required")
    assert rails81.to_h.dig("active_storage", "negative_rules").any? { |rule| rule.fetch("evidence") == "config.active_storage.*" }
    assert_includes rails81.to_h.keys, "active_model"
  end

  def test_dynamic_constant_patterns_keep_exact_literal_constants
    Dir.mktmpdir("rails_dependency_pruner_dynamic_constants") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(
        File.join(app_root, "app/models/dynamic_rails_use.rb"),
        <<~RUBY,
          class DynamicRailsUse
            def exact
              "ActiveRecord::Relation".constantize
              "ActionController::UnusedControllerFeature".safe_constantize
              Object.const_get("ActiveRecord::UnusedRecordFeature")
              Object.const_defined?(:ActionController)
              ActiveSupport.const_get(:Dependencies)
            end

            def risky(name)
              name.constantize
              Kernel.const_get(name)
            end
          end
        RUBY
      )

      index = RailsDependencyPruner::ConstantIndex.build(
        rails_root: FAKE_RAILS_ROOT,
        frameworks: %w[actionpack activerecord activesupport],
      )
      usage = RailsDependencyPruner::AppUsage.scan(app_root: app_root, index: index)
      planner = RailsDependencyPruner::Planner.new(index: index, usage: usage)

      assert_includes usage.direct_rails_constants, "ActiveRecord::Relation"
      assert_includes usage.direct_rails_constants, "ActiveRecord::UnusedRecordFeature"
      assert_includes usage.direct_rails_constants, "ActionController::UnusedControllerFeature"
      assert_includes usage.direct_rails_constants, "ActiveSupport::Dependencies"

      refute_includes planner.unused_constants, "ActiveRecord::Relation"
      refute_includes planner.unused_constants, "ActiveRecord::UnusedRecordFeature"
      refute_includes planner.unused_constants, "ActionController::UnusedControllerFeature"

      exact = usage.dynamic_matches.find { |match| match["constant"] == "ActiveRecord::Relation" }
      assert_equal "constantize", exact.fetch("kind")
      assert_equal 1.0, exact.fetch("confidence")
      assert_equal false, exact.fetch("dynamic")

      risky = usage.dynamic_matches.select { |match| match["dynamic"] }
      assert risky.any? { |match| match.fetch("kind") == "constantize" && match.fetch("confidence") == 0.2 }
      assert risky.any? { |match| match.fetch("kind") == "const_get" && match.fetch("confidence") == 0.3 }
    end
  end

  def test_require_scanner_tracks_only_ruby_load_edges
    Dir.mktmpdir("rails_dependency_pruner_require_scanner") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(
        File.join(app_root, "app/controllers/require_scanner_controller.rb"),
        <<~RUBY,
          class RequireScannerController < ApplicationController
            def show
              params.require(:id)
              Message.all.load
              Kernel.require "active_record/base"
              require Rails.root.join("lib/time_series.rb").to_s
            end
          end
        RUBY
      )

      index = RailsDependencyPruner::ConstantIndex.build(
        rails_root: FAKE_RAILS_ROOT,
        frameworks: %w[actionpack activerecord],
      )
      usage = RailsDependencyPruner::AppUsage.scan(app_root: app_root, index: index)

      matches = usage.sorted_require_matches.select do |match|
        match.fetch("path") == "app/controllers/require_scanner_controller.rb"
      end
      assert_equal [
        ["active_record/base", false, "require"],
        ["lib/time_series.rb", false, "require"],
      ], matches.map { |match| [match["target"], match.fetch("dynamic"), match.fetch("kind")] }
    end
  end

  def test_config_patterns_keep_framework_constants
    Dir.mktmpdir("rails_dependency_pruner_config_patterns") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config/environments"))
      File.write(
        File.join(app_root, "config/environments/production.rb"),
        <<~RUBY,
          Rails.application.configure do
            config.active_storage.service = :local
            config.action_mailer.delivery_method = :test
            config.active_job.queue_adapter = :inline
            config.active_support.deprecation = :stderr
            config.action_controller.perform_caching = true
            Rails.application.config.active_record.query_log_tags = [:controller, :job]
          end
        RUBY
      )

      index = RailsDependencyPruner::ConstantIndex.build(
        rails_root: FAKE_RAILS_ROOT,
        frameworks: %w[
          actionmailer
          actionpack
          activejob
          activerecord
          activestorage
          activesupport
        ],
      )
      usage = RailsDependencyPruner::AppUsage.scan(app_root: app_root, index: index)
      planner = RailsDependencyPruner::Planner.new(index: index, usage: usage)

      assert_includes usage.direct_rails_constants, "ActiveStorage::Blob"
      assert_includes usage.direct_rails_constants, "ActionMailer::Base"
      assert_includes usage.direct_rails_constants, "ActiveJob::Base"
      assert_includes usage.direct_rails_constants, "ActiveSupport::Dependencies"

      refute_includes planner.unused_constants, "ActiveStorage::Blob"
      refute_includes planner.unused_constants, "ActionMailer::Base"
      refute_includes planner.unused_constants, "ActiveJob::Base"
      refute_includes planner.unused_constants, "ActiveSupport::Dependencies"

      config_paths = usage.sorted_config_matches.map { |match| match.fetch("config_path") }
      assert_includes config_paths, "active_storage.service"
      assert_includes config_paths, "action_mailer.delivery_method"
      assert_includes config_paths, "active_job.queue_adapter"
      assert_includes config_paths, "active_support.deprecation"
      assert_includes config_paths, "active_record.query_log_tags"

      storage_config_match = usage.sorted_config_matches.find { |match| match.fetch("feature") == "active_storage" }
      assert_equal "config", storage_config_match.fetch("evidence_kind")
      assert_equal ["active_storage/engine"], storage_config_match.fetch("railties")
      assert_equal ["active_storage"], storage_config_match.fetch("coverage_required")
    end
  end

  def test_route_patterns_keep_framework_constants
    Dir.mktmpdir("rails_dependency_pruner_route_patterns") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(
        File.join(app_root, "config/routes.rb"),
        <<~RUBY,
          Rails.application.routes.draw do
            root to: "home#index"
            get "/posts" => "posts#index"
            resources :stories
            mount ActionCable.server => "/cable"
            direct :rails_blob do |blob|
              "/rails/active_storage/blobs/\#{blob.id}"
            end
          end
        RUBY
      )

      index = RailsDependencyPruner::ConstantIndex.build(
        rails_root: FAKE_RAILS_ROOT,
        frameworks: %w[actioncable actionpack activestorage],
      )
      usage = RailsDependencyPruner::AppUsage.scan(app_root: app_root, index: index, scan_roots: %w[config])
      planner = RailsDependencyPruner::Planner.new(index: index, usage: usage)

      assert_includes usage.direct_rails_constants, "ActionController::Base"
      assert_includes usage.direct_rails_constants, "ActionCable::Channel::Base"
      assert_includes usage.direct_rails_constants, "ActiveStorage::Blob"

      refute_includes planner.unused_constants, "ActionController::Base"
      refute_includes planner.unused_constants, "ActionCable::Channel::Base"
      refute_includes planner.unused_constants, "ActiveStorage::Blob"

      route_signatures = usage.sorted_route_matches.map { |match| match.fetch("route_signature") }
      assert_includes route_signatures, "route:get"
      assert_includes route_signatures, "route:resources"
      assert_includes route_signatures, "mount:ActionCable.server"
      assert_includes route_signatures, "direct:rails_blob"

      cable_route_match = usage.sorted_route_matches.find { |match| match.fetch("feature") == "action_cable" }
      assert_equal "route", cable_route_match.fetch("evidence_kind")
      assert_equal ["action_cable/engine"], cable_route_match.fetch("railties")
      assert_equal ["channels"], cable_route_match.fetch("coverage_required")
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
        "actionmailer,actionpack,activerecord",
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
      assert_includes payload.fetch("unused_constants"), "ActionMailer::Base"
      assert_includes payload.fetch("unused_require_paths"), "action_mailer/base"
      assert File.exist?(profile_path)
      assert File.exist?(shim_path)

      profile = JSON.parse(File.read(profile_path))
      assert_includes profile.fetch("unused_constants"), "ActionMailer::Base"
      assert_includes profile.fetch("unused_require_paths"), "action_mailer/base"

      guard_stdout, guard_stderr, guard_status = Open3.capture3(
        RUBY,
        "-e",
        <<~RUBY,
          module ActionMailer; end
          require #{shim_path.dump}

          begin
            ActionMailer::Base.new
          rescue RailsDependencyPrunerShim::DisabledConstantError => error
            abort unless error.message.include?("ActionMailer::Base.new")
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
            require "action_mailer/base"
          rescue RailsDependencyPrunerShim::DisabledConstantError => error
            abort unless error.message.include?("action_mailer/base")
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
      assert_equal 3, profile.schema_version
      assert_match(/\Asha256:/, profile.profile_id)
      assert_equal profile.digest, profile.profile_id
      assert_equal profile.profile_id, profile.payload.dig("fingerprints", "profile_id")
      assert_equal "rails_dependency_pruner", profile.payload.dig("tool", "name")
      assert profile.payload.fetch("environment").key?("rails_version")
      assert_equal "rails_8_1", profile.payload.dig("analysis", "feature_catalog", "name")
      assert_equal "8.1", profile.payload.dig("analysis", "feature_catalog", "rails_version")
      assert_match(/\Asha256:/, profile.payload.dig("analysis", "feature_catalog", "digest"))
      assert_match(/\Asha256:/, profile.payload.dig("fingerprints", "source_manifest_sha256"))
      refute_includes profile.unused_require_paths, "active_record/orphan_feature"
      assert_includes profile.payload.fetch("require_matches").map { |match| match.fetch("target") }, "active_record/railtie"

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
      assert_includes stderr, "fingerprints.gemfile_lock_sha256 mismatch"
    end
  end

  def test_profile_validate_rejects_changed_routes
    Dir.mktmpdir("rails_dependency_pruner_stale_routes") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config"))
      File.write(File.join(app_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
      profile_path = File.join(dir, "profile.json")
      write_deterministic_profile(profile_path: profile_path, app_root: app_root)

      File.open(File.join(app_root, "config/routes.rb"), "a") do |file|
        file.puts "get \"/health\" => \"application#show\""
      end

      _stdout, stderr, status = validate_profile(profile_path: profile_path, app_root: app_root)
      refute status.success?
      assert_includes stderr, "fingerprints.routes_sha256 mismatch"
    end
  end

  def test_profile_validate_rejects_changed_initializer
    Dir.mktmpdir("rails_dependency_pruner_stale_initializer") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config/initializers"))
      File.write(File.join(app_root, "config/initializers/current.rb"), "Rails.application.config.x.current = true\n")
      profile_path = File.join(dir, "profile.json")
      write_deterministic_profile(profile_path: profile_path, app_root: app_root)

      File.open(File.join(app_root, "config/initializers/current.rb"), "a") do |file|
        file.puts "Rails.application.config.x.changed = true"
      end

      _stdout, stderr, status = validate_profile(profile_path: profile_path, app_root: app_root)
      refute status.success?
      assert_includes stderr, "fingerprints.initializers_sha256 mismatch"
    end
  end

  def test_profile_validate_ignores_unrelated_tmp_files
    Dir.mktmpdir("rails_dependency_pruner_tmp_files") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      profile_path = File.join(dir, "profile.json")
      write_deterministic_profile(profile_path: profile_path, app_root: app_root)

      FileUtils.mkdir_p(File.join(app_root, "tmp/cache"))
      File.write(File.join(app_root, "tmp/cache/noise.rb"), "raise 'ignored'\n")

      _stdout, stderr, status = validate_profile(profile_path: profile_path, app_root: app_root)
      assert status.success?, stderr
    end
  end

  def test_profile_validate_rejects_unknown_unexpected_event_policy
    Dir.mktmpdir("rails_dependency_pruner_event_policy") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      profile_path = File.join(dir, "profile.json")
      write_deterministic_profile(profile_path: profile_path, app_root: app_root)

      payload = JSON.parse(File.read(profile_path))
      payload["unexpected_event_policy"] = "ignore_events"
      RailsDependencyPruner::ProfileSchema.set_profile_id(payload, RailsDependencyPruner::Profile.new(payload).digest)
      RailsDependencyPruner::Profile.new(payload).write(profile_path)

      _stdout, stderr, status = validate_profile(profile_path: profile_path, app_root: app_root)
      refute status.success?
      assert_includes stderr, "unexpected_event_policy invalid"
      assert_includes stderr, "ignore_events"
    end
  end

  def test_profile_schema_migrates_v2_payload_shape
    migrated = RailsDependencyPruner::ProfileSchema.migrate_v2(
      "schema_version" => 2,
      "profile_id" => "sha256:old",
      "ruby" => {
        "version" => "4.0.5",
        "platform" => "arm64-darwin",
      },
      "rails" => {
        "version" => "8.1.3",
      },
      "bundler" => {
        "gemfile_lock_digest" => "sha256:lock",
      },
      "app" => {
        "files_digest" => "sha256:files",
        "rails_env" => "production",
      },
      "evidence" => {
        "coverage_manifest_digest" => "sha256:coverage",
      },
      "analysis" => {
        "scanner_version" => "0.1.0",
      },
    )

    assert_equal 3, migrated.fetch("schema_version")
    assert_equal "rails_dependency_pruner", migrated.dig("tool", "name")
    assert_equal "4.0.5", migrated.dig("environment", "ruby_version")
    assert_equal "sha256:old", migrated.dig("fingerprints", "profile_id")
    assert_equal "sha256:lock", migrated.dig("fingerprints", "gemfile_lock_sha256")
    assert_equal "sha256:files", migrated.dig("fingerprints", "source_manifest_sha256")
    assert_equal "sha256:coverage", migrated.dig("fingerprints", "coverage_manifest_sha256")
    assert_equal [], migrated.fetch("expected_events")
    assert_equal "fail_in_canary_report_in_production", migrated.fetch("unexpected_event_policy")
    assert_equal({}, migrated.fetch("lazy_constants"))
    assert_equal "reject", migrated.dig("safety_policy", "unknown_dynamic_require")
    assert_equal "reject_if_pruned_namespace_possible", migrated.dig("safety_policy", "unknown_dynamic_constantize")
    assert_equal [], migrated.fetch("overrides")
  end

  def test_profile_digest_preserves_legacy_v2_shape
    payload = {
      "schema_version" => 2,
      "profile_id" => nil,
      "mode" => "boot_prune",
      "ruby" => {},
      "rails" => {},
      "bundler" => {},
      "app" => {},
      "analysis" => {},
      "evidence" => {},
      "summary" => {},
      "pruning" => {
        "disabled_constants" => [],
        "disabled_require_paths" => [],
      },
      "safety" => {
        "production_allowed" => true,
      },
    }
    digest = RailsDependencyPruner::Profile.new(payload).digest
    payload["profile_id"] = digest

    assert_equal digest, RailsDependencyPruner::Profile.new(payload).digest
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

  def test_profile_diff_reports_lazy_constant_policy_changes
    Dir.mktmpdir("rails_dependency_pruner_profile_diff_lazy_constants") do |dir|
      old_profile = File.join(dir, "old.json")
      new_profile = File.join(dir, "new.json")
      File.write(old_profile, JSON.pretty_generate(
        "schema_version" => 3,
        "lazy_constants" => {
          "Faker" => {
            "gem" => "faker",
            "allowed_phases" => ["boot"],
          },
        },
        "pruning" => {
          "disabled_constants" => [],
          "disabled_require_paths" => [],
        },
      ))
      File.write(new_profile, JSON.pretty_generate(
        "schema_version" => 3,
        "lazy_constants" => {
          "Faker" => {
            "gem" => "faker",
            "allowed_phases" => ["manual_app_use"],
          },
        },
        "pruning" => {
          "disabled_constants" => [],
          "disabled_require_paths" => [],
        },
      ))

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
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
      assert payload.fetch("context_changes").any? { |change| change.fetch("key") == "lazy_constants" }
    end
  end

  def test_profile_diff_reports_safety_policy_changes
    Dir.mktmpdir("rails_dependency_pruner_profile_diff_safety_policy") do |dir|
      old_profile = File.join(dir, "old.json")
      new_profile = File.join(dir, "new.json")
      payload = {
        "schema_version" => 3,
        "safety_policy" => RailsDependencyPruner::SafetyPolicy.defaults,
        "pruning" => {
          "disabled_constants" => [],
          "disabled_require_paths" => [],
        },
      }
      weakened = Marshal.load(Marshal.dump(payload))
      weakened["safety_policy"]["unknown_dynamic_require"] = "report"
      File.write(old_profile, JSON.pretty_generate(payload))
      File.write(new_profile, JSON.pretty_generate(weakened))

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
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
      assert payload.fetch("context_changes").any? { |change| change.fetch("key") == "safety_policy" }
    end
  end

  def test_profile_diff_reports_safety_override_changes
    Dir.mktmpdir("rails_dependency_pruner_profile_diff_overrides") do |dir|
      old_profile = File.join(dir, "old.json")
      new_profile = File.join(dir, "new.json")
      payload = {
        "schema_version" => 3,
        "overrides" => [],
        "pruning" => {
          "disabled_constants" => [],
          "disabled_require_paths" => [],
        },
      }
      changed = Marshal.load(Marshal.dump(payload))
      changed["overrides"] = [
        {
          "id" => "allow_dynamic_constantize_admin_reports",
          "reason" => "Admin reports constantize only app-owned report classes",
          "owner" => "platform-team",
          "expires_at" => "2099-01-01",
          "paths" => ["app/services/report_runner.rb"],
        },
      ]
      File.write(old_profile, JSON.pretty_generate(payload))
      File.write(new_profile, JSON.pretty_generate(changed))

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "diff",
        "--old",
        old_profile,
        "--new",
        new_profile,
        "--semantic",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      diff = JSON.parse(stdout)
      assert_equal true, diff.fetch("changed")
      assert_equal true, diff.fetch("semantic")
      assert diff.fetch("context_changes").any? { |change| change.fetch("key") == "overrides" }
    end
  end

  def test_profile_diff_semantic_ignores_approval_only_changes
    Dir.mktmpdir("rails_dependency_pruner_profile_semantic_diff") do |dir|
      old_profile = File.join(dir, "old.json")
      new_profile = File.join(dir, "new.json")
      payload = {
        "schema_version" => 3,
        "profile_id" => "sha256:old",
        "fingerprints" => {
          "profile_id" => "sha256:old",
          "source_manifest_sha256" => "sha256:source",
        },
        "safety" => {
          "production_allowed" => false,
        },
        "pruning" => {
          "disabled_constants" => ["ActiveRecord::Thing"],
          "disabled_require_paths" => ["active_record/thing"],
        },
      }
      approved = Marshal.load(Marshal.dump(payload))
      approved["profile_id"] = "sha256:new"
      approved["fingerprints"]["profile_id"] = "sha256:new"
      approved["safety"]["production_allowed"] = true
      approved["safety"]["approved_at"] = "2026-07-05T12:00:00Z"
      approved["safety"]["approved_by"] = "release-owner"
      approved["safety"]["verifier_version"] = "0.1.0"
      approved["safety"]["errors"] = []
      approved["safety"]["warnings"] = []

      File.write(old_profile, JSON.pretty_generate(payload))
      File.write(new_profile, JSON.pretty_generate(approved))

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "diff",
        "--old",
        old_profile,
        "--new",
        new_profile,
        "--semantic",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      diff = JSON.parse(stdout)
      assert_equal true, diff.fetch("semantic")
      assert_equal false, diff.fetch("changed")
      assert_empty diff.fetch("context_changes")
    end
  end

  def test_check_accepts_current_deterministic_profile
    Dir.mktmpdir("rails_dependency_pruner_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      profile_path = File.join(dir, "profile.json")
      write_deterministic_profile(profile_path: profile_path, app_root: app_root)

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "check",
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

  def test_verify_production_rejects_unknown_unexpected_event_policy
    Dir.mktmpdir("rails_dependency_pruner_verify_event_policy") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      build_profile(profile_path: profile_path, app_root: app_root, coverage_path: coverage_path)
      payload = JSON.parse(File.read(profile_path))
      payload["unexpected_event_policy"] = "ignore_events"
      RailsDependencyPruner::ProfileSchema.set_profile_id(payload, RailsDependencyPruner::Profile.new(payload).digest)
      RailsDependencyPruner::Profile.new(payload).write(profile_path)

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_equal false, payload.fetch("verified")
      assert payload.fetch("errors").any? { |error| error.include?("unexpected_event_policy invalid") }
    end
  end

  def test_verify_production_rejects_dynamic_boot_requires
    Dir.mktmpdir("rails_dependency_pruner_dynamic_require_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "config/dynamic_require.rb"), <<~RUBY)
        feature = ENV.fetch("BOOT_FEATURE")
        require feature
      RUBY
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      build_profile(profile_path: profile_path, app_root: app_root, coverage_path: coverage_path)

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_equal false, payload.fetch("verified")
      assert payload.fetch("errors").any? { |error| error.include?("dynamic require/load risk: config/dynamic_require.rb:2:require") }
      assert_equal "config/dynamic_require.rb", payload.dig("production_risks", "dynamic_boot_require_matches", 0, "path")
    end
  end

  def test_verify_production_allows_overridden_dynamic_boot_requires
    Dir.mktmpdir("rails_dependency_pruner_dynamic_require_override") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "config/dynamic_require.rb"), <<~RUBY)
        feature = ENV.fetch("BOOT_FEATURE")
        require feature
      RUBY
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        overrides:
          - id: allow_dynamic_boot_feature
            owner: platform-team
            reason: boot feature names are app-owned and reviewed
            expires_at: 2099-01-01
            paths:
              - config/dynamic_require.rb
      YAML
      profile_path = File.join(dir, "profile.json")

      build_profile(profile_path: profile_path, app_root: app_root, coverage_path: coverage_path)

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stdout + stderr

      payload = JSON.parse(stdout)
      assert_equal true, payload.fetch("verified")
      assert_empty payload.dig("production_risks", "dynamic_boot_require_matches")
    end
  end

  def test_verify_production_ignores_expired_dynamic_boot_override
    Dir.mktmpdir("rails_dependency_pruner_dynamic_require_expired_override") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "config/dynamic_require.rb"), <<~RUBY)
        feature = ENV.fetch("BOOT_FEATURE")
        require feature
      RUBY
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        overrides:
          - id: allow_dynamic_boot_feature
            owner: platform-team
            reason: expired review
            expires_at: 2000-01-01
            paths:
              - config/dynamic_require.rb
      YAML
      profile_path = File.join(dir, "profile.json")

      build_profile(profile_path: profile_path, app_root: app_root, coverage_path: coverage_path)

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert payload.fetch("errors").any? { |error| error.include?("dynamic require/load risk: config/dynamic_require.rb:2:require") }
      assert_equal "config/dynamic_require.rb", payload.dig("production_risks", "dynamic_boot_require_matches", 0, "path")
    end
  end

  def test_verify_production_rejects_missing_framework_coverage_workloads
    Dir.mktmpdir("rails_dependency_pruner_coverage_workload_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      build_profile(
        profile_path: profile_path,
        app_root: app_root,
        coverage_path: coverage_path,
        frameworks: "actionmailer,actionpack,activerecord",
      )

      profile = JSON.parse(File.read(profile_path))
      assert_includes profile.dig("pruning", "disabled_frameworks"), "actionmailer"
      refute_includes profile.dig("evidence", "workloads"), "mailers"

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
        "actionmailer,actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_equal false, payload.fetch("verified")
      assert_includes payload.fetch("errors"), "production verify missing coverage workload for disabled framework: actionmailer requires mailers"
      assert_equal(
        {
          "framework" => "actionmailer",
          "required_workloads" => ["mailers"],
          "missing_workloads" => ["mailers"],
        },
        payload.dig("production_risks", "coverage_workload_gaps", 0),
      )
    end
  end

  def test_verify_production_rejects_missing_action_text_coverage_workload
    Dir.mktmpdir("rails_dependency_pruner_action_text_coverage_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      build_profile(
        profile_path: profile_path,
        app_root: app_root,
        coverage_path: coverage_path,
        frameworks: "actionpack,activerecord,actiontext",
      )

      profile = JSON.parse(File.read(profile_path))
      assert_includes profile.dig("pruning", "disabled_frameworks"), "actiontext"
      refute_includes profile.dig("evidence", "workloads"), "action_text"

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
        "actionpack,activerecord,actiontext",
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_equal false, payload.fetch("verified")
      assert_includes payload.fetch("errors"), "production verify missing coverage workload for disabled framework: actiontext requires action_text"
      assert_equal(
        {
          "framework" => "actiontext",
          "required_workloads" => ["action_text"],
          "missing_workloads" => ["action_text"],
        },
        payload.dig("production_risks", "coverage_workload_gaps", 0),
      )
    end
  end

  def test_verify_production_rejects_missing_extreme_boot_coverage_workloads
    Dir.mktmpdir("rails_dependency_pruner_extreme_coverage_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "app/models/avatar.rb"), <<~RUBY)
        class Avatar < ApplicationRecord
          has_one_attached :image
        end
      RUBY
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--disable-eager-load",
        "--skip-railties",
        "active_storage/engine",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify missing coverage workload for extreme boot: disable_eager_load requires requests"
      assert_includes payload.fetch("errors"), "production verify missing coverage workload for extreme boot: active_storage/engine requires attachments"
      assert_includes payload.fetch("errors"), "production verify missing catalog coverage workload: active_storage/engine active_storage:has_one_attached:app/models/avatar.rb:2 requires attachments"
      assert_equal %w[active_storage/engine disable_eager_load], payload.dig("production_risks", "extreme_boot_workload_gaps").map { |gap| gap.fetch("framework") }.sort
      catalog_gap = payload.dig("production_risks", "catalog_coverage_gaps").find do |gap|
        gap.fetch("target") == "active_storage/engine" && gap.fetch("feature") == "active_storage"
      end
      assert_equal "feature_catalog", catalog_gap.fetch("source")
      assert_equal "skip_railtie", catalog_gap.fetch("target_kind")
      assert_equal "activestorage", catalog_gap.fetch("framework")
      assert_equal "dsl", catalog_gap.fetch("evidence_kind")
      assert_equal "has_one_attached", catalog_gap.fetch("pattern")
      assert_equal "app/models/avatar.rb", catalog_gap.fetch("path")
      assert_equal ["attachments"], catalog_gap.fetch("required_workloads")
      assert_equal ["attachments"], catalog_gap.fetch("missing_workloads")
      assert catalog_gap.fetch("negative_rules").any? { |rule| rule.fetch("evidence") == "has_one_attached" }
      static_match = payload.dig("production_risks", "extreme_boot_static_matches").find do |match|
        match.fetch("railtie") == "active_storage/engine" && match.fetch("kind") == "feature"
      end
      assert_equal "active_storage", static_match.fetch("name")
      assert_equal "has_one_attached", static_match.fetch("pattern")
      assert_equal ["active_storage/engine"], static_match.fetch("catalog_railties")
      assert_equal ["active_storage"], static_match.fetch("coverage_required")
      assert static_match.fetch("negative_rules").any? { |rule| rule.fetch("evidence") == "has_one_attached" }
    end
  end

  def test_verify_production_requires_latency_policy_for_disable_eager_load
    Dir.mktmpdir("rails_dependency_pruner_eager_load_latency_policy_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      FileUtils.mkdir_p(File.dirname(coverage_path))
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: false
        routes:
          include: all
        requests:
          - GET /privacy => 200
      YAML
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--disable-eager-load",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify missing high-risk transform proof: disable_eager_load requires memory_policy.max_first_request_latency_regression_*, memory_policy.max_request_p95_latency_regression_* or max_warmed_p95_latency_regression_*, memory_policy.max_request_p99_latency_regression_* or max_warmed_p99_latency_regression_*"
      assert_equal [
        {
          "transform_id" => "disable_eager_load",
          "requirement" => "latency_policy",
          "missing_requirements" => [
            "memory_policy.max_first_request_latency_regression_*",
            "memory_policy.max_request_p95_latency_regression_* or max_warmed_p95_latency_regression_*",
            "memory_policy.max_request_p99_latency_regression_* or max_warmed_p99_latency_regression_*",
          ],
        },
      ], payload.dig("production_risks", "high_risk_transform_gaps")
    end
  end

  def test_verify_production_allows_disable_eager_load_with_latency_policy
    Dir.mktmpdir("rails_dependency_pruner_eager_load_latency_policy_pass") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      FileUtils.mkdir_p(File.dirname(coverage_path))
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: false
        routes:
          include: all
        requests:
          - GET /privacy => 200
        memory_policy:
          min_total_savings_mib: 1
          max_first_request_latency_regression_ms: 100
          max_warmed_p95_latency_regression_percent: 5
          max_warmed_p99_latency_regression_percent: 10
      YAML
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--disable-eager-load",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

      measurement_path = File.join(dir, "measurement.json")
      File.write(measurement_path, JSON.pretty_generate(
        "variants" => {
          "baseline" => {
            "status" => "ok",
            "rss_kb_median" => 100_000,
            "first_request_duration_ms_median" => 20.0,
            "warmed_request_duration_ms_p95_median" => 10.0,
            "warmed_request_duration_ms_p99_median" => 20.0,
          },
          "boot_prune" => {
            "status" => "ok",
            "rss_kb_median" => 80_000,
            "first_request_duration_ms_median" => 30.0,
            "warmed_request_duration_ms_p95_median" => 10.3,
            "warmed_request_duration_ms_p99_median" => 21.0,
          },
        },
      ))

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
        "--coverage",
        coverage_path,
        "--measurement",
        measurement_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stdout

      payload = JSON.parse(stdout)
      assert_equal true, payload.fetch("verified")
      assert_empty payload.dig("production_risks", "high_risk_transform_gaps")
    end
  end

  def test_verify_production_requires_declared_workload_coverage_for_disable_eager_load
    Dir.mktmpdir("rails_dependency_pruner_eager_load_declared_workload_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "app/jobs"))
      File.write(File.join(app_root, "app/jobs/cleanup_job.rb"), <<~RUBY)
        class CleanupJob < ActiveJob::Base
          queue_as :default
        end
      RUBY
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      FileUtils.mkdir_p(File.dirname(coverage_path))
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: false
        routes:
          include: all
        requests:
          - GET /privacy => 200
        memory_policy:
          min_total_savings_mib: 1
          max_first_request_latency_regression_ms: 100
          max_warmed_p95_latency_regression_percent: 5
          max_warmed_p99_latency_regression_percent: 10
      YAML
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--disable-eager-load",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

      measurement_path = File.join(dir, "measurement.json")
      File.write(measurement_path, JSON.pretty_generate(
        "variants" => {
          "baseline" => {
            "status" => "ok",
            "rss_kb_median" => 100_000,
            "first_request_duration_ms_median" => 20.0,
            "warmed_request_duration_ms_p95_median" => 10.0,
            "warmed_request_duration_ms_p99_median" => 20.0,
          },
          "boot_prune" => {
            "status" => "ok",
            "rss_kb_median" => 80_000,
            "first_request_duration_ms_median" => 30.0,
            "warmed_request_duration_ms_p95_median" => 10.3,
            "warmed_request_duration_ms_p99_median" => 21.0,
          },
        },
      ))

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
        "--coverage",
        coverage_path,
        "--measurement",
        measurement_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify missing high-risk transform proof: disable_eager_load requires jobs"
      assert_equal(
        {
          "transform_id" => "disable_eager_load",
          "requirement" => "declared_workload_coverage",
          "missing_requirements" => ["jobs"],
        },
        payload.dig("production_risks", "high_risk_transform_gaps", 0),
      )
    end
  end

  def test_verify_production_allows_disable_eager_load_with_declared_job_coverage
    Dir.mktmpdir("rails_dependency_pruner_eager_load_declared_workload_pass") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "app/jobs"))
      File.write(File.join(app_root, "app/jobs/cleanup_job.rb"), <<~RUBY)
        class CleanupJob < ActiveJob::Base
          queue_as :default
        end
      RUBY
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      FileUtils.mkdir_p(File.dirname(coverage_path))
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: false
        routes:
          include: all
        requests:
          - GET /privacy => 200
        jobs:
          - CleanupJob
        memory_policy:
          min_total_savings_mib: 1
          max_first_request_latency_regression_ms: 100
          max_warmed_p95_latency_regression_percent: 5
          max_warmed_p99_latency_regression_percent: 10
      YAML
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--disable-eager-load",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

      measurement_path = File.join(dir, "measurement.json")
      File.write(measurement_path, JSON.pretty_generate(
        "variants" => {
          "baseline" => {
            "status" => "ok",
            "rss_kb_median" => 100_000,
            "first_request_duration_ms_median" => 20.0,
            "warmed_request_duration_ms_p95_median" => 10.0,
            "warmed_request_duration_ms_p99_median" => 20.0,
          },
          "boot_prune" => {
            "status" => "ok",
            "rss_kb_median" => 80_000,
            "first_request_duration_ms_median" => 30.0,
            "warmed_request_duration_ms_p95_median" => 10.3,
            "warmed_request_duration_ms_p99_median" => 21.0,
          },
        },
      ))

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
        "--coverage",
        coverage_path,
        "--measurement",
        measurement_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal true, payload.fetch("verified")
      assert_empty payload.dig("production_risks", "high_risk_transform_gaps")
    end
  end

  def test_verify_production_requires_inbound_email_when_storage_skip_keeps_mailboxes
    Dir.mktmpdir("rails_dependency_pruner_storage_mailbox_coverage_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "app/mailboxes"))
      File.write(File.join(app_root, "app/mailboxes/application_mailbox.rb"), <<~RUBY)
        class ApplicationMailbox < ActionMailbox::Base
        end
      RUBY
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      FileUtils.mkdir_p(File.dirname(coverage_path))
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        attachments:
          - avatar
      YAML
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--skip-railties",
        "active_storage/engine",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify missing coverage workload for extreme boot: active_storage/engine requires inbound_email"
      assert_equal [
        {
          "framework" => "active_storage/engine",
          "required_workloads" => %w[attachments routes inbound_email],
          "missing_workloads" => %w[inbound_email],
        },
      ], payload.dig("production_risks", "extreme_boot_workload_gaps")
    end
  end

  def test_verify_production_requires_attachment_coverage_for_vips_lazy_gem_with_attachments
    Dir.mktmpdir("rails_dependency_pruner_vips_attachment_coverage_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "app/models/avatar.rb"), <<~RUBY)
        class Avatar < ApplicationRecord
          has_one_attached :image
        end
      RUBY
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--lazy-gems",
        "ruby-vips",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify missing coverage workload for extreme boot: stub:active_storage_vips_analyzer requires attachments"
      assert_equal [
        {
          "framework" => "stub:active_storage_vips_analyzer",
          "required_workloads" => %w[attachments],
          "missing_workloads" => %w[attachments],
        },
      ], payload.dig("production_risks", "extreme_boot_workload_gaps")
      assert_equal [
        {
          "transform_id" => "stub:active_storage_vips_analyzer",
          "requirement" => "active_storage_vips_stub",
          "missing_requirements" => %w[
            active_storage.upload
            active_storage.analyze
            active_storage.variant
            active_storage.preview
            active_storage.representation
            active_storage.attachment_read
          ],
          "alternative" => "unexpired high_risk_overrides.stub_active_storage_vips_analyzer",
        },
      ], payload.dig("production_risks", "high_risk_transform_gaps")
    end
  end

  def test_verify_production_allows_vips_lazy_gem_with_full_attachment_coverage
    Dir.mktmpdir("rails_dependency_pruner_vips_attachment_coverage_pass") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "app/models/avatar.rb"), <<~RUBY)
        class Avatar < ApplicationRecord
          has_one_attached :image
        end
      RUBY
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      FileUtils.mkdir_p(File.dirname(coverage_path))
      File.write(coverage_path, <<~YAML)
        version: 2
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        active_storage:
          review_required: false
          declarations_expected: true
          upload: true
          analyze: true
          variant: true
          preview: true
          representation: true
          attachment_read: true
        canary:
          review_required: false
          duration_minutes: 60
          request_count: 100
          unexpected_events_count: 0
        rollback:
          review_required: false
          disable_env_tested: true
          env_var: RAILS_DEPENDENCY_PRUNER_DISABLE
      YAML
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--lazy-gems",
        "ruby-vips",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stdout

      payload = JSON.parse(stdout)
      assert_equal true, payload.fetch("verified")
      assert_empty payload.dig("production_risks", "high_risk_transform_gaps")
    end
  end

  def test_verify_production_rejects_missing_transform_declaration
    Dir.mktmpdir("rails_dependency_pruner_transform_manifest_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      FileUtils.mkdir_p(File.dirname(coverage_path))
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: false
        routes:
          include: all
        requests:
          - GET /privacy => 200
      YAML
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--disable-eager-load",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

      profile_payload = JSON.parse(File.read(profile_path))
      profile_payload["transforms"].reject! { |transform| transform.fetch("id") == "disable_eager_load" }
      profile_payload["profile_id"] = RailsDependencyPruner::Profile.new(profile_payload).digest
      File.write(profile_path, JSON.pretty_generate(profile_payload))

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify missing registered transform: disable_eager_load"
      assert_equal ["disable_eager_load"], payload.dig("production_risks", "missing_profile_transforms")
    end
  end

  def test_verify_production_rejects_unknown_transform_declaration
    Dir.mktmpdir("rails_dependency_pruner_unknown_transform_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

      profile_payload = JSON.parse(File.read(profile_path))
      profile_payload["transforms"] << {
        "id" => "lazy_gem:unknown",
        "kind" => "unsafe_unknown",
        "risk" => "unknown",
        "description" => "Unknown lazy gem",
        "source" => "test",
        "required_coverage" => [],
        "expected_events" => [],
        "registered" => false,
      }
      profile_payload["profile_id"] = RailsDependencyPruner::Profile.new(profile_payload).digest
      File.write(profile_path, JSON.pretty_generate(profile_payload))

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify found unknown transform: lazy_gem:unknown"
      assert_equal ["lazy_gem:unknown"], payload.dig("production_risks", "unknown_profile_transforms")
    end
  end

  def test_verify_production_rejects_incomplete_transform_contract
    Dir.mktmpdir("rails_dependency_pruner_transform_contract_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--skip-railties",
        "rails/test_unit/railtie",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

      profile_payload = JSON.parse(File.read(profile_path))
      transform = profile_payload.fetch("transforms").find { |entry| entry.fetch("id") == "skip_railtie:rails/test_unit/railtie" }
      transform.delete("rollback")
      transform.delete("production_rule")
      RailsDependencyPruner::ProfileSchema.set_profile_id(
        profile_payload,
        RailsDependencyPruner::Profile.new(profile_payload).digest,
      )
      File.write(profile_path, JSON.pretty_generate(profile_payload))

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify found incomplete transform contract: skip_railtie:rails/test_unit/railtie missing rollback, production_rule"
      assert_equal [
        {
          "transform_id" => "skip_railtie:rails/test_unit/railtie",
          "missing_fields" => %w[rollback production_rule],
        },
      ], payload.dig("production_risks", "transform_contract_gaps")
    end
  end

  def test_verify_production_rejects_missing_lazy_require_coverage
    Dir.mktmpdir("rails_dependency_pruner_lazy_require_coverage_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--lazy-requires",
        "action_mailbox/mail_ext",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify missing coverage workload for extreme boot: action_mailbox/mail_ext requires inbound_email"
      assert_equal ["action_mailbox/mail_ext"], payload.dig("production_risks", "extreme_boot_workload_gaps").map { |gap| gap.fetch("framework") }
    end
  end

  def test_verify_production_rejects_unsupported_lazy_require_path
    Dir.mktmpdir("rails_dependency_pruner_lazy_require_support_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--lazy-requires",
        "rails/unknown",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify found unsupported lazy require path: rails/unknown"
      assert_equal ["rails/unknown"], payload.dig("production_risks", "unsupported_lazy_require_paths")
    end
  end

  def test_verify_production_rejects_unsupported_lazy_gem
    Dir.mktmpdir("rails_dependency_pruner_lazy_gem_support_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--lazy-gems",
        "unknown-gem",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify found unsupported lazy gem: unknown-gem"
      assert_equal ["unknown-gem"], payload.dig("production_risks", "unsupported_lazy_gems")
    end
  end

  def test_verify_production_requires_structured_lazy_gem_policy
    Dir.mktmpdir("rails_dependency_pruner_lazy_gem_policy_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--lazy-gems",
        "faker",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

      profile_payload = JSON.parse(File.read(profile_path))
      assert_equal ["faker"], profile_payload.dig("extreme_boot", "lazy_gems")
      assert_equal "Faker", profile_payload.dig("lazy_gems", "faker", "constants", 0)
      profile_payload.delete("lazy_gems")
      RailsDependencyPruner::ProfileSchema.set_profile_id(profile_payload, RailsDependencyPruner::Profile.new(profile_payload).digest)
      File.write(profile_path, JSON.pretty_generate(profile_payload))

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify missing structured lazy gem policy: faker missing lazy_gems.faker"
      assert_equal(
        [
          {
            "gem" => "faker",
            "missing_fields" => ["lazy_gems.faker"],
            "mismatched_fields" => [],
          },
        ],
        payload.dig("production_risks", "structured_lazy_gem_policy_gaps"),
      )
    end
  end

  def test_verify_production_requires_external_integration_proof_for_lazy_integration_gems
    Dir.mktmpdir("rails_dependency_pruner_lazy_gem_integration_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--lazy-gems",
        "sentry-rails",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify missing external integration proof: sentry-rails requires external_integrations.sentry-rails reviewed status; got missing"
      assert_equal(
        [
          {
            "gem" => "sentry-rails",
            "requirement" => "external_integrations.sentry-rails",
            "actual" => nil,
            "accepted_statuses" => RailsDependencyPruner::CoverageManifest::EXTERNAL_INTEGRATION_REVIEW_STATUSES,
          },
        ],
        payload.dig("production_risks", "external_integration_gaps"),
      )
    end
  end

  def test_verify_production_accepts_reviewed_external_integration_alias
    Dir.mktmpdir("rails_dependency_pruner_lazy_gem_integration_pass") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      FileUtils.mkdir_p(File.dirname(coverage_path))
      File.write(coverage_path, <<~YAML)
        version: 2
        rails_env: production
        boot:
          eager_load: true
        routes:
          review_required: false
          include: all
        external_integrations:
          sentry: disabled_in_production
        canary:
          review_required: false
          duration_minutes: 60
          request_count: 100
          unexpected_events_count: 0
        rollback:
          review_required: false
          disable_env_tested: true
          env_var: RAILS_DEPENDENCY_PRUNER_DISABLE
      YAML
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--lazy-gems",
        "sentry-rails",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal true, payload.fetch("verified")
      assert_empty payload.dig("production_risks", "external_integration_gaps")
    end
  end

  def test_verify_production_requires_lazy_gem_direct_use_proof
    Dir.mktmpdir("rails_dependency_pruner_lazy_gem_direct_use_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "app/models/image_processor.rb"), <<~RUBY)
        class ImageProcessor
          def self.call(path)
            Vips::Image.new_from_file(path)
          end
        end
      RUBY
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--lazy-gems",
        "ruby-vips",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify missing lazy gem direct-use proof: ruby-vips requires lazy_gems.ruby-vips reviewed status for Vips::Image at app/models/image_processor.rb:3; got missing"
      assert_equal(
        [
          {
            "gem" => "ruby-vips",
            "requirement" => "lazy_gems.ruby-vips",
            "actual" => nil,
            "accepted_statuses" => RailsDependencyPruner::CoverageManifest::LAZY_GEM_REVIEW_STATUSES,
            "matches" => [
              {
                "constant" => "Vips::Image",
                "path" => "app/models/image_processor.rb",
                "line" => 3,
              },
            ],
          },
        ],
        payload.dig("production_risks", "lazy_gem_direct_usage_gaps"),
      )
    end
  end

  def test_verify_production_accepts_reviewed_lazy_gem_direct_use_proof
    Dir.mktmpdir("rails_dependency_pruner_lazy_gem_direct_use_pass") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "app/models/image_processor.rb"), <<~RUBY)
        class ImageProcessor
          def self.call(path)
            Vips::Image.new_from_file(path)
          end
        end
      RUBY
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      FileUtils.mkdir_p(File.dirname(coverage_path))
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        lazy_gems:
          ruby-vips:
            review_required: false
            status: manual_app_use
      YAML
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--lazy-gems",
        "ruby-vips",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal true, payload.fetch("verified")
      assert_empty payload.dig("production_risks", "lazy_gem_direct_usage_gaps")
    end
  end

  def test_verify_production_requires_lazy_constant_policy_for_lazy_gems
    Dir.mktmpdir("rails_dependency_pruner_lazy_constant_policy_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--lazy-gems",
        "faker",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

      original_profile = JSON.parse(File.read(profile_path))
      assert_equal "faker", original_profile.dig("lazy_constants", "Faker", "require")

      missing_profile = Marshal.load(Marshal.dump(original_profile))
      missing_profile.delete("lazy_constants")
      RailsDependencyPruner::ProfileSchema.set_profile_id(missing_profile, RailsDependencyPruner::Profile.new(missing_profile).digest)
      File.write(profile_path, JSON.pretty_generate(missing_profile))

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify missing lazy constant policy: Faker for faker missing lazy_constants.Faker"
      assert_equal(
        [
          {
            "constant" => "Faker",
            "gem" => "faker",
            "missing_fields" => ["lazy_constants.Faker"],
            "mismatched_fields" => [],
          },
        ],
        payload.dig("production_risks", "lazy_constant_policy_gaps"),
      )

      stale_profile = Marshal.load(Marshal.dump(original_profile))
      stale_profile["lazy_constants"]["Faker"]["require"] = "faker/old"
      RailsDependencyPruner::ProfileSchema.set_profile_id(stale_profile, RailsDependencyPruner::Profile.new(stale_profile).digest)
      File.write(profile_path, JSON.pretty_generate(stale_profile))

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify missing lazy constant policy: Faker for faker mismatched require"
      assert_equal ["require"], payload.dig("production_risks", "lazy_constant_policy_gaps", 0, "mismatched_fields")
    end
  end

  def test_verify_production_rejects_extra_lazy_constant_policy
    Dir.mktmpdir("rails_dependency_pruner_extra_lazy_constant_policy") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--lazy-gems",
        "faker",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

      profile_payload = JSON.parse(File.read(profile_path))
      profile_payload["lazy_constants"]["FakerTools"] = {
        "gem" => "faker",
        "require" => "faker",
        "allowed_phases" => [],
        "disallowed_phases" => [],
      }
      RailsDependencyPruner::ProfileSchema.set_profile_id(profile_payload, RailsDependencyPruner::Profile.new(profile_payload).digest)
      File.write(profile_path, JSON.pretty_generate(profile_payload))

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify found unsupported lazy constant policy: FakerTools for faker"
      assert_equal(
        [
          {
            "constant" => "FakerTools",
            "gem" => "faker",
            "allowed_constants" => ["Faker"],
          },
        ],
        payload.dig("production_risks", "unsupported_lazy_constant_policies"),
      )
      assert_empty payload.dig("production_risks", "lazy_constant_policy_gaps")
    end
  end

  def test_verify_production_rejects_extreme_boot_static_mailbox_usage
    Dir.mktmpdir("rails_dependency_pruner_extreme_static_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "app/mailboxes"))
      File.write(File.join(app_root, "app/mailboxes/application_mailbox.rb"), <<~RUBY)
        class ApplicationMailbox < ActionMailbox::Base
        end
      RUBY
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      FileUtils.mkdir_p(File.dirname(coverage_path))
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        inbound_email:
          - application_mailbox
      YAML
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--skip-railties",
        "action_mailbox/engine",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_empty payload.dig("production_risks", "extreme_boot_workload_gaps")
      assert payload.fetch("errors").any? { |error| error.include?("production verify found extreme boot static evidence: action_mailbox/engine:path:app/mailboxes/application_mailbox.rb") }
      assert_equal "path", payload.dig("production_risks", "extreme_boot_static_matches", 0, "kind")
    end
  end

  def test_verify_production_allows_config_namespace_stub_static_config
    Dir.mktmpdir("rails_dependency_pruner_extreme_static_env_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config/environments"))
      File.write(File.join(app_root, "config/environments/development.rb"), <<~RUBY)
        Rails.application.configure do
          config.active_storage.service = :local
        end
      RUBY
      File.write(File.join(app_root, "config/environments/test.rb"), <<~RUBY)
        Rails.application.configure do
          config.active_storage.service = :test
        end
      RUBY
      File.write(File.join(app_root, "config/environments/production.rb"), <<~RUBY)
        Rails.application.configure do
          config.active_storage.service = :local
        end
      RUBY
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      FileUtils.mkdir_p(File.dirname(coverage_path))
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        attachments:
          - story_image
      YAML
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        "--skip-railties",
        "active_storage/engine",
        chdir: ROOT.to_s,
      )
      assert build_status.success?, build_stderr

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stdout

      payload = JSON.parse(stdout)
      assert_equal true, payload.fetch("verified")
      assert_empty payload.dig("production_risks", "extreme_boot_static_matches")
    end
  end

  def test_verify_production_rejects_dynamic_constantization_for_pruned_namespaces
    Dir.mktmpdir("rails_dependency_pruner_dynamic_constant_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "app/models/dynamic_constant_risk.rb"), <<~RUBY)
        class DynamicConstantRisk
          def resolve(name)
            name.constantize
          end
        end
      RUBY
      coverage_path = write_coverage_manifest(app_root)
      profile_path = File.join(dir, "profile.json")

      build_profile(
        profile_path: profile_path,
        app_root: app_root,
        coverage_path: coverage_path,
        frameworks: "actionmailer,actionpack,activerecord",
      )

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
        "actionmailer,actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_equal false, payload.fetch("verified")
      assert payload.fetch("errors").any? { |error| error.include?("dynamic constantization risk for pruned constants") }
      assert_equal "app/models/dynamic_constant_risk.rb", payload.dig("production_risks", "dynamic_constantization_matches", 0, "path")
    end
  end

  def test_verify_production_allows_overridden_dynamic_constantization_for_pruned_namespaces
    Dir.mktmpdir("rails_dependency_pruner_dynamic_constant_override") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "app/models/dynamic_constant_risk.rb"), <<~RUBY)
        class DynamicConstantRisk
          def resolve(name)
            name.constantize
          end
        end
      RUBY
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        mailers:
          review_required: false
          actions: []
        overrides:
          - id: allow_app_report_constantization
            owner: platform-team
            reason: dynamic constant names are restricted to app report classes
            expires_at: 2099-01-01
            paths:
              - app/models/dynamic_constant_risk.rb
      YAML
      profile_path = File.join(dir, "profile.json")

      build_profile(
        profile_path: profile_path,
        app_root: app_root,
        coverage_path: coverage_path,
        frameworks: "actionmailer,actionpack,activerecord",
      )

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
        "actionmailer,actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stdout + stderr

      payload = JSON.parse(stdout)
      assert_equal true, payload.fetch("verified")
      assert_empty payload.dig("production_risks", "dynamic_constantization_matches")
    end
  end

  def test_verify_production_rejects_truncated_runtime_evidence
    Dir.mktmpdir("rails_dependency_pruner_truncated_runtime_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      runtime_path = File.join(dir, "runtime.json")
      File.write(runtime_path, JSON.pretty_generate(
        "defined_constants" => [],
        "limits" => {
          "called_methods" => { "recorded" => 1, "max" => 1, "truncated" => true },
          "require_events" => { "recorded" => 0, "max" => 1, "truncated" => false },
          "load_events" => { "recorded" => 0, "max" => 1, "truncated" => false },
          "snapshots" => { "recorded" => 0, "max" => 1, "truncated" => false },
        },
      ))
      profile_path = File.join(dir, "profile.json")

      build_profile(
        profile_path: profile_path,
        app_root: app_root,
        coverage_path: coverage_path,
        runtime_evidence_path: runtime_path,
      )

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
        "--coverage",
        coverage_path,
        "--runtime-evidence",
        runtime_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_equal false, payload.fetch("verified")
      assert_includes payload.fetch("errors"), "production verify found truncated runtime evidence: called_methods"
      assert_equal ["called_methods"], payload.dig("production_risks", "truncated_runtime_evidence")
    end
  end

  def test_verify_production_rejects_unexpected_runtime_events
    Dir.mktmpdir("rails_dependency_pruner_unexpected_runtime_event_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      runtime_path = File.join(dir, "runtime-events.json")
      File.write(runtime_path, JSON.pretty_generate(
        "mode" => "canary",
        "events" => [
          {
            "mode" => "canary",
            "phase" => "request",
            "action" => "loaded_lazy_gem",
            "gem" => "ruby-vips",
            "event_id" => "request:loaded_lazy_gem:ruby-vips",
            "expected" => false,
            "caller_path" => "app/models/story_image.rb",
            "caller_line" => 12,
          },
        ],
      ))
      profile_path = File.join(dir, "profile.json")

      build_profile(
        profile_path: profile_path,
        app_root: app_root,
        coverage_path: coverage_path,
        runtime_evidence_path: runtime_path,
      )

      profile = JSON.parse(File.read(profile_path))
      assert_equal 1, profile.dig("summary", "runtime_event_summary", "unexpected_events_count")

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
        "--coverage",
        coverage_path,
        "--runtime-evidence",
        runtime_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify found unexpected runtime event: request:loaded_lazy_gem:ruby-vips"
      assert_equal "request:loaded_lazy_gem:ruby-vips", payload.dig("production_risks", "unexpected_runtime_events", 0, "event_id")
    end
  end

  def test_verify_production_rejects_disabled_framework_runtime_routes_and_middleware
    Dir.mktmpdir("rails_dependency_pruner_runtime_framework_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      coverage_path = write_coverage_manifest(app_root)
      runtime_path = File.join(dir, "runtime.json")
      File.write(runtime_path, JSON.pretty_generate(
        "defined_constants" => [],
        "rails_application" => {
          "middleware" => [
            { "name" => "ActiveStorage::Engine" },
          ],
          "routes" => [
            {
              "name" => "rails_service_blob",
              "verb" => "GET",
              "path" => "/rails/active_storage/blobs/:signed_id/*filename",
              "controller" => "active_storage/blobs/redirect",
              "action" => "show",
            },
          ],
        },
        "limits" => {
          "called_methods" => { "recorded" => 0, "max" => 1, "truncated" => false },
          "require_events" => { "recorded" => 0, "max" => 1, "truncated" => false },
          "load_events" => { "recorded" => 0, "max" => 1, "truncated" => false },
          "snapshots" => { "recorded" => 0, "max" => 1, "truncated" => false },
          "middleware" => { "recorded" => 1, "max" => 200, "truncated" => false },
          "routes" => { "recorded" => 1, "max" => 1000, "truncated" => false },
        },
      ))
      profile_path = File.join(dir, "profile.json")

      build_profile(
        profile_path: profile_path,
        app_root: app_root,
        coverage_path: coverage_path,
        frameworks: "actionpack,activerecord,activestorage",
        runtime_evidence_path: runtime_path,
      )

      profile = JSON.parse(File.read(profile_path))
      assert_includes profile.dig("pruning", "disabled_frameworks"), "activestorage"

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
        "actionpack,activerecord,activestorage",
        "--coverage",
        coverage_path,
        "--runtime-evidence",
        runtime_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_equal false, payload.fetch("verified")
      assert_includes payload.fetch("errors"), "production verify found disabled framework runtime evidence: activestorage:middleware:ActiveStorage::Engine"
      assert_includes payload.fetch("errors"), "production verify found disabled framework runtime evidence: activestorage:route:rails_service_blob"
      matches = payload.dig("production_risks", "disabled_framework_runtime_matches")
      assert_equal %w[middleware route], matches.map { |match| match.fetch("kind") }.sort
    end
  end

  def test_profile_build_writes_deterministic_profile_with_coverage_manifest
    Dir.mktmpdir("rails_dependency_pruner_profile_build") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config"))
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        jobs:
          - CleanupJob
        mailers:
          - UserMailer#welcome
        rake_tasks:
          - assets:precompile
      YAML
      profile_path = File.join(dir, "profile.json")

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "profile",
        "build",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        "config/pruner_coverage.yml",
        "--write",
        profile_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal 3, payload.fetch("schema_version")
      assert_match(/\Asha256:/, payload.fetch("profile_id"))
      assert_equal payload.fetch("profile_id"), payload.dig("fingerprints", "profile_id")
      assert_equal "production", payload.dig("app", "rails_env")
      assert_equal "production", payload.dig("environment", "rails_env")
      assert_equal true, payload.dig("app", "eager_load")
      assert_match(/\Asha256:/, payload.dig("evidence", "coverage_manifest_digest"))
      assert_equal payload.dig("evidence", "coverage_manifest_digest"), payload.dig("fingerprints", "coverage_manifest_sha256")
      assert_equal %w[boot jobs mailers rake_tasks routes], payload.dig("evidence", "workloads")
      assert_equal "reject", payload.dig("safety_policy", "unknown_dynamic_require")
      assert_equal "reject", payload.dig("safety_policy", "runtime_evidence_truncated")
      assert_equal "reject_if_pruned_namespace_possible", payload.dig("safety_policy", "unknown_dynamic_constantize")

      file_payload = JSON.parse(File.read(profile_path))
      assert_equal payload.fetch("profile_id"), file_payload.fetch("profile_id")

      verify_stdout, verify_stderr, verify_status = Open3.capture3(
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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      assert verify_status.success?, verify_stderr
      assert_equal true, JSON.parse(verify_stdout).fetch("verified")

      File.write(coverage_path, File.read(coverage_path).sub("assets:precompile", "db:migrate"))
      validate_stdout, _validate_stderr, validate_status = Open3.capture3(
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
        "--coverage",
        coverage_path,
        "--json",
        chdir: ROOT.to_s,
      )

      refute validate_status.success?
      assert JSON.parse(validate_stdout).fetch("errors").any? { |error| error.include?("coverage_manifest_digest mismatch") }
    end
  end

  def test_verify_production_rejects_weakened_safety_policy
    Dir.mktmpdir("rails_dependency_pruner_safety_policy_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config"))
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        safety_policy:
          unknown_dynamic_require: report
      YAML
      profile_path = File.join(dir, "profile.json")

      build_profile(profile_path: profile_path, app_root: app_root, coverage_path: coverage_path)
      profile = JSON.parse(File.read(profile_path))
      assert_equal "report", profile.dig("safety_policy", "unknown_dynamic_require")
      assert_equal "reject", profile.dig("safety_policy", "runtime_evidence_truncated")

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify weak safety policy: unknown_dynamic_require expected reject, got report"
      assert_equal [
        {
          "key" => "unknown_dynamic_require",
          "expected" => "reject",
          "actual" => "report",
        },
      ], payload.dig("production_risks", "safety_policy_gaps")
    end
  end

  def test_verify_production_requires_v2_rollback_evidence
    Dir.mktmpdir("rails_dependency_pruner_rollback_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config"))
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      profile_path = File.join(dir, "profile.json")

      File.write(coverage_path, <<~YAML)
        version: 2
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        rollback:
          review_required: true
          disable_env_tested: false
          env_var: RAILS_DEPENDENCY_PRUNER_DISABLE
      YAML

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "profile",
        "build",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        "config/pruner_coverage.yml",
        "--write",
        profile_path,
        "--json",
        chdir: ROOT.to_s,
      )
      assert status.success?, stderr

      profile = JSON.parse(stdout)
      assert_equal 2, profile.dig("evidence", "coverage_manifest_version")
      assert_equal false, profile.dig("evidence", "rollback_tested")

      verify_stdout, _verify_stderr, verify_status = Open3.capture3(
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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute verify_status.success?
      payload = JSON.parse(verify_stdout)
      assert_includes payload.fetch("errors"), "production verify missing rollback proof: rollback.disable_env_tested must be true for RAILS_DEPENDENCY_PRUNER_DISABLE"
      assert_equal [
        {
          "requirement" => "rollback.disable_env_tested",
          "expected" => true,
          "env_var" => "RAILS_DEPENDENCY_PRUNER_DISABLE",
        },
      ], payload.dig("production_risks", "rollback_evidence_gaps")

      File.write(coverage_path, <<~YAML)
        version: 2
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        canary:
          review_required: false
          duration_minutes: 60
          request_count: 100
          unexpected_events_count: 0
        rollback:
          review_required: false
          disable_env_tested: true
          env_var: RAILS_DEPENDENCY_PRUNER_DISABLE
      YAML

      rebuild_stdout, rebuild_stderr, rebuild_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "profile",
        "build",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        "config/pruner_coverage.yml",
        "--write",
        profile_path,
        "--json",
        chdir: ROOT.to_s,
      )
      assert rebuild_status.success?, rebuild_stderr
      assert_equal true, JSON.parse(rebuild_stdout).dig("evidence", "rollback_tested")

      approved_stdout, approved_stderr, approved_status = Open3.capture3(
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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      assert approved_status.success?, approved_stderr
      assert_empty JSON.parse(approved_stdout).dig("production_risks", "rollback_evidence_gaps")
    end
  end

  def test_verify_production_requires_v2_canary_evidence
    Dir.mktmpdir("rails_dependency_pruner_canary_verify") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config"))
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      profile_path = File.join(dir, "profile.json")

      File.write(coverage_path, <<~YAML)
        version: 2
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        rollback:
          review_required: false
          disable_env_tested: true
          env_var: RAILS_DEPENDENCY_PRUNER_DISABLE
      YAML
      build_profile(profile_path: profile_path, app_root: app_root, coverage_path: coverage_path)

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify insufficient canary proof: canary section is required for v2 production coverage"
      assert_equal [
        {
          "requirement" => "canary",
          "expected" => "reviewed canary evidence",
          "actual" => "missing",
        },
      ], payload.dig("production_risks", "canary_evidence_gaps")

      File.write(coverage_path, <<~YAML)
        version: 2
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        canary:
          review_required: false
          duration_minutes: 15
          request_count: 100
          unexpected_events_count: 1
        rollback:
          review_required: false
          disable_env_tested: true
          env_var: RAILS_DEPENDENCY_PRUNER_DISABLE
      YAML
      build_profile(profile_path: profile_path, app_root: app_root, coverage_path: coverage_path)

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify insufficient canary proof: canary.unexpected_events_count must be 0, got 1"
      assert_includes payload.fetch("errors"), "production verify insufficient canary proof: canary requires duration_seconds >= 3600 or request_count >= 10000; got duration_seconds=900, request_count=100"
      assert_equal %w[canary.unexpected_events_count canary.duration_or_request_count], payload.dig("production_risks", "canary_evidence_gaps").map { |gap| gap.fetch("requirement") }
      assert_equal 900, JSON.parse(File.read(profile_path)).dig("evidence", "canary_evidence", "duration_seconds")

      File.write(coverage_path, <<~YAML)
        version: 2
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        canary:
          review_required: false
          duration_minutes: 15
          request_count: 10000
          unexpected_events_count: 0
        rollback:
          review_required: false
          disable_env_tested: true
          env_var: RAILS_DEPENDENCY_PRUNER_DISABLE
      YAML
      build_profile(profile_path: profile_path, app_root: app_root, coverage_path: coverage_path)

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stdout + stderr
      assert_empty JSON.parse(stdout).dig("production_risks", "canary_evidence_gaps")
    end
  end

  def test_profile_build_copies_memory_policy_from_coverage_manifest
    Dir.mktmpdir("rails_dependency_pruner_memory_policy_profile_build") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config"))
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        memory_policy:
          min_total_savings_mib: 20
          min_total_savings_percent: 10
          max_first_request_latency_regression_ms: 100
          max_warmed_p95_latency_regression_percent: 5
          preserve_at_least_percent_of_reference_savings: 80
          reference_savings_mib: 98.3
      YAML
      profile_path = File.join(dir, "profile.json")

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "profile",
        "build",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        "config/pruner_coverage.yml",
        "--write",
        profile_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal 20, payload.dig("memory_policy", "min_total_savings_mib")
      assert_equal 10, payload.dig("memory_policy", "min_total_savings_percent")
      assert_equal 100, payload.dig("memory_policy", "max_first_request_latency_regression_ms")
      assert_equal 5, payload.dig("memory_policy", "max_warmed_p95_latency_regression_percent")
      assert_equal 80, payload.dig("memory_policy", "preserve_at_least_percent_of_reference_savings")
      assert_equal 98.3, payload.dig("memory_policy", "reference_savings_mib")
      assert_equal payload.fetch("profile_id"), JSON.parse(File.read(profile_path)).fetch("profile_id")
    end
  end

  def test_profile_build_copies_safety_overrides_from_coverage_manifest
    Dir.mktmpdir("rails_dependency_pruner_safety_override_profile_build") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config"))
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        overrides:
          - id: allow_dynamic_constantize_admin_reports
            reason: Admin reports constantize only app-owned report classes
            owner: platform-team
            expires_at: 2099-01-01
            paths:
              - app/services/report_runner.rb
      YAML
      profile_path = File.join(dir, "profile.json")

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "profile",
        "build",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        "config/pruner_coverage.yml",
        "--write",
        profile_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stdout + stderr

      payload = JSON.parse(stdout)
      assert_equal [
        {
          "id" => "allow_dynamic_constantize_admin_reports",
          "reason" => "Admin reports constantize only app-owned report classes",
          "owner" => "platform-team",
          "expires_at" => "2099-01-01",
          "paths" => ["app/services/report_runner.rb"],
        },
      ], payload.fetch("overrides")
      assert_equal payload.fetch("overrides"), JSON.parse(File.read(profile_path)).fetch("overrides")
      assert_equal payload.fetch("profile_id"), JSON.parse(File.read(profile_path)).fetch("profile_id")
    end
  end

  def test_verify_production_requires_measurement_for_memory_policy
    Dir.mktmpdir("rails_dependency_pruner_memory_policy_requires_measurement") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config"))
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        memory_policy:
          min_total_savings_mib: 20
      YAML
      profile_path = File.join(dir, "profile.json")

      build_profile(profile_path: profile_path, app_root: app_root, coverage_path: coverage_path)

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
        "--coverage",
        coverage_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert_includes payload.fetch("errors"), "production verify memory policy requires --measurement"
      assert_equal true, payload.dig("production_risks", "memory_policy", "configured")
      assert_equal false, payload.dig("production_risks", "memory_policy", "passed")
    end
  end

  def test_verify_production_enforces_memory_policy_measurement
    Dir.mktmpdir("rails_dependency_pruner_memory_policy_measurement") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config"))
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
        memory_policy:
          min_total_savings_mib: 20
          min_total_savings_percent: 10
          preserve_at_least_percent_of_reference_savings: 80
          reference_savings_mib: 40
      YAML
      profile_path = File.join(dir, "profile.json")

      build_profile(profile_path: profile_path, app_root: app_root, coverage_path: coverage_path)
      profile_id = JSON.parse(File.read(profile_path)).fetch("profile_id")
      weak_measurement_path = File.join(dir, "weak-measurement.json")
      write_measurement_report(
        path: weak_measurement_path,
        profile_id: profile_id,
        baseline_rss_kb: 100_000,
        candidate_rss_kb: 95_000,
      )

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
        "--coverage",
        coverage_path,
        "--measurement",
        weak_measurement_path,
        "--production",
        "--json",
        chdir: ROOT.to_s,
      )

      refute status.success?

      payload = JSON.parse(stdout)
      assert payload.fetch("errors").any? { |error| error.include?("min_total_savings_mib not met") }
      assert payload.fetch("errors").any? { |error| error.include?("min_total_savings_percent not met") }
      assert payload.fetch("errors").any? { |error| error.include?("reference savings not preserved") }
      assert_equal 5_000, payload.dig("production_risks", "memory_policy", "measurement", "saved_kb")

      passing_measurement_path = File.join(dir, "passing-measurement.json")
      write_measurement_report(
        path: passing_measurement_path,
        profile_id: profile_id,
        baseline_rss_kb: 100_000,
        candidate_rss_kb: 60_000,
      )

      approve_stdout, approve_stderr, approve_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "approve",
        "--profile",
        profile_path,
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--measurement",
        passing_measurement_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert approve_status.success?, approve_stderr

      approved_payload = JSON.parse(approve_stdout)
      assert_equal true, approved_payload.fetch("verified")
      assert_equal true, approved_payload.fetch("profile_approved")
      assert_equal 40_000, approved_payload.dig("production_risks", "memory_policy", "measurement", "saved_kb")
    end
  end

  def test_verify_approve_production_rewrites_profile_after_success
    Dir.mktmpdir("rails_dependency_pruner_approve_production") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config"))
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
      YAML
      profile_path = File.join(dir, "profile.json")

      _stdout, build_stderr, build_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
        chdir: ROOT.to_s,
      )

      assert build_status.success?, build_stderr

      before = JSON.parse(File.read(profile_path))
      assert_equal false, before.dig("safety", "production_allowed")
      assert_nil before.dig("safety", "approved_at")
      assert_nil before.dig("safety", "approved_by")
      assert_nil before.dig("safety", "verifier_version")
      assert_equal [], before.dig("safety", "errors")
      assert_equal [], before.dig("safety", "warnings")

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "approve",
        "--profile",
        profile_path,
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--coverage",
        coverage_path,
        "--approved-by",
        "release-owner",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal true, payload.fetch("verified")
      assert_equal true, payload.fetch("profile_approved")
      assert_equal true, payload.dig("profile", "production_allowed")
      assert_equal "release-owner", payload.dig("profile", "approved_by")
      refute_nil payload.dig("profile", "approved_at")

      approved = JSON.parse(File.read(profile_path))
      assert_equal true, approved.dig("safety", "production_allowed")
      assert_equal "release-owner", approved.dig("safety", "approved_by")
      assert_match(/\A\d{4}-\d{2}-\d{2}T/, approved.dig("safety", "approved_at"))
      assert_equal RailsDependencyPruner::VERSION, approved.dig("safety", "verifier_version")
      assert_equal [], approved.dig("safety", "errors")
      assert_equal [], approved.dig("safety", "warnings")
      refute_equal before.fetch("profile_id"), approved.fetch("profile_id")

      early_stdout, early_stderr, early_status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "production",
          "RAILS_DEPENDENCY_PRUNER_PROFILE_ID" => approved.fetch("profile_id"),
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-e",
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
          puts "production profile accepted"
        RUBY
      )

      assert early_status.success?, early_stderr
      assert_equal "production profile accepted\n", early_stdout
    end
  end

  def test_verify_approve_production_requires_production_gate
    stdout, stderr, status = Open3.capture3(
      RUBY,
      ROOT.join("exe/rails-dependency-pruner").to_s,
      "verify",
      "--profile",
      "tmp/missing.json",
      "--app",
      FAKE_APP_ROOT.to_s,
      "--approve-production",
      "--json",
      chdir: ROOT.to_s,
    )

    refute status.success?
    assert_empty stdout
    assert_includes stderr, "--approve-production requires --production"
  end

  def test_plan_command_uses_simple_defaults_and_writes_optional_patch
    Dir.mktmpdir("rails_dependency_pruner_plan") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.open(File.join(app_root, "config/application.rb"), "a") do |file|
        file.puts "require \"active_job/railtie\""
      end
      FileUtils.mkdir_p(File.join(app_root, "app/jobs"))
      profile_path = File.join(app_root, "config/rails_dependency_pruner_profile.json")
      patch_path = File.join(dir, "boot_plan.patch")

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,actionview,activejob,activemodel,activerecord",
        "--patch",
        patch_path,
        "--json",
        chdir: app_root,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal File.realpath(profile_path), File.realpath(payload.fetch("profile_path"))
      assert_equal File.realpath(patch_path), File.realpath(payload.fetch("patch_path"))
      assert_equal "boot_prune", payload.fetch("mode")
      assert_match(/\Asha256:/, payload.fetch("profile_id"))
      assert File.exist?(profile_path)
      assert File.exist?(patch_path)

      profile = JSON.parse(File.read(profile_path))
      assert_equal 3, profile.fetch("schema_version")
      assert_equal "boot_prune", profile.fetch("mode")
      assert_equal payload.fetch("profile_id"), profile.fetch("profile_id")
      assert_equal profile.fetch("profile_id"), profile.dig("fingerprints", "profile_id")
      assert_equal ["activejob"], profile.dig("pruning", "disabled_frameworks")
      assert_equal ["active_job/railtie"], profile.dig("pruning", "disabled_railties")

      boot_plan = payload.fetch("boot_plan")
      assert_includes boot_plan.fetch("required_frameworks"), "activerecord"
      assert_includes boot_plan.fetch("required_frameworks"), "activemodel"
      assert_includes boot_plan.fetch("required_frameworks"), "actionpack"
      assert_includes boot_plan.fetch("required_frameworks"), "actionview"
      assert_includes boot_plan.fetch("pruned_frameworks"), "activejob"
      assert_equal ["app/jobs"], boot_plan.fetch("autoload_ignores")
      assert_equal ["app/jobs"], boot_plan.fetch("eager_load_ignores")

      patch = File.read(patch_path)
      assert_includes patch, "-require \"active_job/railtie\""
      assert_includes patch, "+# rails_dependency_pruner: pruned active_job/railtie (transforms: disable_framework:activejob, prune_railtie:active_job/railtie; proof: explanations.activejob)"
      assert_includes patch, "+# require \"active_job/railtie\""
      assert_patch_applies(app_root: app_root, patch_path: patch_path)

      assert_equal boot_plan.fetch("required_frameworks"), profile.dig("boot_plan", "required_frameworks")
      assert_equal boot_plan.fetch("pruned_frameworks"), profile.dig("boot_plan", "pruned_frameworks")
      assert_equal boot_plan.fetch("pruned_railties"), profile.dig("boot_plan", "pruned_railties")
      assert_equal ["app/jobs"], profile.dig("pruning", "autoload_ignores")
      assert_equal ["app/jobs"], profile.dig("pruning", "eager_load_ignores")
      assert_equal "disable_framework", profile.dig("explanations", "activejob", "decision")
      assert_equal "active_job/railtie", profile.dig("explanations", "activejob", "railtie")
      assert_includes profile.dig("explanations", "activejob", "negative_evidence"), "no static framework evidence in scanned app files"
      assert_equal "keep_framework", profile.dig("explanations", "activerecord", "decision")
      assert profile.dig("explanations", "activerecord", "positive_evidence").any? { |evidence| evidence.include?("ActiveRecord::Base") }
    end
  end

  def test_plan_command_records_extreme_boot_settings
    Dir.mktmpdir("rails_dependency_pruner_extreme_plan") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      profile_path = File.join(dir, "profile.json")

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,activerecord",
        "--profile",
        profile_path,
        "--disable-eager-load",
        "--skip-railties",
        "action_mailbox/engine,active_storage/engine",
        "--lazy-requires",
        "action_mailbox/mail_ext",
        "--lazy-gems",
        "faker,pdf-reader,ruby-vips",
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal true, payload.dig("extreme_boot", "disable_eager_load")
      assert_equal %w[action_mailbox/engine active_storage/engine], payload.dig("extreme_boot", "skip_railties")
      assert_equal ["action_mailbox/mail_ext"], payload.dig("extreme_boot", "lazy_require_paths")
      assert_equal %w[faker pdf-reader ruby-vips], payload.dig("extreme_boot", "lazy_gems")
      assert_equal %w[faker pdf-reader ruby-vips], payload.fetch("lazy_gems").keys.sort
      assert_equal %w[action_mailbox active_storage], payload.dig("extreme_boot", "config_namespace_stubs")
      transform_ids = payload.fetch("transforms").map { |transform| transform.fetch("id") }
      assert_includes transform_ids, "disable_eager_load"
      assert_includes transform_ids, "skip_railtie:action_mailbox/engine"
      assert_includes transform_ids, "skip_railtie:active_storage/engine"
      assert_includes transform_ids, "lazy_require:action_mailbox/mail_ext"
      assert_includes transform_ids, "lazy_gem:faker"
      assert_includes transform_ids, "lazy_gem:pdf-reader"
      assert_includes transform_ids, "lazy_gem:ruby-vips"
      assert_includes transform_ids, "stub:active_storage_vips_analyzer"

      profile = JSON.parse(File.read(profile_path))
      assert_equal payload.fetch("extreme_boot"), profile.fetch("extreme_boot")
      assert_equal "fail_in_canary_report_in_production", profile.fetch("unexpected_event_policy")
      assert_equal transform_ids.sort, profile.fetch("transforms").map { |transform| transform.fetch("id") }.sort
      assert_empty RailsDependencyPruner::TransformRegistry.transform_contract_gaps(profile)
      vips_transform = profile.fetch("transforms").find { |transform| transform.fetch("id") == "stub:active_storage_vips_analyzer" }
      assert_equal "high", vips_transform.fetch("risk")
      assert_includes vips_transform.fetch("production_rule"), "no-attachment apps"
      assert_includes vips_transform.fetch("required_static_evidence"), "no Active Storage attachment DSL usage"
      assert_includes vips_transform.fetch("required_runtime_evidence"), "unexpected event count"
      assert_equal %w[boot manual_app_use], vips_transform.fetch("allowed_phases")
      assert_includes vips_transform.fetch("disallowed_events"), "Active Storage analyzer Vips use without proof"
      assert_includes vips_transform.fetch("rollback"), "RAILS_DEPENDENCY_PRUNER_DISABLE=1"
      assert_equal ["stubbed_lazy_gem_require"], vips_transform.fetch("expected_events").map { |event| event.fetch("action") }
      eager_transform = profile.fetch("transforms").find { |transform| transform.fetch("id") == "disable_eager_load" }
      assert_includes eager_transform.fetch("required_runtime_evidence"), "first request latency"
      assert_includes eager_transform.fetch("production_rule"), "latency policy gates"
      assert_equal "lazy_constant", profile.dig("lazy_gems", "faker", "strategy")
      assert_equal ["Faker"], profile.dig("lazy_gems", "faker", "constants")
      assert_equal "faker", profile.dig("lazy_gems", "faker", "require")
      assert_equal true, profile.dig("lazy_gems", "faker", "boot_require_blocked")
      assert_equal "lazy_constant", profile.dig("lazy_gems", "ruby-vips", "strategy")
      assert_equal ["manual_app_use"], profile.dig("lazy_gems", "ruby-vips", "allowed_phases")
      assert_equal %w[boot request], profile.dig("lazy_gems", "ruby-vips", "disallowed_phases")
      assert_equal true, profile.dig("lazy_gems", "ruby-vips", "high_risk")
      assert_equal "ruby-vips", profile.dig("lazy_constants", "Vips", "gem")
      assert_equal "vips", profile.dig("lazy_constants", "Vips", "require")
      assert_equal ["manual_app_use"], profile.dig("lazy_constants", "Vips", "allowed_phases")
      faker_lazy_transform = profile.fetch("transforms").find { |transform| transform.fetch("id") == "lazy_gem:faker" }
      assert_equal [
        {
          "action" => "loaded_lazy_gem",
          "gem" => "faker",
        },
      ], faker_lazy_transform.fetch("expected_events")
      vips_lazy_transform = profile.fetch("transforms").find { |transform| transform.fetch("id") == "lazy_gem:ruby-vips" }
      assert_equal "native_heavy_library", vips_lazy_transform.dig("gem_policy", "class")
      assert_equal "high", vips_lazy_transform.dig("gem_policy", "risk")
      assert_equal [
        {
          "action" => "loaded_lazy_gem",
          "gem" => "ruby-vips",
          "phase" => "manual_app_use",
        },
      ], vips_lazy_transform.fetch("expected_events")
      assert_equal %w[active_storage_analyzer_stub lazy_constant], vips_lazy_transform.dig("gem_policy", "strategies")
      assert_equal ["Vips"], vips_lazy_transform.dig("gem_policy", "constants")
      assert_equal vips_lazy_transform.dig("gem_policy", "production_rule"), vips_lazy_transform.fetch("production_rule")
      assert_equal true, RailsDependencyPruner::TransformRegistry.lazy_gem_supported?("ruby-vips")
      assert_equal "vips", RailsDependencyPruner::TransformRegistry.lazy_gem_policy("ruby-vips").fetch("require")
      assert_equal false, RailsDependencyPruner::TransformRegistry.lazy_gem_supported?("unknown-gem")
    end
  end

  def test_explain_reads_profile_decisions_without_rescanning_app
    Dir.mktmpdir("rails_dependency_pruner_profile_explain") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      profile_path = File.join(dir, "profile.json")

      _stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,actionview,activejob,activemodel,activerecord",
        "--profile",
        profile_path,
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      pruned_stdout, pruned_stderr, pruned_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "explain",
        "active_job",
        "--profile",
        profile_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert pruned_status.success?, pruned_stderr
      pruned = JSON.parse(pruned_stdout)
      assert_equal "activejob", pruned.fetch("target")
      assert_equal "framework", pruned.fetch("target_type")
      assert_equal "pruned", pruned.fetch("decision")
      assert_equal "disable_framework", pruned.dig("evidence", "decision")

      kept_stdout, kept_stderr, kept_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "why-kept",
        "ActiveRecord",
        "--profile",
        profile_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert kept_status.success?, kept_stderr
      kept = JSON.parse(kept_stdout)
      assert_equal "activerecord", kept.fetch("target")
      assert_equal "kept", kept.fetch("decision")
      assert kept.dig("evidence", "positive_evidence").any? { |entry| entry.include?("ActiveRecord::Base") }

      require_stdout, require_stderr, require_status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "explain",
        "require:active_job/railtie",
        "--profile",
        profile_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert require_status.success?, require_stderr
      require_payload = JSON.parse(require_stdout)
      assert_equal "require_path", require_payload.fetch("target_type")
      assert_equal "pruned", require_payload.fetch("decision")
      assert_equal ["active_job/railtie"], require_payload.dig("evidence", "disabled_railties")
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
      "actionmailer,actionpack,activerecord",
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
    assert_equal 5, payload.fetch("runtime_rails_constants_count")
    assert_includes payload.fetch("runtime_rails_constants"), "ActiveRecord::Relation"
    assert_includes payload.fetch("runtime_rails_constants"), "ActiveRecord::OrphanFeature"
    assert_includes payload.fetch("runtime_rails_constants"), "ActionMailer"
    assert_includes payload.fetch("runtime_rails_constants"), "ActionMailer::Base"
    refute_includes payload.fetch("unused_constants"), "ActiveRecord::Relation"
    refute_includes payload.fetch("unused_constants"), "ActiveRecord::OrphanFeature"
    refute_includes payload.fetch("unused_constants"), "ActionMailer::Base"
    refute_includes payload.fetch("unused_require_path_provenance").map { |entry| entry.fetch("require_path") }, "active_record/orphan_feature"
    refute_includes payload.fetch("unused_require_path_provenance").map { |entry| entry.fetch("require_path") }, "action_mailer/base"
    assert_equal 1, payload.fetch("runtime_memory").length
    assert_equal 1048576, payload.dig("runtime_memory_summary", "object_sizes", "T_STRING")
    assert_equal "ActionController::UnusedControllerFeature", payload.dig("runtime_memory_summary", "rails_class_instance_sizes", 0, "name")
    assert_equal false, payload.dig("runtime_evidence_truncation", "require_events")
    assert_equal 2, payload.dig("runtime_evidence_limits", 0, "require_events", "recorded")
    assert_equal "ActionDispatch::Executor", payload.dig("runtime_rails_application", 0, "middleware", 0, "name")
    assert_equal "/rails/info", payload.dig("runtime_rails_application", 0, "routes", 0, "path")
  end

  def test_runtime_recorder_writes_runtime_evidence
    Dir.mktmpdir("rails_dependency_pruner_runtime") do |dir|
      output = File.join(dir, "runtime.json")
      runtime_feature = File.join(dir, "runtime_feature.rb")
      relative_feature = File.join(dir, "relative_runtime_feature.rb")
      script = File.join(dir, "runtime_script.rb")
      File.write(runtime_feature, "module ActiveRecord; class RuntimeRequiredFeature; end; end\n")
      File.write(relative_feature, "module ActionCable; class RelativeRuntimeFeature; end; end\n")
      File.write(script, <<~RUBY)
        module ActiveRecord
          class Base
            def persisted?
              true
            end
          end
        end

        module RuntimeNameOverride
          def self.name(required:)
            required
          end
        end

        RailsDependencyPruner::RuntimeRecorder.snapshot!("before_runtime_feature")
        $LOAD_PATH.unshift(#{dir.dump})
        require "runtime_feature"
        require_relative "relative_runtime_feature"
        load #{runtime_feature.dump}
        $runtime_base = ActiveRecord::Base.new
        $runtime_base.persisted?
        RailsDependencyPruner::RuntimeRecorder.snapshot!("after_runtime_feature")
      RUBY
      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT" => output,
          "RAILS_DEPENDENCY_PRUNER_TRACE_CALLS" => "1",
          "RAILS_DEPENDENCY_PRUNER_TRACE_REQUIRES" => "1",
          "RAILS_DEPENDENCY_PRUNER_OBJECTSPACE" => "1",
          "RAILS_DEPENDENCY_PRUNER_SNAPSHOTS" => "1",
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-rrails_dependency_pruner/runtime_recorder",
        script,
      )

      assert status.success?, stderr
      assert_empty stdout

      payload = JSON.parse(File.read(output))
      assert_includes payload.fetch("defined_constants"), "ActiveRecord::Base"
      assert_includes payload.fetch("called_constants"), "ActiveRecord::Base"
      assert payload.fetch("called_methods").any? { |entry| entry.fetch("method_id") == "persisted?" }
      require_event = payload.fetch("require_events").find { |entry| entry.fetch("path") == "runtime_feature" }
      refute_nil require_event
      assert_equal "require", require_event.fetch("operation")
      assert_equal "before_runtime_feature", require_event.fetch("phase")
      assert require_event["caller_line"]

      relative_event = payload.fetch("require_events").find { |entry| entry.fetch("path") == "relative_runtime_feature" }
      refute_nil relative_event
      assert_equal "require_relative", relative_event.fetch("operation")
      assert_equal relative_feature.delete_suffix(".rb"), relative_event.fetch("resolved_path")
      assert_equal "before_runtime_feature", relative_event.fetch("phase")

      load_event = payload.fetch("load_events").find { |entry| entry.fetch("path") == runtime_feature }
      refute_nil load_event
      assert_equal "load", load_event.fetch("operation")
      assert_equal "before_runtime_feature", load_event.fetch("phase")
      assert load_event["caller_line"]
      assert payload.dig("memory", "object_sizes", "T_STRING")
      assert payload.dig("memory", "rails_class_instance_sizes").any? { |entry| entry.fetch("name") == "ActiveRecord::Base" }
      assert_operator payload.dig("process_memory", "rss_kb"), :>, 0
      phases = payload.fetch("snapshots").map { |snapshot| snapshot.fetch("phase") }
      assert_includes phases, "recorder_start"
      assert_includes phases, "before_runtime_feature"
      assert_includes phases, "after_runtime_feature"
      assert_includes phases, "recorder_exit"
      assert payload.fetch("snapshots").all? { |snapshot| snapshot.dig("process_memory", "rss_kb").positive? }
      assert_equal false, payload.fetch("called_methods_truncated")
      assert_equal false, payload.fetch("require_events_truncated")
      assert_equal false, payload.fetch("load_events_truncated")
      assert_equal false, payload.fetch("snapshots_truncated")
      assert_equal 20_000, payload.dig("limits", "called_methods", "max")
      assert_equal payload.fetch("called_methods").length, payload.dig("limits", "called_methods", "recorded")
      assert_equal payload.fetch("require_events").length, payload.dig("limits", "require_events", "recorded")
      assert_equal payload.fetch("load_events").length, payload.dig("limits", "load_events", "recorded")
      assert_equal payload.fetch("snapshots").length, payload.dig("limits", "snapshots", "recorded")
    end
  end

  def test_runtime_recorder_reports_truncated_evidence_limits
    Dir.mktmpdir("rails_dependency_pruner_runtime_limits") do |dir|
      output = File.join(dir, "runtime.json")
      first_feature = File.join(dir, "limit_feature_one.rb")
      second_feature = File.join(dir, "limit_feature_two.rb")
      script = File.join(dir, "runtime_limit_script.rb")
      File.write(first_feature, "module ActiveRecord; class LimitFeatureOne; end; end\n")
      File.write(second_feature, "module ActiveRecord; class LimitFeatureTwo; end; end\n")
      File.write(script, <<~RUBY)
        module ActiveRecord
          class Base
            def one
              true
            end

            def two
              true
            end
          end
        end

        $LOAD_PATH.unshift(#{dir.dump})
        require "limit_feature_one"
        require "limit_feature_two"
        load #{first_feature.dump}
        load #{second_feature.dump}
        ActiveRecord::Base.new.one
        ActiveRecord::Base.new.two
        RailsDependencyPruner::RuntimeRecorder.snapshot!("after_limits")
      RUBY

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT" => output,
          "RAILS_DEPENDENCY_PRUNER_TRACE_CALLS" => "1",
          "RAILS_DEPENDENCY_PRUNER_TRACE_REQUIRES" => "1",
          "RAILS_DEPENDENCY_PRUNER_SNAPSHOTS" => "1",
          "RAILS_DEPENDENCY_PRUNER_MAX_CALLS" => "1",
          "RAILS_DEPENDENCY_PRUNER_MAX_REQUIRE_EVENTS" => "1",
          "RAILS_DEPENDENCY_PRUNER_MAX_LOAD_EVENTS" => "1",
          "RAILS_DEPENDENCY_PRUNER_MAX_SNAPSHOTS" => "1",
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-rrails_dependency_pruner/runtime_recorder",
        script,
      )

      assert status.success?, stderr
      assert_empty stdout

      payload = JSON.parse(File.read(output))
      assert_equal 1, payload.fetch("called_methods").length
      assert_equal 1, payload.fetch("require_events").length
      assert_equal 1, payload.fetch("load_events").length
      assert_equal 1, payload.fetch("snapshots").length
      assert_equal true, payload.fetch("called_methods_truncated")
      assert_equal true, payload.fetch("require_events_truncated")
      assert_equal true, payload.fetch("load_events_truncated")
      assert_equal true, payload.fetch("snapshots_truncated")
      assert_equal({ "max" => 1, "recorded" => 1, "truncated" => true }, payload.dig("limits", "called_methods"))
      assert_equal({ "max" => 1, "recorded" => 1, "truncated" => true }, payload.dig("limits", "require_events"))
      assert_equal({ "max" => 1, "recorded" => 1, "truncated" => true }, payload.dig("limits", "load_events"))
      assert_equal({ "max" => 1, "recorded" => 1, "truncated" => true }, payload.dig("limits", "snapshots"))
    end
  end

  def test_runtime_recorder_reports_rails_middleware_and_routes
    Dir.mktmpdir("rails_dependency_pruner_runtime_app") do |dir|
      output = File.join(dir, "runtime.json")
      script = File.join(dir, "runtime_app_script.rb")
      File.write(script, <<~RUBY)
        RuntimeMiddlewareOne = Class.new
        RuntimeMiddlewareTwo = Class.new
        FakeMiddleware = Struct.new(:klass)
        FakePath = Struct.new(:spec)
        FakeRoute = Struct.new(:name, :verb, :path, :defaults)
        FakeRoutes = Struct.new(:routes)
        FakeApp = Struct.new(:middleware, :routes)

        module Rails
          def self.application=(app)
            @application = app
          end

          def self.application
            @application
          end
        end

        Rails.application = FakeApp.new(
          [
            FakeMiddleware.new(RuntimeMiddlewareOne),
            FakeMiddleware.new(RuntimeMiddlewareTwo),
          ],
          FakeRoutes.new([
            FakeRoute.new("runtime_one", "GET", FakePath.new("/runtime/one"), {"controller" => "runtime", "action" => "one"}),
            FakeRoute.new("runtime_two", "POST", FakePath.new("/runtime/two"), {"controller" => "runtime", "action" => "two"}),
          ])
        )

        RailsDependencyPruner::RuntimeRecorder.snapshot!("after_routes")
      RUBY

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_RUNTIME_OUTPUT" => output,
          "RAILS_DEPENDENCY_PRUNER_SNAPSHOTS" => "1",
          "RAILS_DEPENDENCY_PRUNER_MAX_MIDDLEWARE" => "1",
          "RAILS_DEPENDENCY_PRUNER_MAX_ROUTES" => "1",
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-rrails_dependency_pruner/runtime_recorder",
        script,
      )

      assert status.success?, stderr
      assert_empty stdout

      payload = JSON.parse(File.read(output))
      assert_equal "RuntimeMiddlewareOne", payload.dig("rails_application", "middleware", 0, "name")
      assert_equal "runtime_one", payload.dig("rails_application", "routes", 0, "name")
      assert_equal "/runtime/one", payload.dig("rails_application", "routes", 0, "path")
      assert_equal "runtime", payload.dig("rails_application", "routes", 0, "controller")
      assert_equal true, payload.fetch("middleware_truncated")
      assert_equal true, payload.fetch("routes_truncated")
      assert_equal({ "max" => 1, "recorded" => 1, "truncated" => true }, payload.dig("limits", "middleware"))
      assert_equal({ "max" => 1, "recorded" => 1, "truncated" => true }, payload.dig("limits", "routes"))

      app_snapshot = payload.fetch("snapshots").find { |snapshot| snapshot.fetch("phase") == "after_routes" }
      assert_equal "RuntimeMiddlewareOne", app_snapshot.dig("rails_application", "middleware", 0, "name")
      assert_equal "/runtime/one", app_snapshot.dig("rails_application", "routes", 0, "path")
    end
  end

  def test_runtime_collect_command_writes_runtime_evidence
    Dir.mktmpdir("rails_dependency_pruner_runtime_collect") do |dir|
      app_root = File.join(dir, "app")
      rails_root = File.join(dir, "fake_rails")
      FileUtils.mkdir_p(File.join(app_root, "config"))
      FileUtils.mkdir_p(rails_root)
      File.write(File.join(rails_root, "fake_runtime_rails_feature.rb"), "module ActiveRecord; class RuntimeCollectFeature; end; end\n")
      File.write(File.join(app_root, "app_runtime_feature.rb"), "module RuntimeCollectApp; class LocalFeature; end; end\n")
      File.write(File.join(app_root, "config/application.rb"), <<~RUBY)
        $LOAD_PATH.unshift(#{rails_root.dump})
        $LOAD_PATH.unshift(#{app_root.dump})
        require "fake_runtime_rails_feature"
        require "app_runtime_feature"

        module RuntimeCollectApp
        end

        RailsDependencyPruner::RuntimeRecorder.snapshot!("inside_application")
      RUBY
      coverage_path = write_coverage_manifest(app_root)
      output_path = File.join(dir, "runtime.json")

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "runtime",
        "collect",
        "--app",
        app_root,
        "--coverage",
        coverage_path,
        "--output",
        output_path,
        "--rails-root",
        rails_root,
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      report = JSON.parse(stdout)
      assert_equal "ok", report.fetch("status")
      assert_equal output_path, report.fetch("output_path")
      assert_match(/\Asha256:/, report.dig("coverage", "digest"))
      assert_equal %w[boot routes], report.dig("coverage", "workloads")
      assert File.exist?(output_path)

      runtime = JSON.parse(File.read(output_path))
      phases = runtime.fetch("snapshots").map { |snapshot| snapshot.fetch("phase") }
      assert_includes phases, "inside_application"
      assert_includes phases, "after_application_load"
      assert runtime.fetch("loaded_features").any? { |feature| feature.end_with?("fake_runtime_rails_feature.rb") }
      refute runtime.fetch("loaded_features").any? { |feature| feature.end_with?("app_runtime_feature.rb") }
      assert_operator runtime.fetch("process_memory").fetch("rss_kb"), :>, 0
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

  def test_early_boot_prune_mode_blocks_absolute_require_path
    Dir.mktmpdir("rails_dependency_pruner_early_absolute_blocking") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      feature_path = File.join(dir, "blocked_absolute.rb")
      File.write(feature_path, "BLOCKED_ABSOLUTE_LOADED = true\n")
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "boot_prune",
        "pruning" => {
          "disabled_require_paths" => ["blocked_absolute"],
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
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
          require #{feature_path.dump}
        RUBY
      )

      refute status.success?
      assert_includes stderr, "#{feature_path} is disabled by rails_dependency_pruner early boot"

      payload = JSON.parse(File.read(output_path))
      assert_equal feature_path, payload.dig("events", 0, "path")
      assert_equal "blocked_absolute", payload.dig("events", 0, "matched_path")
      assert_equal "require", payload.dig("events", 0, "operation")
    end
  end

  def test_early_boot_prune_mode_blocks_require_relative
    Dir.mktmpdir("rails_dependency_pruner_early_relative_blocking") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      script_path = File.join(dir, "boot_script.rb")
      File.write(File.join(dir, "relative_feature.rb"), "RELATIVE_FEATURE_LOADED = true\n")
      File.write(script_path, <<~RUBY)
        require "rails_dependency_pruner/early_boot"
        require_relative "relative_feature"
      RUBY
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "boot_prune",
        "pruning" => {
          "disabled_require_paths" => ["relative_feature"],
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
        script_path,
      )

      refute status.success?
      assert_includes stderr, "relative_feature is disabled by rails_dependency_pruner early boot"

      payload = JSON.parse(File.read(output_path))
      assert_equal "relative_feature", payload.dig("events", 0, "path")
      assert_equal "relative_feature", payload.dig("events", 0, "matched_path")
      assert_equal "require_relative", payload.dig("events", 0, "operation")
    end
  end

  def test_early_boot_shadow_records_load_without_blocking
    Dir.mktmpdir("rails_dependency_pruner_early_load_shadow") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      feature_path = File.join(dir, "loaded_feature.rb")
      File.write(feature_path, "LOADED_FEATURE = true\n")
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "shadow",
        "pruning" => {
          "disabled_require_paths" => ["loaded_feature"],
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
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
          load #{feature_path.dump}
          puts LOADED_FEATURE
        RUBY
      )

      assert status.success?, stderr
      assert_equal "true\n", stdout

      payload = JSON.parse(File.read(output_path))
      assert_equal feature_path, payload.dig("events", 0, "path")
      assert_equal "loaded_feature", payload.dig("events", 0, "matched_path")
      assert_equal "load", payload.dig("events", 0, "operation")
      assert_equal "would_block", payload.dig("events", 0, "action")
    end
  end

  def test_early_boot_prune_mode_blocks_disabled_railtie
    Dir.mktmpdir("rails_dependency_pruner_early_railtie_blocking") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      FileUtils.mkdir_p(File.join(dir, "active_job"))
      File.write(File.join(dir, "active_job/railtie.rb"), "ACTIVE_JOB_RAILTIE_LOADED = true\n")
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "boot_prune",
        "pruning" => {
          "disabled_railties" => ["active_job/railtie"],
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
          require "active_job/railtie"
        RUBY
      )

      refute status.success?
      assert_includes stderr, "active_job/railtie is disabled by rails_dependency_pruner early boot"

      payload = JSON.parse(File.read(output_path))
      assert_equal "active_job/railtie", payload.dig("events", 0, "path")
      assert_equal "blocked", payload.dig("events", 0, "action")
    end
  end

  def test_early_boot_extreme_mode_skips_railtie_and_disables_eager_load
    Dir.mktmpdir("rails_dependency_pruner_early_extreme") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      probe_path = File.join(dir, "eager_probe")
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => true,
          "skip_railties" => ["action_mailbox/engine"],
          "config_namespace_stubs" => ["action_mailbox"],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
      ))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "boot_prune",
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-e",
        <<~RUBY,
          require "json"
          require "logger"
          require "rails_dependency_pruner/early_boot"
          require "rails"
          skipped = require "action_mailbox/engine"

          module EarlyExtremeApp
            class EagerProbe
              def self.eager_load!
                File.write(#{probe_path.dump}, "called")
              end
            end

            class Application < Rails::Application
              config.root = #{dir.dump}
              config.secret_key_base = "x" * 64
              config.logger = Logger.new(nil)
              config.eager_load = true
              config.eager_load_namespaces << EagerProbe
              config.action_mailbox.ingress = :relay
            end
          end

          Rails.application.initialize!
          puts JSON.generate("skipped" => skipped, "eager_probe" => File.exist?(#{probe_path.dump}))
        RUBY
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal false, payload.fetch("skipped")
      assert_equal false, payload.fetch("eager_probe")

      early_payload = JSON.parse(File.read(output_path))
      assert_equal "skipped", early_payload.dig("events", 0, "action")
      assert_equal "action_mailbox/engine", early_payload.dig("events", 0, "matched_path")
    end
  end

  def test_early_boot_lazy_loads_action_mailbox_mail_ext
    Dir.mktmpdir("rails_dependency_pruner_early_lazy_mail_ext") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => [],
          "lazy_require_paths" => ["action_mailbox/mail_ext"],
          "config_namespace_stubs" => [],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
      ))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "boot_prune",
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-e",
        <<~RUBY,
          require "json"
          require "rails_dependency_pruner/early_boot"
          require "mail"
          require "action_mailbox"

          before = $LOADED_FEATURES.grep(/action_mailbox\\/mail_ext/)
          message = Mail.from_source("To: replies@example.com\\n\\nhello")
          recipients = message.recipients
          after = $LOADED_FEATURES.grep(/action_mailbox\\/mail_ext/)

          puts JSON.generate(
            "before_count" => before.length,
            "after_count" => after.length,
            "recipients" => recipients,
          )
        RUBY
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal 0, payload.fetch("before_count")
      assert_operator payload.fetch("after_count"), :>, 0
      assert_equal ["replies@example.com"], payload.fetch("recipients")

      early_payload = JSON.parse(File.read(output_path))
      assert early_payload.fetch("events").any? { |event| event["action"] == "deferred" && event["matched_path"] == "action_mailbox/mail_ext" }
      assert early_payload.fetch("events").any? { |event| event["action"] == "loaded_lazy" && event["matched_path"] == "action_mailbox/mail_ext" }
    end
  end

  def test_early_boot_lazy_loads_gem_constant
    Dir.mktmpdir("rails_dependency_pruner_early_lazy_gem") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      fake_gem_path = File.join(dir, "faker.rb")
      File.write(fake_gem_path, <<~RUBY)
        module Faker
          module Name
            def self.name
              "Deferred Gem"
            end
          end
        end
      RUBY
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => [],
          "lazy_require_paths" => [],
          "lazy_gems" => ["faker"],
          "config_namespace_stubs" => [],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
      ))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "boot_prune",
          "RUBYLIB" => [dir, ROOT.join("lib").to_s].join(File::PATH_SEPARATOR),
        },
        RUBY,
        "-e",
        <<~RUBY,
          require "json"
          require "rails_dependency_pruner/early_boot"

          before = Object.const_defined?(:Faker, false)
          name = Faker::Name.name
          after = Object.const_defined?(:Faker, false)

          puts JSON.generate(
            "before" => before,
            "after" => after,
            "name" => name,
          )
        RUBY
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal false, payload.fetch("before")
      assert_equal true, payload.fetch("after")
      assert_equal "Deferred Gem", payload.fetch("name")

      early_payload = JSON.parse(File.read(output_path))
      event = early_payload.fetch("events").find { |candidate| candidate["action"] == "loaded_lazy_gem" && candidate["matched_path"] == "faker" }
      refute_nil event
      assert_equal "Faker", event.fetch("constant")
      assert_equal "-e", event.fetch("caller_path")
      assert_operator event.fetch("caller_line"), :>, 0
    end
  end

  def test_early_boot_lazy_constant_loader_ignores_unconfigured_constants
    Dir.mktmpdir("rails_dependency_pruner_early_lazy_exact_constant") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      File.write(File.join(dir, "faker.rb"), "module Faker; end\n")
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => [],
          "lazy_require_paths" => [],
          "lazy_gems" => ["faker"],
          "config_namespace_stubs" => [],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
      ))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "boot_prune",
          "RUBYLIB" => [dir, ROOT.join("lib").to_s].join(File::PATH_SEPARATOR),
        },
        RUBY,
        "-e",
        <<~RUBY,
          require "json"
          require "rails_dependency_pruner/early_boot"

          begin
            FakerTools
          rescue NameError
          end

          puts JSON.generate(
            "faker_defined" => Object.const_defined?(:Faker, false),
            "faker_loaded" => $LOADED_FEATURES.any? { |feature| feature.end_with?("/faker.rb") },
          )
        RUBY
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal false, payload.fetch("faker_defined")
      assert_equal false, payload.fetch("faker_loaded")

      early_payload = JSON.parse(File.read(output_path))
      assert_equal 0, early_payload.fetch("events_count")
    end
  end

  def test_early_boot_lazy_constant_loader_ignores_nested_constant_owner
    Dir.mktmpdir("rails_dependency_pruner_early_lazy_nested_owner") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      File.write(File.join(dir, "faker.rb"), "module Faker; end\n")
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => [],
          "lazy_require_paths" => [],
          "lazy_gems" => ["faker"],
          "config_namespace_stubs" => [],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
      ))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "boot_prune",
          "RUBYLIB" => [dir, ROOT.join("lib").to_s].join(File::PATH_SEPARATOR),
        },
        RUBY,
        "-e",
        <<~RUBY,
          require "json"
          require "rails_dependency_pruner/early_boot"

          module Reports
            def self.resolve
              Faker
            end
          end

          nested_error = begin
            Reports.resolve
            nil
          rescue NameError => error
            error.name.to_s
          end

          top_level_before = Object.const_defined?(:Faker, false)
          top_level_value = Faker
          top_level_after = Object.const_defined?(:Faker, false)

          puts JSON.generate(
            "nested_error" => nested_error,
            "top_level_before" => top_level_before,
            "top_level_after" => top_level_after,
            "top_level_name" => top_level_value.name,
            "faker_loaded" => $LOADED_FEATURES.any? { |feature| feature.end_with?("/faker.rb") },
          )
        RUBY
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal "Faker", payload.fetch("nested_error")
      assert_equal false, payload.fetch("top_level_before")
      assert_equal true, payload.fetch("top_level_after")
      assert_equal "Faker", payload.fetch("top_level_name")
      assert_equal true, payload.fetch("faker_loaded")

      early_payload = JSON.parse(File.read(output_path))
      events = early_payload.fetch("events")
      assert_equal 1, early_payload.fetch("events_count")
      assert_equal "loaded_lazy_gem", events.dig(0, "action")
      assert_equal "Faker", events.dig(0, "constant")
      assert_equal "Object", events.dig(0, "owner")
    end
  end

  def test_early_boot_canary_fails_lazy_constant_in_disallowed_phase
    Dir.mktmpdir("rails_dependency_pruner_early_lazy_phase_violation") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      File.write(File.join(dir, "faker.rb"), "module Faker; end\n")
      payload = approved_early_boot_profile(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => [],
          "lazy_require_paths" => [],
          "lazy_gems" => ["faker"],
          "config_namespace_stubs" => [],
        },
        "lazy_constants" => {
          "Faker" => {
            "gem" => "faker",
            "allowed_phases" => ["manual_app_use"],
          },
        },
        "expected_events" => [],
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
      )
      File.write(profile_path, JSON.pretty_generate(payload))

      _stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "canary",
          "RAILS_DEPENDENCY_PRUNER_PROFILE_ID" => payload.fetch("profile_id"),
          "RUBYLIB" => [dir, ROOT.join("lib").to_s].join(File::PATH_SEPARATOR),
        },
        RUBY,
        "-e",
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
          Faker
        RUBY
      )

      refute status.success?
      assert_includes stderr, "unexpected early boot event boot:disallowed_lazy_gem_constant:faker in canary mode"

      early_payload = JSON.parse(File.read(output_path))
      event = early_payload.fetch("events").first
      assert_equal 1, early_payload.fetch("unexpected_events_count")
      assert_equal "disallowed_lazy_gem_constant", event.fetch("action")
      assert_equal "boot", event.fetch("phase")
      assert_equal "Faker", event.fetch("constant")
      assert_equal "faker", event.fetch("gem")
      assert_equal ["manual_app_use"], event.fetch("allowed_phases")
      assert_equal false, event.fetch("expected")
    end
  end

  def test_early_boot_canary_fails_lazy_constant_for_unapproved_gem
    Dir.mktmpdir("rails_dependency_pruner_early_lazy_unapproved_gem") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      File.write(File.join(dir, "faker.rb"), "module Faker; end\n")
      payload = approved_early_boot_profile(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => [],
          "lazy_require_paths" => [],
          "lazy_gems" => [],
          "config_namespace_stubs" => [],
        },
        "lazy_constants" => {
          "Faker" => {
            "gem" => "faker",
            "allowed_phases" => ["boot"],
          },
        },
        "expected_events" => [],
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
      )
      File.write(profile_path, JSON.pretty_generate(payload))

      _stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "canary",
          "RAILS_DEPENDENCY_PRUNER_PROFILE_ID" => payload.fetch("profile_id"),
          "RUBYLIB" => [dir, ROOT.join("lib").to_s].join(File::PATH_SEPARATOR),
        },
        RUBY,
        "-e",
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
          Faker
        RUBY
      )

      refute status.success?
      assert_includes stderr, "unexpected early boot event boot:unapproved_lazy_gem_constant:faker in canary mode"

      early_payload = JSON.parse(File.read(output_path))
      event = early_payload.fetch("events").first
      assert_equal 1, early_payload.fetch("unexpected_events_count")
      assert_equal "unapproved_lazy_gem_constant", event.fetch("action")
      assert_equal "Faker", event.fetch("constant")
      assert_equal "faker", event.fetch("gem")
      assert_equal false, event.fetch("expected")
    end
  end

  def test_early_boot_canary_allows_lazy_constant_in_declared_phase
    Dir.mktmpdir("rails_dependency_pruner_early_lazy_phase_allowed") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      File.write(File.join(dir, "faker.rb"), <<~RUBY)
        module Faker
          def self.ok?
            true
          end
        end
      RUBY
      payload = approved_early_boot_profile(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => [],
          "lazy_require_paths" => [],
          "lazy_gems" => ["faker"],
          "config_namespace_stubs" => [],
        },
        "lazy_constants" => {
          "Faker" => {
            "gem" => "faker",
            "allowed_phases" => ["manual_app_use"],
          },
        },
        "expected_events" => [
          {
            "phase" => "manual_app_use",
            "action" => "loaded_lazy_gem",
            "gem" => "faker",
          },
        ],
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
      )
      File.write(profile_path, JSON.pretty_generate(payload))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "canary",
          "RAILS_DEPENDENCY_PRUNER_PROFILE_ID" => payload.fetch("profile_id"),
          "RAILS_DEPENDENCY_PRUNER_PHASE" => "manual_app_use",
          "RUBYLIB" => [dir, ROOT.join("lib").to_s].join(File::PATH_SEPARATOR),
        },
        RUBY,
        "-e",
        <<~RUBY
          require "json"
          require "rails_dependency_pruner/early_boot"
          puts JSON.generate("ok" => Faker.ok?)
        RUBY
      )

      assert status.success?, stderr
      assert_equal true, JSON.parse(stdout).fetch("ok")

      early_payload = JSON.parse(File.read(output_path))
      event = early_payload.fetch("events").first
      assert_equal 1, early_payload.fetch("expected_events_count")
      assert_equal 0, early_payload.fetch("unexpected_events_count")
      assert_equal "manual_app_use", event.fetch("phase")
      assert_equal "loaded_lazy_gem", event.fetch("action")
      assert_equal true, event.fetch("expected")
    end
  end

  def test_early_boot_expected_lazy_gem_event_without_phase_matches_request_phase
    Dir.mktmpdir("rails_dependency_pruner_early_lazy_phase_wildcard") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      File.write(File.join(dir, "faker.rb"), "module Faker; def self.ok? = true; end\n")
      payload = approved_early_boot_profile(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => [],
          "lazy_require_paths" => [],
          "lazy_gems" => ["faker"],
          "config_namespace_stubs" => [],
        },
        "expected_events" => [
          {
            "action" => "loaded_lazy_gem",
            "gem" => "faker",
          },
        ],
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
      )
      File.write(profile_path, JSON.pretty_generate(payload))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "canary",
          "RAILS_DEPENDENCY_PRUNER_PHASE" => "request",
          "RAILS_DEPENDENCY_PRUNER_PROFILE_ID" => payload.fetch("profile_id"),
          "RUBYLIB" => [dir, ROOT.join("lib").to_s].join(File::PATH_SEPARATOR),
        },
        RUBY,
        "-e",
        <<~RUBY
          require "json"
          require "rails_dependency_pruner/early_boot"
          puts JSON.generate("ok" => Faker.ok?)
        RUBY
      )

      assert status.success?, stderr
      assert_equal true, JSON.parse(stdout).fetch("ok")

      early_payload = JSON.parse(File.read(output_path))
      event = early_payload.fetch("events").first
      assert_equal 1, early_payload.fetch("expected_events_count")
      assert_equal 0, early_payload.fetch("unexpected_events_count")
      assert_equal "request", event.fetch("phase")
      assert_equal "loaded_lazy_gem", event.fetch("action")
      assert_equal true, event.fetch("expected")
    end
  end

  def test_early_boot_lazy_loads_hyphenated_gem_constant
    Dir.mktmpdir("rails_dependency_pruner_early_lazy_hyphen_gem") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      File.write(File.join(dir, "sentry-rails.rb"), <<~RUBY)
        module Sentry
          def self.initialized?
            true
          end
        end
      RUBY
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => [],
          "lazy_require_paths" => [],
          "lazy_gems" => ["sentry-rails"],
          "config_namespace_stubs" => [],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
      ))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "boot_prune",
          "RUBYLIB" => [dir, ROOT.join("lib").to_s].join(File::PATH_SEPARATOR),
        },
        RUBY,
        "-e",
        <<~RUBY,
          require "json"
          require "rails_dependency_pruner/early_boot"

          before = Object.const_defined?(:Sentry, false)
          initialized = Sentry.initialized?
          after = Object.const_defined?(:Sentry, false)

          puts JSON.generate(
            "before" => before,
            "after" => after,
            "initialized" => initialized,
          )
        RUBY
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal false, payload.fetch("before")
      assert_equal true, payload.fetch("after")
      assert_equal true, payload.fetch("initialized")

      early_payload = JSON.parse(File.read(output_path))
      assert early_payload.fetch("events").any? { |event| event["action"] == "loaded_lazy_gem" && event["matched_path"] == "sentry-rails" }
    end
  end

  def test_early_boot_stubs_rack_mini_profiler
    Dir.mktmpdir("rails_dependency_pruner_early_rack_mini_profiler_stub") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => [],
          "lazy_require_paths" => [],
          "lazy_gems" => ["rack-mini-profiler"],
          "config_namespace_stubs" => [],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
      ))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "boot_prune",
          "RUBYLIB" => ROOT.join("lib").to_s,
        },
        RUBY,
        "-e",
        <<~RUBY,
          require "json"
          require "rails_dependency_pruner/early_boot"

          Rack::MiniProfiler.config.position = "bottom-left"
          Rack::MiniProfiler.authorize_request

          puts JSON.generate(
            "defined" => defined?(Rack::MiniProfiler),
            "loaded" => $LOADED_FEATURES.any? { |feature| feature.include?("rack-mini-profiler") },
          )
        RUBY
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal "constant", payload.fetch("defined")
      assert_equal false, payload.fetch("loaded")
    end
  end

  def test_early_boot_stubs_active_storage_vips_analyzer
    Dir.mktmpdir("rails_dependency_pruner_early_vips_analyzer_stub") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      fake_analyzer_path = File.join(dir, "active_storage/analyzer/image_analyzer")
      FileUtils.mkdir_p(fake_analyzer_path)
      File.write(File.join(fake_analyzer_path, "vips.rb"), <<~RUBY)
        VIPS_ANALYZER_FILE_LOADED = true
        require "ruby-vips"
      RUBY
      File.write(File.join(dir, "vips.rb"), <<~RUBY)
        module Vips
          class Image
          end
        end
      RUBY
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => [],
          "lazy_require_paths" => [],
          "lazy_gems" => ["ruby-vips"],
          "config_namespace_stubs" => [],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
      ))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "boot_prune",
          "RUBYLIB" => [dir, ROOT.join("lib").to_s].join(File::PATH_SEPARATOR),
        },
        RUBY,
        "-e",
        <<~RUBY,
          require "json"
          require "rails_dependency_pruner/early_boot"

          module ActiveStorage
            class Analyzer
            end
            class Analyzer::ImageAnalyzer < Analyzer
              autoload :Vips, "active_storage/analyzer/image_analyzer/vips"
            end
          end

          analyzer = ActiveStorage::Analyzer::ImageAnalyzer::Vips
          analyzer_accepts = analyzer.accept?(Object.new)
          analyzer_file_loaded = Object.const_defined?(:VIPS_ANALYZER_FILE_LOADED, false)
          vips_before = Object.const_defined?(:Vips, false)
          image_class = Vips::Image
          vips_after = Object.const_defined?(:Vips, false)

          puts JSON.generate(
            "analyzer_class" => analyzer.name,
            "analyzer_accepts" => analyzer_accepts,
            "analyzer_file_loaded" => analyzer_file_loaded,
            "vips_before" => vips_before,
            "vips_after" => vips_after,
            "image_class" => image_class.name,
          )
        RUBY
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal "ActiveStorage::Analyzer::ImageAnalyzer::Vips", payload.fetch("analyzer_class")
      assert_equal false, payload.fetch("analyzer_accepts")
      assert_equal false, payload.fetch("analyzer_file_loaded")
      assert_equal false, payload.fetch("vips_before")
      assert_equal true, payload.fetch("vips_after")
      assert_equal "Vips::Image", payload.fetch("image_class")

      early_payload = JSON.parse(File.read(output_path))
      assert early_payload.fetch("events").any? { |event| event["action"] == "stubbed_lazy_gem_require" && event["gem"] == "ruby-vips" }
      assert early_payload.fetch("events").any? { |event| event["action"] == "loaded_lazy_gem" && event["matched_path"] == "ruby-vips" }
    end
  end

  def test_early_boot_only_blocks_require_paths_from_pruned_frameworks
    Dir.mktmpdir("rails_dependency_pruner_early_framework_filter") do |dir|
      profile_path = File.join(dir, "profile.json")
      output_path = File.join(dir, "early.json")
      File.write(File.join(dir, "kept_support_feature.rb"), "KEPT_SUPPORT_FEATURE_LOADED = true\n")
      File.write(File.join(dir, "pruned_cable_feature.rb"), "PRUNED_CABLE_FEATURE_LOADED = true\n")
      File.write(profile_path, JSON.pretty_generate(
        "mode" => "boot_prune",
        "boot_plan" => {
          "pruned_frameworks" => ["actioncable"],
        },
        "pruning" => {
          "disabled_require_paths" => ["kept_support_feature", "pruned_cable_feature"],
          "disabled_require_path_provenance" => [
            {
              "require_path" => "kept_support_feature",
              "component" => "activesupport",
            },
            {
              "require_path" => "pruned_cable_feature",
              "component" => "actioncable",
            },
          ],
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
        <<~RUBY
          $LOAD_PATH.unshift(#{dir.dump})
          require "rails_dependency_pruner/early_boot"
          require "kept_support_feature"
          require "pruned_cable_feature"
        RUBY
      )

      refute status.success?
      refute_includes stderr, "kept_support_feature is disabled"
      assert_includes stderr, "pruned_cable_feature is disabled by rails_dependency_pruner early boot"

      payload = JSON.parse(File.read(output_path))
      assert_equal ["pruned_cable_feature"], payload.fetch("events").map { |event| event.fetch("path") }
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

  def test_early_boot_disable_bypasses_production_safety
    Dir.mktmpdir("rails_dependency_pruner_early_disable") do |dir|
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

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "production",
          "RAILS_DEPENDENCY_PRUNER_DISABLE" => "1",
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-e",
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
          puts "disabled"
        RUBY
      )

      assert status.success?, stderr
      assert_equal "disabled\n", stdout
    end
  end

  def test_early_boot_production_mode_rejects_profile_id_mismatch
    Dir.mktmpdir("rails_dependency_pruner_early_digest") do |dir|
      profile_path = File.join(dir, "profile.json")
      File.write(profile_path, JSON.pretty_generate(
        "schema_version" => 2,
        "profile_id" => "sha256:stale",
        "mode" => "production",
        "safety" => {
          "production_allowed" => true,
        },
        "pruning" => {
          "disabled_require_paths" => [],
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
      assert_includes stderr, "production mode requires matching profile_id"
    end
  end

  def test_early_boot_stale_profile_fails_before_boot_mutates_state
    Dir.mktmpdir("rails_dependency_pruner_early_stale_before_boot") do |dir|
      profile_path = File.join(dir, "profile.json")
      mutation_path = File.join(dir, "boot-mutated")
      File.write(profile_path, JSON.pretty_generate(
        "schema_version" => 2,
        "profile_id" => "sha256:stale",
        "mode" => "production",
        "safety" => {
          "production_allowed" => true,
        },
        "pruning" => {
          "disabled_require_paths" => [],
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
          File.write(#{mutation_path.dump}, "mutated")
        RUBY
      )

      refute status.success?
      assert_includes stderr, "production mode requires matching profile_id"
      refute File.exist?(mutation_path)
    end
  end

  def test_early_boot_production_mode_requires_profile_id_environment
    Dir.mktmpdir("rails_dependency_pruner_early_profile_id_env") do |dir|
      profile_path = File.join(dir, "profile.json")
      payload = approved_early_boot_profile(
        "mode" => "production",
        "pruning" => {
          "disabled_require_paths" => [],
        },
      )
      File.write(profile_path, JSON.pretty_generate(payload))

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
      assert_includes stderr, "production mode requires RAILS_DEPENDENCY_PRUNER_PROFILE_ID=#{payload.fetch("profile_id")}"
    end
  end

  def test_early_boot_safety_modes_reject_invalid_unexpected_event_policy
    %w[canary production].each do |mode|
      Dir.mktmpdir("rails_dependency_pruner_early_invalid_policy") do |dir|
        profile_path = File.join(dir, "profile.json")
        payload = approved_early_boot_profile(
          "mode" => "boot_prune",
          "unexpected_event_policy" => "ignore_events",
          "pruning" => {
            "disabled_require_paths" => [],
          },
        )
        File.write(profile_path, JSON.pretty_generate(payload))

        _stdout, stderr, status = Open3.capture3(
          {
            "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
            "RAILS_DEPENDENCY_PRUNER_MODE" => mode,
            "RAILS_DEPENDENCY_PRUNER_PROFILE_ID" => payload.fetch("profile_id"),
          },
          RUBY,
          "-I#{ROOT.join("lib")}",
          "-e",
          <<~RUBY
            require "rails_dependency_pruner/early_boot"
          RUBY
        )

        refute status.success?, mode
        assert_includes stderr, "#{mode} mode requires a valid unexpected_event_policy"
      end
    end
  end

  def test_early_boot_canary_mode_blocks_with_approved_profile
    Dir.mktmpdir("rails_dependency_pruner_early_canary") do |dir|
      File.write(File.join(dir, "blocked_feature.rb"), "raise 'should not load'\n")
      output_path = File.join(dir, "events.json")
      profile_path = File.join(dir, "profile.json")
      payload = approved_early_boot_profile(
        "mode" => "boot_prune",
        "pruning" => {
          "disabled_require_paths" => ["blocked_feature"],
        },
      )
      File.write(profile_path, JSON.pretty_generate(payload))

      _stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "canary",
          "RAILS_DEPENDENCY_PRUNER_PROFILE_ID" => payload.fetch("profile_id"),
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-I#{dir}",
        "-e",
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
          require "blocked_feature"
        RUBY
      )

      refute status.success?
      assert_includes stderr, "blocked_feature is disabled by rails_dependency_pruner early boot"

      events = JSON.parse(File.read(output_path))
      assert_equal "canary", events.fetch("mode")
      assert_equal "blocked", events.dig("events", 0, "action")
      assert_equal "blocked_feature", events.dig("events", 0, "path")
    end
  end

  def test_early_boot_canary_allows_expected_skip_event
    Dir.mktmpdir("rails_dependency_pruner_early_expected_event") do |dir|
      File.write(File.join(dir, "blocked_feature.rb"), "raise 'should not load'\n")
      output_path = File.join(dir, "events.json")
      profile_path = File.join(dir, "profile.json")
      payload = approved_early_boot_profile(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => ["blocked_feature"],
          "lazy_require_paths" => [],
          "lazy_gems" => [],
          "config_namespace_stubs" => [],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
        "expected_events" => [
          {
            "phase" => "boot",
            "action" => "skipped",
            "path" => "blocked_feature",
          },
        ],
        "memory_policy" => {
          "reference_baseline_rss_kb" => 123_456,
        },
      )
      File.write(profile_path, JSON.pretty_generate(payload))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "canary",
          "RAILS_DEPENDENCY_PRUNER_PROFILE_ID" => payload.fetch("profile_id"),
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-I#{dir}",
        "-e",
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
          require "blocked_feature"
          puts "ok"
        RUBY
      )

      assert status.success?, stderr
      assert_equal "ok\n", stdout

      events = JSON.parse(File.read(output_path))
      event = events.fetch("events").first
      assert_equal 1, events.fetch("expected_events_count")
      assert_equal 0, events.fetch("unexpected_events_count")
      assert_equal true, event.fetch("expected")
      assert_equal "boot:skipped:blocked_feature", event.fetch("event_id")
      assert_equal "skip_railtie:blocked_feature", event.fetch("transform_id")
      assert_operator event.fetch("pid"), :>, 0
      assert_equal 1, events.dig("counters", "pruner.profile.valid")
      assert_equal 1, events.dig("counters", "pruner.event.total")
      assert_equal 1, events.dig("counters", "pruner.event.expected")
      assert_equal 1, events.dig("counters", "pruner.event.skipped_require")
      assert_nil events.dig("counters", "pruner.event.unexpected")
      assert_equal 123_456, events.dig("counters", "pruner.memory.baseline_reference_rss_kb")
      assert_operator events.dig("counters", "pruner.memory.current_rss_kb"), :>, 0
    end
  end

  def test_early_boot_writes_structured_event_log
    Dir.mktmpdir("rails_dependency_pruner_early_event_log") do |dir|
      File.write(File.join(dir, "blocked_feature.rb"), "raise 'should not load'\n")
      event_log_path = File.join(dir, "events.ndjson")
      profile_path = File.join(dir, "profile.json")
      payload = approved_early_boot_profile(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => ["blocked_feature"],
          "lazy_require_paths" => [],
          "lazy_gems" => [],
          "config_namespace_stubs" => [],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
        "expected_events" => [
          {
            "phase" => "boot",
            "action" => "skipped",
            "path" => "blocked_feature",
          },
        ],
      )
      File.write(profile_path, JSON.pretty_generate(payload))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "boot_prune",
          "RAILS_DEPENDENCY_PRUNER_EVENT_LOG" => event_log_path,
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-I#{dir}",
        "-e",
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
          require "blocked_feature"
          puts "ok"
        RUBY
      )

      assert status.success?, stderr
      assert_equal "ok\n", stdout

      lines = File.readlines(event_log_path, chomp: true)
      assert_equal 1, lines.length

      event = JSON.parse(lines.first)
      assert_equal "rails_dependency_pruner", event.fetch("component")
      assert_equal payload.fetch("profile_id"), event.fetch("profile_id")
      assert_equal "boot_prune", event.fetch("mode")
      assert_equal "skipped", event.fetch("event")
      assert_equal "boot:skipped:blocked_feature", event.fetch("event_id")
      assert_equal "skip_railtie:blocked_feature", event.fetch("transform_id")
      assert_equal true, event.fetch("expected")
      assert_includes event.fetch("caller"), "-e:"
    end
  end

  def test_early_boot_canary_fails_unexpected_skip_event
    Dir.mktmpdir("rails_dependency_pruner_early_unexpected_event") do |dir|
      File.write(File.join(dir, "blocked_feature.rb"), "raise 'should not load'\n")
      output_path = File.join(dir, "events.json")
      profile_path = File.join(dir, "profile.json")
      payload = approved_early_boot_profile(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => ["blocked_feature"],
          "lazy_require_paths" => [],
          "lazy_gems" => [],
          "config_namespace_stubs" => [],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
        "expected_events" => [],
      )
      File.write(profile_path, JSON.pretty_generate(payload))

      _stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "canary",
          "RAILS_DEPENDENCY_PRUNER_PROFILE_ID" => payload.fetch("profile_id"),
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-I#{dir}",
        "-e",
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
          require "blocked_feature"
        RUBY
      )

      refute status.success?
      assert_includes stderr, "unexpected early boot event boot:skipped:blocked_feature in canary mode"

      events = JSON.parse(File.read(output_path))
      assert_equal 0, events.fetch("expected_events_count")
      assert_equal 1, events.fetch("unexpected_events_count")
      assert_equal false, events.dig("events", 0, "expected")
      assert_equal 1, events.dig("counters", "pruner.event.total")
      assert_equal 1, events.dig("counters", "pruner.event.unexpected")
      assert_equal 1, events.dig("counters", "pruner.event.skipped_require")
    end
  end

  def test_early_boot_canary_fails_unexpected_request_event_by_default
    Dir.mktmpdir("rails_dependency_pruner_early_canary_request_event") do |dir|
      File.write(File.join(dir, "blocked_feature.rb"), "raise 'should not load'\n")
      output_path = File.join(dir, "events.json")
      profile_path = File.join(dir, "profile.json")
      payload = approved_early_boot_profile(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => ["blocked_feature"],
          "lazy_require_paths" => [],
          "lazy_gems" => [],
          "config_namespace_stubs" => [],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
        "expected_events" => [],
      )
      File.write(profile_path, JSON.pretty_generate(payload))

      _stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "canary",
          "RAILS_DEPENDENCY_PRUNER_PHASE" => "request",
          "RAILS_DEPENDENCY_PRUNER_PROFILE_ID" => payload.fetch("profile_id"),
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-I#{dir}",
        "-e",
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
          require "blocked_feature"
        RUBY
      )

      refute status.success?
      assert_includes stderr, "unexpected early boot event request:skipped:blocked_feature in canary mode"

      events = JSON.parse(File.read(output_path))
      assert_equal 0, events.fetch("expected_events_count")
      assert_equal 1, events.fetch("unexpected_events_count")
      assert_equal "request", events.dig("events", 0, "phase")
      assert_equal false, events.dig("events", 0, "expected")
    end
  end

  def test_early_boot_production_reports_unexpected_request_event_by_default
    Dir.mktmpdir("rails_dependency_pruner_early_production_request_event") do |dir|
      File.write(File.join(dir, "blocked_feature.rb"), "raise 'should not load'\n")
      output_path = File.join(dir, "events.json")
      profile_path = File.join(dir, "profile.json")
      payload = approved_early_boot_profile(
        "mode" => "boot_prune",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => ["blocked_feature"],
          "lazy_require_paths" => [],
          "lazy_gems" => [],
          "config_namespace_stubs" => [],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
        "expected_events" => [],
      )
      File.write(profile_path, JSON.pretty_generate(payload))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "production",
          "RAILS_DEPENDENCY_PRUNER_PHASE" => "request",
          "RAILS_DEPENDENCY_PRUNER_PROFILE_ID" => payload.fetch("profile_id"),
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-I#{dir}",
        "-e",
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
          require "blocked_feature"
          puts "ok"
        RUBY
      )

      assert status.success?, stderr
      assert_equal "ok\n", stdout

      events = JSON.parse(File.read(output_path))
      assert_equal 0, events.fetch("expected_events_count")
      assert_equal 1, events.fetch("unexpected_events_count")
      assert_equal "request", events.dig("events", 0, "phase")
      assert_equal false, events.dig("events", 0, "expected")
    end
  end

  def test_early_boot_production_reports_unexpected_event_when_policy_allows_it
    Dir.mktmpdir("rails_dependency_pruner_early_report_event") do |dir|
      File.write(File.join(dir, "blocked_feature.rb"), "raise 'should not load'\n")
      output_path = File.join(dir, "events.json")
      profile_path = File.join(dir, "profile.json")
      payload = approved_early_boot_profile(
        "mode" => "boot_prune",
        "unexpected_event_policy" => "report",
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => ["blocked_feature"],
          "lazy_require_paths" => [],
          "lazy_gems" => [],
          "config_namespace_stubs" => [],
        },
        "pruning" => {
          "disabled_require_paths" => [],
          "disabled_railties" => [],
        },
        "expected_events" => [],
      )
      File.write(profile_path, JSON.pretty_generate(payload))

      stdout, stderr, status = Open3.capture3(
        {
          "RAILS_DEPENDENCY_PRUNER_PROFILE" => profile_path,
          "RAILS_DEPENDENCY_PRUNER_MODE" => "production",
          "RAILS_DEPENDENCY_PRUNER_PROFILE_ID" => payload.fetch("profile_id"),
          "RAILS_DEPENDENCY_PRUNER_EARLY_OUTPUT" => output_path,
        },
        RUBY,
        "-I#{ROOT.join("lib")}",
        "-I#{dir}",
        "-e",
        <<~RUBY
          require "rails_dependency_pruner/early_boot"
          require "blocked_feature"
          puts "ok"
        RUBY
      )

      assert status.success?, stderr
      assert_equal "ok\n", stdout

      events = JSON.parse(File.read(output_path))
      assert_equal 0, events.fetch("expected_events_count")
      assert_equal 1, events.fetch("unexpected_events_count")
      assert_equal false, events.dig("events", 0, "expected")
    end
  end

  def test_apply_early_boot_shim_writes_review_patch
    Dir.mktmpdir("rails_dependency_pruner_early_boot_patch") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "config/boot.rb"), <<~RUBY)
        ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
        require "bundler/setup"
        require "bootsnap/setup"
      RUBY
      patch_path = File.join(dir, "early_boot.patch")

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "shim",
        "--app",
        app_root,
        "--patch",
        patch_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal "patch_available", payload.fetch("status")
      assert_equal "config/boot.rb", payload.fetch("target")

      patch = File.read(patch_path)
      assert_includes patch, "+require \"rails_dependency_pruner/early_boot\" if ENV[\"RAILS_DEPENDENCY_PRUNER_EARLY\"] == \"1\""
      assert_includes File.read(File.join(app_root, "config/boot.rb")), "require \"bootsnap/setup\""
      refute_includes File.read(File.join(app_root, "config/boot.rb")), "rails_dependency_pruner/early_boot"
    end
  end

  def test_apply_early_boot_shim_reports_existing_installation
    Dir.mktmpdir("rails_dependency_pruner_early_boot_existing") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      File.write(File.join(app_root, "config/boot.rb"), <<~RUBY)
        require "bundler/setup"
        require "rails_dependency_pruner/early_boot" if ENV["RAILS_DEPENDENCY_PRUNER_EARLY"] == "1"
      RUBY
      patch_path = File.join(dir, "early_boot.patch")

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "apply",
        "early-boot-shim",
        "--app",
        app_root,
        "--write-patch",
        patch_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal "already_installed", payload.fetch("status")
      assert_equal "early boot shim already installed", payload.fetch("reason")
      assert_includes File.read(patch_path), "no early-boot shim patch generated"
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
        "patch",
        "--profile",
        profile_path,
        "--app",
        app_root,
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        "actionpack,actionview,activejob,activemodel,activerecord",
        "--patch",
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
      assert_includes patch, "+# rails_dependency_pruner: pruned active_job/railtie (transforms: disable_framework:activejob, prune_railtie:active_job/railtie)"
      assert_includes patch, "+# require \"active_job/railtie\""
      assert_includes File.read(application_path), "require \"rails/all\""
      assert_patch_applies(app_root: app_root, patch_path: patch_path)
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
      assert_includes patch, "+# rails_dependency_pruner: pruned active_job/railtie (transforms: disable_framework:activejob, prune_railtie:active_job/railtie)"
      assert_includes patch, "+# require \"active_job/railtie\""
      assert_includes File.read(application_path), "require \"active_job/railtie\""
      assert_patch_applies(app_root: app_root, patch_path: patch_path)
    end
  end

  def test_rollout_writes_review_patch_for_production_files
    Dir.mktmpdir("rails_dependency_pruner_rollout") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      application_path = File.join(app_root, "config/application.rb")
      File.write(application_path, <<~RUBY)
        # frozen_string_literal: true

        require "rails/all"
      RUBY
      File.write(File.join(app_root, "config/boot.rb"), <<~RUBY)
        # frozen_string_literal: true

        require "bundler/setup"
        require "bootsnap/setup"
      RUBY
      FileUtils.mkdir_p(File.join(app_root, "config/environments"))
      production_path = File.join(app_root, "config/environments/production.rb")
      File.write(production_path, <<~RUBY)
        Rails.application.configure do
          config.eager_load = true
        end
      RUBY
      coverage_path = File.join(dir, "coverage.yml")
      File.write(coverage_path, <<~YAML)
        version: 2
        rails_env: production
        boot:
          eager_load: true
      YAML
      profile_path = File.join(dir, "profile.json")
      profile_payload = approved_early_boot_profile(
        "mode" => "boot_prune",
        "boot_plan" => {
          "required_frameworks" => %w[actionpack actionview activemodel activerecord],
          "pruned_frameworks" => ["activejob"],
          "autoload_ignores" => ["app/jobs"],
          "eager_load_ignores" => ["app/jobs"],
        },
        "pruning" => {
          "disabled_frameworks" => ["activejob"],
          "disabled_railties" => ["active_job/railtie"],
          "disabled_initializers" => [],
          "disabled_require_paths" => [],
          "disabled_require_path_provenance" => [],
          "disabled_constants" => [],
          "autoload_ignores" => ["app/jobs"],
          "eager_load_ignores" => ["app/jobs"],
        },
        "extreme_boot" => {
          "disable_eager_load" => true,
          "skip_railties" => ["rails/test_unit/railtie"],
          "lazy_require_paths" => [],
          "lazy_gems" => [],
          "config_namespace_stubs" => [],
        },
        "explanations" => {
          "activejob" => {
            "decision" => "disable_framework",
            "railtie" => "active_job/railtie",
          },
        },
      )
      RailsDependencyPruner::Profile.new(profile_payload).write(profile_path)
      patch_path = File.join(dir, "rollout.patch")

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "rollout",
        "--app",
        app_root,
        "--profile",
        profile_path,
        "--coverage",
        coverage_path,
        "--patch",
        patch_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal patch_path, payload.fetch("patch_path")
      assert_equal "config/rails_dependency_pruner_profile.json", payload.fetch("profile_target")
      assert_equal "config/pruner_coverage.yml", payload.fetch("coverage_target")
      assert_includes payload.fetch("sections"), "production_config"

      patch = File.read(patch_path)
      assert_includes patch, "-require \"rails/all\""
      assert_includes patch, "+require \"active_record/railtie\""
      assert_includes patch, "+# rails_dependency_pruner: pruned active_job/railtie (transforms: disable_framework:activejob, prune_railtie:active_job/railtie; proof: explanations.activejob)"
      assert_includes patch, "+# require \"active_job/railtie\""
      assert_includes patch, "+require \"rails_dependency_pruner/early_boot\" if ENV[\"RAILS_DEPENDENCY_PRUNER_EARLY\"] == \"1\""
      assert_includes patch, "+  # Roll back early boot with RAILS_DEPENDENCY_PRUNER_DISABLE=1."
      assert_includes patch, "+  config.rails_dependency_pruner.enabled = ENV[\"RAILS_DEPENDENCY_PRUNER_ENABLED\"] == \"1\""
      assert_includes patch, "+++ b/config/rails_dependency_pruner_profile.json"
      assert_includes patch, profile_payload.fetch("profile_id")
      assert_includes patch, "+++ b/config/pruner_coverage.yml"
      assert_includes patch, "+rails_env: production"
      assert_includes File.read(application_path), "require \"rails/all\""
      refute_includes File.read(production_path), "rails_dependency_pruner"
      assert_patch_applies(app_root: app_root, patch_path: patch_path)
    end
  end

  def test_measure_boot_reports_process_memory
    Dir.mktmpdir("rails_dependency_pruner_measure") do |dir|
      report_path = File.join(dir, "measurement.json")
      markdown_path = File.join(dir, "measurement.md")
      profile_path = File.join(dir, "profile.json")
      File.write(profile_path, JSON.pretty_generate(
        "schema_version" => 2,
        "profile_id" => "sha256:test",
        "mode" => "boot_prune",
        "pruning" => {
          "disabled_frameworks" => ["activejob"],
          "disabled_railties" => ["active_job/railtie"],
          "disabled_require_paths" => ["active_job/railtie"],
          "disabled_constants" => ["ActiveJob::Base"],
        },
      ))
      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "measure",
        "--app",
        FAKE_APP_ROOT.to_s,
        "--profile",
        profile_path,
        "--variants",
        "baseline,shadow",
        "--runs",
        "1",
        "--output",
        report_path,
        "--markdown",
        markdown_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal "application", payload.fetch("target")
      assert_equal "ok", payload.dig("variants", "baseline", "status")
      assert_equal "ok", payload.dig("variants", "shadow", "status")
      assert_operator payload.dig("variants", "baseline", "rss_kb_median"), :>, 0
      assert_operator payload.dig("variants", "baseline", "process_memory_median", "rss_kb"), :>, 0
      assert_kind_of Hash, payload.dig("variants", "baseline", "rails_loaded_features_by_framework_median")
      assert payload.dig("deltas", "shadow").key?("rss_kb")
      assert payload.dig("deltas", "shadow", "process_memory").key?("rss_kb")
      assert_kind_of Hash, payload.dig("deltas", "shadow", "rails_loaded_features_by_framework")
      assert_equal "sha256:test", payload.dig("profile", "profile_id")
      assert_equal ["active_job/railtie"], payload.dig("profile", "disabled_railties")
      assert_equal 1, payload.dig("profile", "disabled_require_paths_count")
      assert File.exist?(report_path)
      assert File.exist?(markdown_path)

      markdown = File.read(markdown_path)
      assert_includes markdown, "# Rails Dependency Pruner Measurement"
      assert_includes markdown, "- Target: `application`"
      assert_includes markdown, "| baseline | ok |"
      assert_includes markdown, "| shadow | ok |"
      assert_includes markdown, "events | unexpected"
      assert_includes markdown, "## Process Memory"
      assert_includes markdown, "## Process Memory Deltas"
      assert_includes markdown, "physical footprint"
      assert_includes markdown, "## Deltas Vs Baseline"
      assert_includes markdown, "## Rails Features By Framework"
      assert_includes markdown, "## Rails Feature Deltas By Framework"
    end
  end

  def test_memory_probe_parses_process_memory_details
    smaps = <<~TEXT
      Rss:                2048 kB
      Pss:                1536 kB
      Private_Clean:       256 kB
      Private_Dirty:       512 kB
    TEXT

    linux = RailsDependencyPruner::Measurement::MemoryProbe.parse_linux_smaps_rollup(smaps)
    assert_equal 1536, linux.fetch("pss_kb")
    assert_equal 256, linux.fetch("private_clean_kb")
    assert_equal 512, linux.fetch("private_dirty_kb")
    assert_equal 768, linux.fetch("uss_kb")

    vmmap = <<~TEXT
      Physical footprint:         2368K
      Physical footprint (peak):  2464K
    TEXT

    assert_equal 2368, RailsDependencyPruner::Measurement::MemoryProbe.parse_macos_physical_footprint_kb(vmmap)
    assert_equal 1536, RailsDependencyPruner::Measurement::MemoryProbe.parse_memory_size_kb("1.5M")
  end

  def test_measure_captures_early_boot_event_counts
    Dir.mktmpdir("rails_dependency_pruner_measure_events") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app_root, "config"))
      FileUtils.mkdir_p(File.join(app_root, "lib"))
      File.write(File.join(app_root, "lib/blocked_feature.rb"), "# frozen_string_literal: true\n")
      File.write(File.join(app_root, "config/application.rb"), <<~RUBY)
        # frozen_string_literal: true

        $LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
        require "blocked_feature"
      RUBY

      profile_path = File.join(dir, "profile.json")
      payload = {
        "schema_version" => 3,
        "profile_id" => nil,
        "fingerprints" => { "profile_id" => nil },
        "mode" => "boot_prune",
        "pruning" => {
          "disabled_frameworks" => [],
          "disabled_railties" => [],
          "disabled_require_paths" => [],
          "disabled_constants" => [],
        },
        "extreme_boot" => {
          "disable_eager_load" => false,
          "skip_railties" => ["blocked_feature"],
          "lazy_require_paths" => [],
          "lazy_gems" => [],
          "config_namespace_stubs" => [],
        },
        "safety" => {
          "production_allowed" => false,
        },
        "memory_policy" => {
          "baseline_reference_rss_kb" => 111_222,
        },
      }
      payload["transforms"] = RailsDependencyPruner::TransformRegistry.transforms_for_payload(payload)
      payload["expected_events"] = payload.fetch("transforms").flat_map { |transform| Array(transform["expected_events"]) }
      RailsDependencyPruner::ProfileSchema.set_profile_id(payload, RailsDependencyPruner::Profile.new(payload).digest)
      RailsDependencyPruner::Profile.new(payload).write(profile_path)

      report = RailsDependencyPruner::Measurement::Runner.new(
        app_root: app_root,
        variants: %w[baseline boot_prune],
        profile_path: profile_path,
        runs: 1,
      ).run

      assert_equal "ok", report.dig("variants", "baseline", "status")
      assert_equal "ok", report.dig("variants", "boot_prune", "status")
      assert_nil report.dig("variants", "baseline", "events_count")
      assert_equal 1, report.dig("runs", "boot_prune", 0, "events_count")
      assert_equal 1, report.dig("runs", "boot_prune", 0, "expected_events_count")
      assert_equal 0, report.dig("runs", "boot_prune", 0, "unexpected_events_count")
      assert_equal 1, report.dig("runs", "boot_prune", 0, "counters", "pruner.event.skipped_require")
      assert_equal 111_222, report.dig("runs", "boot_prune", 0, "counters", "pruner.memory.baseline_reference_rss_kb")
      assert_operator report.dig("runs", "boot_prune", 0, "counters", "pruner.memory.current_rss_kb"), :>, 0
      assert_equal 1, report.dig("variants", "boot_prune", "events_count")
      assert_equal 0, report.dig("variants", "boot_prune", "unexpected_events_count")
      assert_equal 1, report.dig("variants", "boot_prune", "counters", "pruner.event.skipped_require")
      assert_equal 111_222, report.dig("variants", "boot_prune", "counters", "pruner.memory.baseline_reference_rss_kb")
      assert_operator report.dig("variants", "boot_prune", "counters", "pruner.memory.current_rss_kb"), :>, 0
    end
  end

  def test_measure_ablation_reports_transform_buckets
    Dir.mktmpdir("rails_dependency_pruner_measure_ablation") do |dir|
      report_path = File.join(dir, "ablation.json")
      markdown_path = File.join(dir, "ablation.md")
      profile_path = File.join(dir, "profile.json")
      write_measurement_profile(profile_path)

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "measure",
        "ablation",
        "--app",
        FAKE_APP_ROOT.to_s,
        "--profile",
        profile_path,
        "--runs",
        "1",
        "--output",
        report_path,
        "--markdown",
        markdown_path,
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      assert_equal true, payload.fetch("ablation")
      assert_equal "application", payload.fetch("target")
      assert_equal "ok", payload.dig("variants", "baseline", "status")
      assert_equal "ok", payload.dig("variants", "all_approved_transforms", "status")
      assert_kind_of Hash, payload.dig("variants", "baseline", "object_counts_median")
      assert_kind_of Hash, payload.dig("deltas", "all_approved_transforms", "object_counts")
      variant_names = payload.fetch("ablation_variants").map { |variant| variant.fetch("name") }
      assert_includes variant_names, "disable_eager_load_only"
      assert_includes variant_names, "lazy_gems_only"
      assert_includes variant_names, "rails_prune_plan_only"
      assert_includes variant_names, "all_low_risk_transforms"
      assert_equal profile_path, payload.dig("source_profile", "path")
      assert_equal true, payload.dig("memory_policy", "configured")
      assert_kind_of Array, payload.dig("memory_policy", "ablation_assessment")
      assert File.exist?(report_path)
      assert File.exist?(markdown_path)

      markdown = File.read(markdown_path)
      assert_includes markdown, "# Rails Dependency Pruner Ablation"
      assert_includes markdown, "## Process Memory"
      assert_includes markdown, "## Rails Memory Buckets"
      assert_includes markdown, "## Ruby Object Buckets"
      assert_includes markdown, "## Transform Sets"
      assert_includes markdown, "assessment"
      assert_includes markdown, "boot ms"
      assert_includes markdown, "warm p95 ms"
      assert_includes markdown, "events | unexpected"
      assert_includes markdown, "RSS is process memory"
    end
  end

  def test_memory_policy_evaluates_ablation_measurement
    result = RailsDependencyPruner::MemoryPolicy.new(
      policy: {
        "min_total_savings_mib" => 20,
        "min_total_savings_percent" => 10,
        "min_transform_savings_mib" => 2,
        "reference_profile_id" => "sha256:test",
      },
      measurement: {
        "ablation" => true,
        "source_profile" => {
          "profile_id" => "sha256:test",
        },
        "variants" => {
          "baseline" => {
            "status" => "ok",
            "rss_kb_median" => 100_000,
          },
          "disable_eager_load_only" => {
            "status" => "ok",
            "rss_kb_median" => 90_000,
          },
          "all_approved_transforms" => {
            "status" => "ok",
            "rss_kb_median" => 60_000,
          },
        },
        "ablation_variants" => [
          {
            "name" => "baseline",
            "transform_ids" => [],
          },
          {
            "name" => "disable_eager_load_only",
            "transform_ids" => ["disable_eager_load"],
          },
          {
            "name" => "all_approved_transforms",
            "transform_ids" => ["disable_eager_load"],
          },
        ],
      },
    ).evaluate

    assert_equal true, result.fetch("passed")
    assert_empty result.fetch("errors")
    assert_equal "all_approved_transforms", result.dig("measurement", "candidate_variant")
    assert_equal 40_000, result.dig("measurement", "saved_kb")
    assert_equal [
      {
        "variant" => "disable_eager_load_only",
        "transform_ids" => ["disable_eager_load"],
        "rss_kb" => 90_000,
        "saved_kb" => 10_000,
        "saved_mib" => 9.765625,
      },
    ], result.fetch("transform_savings")
    assert_equal "production_candidate", result.dig("ablation_assessment", 0, "classification")
  end

  def test_memory_policy_classifies_ablation_transform_variants
    result = RailsDependencyPruner::MemoryPolicy.new(
      policy: {
        "min_total_savings_mib" => 20,
        "min_transform_savings_mib" => 2,
        "max_first_request_latency_regression_ms" => 100,
        "forced_transform_ids" => ["lazy_gem:small"],
      },
      measurement: {
        "ablation" => true,
        "variants" => {
          "baseline" => {
            "status" => "ok",
            "rss_kb_median" => 100_000,
            "first_request_duration_ms_median" => 20.0,
          },
          "small_transform_only" => {
            "status" => "ok",
            "rss_kb_median" => 99_000,
            "first_request_duration_ms_median" => 20.0,
          },
          "forced_transform_only" => {
            "status" => "ok",
            "rss_kb_median" => 99_000,
            "first_request_duration_ms_median" => 20.0,
          },
          "slow_transform_only" => {
            "status" => "ok",
            "rss_kb_median" => 80_000,
            "first_request_duration_ms_median" => 140.0,
          },
          "all_approved_transforms" => {
            "status" => "ok",
            "rss_kb_median" => 60_000,
            "first_request_duration_ms_median" => 25.0,
          },
        },
        "ablation_variants" => [
          {
            "name" => "baseline",
            "transform_ids" => [],
          },
          {
            "name" => "small_transform_only",
            "transform_ids" => ["lazy_gem:tiny"],
          },
          {
            "name" => "forced_transform_only",
            "transform_ids" => ["lazy_gem:small"],
          },
          {
            "name" => "slow_transform_only",
            "transform_ids" => ["disable_eager_load"],
          },
          {
            "name" => "all_approved_transforms",
            "transform_ids" => ["lazy_gem:tiny", "lazy_gem:small", "disable_eager_load"],
          },
        ],
      },
    ).evaluate

    assert_equal false, result.fetch("passed")
    assert_includes result.fetch("errors"), "memory policy min_transform_savings_mib not met for small_transform_only: saved 1.0 MiB, required 2.0 MiB"
    refute result.fetch("errors").any? { |error| error.include?("forced_transform_only") }

    assessments = result.fetch("ablation_assessment").each_with_object({}) do |entry, hash|
      hash[entry.fetch("variant")] = entry
    end
    assert_equal "not_worth_enabling", assessments.dig("small_transform_only", "classification")
    assert_includes assessments.dig("small_transform_only", "reasons"), "saved 1.0 MiB below 2.0 MiB threshold"
    assert_equal "forced", assessments.dig("forced_transform_only", "classification")
    assert_includes assessments.dig("forced_transform_only", "reasons"), "forced by memory_policy.forced_transform_ids"
    assert_equal "unsafe_for_production", assessments.dig("slow_transform_only", "classification")
    assert_includes assessments.dig("slow_transform_only", "reasons"), "first_request latency regression 120.0 ms exceeds 100.0 ms"
    assert_equal "production_candidate", assessments.dig("all_approved_transforms", "classification")
    assert_equal 40_000, assessments.dig("all_approved_transforms", "saved_kb")
  end

  def test_memory_policy_enforces_latency_regression_gates
    result = RailsDependencyPruner::MemoryPolicy.new(
      policy: {
        "min_total_savings_mib" => 20,
        "max_first_request_latency_regression_ms" => 100,
        "max_warmed_p95_latency_regression_percent" => 5,
        "max_warmed_p99_latency_regression_ms" => 10,
      },
      measurement: {
        "variants" => {
          "baseline" => {
            "status" => "ok",
            "rss_kb_median" => 100_000,
            "first_request_duration_ms_median" => 20.0,
            "warmed_request_duration_ms_p95_median" => 10.0,
            "warmed_request_duration_ms_p99_median" => 30.0,
          },
          "boot_prune" => {
            "status" => "ok",
            "rss_kb_median" => 60_000,
            "first_request_duration_ms_median" => 140.0,
            "warmed_request_duration_ms_p95_median" => 11.0,
            "warmed_request_duration_ms_p99_median" => 45.0,
          },
        },
      },
    ).evaluate

    assert_equal false, result.fetch("passed")
    assert_equal 40_000, result.dig("measurement", "saved_kb")
    assert_equal 120.0, result.dig("measurement", "latency", "first_request", "delta_ms")
    assert_equal 10.0, result.dig("measurement", "latency", "warmed_p95", "delta_percent")
    assert_includes result.fetch("errors"), "memory policy max_first_request_latency_regression_ms not met: regression 120.0 ms, allowed 100.0 ms"
    assert_includes result.fetch("errors"), "memory policy max_warmed_p95_latency_regression_percent not met: regression 10.0%, allowed 5.0%"
    assert_includes result.fetch("errors"), "memory policy max_warmed_p99_latency_regression_ms not met: regression 15.0 ms, allowed 10.0 ms"
  end

  def test_memory_policy_enforces_request_status_and_unexpected_event_gates
    result = RailsDependencyPruner::MemoryPolicy.new(
      policy: {
        "min_total_savings_mib" => 20,
      },
      measurement: {
        "target" => "requests",
        "request_paths" => ["/ok", "/missing"],
        "variants" => {
          "baseline" => {
            "status" => "ok",
            "rss_kb_median" => 100_000,
            "request_status_matrix" => {
              "/ok" => { "statuses" => [200] },
              "/missing" => { "statuses" => [404] },
            },
          },
          "boot_prune" => {
            "status" => "ok",
            "rss_kb_median" => 60_000,
            "request_status_matrix" => {
              "/ok" => { "statuses" => [500] },
              "/missing" => { "errors" => ["NoMethodError"] },
            },
            "runtime_event_summary" => {
              "unexpected_events_count" => 1,
            },
          },
        },
      },
    ).evaluate

    assert_equal false, result.fetch("passed")
    assert_equal false, result.dig("request_status", "passed")
    assert_equal ["/ok", "/missing"], result.dig("request_status", "paths")
    assert_includes result.fetch("errors"), "memory policy request status mismatch for boot_prune /ok: expected 200, got 500"
    assert_includes result.fetch("errors"), "memory policy request status variant boot_prune has errors for /missing: NoMethodError"
    assert_includes result.fetch("errors"), "memory policy request status variant boot_prune missing statuses for /missing"
    assert_includes result.fetch("errors"), "memory policy measurement has unexpected runtime events in variant boot_prune: 1"
    assert_equal [
      {
        "source" => "variant boot_prune",
        "count" => 1,
      },
    ], result.dig("unexpected_events", "reports")
  end

  def test_memory_policy_rejects_failed_ablation_transform_variant
    result = RailsDependencyPruner::MemoryPolicy.new(
      policy: {
        "min_total_savings_mib" => 20,
      },
      measurement: {
        "ablation" => true,
        "variants" => {
          "baseline" => {
            "status" => "ok",
            "rss_kb_median" => 100_000,
          },
          "all_approved_transforms" => {
            "status" => "ok",
            "rss_kb_median" => 60_000,
          },
          "disable_eager_load_only" => {
            "status" => "error",
          },
        },
        "ablation_variants" => [
          {
            "name" => "baseline",
            "transform_ids" => [],
          },
          {
            "name" => "disable_eager_load_only",
            "transform_ids" => ["disable_eager_load"],
          },
          {
            "name" => "all_approved_transforms",
            "transform_ids" => ["disable_eager_load"],
          },
        ],
      },
    ).evaluate

    assert_equal false, result.fetch("passed")
    assert_includes result.fetch("errors"), "memory policy ablation variant failed: disable_eager_load_only"
  end

  def test_measure_environment_no_eager_load_variant_skips_eager_load
    Dir.mktmpdir("rails_dependency_pruner_measure_environment") do |dir|
      app_root = File.join(dir, "app")
      probe_path = File.join(dir, "eager_load_probe")
      FileUtils.mkdir_p(File.join(app_root, "config"))
      File.write(File.join(app_root, "config/application.rb"), <<~RUBY)
        # frozen_string_literal: true

        require "rails"
        require "logger"

        module MeasureEnvironmentApp
          class EagerProbe
            def self.eager_load!
              File.write(#{probe_path.dump}, "called")
            end
          end

          class Application < Rails::Application
            config.root = #{app_root.dump}
            config.secret_key_base = "x" * 64
            config.logger = Logger.new(nil)
            config.eager_load = true
            config.eager_load_namespaces << EagerProbe
          end
        end
      RUBY

      baseline = RailsDependencyPruner::Measurement::Runner.new(
        app_root: app_root,
        variants: ["baseline"],
        runs: 1,
        target: "environment",
      ).run
      assert_equal "environment", baseline.fetch("target")
      assert_equal "ok", baseline.dig("variants", "baseline", "status")
      assert File.exist?(probe_path)

      FileUtils.rm_f(probe_path)
      no_eager_load = RailsDependencyPruner::Measurement::Runner.new(
        app_root: app_root,
        variants: ["no_eager_load"],
        runs: 1,
        target: "environment",
      ).run
      assert_equal "ok", no_eager_load.dig("variants", "no_eager_load", "status")
      refute File.exist?(probe_path)
    end
  end

  def test_measure_environment_skip_railties_variant_stubs_config_namespaces
    Dir.mktmpdir("rails_dependency_pruner_measure_skip_railties") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app_root, "config"))
      File.write(File.join(app_root, "config/application.rb"), <<~RUBY)
        # frozen_string_literal: true

        require "rails"
        require "action_mailbox/engine"
        require "logger"

        module MeasureSkipRailtiesApp
          class Application < Rails::Application
            config.root = #{app_root.dump}
            config.secret_key_base = "x" * 64
            config.logger = Logger.new(nil)
            config.eager_load = false
            config.action_mailbox.ingress = :relay
          end
        end
      RUBY

      report = RailsDependencyPruner::Measurement::Runner.new(
        app_root: app_root,
        variants: ["no_eager_load_skip_railties"],
        runs: 1,
        target: "environment",
        skip_railties: ["action_mailbox/engine"],
      ).run

      assert_equal ["action_mailbox/engine"], report.fetch("skip_railties")
      assert_equal "ok", report.dig("variants", "no_eager_load_skip_railties", "status")
    end
  end

  def test_measure_requests_runs_rack_paths_before_snapshot
    Dir.mktmpdir("rails_dependency_pruner_measure_requests") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app_root, "config"))
      File.write(File.join(app_root, "config/application.rb"), <<~RUBY)
        # frozen_string_literal: true

        require "rails"
        require "action_controller/railtie"
        require "logger"

        class HelloController < ActionController::Base
          def index
            render plain: "hello"
          end
        end

        module MeasureRequestsApp
          class Application < Rails::Application
            config.root = #{app_root.dump}
            config.secret_key_base = "x" * 64
            config.logger = Logger.new(nil)
            config.eager_load = false
            config.hosts.clear
            routes.append do
              get "/hello" => "hello#index"
            end
          end
        end
      RUBY

      report = RailsDependencyPruner::Measurement::Runner.new(
        app_root: app_root,
        variants: ["baseline"],
        runs: 1,
        target: "requests",
        request_paths: ["/hello"],
      ).run

      assert_equal "requests", report.fetch("target")
      assert_equal ["/hello"], report.fetch("request_paths")
      assert_equal "ok", report.dig("variants", "baseline", "status")
      assert_equal 200, report.dig("runs", "baseline", 0, "requests", 0, "status")
      assert_equal "/hello", report.dig("runs", "baseline", 0, "requests", 0, "path")
      assert_kind_of Numeric, report.dig("runs", "baseline", 0, "boot_time_ms")
      assert_operator report.dig("runs", "baseline", 0, "boot_time_ms"), :>, 0
      assert_kind_of Numeric, report.dig("runs", "baseline", 0, "requests", 0, "duration_ms")
      assert_kind_of Numeric, report.dig("variants", "baseline", "boot_time_ms_median")
      assert_kind_of Numeric, report.dig("variants", "baseline", "first_request_duration_ms_median")
      assert_kind_of Numeric, report.dig("variants", "baseline", "request_duration_ms_p95_median")
      assert_nil report.dig("variants", "baseline", "warmed_request_duration_ms_p95_median")
      assert_equal [200], report.dig("variants", "baseline", "request_status_matrix", "/hello", "statuses")

      markdown = RailsDependencyPruner::Measurement::Report.new(report).to_markdown
      assert_includes markdown, "- Target: `requests`"
      assert_includes markdown, "- Request paths: `/hello`"
      assert_includes markdown, "boot ms"
      assert_includes markdown, "first req ms"
      assert_includes markdown, "warm p95 ms"
      assert_includes markdown, "## Request Status Matrix"
      assert_includes markdown, "| baseline | /hello | 200 | none |"
    end
  end

  def test_measure_runner_uses_measured_app_bundle
    Dir.mktmpdir("rails_dependency_pruner_measure_bundle") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.mkdir_p(app_root)
      File.write(File.join(app_root, "Gemfile"), "source \"https://rubygems.org\"\n")

      runner = RailsDependencyPruner::Measurement::Runner.new(
        app_root: app_root,
        variants: ["baseline"],
        runs: 1,
      )

      assert_equal File.join(app_root, "Gemfile"), runner.send(:env_for, "baseline").fetch("BUNDLE_GEMFILE")
    end
  end

  def test_measure_runner_parses_json_after_app_stdout_noise
    runner = RailsDependencyPruner::Measurement::Runner.new(
      app_root: FAKE_APP_ROOT.to_s,
      variants: ["baseline"],
      runs: 1,
    )
    payload = runner.send(
      :parse_successful_run,
      "W, app warning\n{\"rss_kb\":1,\"loaded_features\":2,\"rails_loaded_features\":3,\"gc_heap_live_slots\":4}\n",
      "",
    )

    assert_equal "ok", payload.fetch("status")
    assert_equal 1, payload.fetch("rss_kb")
    assert_equal 3, payload.fetch("rails_loaded_features")
  end

  def test_doctor_reports_boot_and_load_path_recommendations
    Dir.mktmpdir("rails_dependency_pruner_doctor") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "lib/assets"))
      File.write(File.join(app_root, ".ruby-version"), "9.9.9\n")
      File.write(File.join(app_root, "config/application.rb"), <<~RUBY)
        # frozen_string_literal: true

        require "rails/all"
      RUBY
      File.write(File.join(app_root, "Gemfile"), <<~RUBY)
        source "https://rubygems.org"
        gem "bootsnap"
        gem "honeybadger"
        gem "puma"
        gem "rollbar"
        gem "sentry-rails"
        gem "sidekiq"
      RUBY
      File.write(File.join(app_root, "Gemfile.lock"), <<~LOCK)
        GEM
          specs:
            rails (8.1.3)
            bootsnap (1.18.6)
            honeybadger (5.0.0)
            puma (7.0.4)
            rollbar (3.6.2)
            sentry-rails (6.0.0)
            sidekiq (8.0.8)
      LOCK
      FileUtils.mkdir_p(File.join(app_root, "config/initializers"))
      File.write(File.join(app_root, "config/initializers/dynamic_require.rb"), <<~RUBY)
        feature = ENV.fetch("BOOT_FEATURE")
        require feature
      RUBY
      File.write(File.join(app_root, "config/routes.rb"), <<~RUBY)
        Rails.application.routes.draw do
          mount AdminApp, at: "/admin"
          resources :stories
        end
      RUBY
      File.open(File.join(app_root, "config/application.rb"), "a") do |file|
        file.write(<<~RUBY)
          module DoctorApp
            class Application < Rails::Application
              config.middleware.use Rack::Attack
            end
          end
        RUBY
      end
      FileUtils.mkdir_p(File.join(app_root, "app/jobs"))
      File.write(File.join(app_root, "app/jobs/cleanup_job.rb"), <<~RUBY)
        class CleanupJob < ActiveJob::Base
          queue_as :default
        end
      RUBY
      FileUtils.mkdir_p(File.join(app_root, "app/mailers"))
      File.write(File.join(app_root, "app/mailers/user_mailer.rb"), <<~RUBY)
        class UserMailer < ActionMailer::Base
          def welcome
            mail(to: "test@example.org")
          end
        end
      RUBY
      FileUtils.mkdir_p(File.join(app_root, "app/channels"))
      File.write(File.join(app_root, "app/channels/notifications_channel.rb"), <<~RUBY)
        class NotificationsChannel < ActionCable::Channel::Base
          def subscribed
            stream_from "notifications"
          end
        end
      RUBY
      File.write(File.join(app_root, "app/models/avatar.rb"), <<~RUBY)
        class Avatar < ApplicationRecord
          has_one_attached :image
          has_rich_text :bio

          def analyze
            Vips::Image.new_from_file("avatar.jpg")
            Nokogiri::HTML("<p>x</p>")
            Sentry.capture_message("avatar")
            Honeybadger.notify("avatar")
            Rollbar.error("avatar")
            name.constantize
          end
        end
      RUBY

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "doctor",
        "--app",
        app_root,
        "--json",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = JSON.parse(stdout)
      ids = payload.fetch("recommendations").map { |entry| entry.fetch("id") }
      assert_includes ids, "ruby_version_mismatch"
      assert_includes ids, "replace_rails_all"
      assert_includes ids, "disable_autoload_paths_load_path"
      assert_includes ids, "use_autoload_lib_ignore"

      assert_equal "8.1.3", payload.dig("runtime", "rails_version")
      assert_equal true, payload.dig("capabilities", "configured_frameworks", "rails_all")
      assert_equal ["rails/all"], payload.dig("capabilities", "loaded_railties")
      assert_equal %w[honeybadger rollbar sentry-rails], payload.dig("capabilities", "integrations")
      assert_equal %w[bootsnap puma sidekiq], payload.dig("capabilities", "adapters")
      assert_equal 1, payload.dig("capabilities", "active_storage", "declarations_count")
      assert_equal "has_one_attached", payload.dig("capabilities", "active_storage", "declarations", 0, "kind")
      assert_equal 1, payload.dig("capabilities", "action_text", "declarations_count")
      assert_equal true, payload.dig("capabilities", "direct_gem_usage", "vips", "present")
      assert_equal true, payload.dig("capabilities", "direct_gem_usage", "nokogiri", "present")
      assert_equal true, payload.dig("capabilities", "direct_gem_usage", "sentry", "present")
      assert_equal true, payload.dig("capabilities", "direct_gem_usage", "honeybadger", "present")
      assert_equal true, payload.dig("capabilities", "direct_gem_usage", "rollbar", "present")
      assert_equal ["Sentry"], payload.dig("capabilities", "direct_gem_usage", "sentry", "constants")
      assert_equal ["CleanupJob"], payload.dig("capabilities", "jobs", "classes")
      assert_equal ["UserMailer"], payload.dig("capabilities", "mailers", "classes")
      assert_equal ["NotificationsChannel"], payload.dig("capabilities", "channels", "classes")
      assert_equal "AdminApp", payload.dig("capabilities", "mounted_rack_apps", 0, "target")
      assert_equal "use", payload.dig("capabilities", "middleware", 0, "operation")
      assert_equal ["resources", "mount"], payload.dig("capabilities", "routes", "calls").map { |entry| entry.fetch("call") }.sort.reverse
      assert_equal "config/initializers/dynamic_require.rb", payload.dig("risks", "initializers_dynamic_require_load", 0, "path")
      assert_equal "constantize", payload.dig("risks", "dynamic_constantization", 0, "kind")
    end
  end

  def test_coverage_template_infers_reviewable_manifest_from_app
    Dir.mktmpdir("rails_dependency_pruner_coverage_template") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      FileUtils.mkdir_p(File.join(app_root, "config/environments"))
      File.write(File.join(app_root, "config/environments/production.rb"), <<~RUBY)
        Rails.application.configure do
          config.eager_load = true
        end
      RUBY
      File.write(File.join(app_root, "config/routes.rb"), <<~RUBY)
        Rails.application.routes.draw do
          root "home#index"
          get "/settings", to: "settings#show"
          post "/comments", to: "comments#create"
          mount AdminApp, at: "/admin"
        end
      RUBY
      File.write(File.join(app_root, "Gemfile"), <<~RUBY)
        source "https://rubygems.org"
        gem "rack-mini-profiler"
        gem "sentry-rails"
      RUBY
      FileUtils.mkdir_p(File.join(app_root, "app/jobs"))
      File.write(File.join(app_root, "app/jobs/cleanup_job.rb"), <<~RUBY)
        class CleanupJob < ActiveJob::Base
          queue_as :default
        end
      RUBY
      FileUtils.mkdir_p(File.join(app_root, "app/mailers"))
      File.write(File.join(app_root, "app/mailers/user_mailer.rb"), <<~RUBY)
        class UserMailer < ActionMailer::Base
          def welcome
            mail(to: "test@example.org")
          end
        end
      RUBY
      FileUtils.mkdir_p(File.join(app_root, "app/channels"))
      File.write(File.join(app_root, "app/channels/notifications_channel.rb"), <<~RUBY)
        class NotificationsChannel < ActionCable::Channel::Base
          def subscribed
            stream_from "notifications"
          end
        end
      RUBY
      FileUtils.mkdir_p(File.join(app_root, "app/mailboxes"))
      File.write(File.join(app_root, "app/mailboxes/application_mailbox.rb"), <<~RUBY)
        class ApplicationMailbox < ActionMailbox::Base
        end
      RUBY
      File.write(File.join(app_root, "app/models/avatar.rb"), <<~RUBY)
        class Avatar < ApplicationRecord
          has_one_attached :image
          has_rich_text :bio

          def analyze
            Vips::Image.new_from_file("avatar.jpg")
            Nokogiri::HTML("<p>x</p>")
            Sentry.capture_message("avatar")
          end
        end
      RUBY

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "coverage",
        "template",
        "--app",
        app_root,
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr

      payload = YAML.safe_load(stdout, aliases: false)
      assert_equal 2, payload.fetch("version")
      assert_equal "production", payload.fetch("rails_env")
      assert_equal true, payload.dig("boot", "eager_load")
      assert_equal true, payload.dig("boot", "assets_precompile")
      assert_equal true, payload.dig("boot", "db_migrate")
      assert_equal true, payload.dig("routes", "review_required")
      assert_equal "all", payload.dig("routes", "include")
      request_paths = payload.dig("requests", "paths").map { |entry| [entry.fetch("method"), entry.fetch("path")] }
      assert_includes request_paths, ["GET", "/"]
      assert_includes request_paths, ["GET", "/settings"]
      assert_includes request_paths, ["POST", "/comments"]
      assert_equal ["CleanupJob"], payload.dig("jobs", "classes")
      assert_equal ["UserMailer#welcome"], payload.dig("mailers", "actions")
      assert_equal ["NotificationsChannel"], payload.dig("channels", "classes")
      assert_equal ["ApplicationMailbox"], payload.dig("inbound_email", "mailboxes")
      assert_equal true, payload.dig("active_storage", "declarations_expected")
      assert_equal "image", payload.dig("active_storage", "declarations", 0, "name")
      assert_equal false, payload.dig("active_storage", "attachment_read")
      assert_equal true, payload.dig("action_text", "rich_text_expected")
      assert_equal "bio", payload.dig("action_text", "declarations", 0, "name")
      assert_equal %w[assets:precompile db:migrate], payload.dig("rake_tasks", "tasks")
      assert_equal "review", payload.dig("external_integrations", "rack-mini-profiler")
      assert_equal "review", payload.dig("external_integrations", "sentry-rails")
      assert_equal true, payload.dig("lazy_gems", "nokogiri", "review_required")
      assert_equal "review", payload.dig("lazy_gems", "nokogiri", "status")
      assert_equal ["Nokogiri"], payload.dig("lazy_gems", "nokogiri", "constants")
      assert_equal "app/models/avatar.rb", payload.dig("lazy_gems", "nokogiri", "matches", 0, "path")
      assert_equal true, payload.dig("lazy_gems", "ruby-vips", "review_required")
      assert_equal "review", payload.dig("lazy_gems", "ruby-vips", "status")
      assert_equal ["Vips"], payload.dig("lazy_gems", "ruby-vips", "constants")
      assert_equal true, payload.dig("lazy_gems", "sentry-rails", "review_required")
      assert_equal ["Sentry"], payload.dig("lazy_gems", "sentry-rails", "constants")
      assert_equal true, payload.dig("canary", "review_required")
      assert_equal 0, payload.dig("canary", "duration_minutes")
      assert_equal 0, payload.dig("canary", "request_count")
      assert_nil payload.dig("canary", "unexpected_events_count")
      assert_equal 60, payload.dig("canary", "min_duration_minutes")
      assert_equal 10_000, payload.dig("canary", "min_request_count")
      assert_equal true, payload.dig("rollback", "review_required")
      assert_equal false, payload.dig("rollback", "disable_env_tested")
      assert_equal "RAILS_DEPENDENCY_PRUNER_DISABLE", payload.dig("rollback", "env_var")
    end
  end

  def test_coverage_template_write_prints_output_path
    Dir.mktmpdir("rails_dependency_pruner_coverage_template_write") do |dir|
      app_root = File.join(dir, "app")
      FileUtils.cp_r(FAKE_APP_ROOT, app_root)
      output_path = File.join(app_root, "config/pruner_coverage.yml")

      stdout, stderr, status = Open3.capture3(
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "coverage",
        "template",
        "--app",
        app_root,
        "--write",
        "config/pruner_coverage.yml",
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr
      assert_equal "#{output_path}\n", stdout
      assert File.exist?(output_path)
      assert_equal 2, YAML.safe_load(File.read(output_path), aliases: false).fetch("version")
    end
  end

  def test_coverage_manifest_ignores_review_required_template_sections
    Dir.mktmpdir("rails_dependency_pruner_coverage_template_review") do |dir|
      manifest_path = File.join(dir, "coverage.yml")
      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        requests:
          review_required: true
          paths:
            - method: GET
              path: /
              expected_status: 200
        jobs:
          review_required: false
          classes:
            - CleanupJob
        channels:
          review_required: false
          classes:
            - NotificationsChannel
        active_storage:
          review_required: false
          upload: true
      YAML

      workloads = RailsDependencyPruner::CoverageManifest.load(manifest_path).workloads
      refute_includes workloads, "requests"
      assert_includes workloads, "jobs"
      assert_includes workloads, "cable"
      assert_includes workloads, "attachments"

      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        action_text:
          review_required: false
          rich_text_expected: false
          declarations: []
      YAML

      workloads = RailsDependencyPruner::CoverageManifest.load(manifest_path).workloads
      assert_includes workloads, "action_text"
    end
  end

  def test_coverage_manifest_requires_reviewed_storage_action_for_attachment_workload
    Dir.mktmpdir("rails_dependency_pruner_coverage_template_storage_review") do |dir|
      manifest_path = File.join(dir, "coverage.yml")
      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        active_storage:
          review_required: false
          declarations_expected: false
          upload: false
          analyze: false
          variant: false
      YAML

      workloads = RailsDependencyPruner::CoverageManifest.load(manifest_path).workloads
      refute_includes workloads, "attachments"

      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        active_storage:
          review_required: false
          declarations_expected: true
          upload: true
          analyze: false
          variant: false
      YAML

      workloads = RailsDependencyPruner::CoverageManifest.load(manifest_path).workloads
      assert_includes workloads, "attachments"

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_equal %w[upload], manifest.active_storage_actions
    end
  end

  def test_coverage_manifest_requires_reviewed_external_integration_status
    Dir.mktmpdir("rails_dependency_pruner_external_integration_review") do |dir|
      manifest_path = File.join(dir, "coverage.yml")
      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        external_integrations:
          rack-mini-profiler: review
          sentry:
            review_required: true
            status: disabled_in_production
      YAML

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_equal "review", manifest.external_integration_status("rack-mini-profiler")
      assert_equal false, manifest.external_integration_reviewed?("rack-mini-profiler")
      assert_nil manifest.external_integration_status("sentry-rails")
      assert_equal false, manifest.external_integration_reviewed?("sentry-rails")

      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        external_integrations:
          rack_mini_profiler:
            review_required: false
            production_behavior: disabled_in_production
          sentry: no_production_dsn
      YAML

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_equal "disabled_in_production", manifest.external_integration_status("rack-mini-profiler")
      assert_equal true, manifest.external_integration_reviewed?("rack-mini-profiler")
      assert_equal "no_production_dsn", manifest.external_integration_status("sentry-rails")
      assert_equal true, manifest.external_integration_reviewed?("sentry-rails")
    end
  end

  def test_coverage_manifest_requires_reviewed_lazy_gem_status
    Dir.mktmpdir("rails_dependency_pruner_lazy_gem_review") do |dir|
      manifest_path = File.join(dir, "coverage.yml")
      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        lazy_gems:
          ruby-vips:
            review_required: true
            status: manual_app_use
      YAML

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_nil manifest.lazy_gem_status("ruby-vips")
      assert_equal false, manifest.lazy_gem_reviewed?("ruby-vips")

      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        lazy_gems:
          ruby_vips:
            review_required: false
            status: manual_app_use
          nokogiri: review
      YAML

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_equal "manual_app_use", manifest.lazy_gem_status("ruby-vips")
      assert_equal true, manifest.lazy_gem_reviewed?("ruby-vips")
      assert_equal "review", manifest.lazy_gem_status("nokogiri")
      assert_equal false, manifest.lazy_gem_reviewed?("nokogiri")
    end
  end

  def test_coverage_manifest_accepts_unexpired_high_risk_override
    Dir.mktmpdir("rails_dependency_pruner_high_risk_override") do |dir|
      manifest_path = File.join(dir, "coverage.yml")
      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        high_risk_overrides:
          stub_active_storage_vips_analyzer:
            accepted_by: "app owner"
            reason: "no Active Storage image analysis in production"
            expires_at: 2099-01-01
      YAML

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_equal(
        "2099-01-01",
        manifest.high_risk_override("stub:active_storage_vips_analyzer").fetch("expires_at"),
      )

      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        high_risk_overrides:
          stub_active_storage_vips_analyzer:
            accepted_by: "app owner"
            reason: "expired"
            expires_at: 2000-01-01
      YAML

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_nil manifest.high_risk_override("stub:active_storage_vips_analyzer")
    end
  end

  def test_coverage_manifest_accepts_unexpired_safety_overrides
    Dir.mktmpdir("rails_dependency_pruner_safety_override") do |dir|
      manifest_path = File.join(dir, "coverage.yml")
      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        overrides:
          - id: allow_dynamic_constantize_admin_reports
            reason: Admin reports constantize only app-owned report classes
            owner: platform-team
            expires_at: 2099-01-01
            paths:
              - app/services/report_runner.rb
              - app/services/report_runner.rb
          - id: expired_override
            reason: expired
            owner: platform-team
            expires_at: 2000-01-01
            paths:
              - config/expired.rb
          - id: incomplete_override
            reason: missing owner
            expires_at: 2099-01-01
            paths:
              - config/incomplete.rb
      YAML

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_equal [
        {
          "id" => "allow_dynamic_constantize_admin_reports",
          "reason" => "Admin reports constantize only app-owned report classes",
          "owner" => "platform-team",
          "expires_at" => "2099-01-01",
          "paths" => ["app/services/report_runner.rb"],
        },
      ], manifest.safety_overrides
    end
  end

  def test_coverage_manifest_requires_reviewed_rollback_evidence
    Dir.mktmpdir("rails_dependency_pruner_rollback_coverage") do |dir|
      manifest_path = File.join(dir, "coverage.yml")
      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        rollback:
          review_required: true
          disable_env_tested: true
      YAML

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_equal 2, manifest.version
      assert_equal false, manifest.rollback_tested?
      assert_equal false, manifest.to_h.fetch("rollback_tested")

      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        rollback:
          review_required: false
          disable_env_tested: true
          env_var: RAILS_DEPENDENCY_PRUNER_DISABLE
      YAML

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_equal true, manifest.rollback_tested?
      assert_equal true, manifest.to_h.fetch("rollback_tested")
    end
  end

  def test_coverage_manifest_requires_reviewed_canary_evidence
    Dir.mktmpdir("rails_dependency_pruner_canary_coverage") do |dir|
      manifest_path = File.join(dir, "coverage.yml")
      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        canary:
          review_required: true
          duration_minutes: 60
          request_count: 10000
          unexpected_events_count: 0
      YAML

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_equal false, manifest.canary_passed?
      assert_equal false, manifest.canary_evidence.fetch("reviewed")
      assert_equal false, manifest.canary_evidence.fetch("passed")

      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        canary:
          review_required: false
          duration_minutes: 15
          request_count: 100
          unexpected_events_count: 1
      YAML

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_equal false, manifest.canary_passed?
      assert_equal 900, manifest.canary_evidence.fetch("duration_seconds")
      assert_equal 100, manifest.canary_evidence.fetch("request_count")
      assert_equal 1, manifest.canary_evidence.fetch("unexpected_events_count")
      assert_equal false, manifest.canary_evidence.fetch("sample_passed")

      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        canary:
          review_required: false
          duration_minutes: 60
          request_count: 100
          unexpected_events_count: 0
      YAML

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_equal true, manifest.canary_passed?
      assert_equal true, manifest.to_h.dig("canary_evidence", "passed")

      File.write(manifest_path, <<~YAML)
        version: 2
        rails_env: production
        canary:
          review_required: false
          duration_minutes: 15
          request_count: 10000
          unexpected_events_count: 0
      YAML

      manifest = RailsDependencyPruner::CoverageManifest.load(manifest_path)
      assert_equal true, manifest.canary_passed?
    end
  end

  private
    def assert_patch_applies(app_root:, patch_path:)
      Dir.mktmpdir("rails_dependency_pruner_patch_apply") do |dir|
        check_root = File.join(dir, "app")
        FileUtils.cp_r(app_root, check_root)
        _init_stdout, init_stderr, init_status = Open3.capture3("git", "init", "--quiet", chdir: check_root)
        assert init_status.success?, init_stderr

        _apply_stdout, apply_stderr, apply_status = Open3.capture3("git", "apply", "--check", patch_path, chdir: check_root)
        assert apply_status.success?, apply_stderr
      end
    end

    def write_coverage_manifest(app_root)
      coverage_path = File.join(app_root, "config/pruner_coverage.yml")
      FileUtils.mkdir_p(File.dirname(coverage_path))
      File.write(coverage_path, <<~YAML)
        version: 1
        rails_env: production
        boot:
          eager_load: true
        routes:
          include: all
      YAML
      coverage_path
    end

    def write_measurement_report(path:, profile_id:, baseline_rss_kb:, candidate_rss_kb:, candidate_variant: "boot_prune")
      File.write(path, JSON.pretty_generate(
        "target" => "requests",
        "profile" => {
          "profile_id" => profile_id,
        },
        "variants" => {
          "baseline" => {
            "status" => "ok",
            "rss_kb_median" => baseline_rss_kb,
            "request_status_matrix" => {
              "/" => {
                "statuses" => [200],
              },
            },
          },
          candidate_variant => {
            "status" => "ok",
            "rss_kb_median" => candidate_rss_kb,
            "request_status_matrix" => {
              "/" => {
                "statuses" => [200],
              },
            },
          },
        },
        "request_paths" => ["/"],
      ))
    end

    def approved_early_boot_profile(payload)
      payload = {
        "schema_version" => 3,
        "profile_id" => nil,
        "fingerprints" => { "profile_id" => nil },
        "safety" => {
          "production_allowed" => true,
        },
      }.merge(payload)
      RailsDependencyPruner::ProfileSchema.set_profile_id(payload, RailsDependencyPruner::Profile.new(payload).digest)
      payload
    end

    def build_profile(profile_path:, app_root:, coverage_path:, frameworks: "actionpack,activerecord", runtime_evidence_path: nil)
      command = [
        RUBY,
        ROOT.join("exe/rails-dependency-pruner").to_s,
        "plan",
        "--rails-root",
        FAKE_RAILS_ROOT.to_s,
        "--frameworks",
        frameworks,
        "--app",
        app_root,
        "--coverage",
        coverage_path,
        "--profile",
        profile_path,
      ]
      command.concat(["--runtime-evidence", runtime_evidence_path]) if runtime_evidence_path

      _stdout, stderr, status = Open3.capture3(
        *command,
        chdir: ROOT.to_s,
      )

      assert status.success?, stderr
    end

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
