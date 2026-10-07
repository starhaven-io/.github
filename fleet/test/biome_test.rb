# frozen_string_literal: true

require "minitest/autorun"
require "open3"

class BiomeTest < Minitest::Test
  def setup
    @root = File.expand_path("../..", __dir__)
    @biome = File.join(@root, "fleet/validator/node_modules/.bin/biome")
    return if File.executable?(@biome)

    refute ENV.key?("FLEET_RENOVATE_VALIDATOR"), "the locked fleet/validator install must include Biome"
    skip "install the locked fleet/validator dependencies to check fleet JavaScript with Biome"
  end

  # pkgstory lints its root with Biome, so fleet JavaScript must render in its style.
  def test_fleet_javascript_passes_consumer_biome
    files = Dir[File.expand_path("../files/*.{mjs,ts}", __dir__)]
    refute_empty files
    output, status = Open3.capture2e(@biome, "check", "--config-path", @root, *files)
    assert status.success?, output
  end

  def test_repository_root_discovers_config_for_nested_manifest
    output, status = Open3.capture2e(@biome, "check", "fleet/validator/package.json", chdir: @root)
    assert status.success?, output
  end

  def test_repository_lint_discovers_nested_configs
    output, status = Open3.capture2e(@biome, "lint", ".", chdir: @root)
    assert status.success?, output
  end
end
