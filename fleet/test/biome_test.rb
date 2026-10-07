# frozen_string_literal: true

require "minitest/autorun"
require "open3"

class BiomeTest < Minitest::Test
  # pkgstory lints its root with Biome, so fleet JavaScript must render in its style.
  def test_fleet_javascript_passes_consumer_biome
    biome = File.expand_path("../validator/node_modules/.bin/biome", __dir__)
    unless File.executable?(biome)
      refute ENV.key?("FLEET_RENOVATE_VALIDATOR"), "the locked fleet/validator install must include Biome"
      skip "install the locked fleet/validator dependencies to check fleet JavaScript with Biome"
    end

    files = Dir[File.expand_path("../files/*.{mjs,ts}", __dir__)]
    refute_empty files
    output, status = Open3.capture2e(biome, "check", "--config-path", File.expand_path("../validator", __dir__),
                                     *files)
    assert status.success?, output
  end
end
