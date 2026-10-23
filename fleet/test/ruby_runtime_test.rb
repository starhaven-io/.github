# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../ruby_runtime"

class RubyRuntimeTest < Minitest::Test
  CONFIG = { "version-file" => ".ruby-version", "checksum-file" => ".ruby-version.sha256",
             "lock-files" => ["Gemfile.lock"] }.freeze
  LOCK = "GEM\n  specs:\n    rake (13.3.1)\n\nRUBY VERSION\n   ruby 4.0.7\n\nBUNDLED WITH\n   4.0.15\n"

  def setup
    @root = Dir.mktmpdir("ruby-runtime-")
    @files = { ".ruby-version" => "4.0.7\n", "Gemfile.lock" => LOCK,
               ".ruby-version.sha256" => "#{"a" * 64}  ruby-4.0.7-ubuntu-24.04-x64.tar.gz\n" }
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_consistent_inputs_are_returned_without_changes
    original = Marshal.load(Marshal.dump(@files))
    assert_same @files, RubyRuntime.check!(@files, CONFIG)
    assert_equal original, @files
  end

  def test_partial_versions_fail_in_both_directions
    [".ruby-version", ".ruby-version.sha256", "Gemfile.lock"].each do |path|
      changed = @files.merge(path => @files.fetch(path).sub("4.0.7", "4.0.8"))
      assert_raises(RubyRuntime::Error) { RubyRuntime.check!(changed, CONFIG) }
    end
  end

  def test_lockfiles_without_ruby_metadata_are_distinct_from_deleted_required_metadata
    files = @files.merge("Gemfile.lock" => LOCK.sub("RUBY VERSION\n   ruby 4.0.7\n\n", ""))
    assert RubyRuntime.check!(files, CONFIG)
    assert_raises(RubyRuntime::Error) { RubyRuntime.check!(files, CONFIG.merge("require-lock-version" => true)) }
  end

  def test_malformed_and_duplicate_checksum_records_fail
    ["bad\n", "#{"a" * 64}  ruby-4.0.7-other.tar.gz\n", @files.fetch(".ruby-version.sha256") * 2].each do |text|
      assert_raises(RubyRuntime::Error) { RubyRuntime.check!(@files.merge(".ruby-version.sha256" => text), CONFIG) }
    end
  end

  def test_malformed_metadata_is_not_treated_as_optional_absence
    [LOCK.sub("ruby 4.0.7", "ruby unknown"), "#{LOCK}\nRUBY VERSION\n   ruby 4.0.7\n",
     LOCK.sub("RUBY VERSION", " RUBY VERSION"), LOCK.sub("RUBY VERSION", "RUBY  VERSION")].each do |text|
      assert_raises(RubyRuntime::Error) { RubyRuntime.check!(@files.merge("Gemfile.lock" => text), CONFIG) }
    end
  end

  def test_confined_regular_file_inputs
    @files.each { |path, bytes| File.write(File.join(@root, path), bytes) }
    assert_equal @files, RubyRuntime.read_files(@root, CONFIG)
    @files.each do |path, bytes|
      File.unlink(File.join(@root, path))
      assert_raises(RubyRuntime::Error) { RubyRuntime.read_files(@root, CONFIG) }
      File.write(File.join(@root, path), bytes)
    end
    File.unlink(File.join(@root, ".ruby-version"))
    File.symlink(File.join(@root, "Gemfile.lock"), File.join(@root, ".ruby-version"))
    assert_raises(RubyRuntime::Error) { RubyRuntime.read_files(@root, CONFIG) }
    ["../.ruby-version", "/.ruby-version", "a/../.ruby-version", "tools/.ruby-version"].each do |path|
      assert_raises(RubyRuntime::Error) { RubyRuntime.validate_config!(CONFIG.merge("version-file" => path)) }
    end
  end

  def test_runtime_requires_one_exact_version_line
    ["", "4.0.7", "4.0.7\n\n", "4.0.7\n4.0.8\n", "ruby-4.0.7\n"].each do |text|
      assert_raises(RubyRuntime::Error) { RubyRuntime.check!(@files.merge(".ruby-version" => text), CONFIG) }
    end
  end

  def test_two_space_lock_metadata_and_crlf_are_supported
    [LOCK.sub("   ruby", "  ruby"), LOCK.gsub("\n", "\r\n")].each do |lock|
      assert RubyRuntime.check!(@files.merge("Gemfile.lock" => lock), CONFIG)
    end
  end

  def test_required_guard_uses_trusted_checker_for_all_actors
    workflow = YAML.safe_load_file(File.expand_path("../../.github/workflows/fleet-guard-required.yml", __dir__))
    step = workflow.fetch("jobs").fetch("guard").fetch("steps").find do |candidate|
      candidate["name"] == "Check Ruby runtime companions"
    end
    refute step.key?("if")
    assert_equal 'ruby hub/fleet/ruby_runtime.rb check . "hub/fleet/repos/${REPO_NAME}.yml"', step.fetch("run")
  end

  def test_hub_runtime_is_consistent
    root = File.expand_path("../..", __dir__)
    config = YAML.safe_load_file(File.join(root, "fleet/repos/.github.yml"))["params"]["ruby-runtime"]
    assert RubyRuntime.check!(RubyRuntime.read_files(root, config), config)
  end

  def test_real_renovate_pipeline_and_counterexample
    runtime = File.expand_path("../validator/node_modules/renovate", __dir__)
    unless File.directory?(runtime)
      refute ENV.key?("FLEET_RENOVATE_VALIDATOR"), "configured Renovate runtime must be installed"
      skip "install the locked validator dependencies"
    end
    output, status = Open3.capture2e("node", File.expand_path("renovate_ruby_updates.mjs", __dir__))
    assert status.success?, output
  end
end
