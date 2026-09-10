# frozen_string_literal: true

require "json"
require "minitest/autorun"

class ValeUpdateTest < Minitest::Test
  def test_legacy_and_literal_downloads_have_exactly_one_update_owner
    preset = JSON.parse(File.read(File.expand_path("../../renovate-config.json", __dir__)))
    managers = preset.fetch("customManagers").select { |manager| manager["packageNameTemplate"] == "vale-cli/vale" }
    digest = "a" * 64
    legacy = <<~YAML
      VALE_SHA256: "#{digest}"
      VALE_VERSION: "3.19.0"
      run: |
        curl "https://github.com/vale-cli/vale/releases/download/v${VALE_VERSION}/${archive}"
    YAML
    literal = <<~YAML
      VALE_SHA256: "#{digest}"
      run: |
        archive="${RUNNER_TEMP}/vale.tar.gz"
        curl --output "${archive}" \\
          "https://github.com/vale-cli/vale/releases/download/v3.19.0/vale_3.19.0_Linux_64-bit.tar.gz"
    YAML
    [legacy, literal].each do |source|
      matches = managers.flat_map do |manager|
        manager.fetch("matchStrings").filter_map { |pattern| Regexp.new(pattern).match(source) }
      end
      assert_equal 1, matches.length
      assert_equal digest, matches.first["currentDigest"]
    end
    literal_manager = managers.find { |manager| manager.fetch("description").start_with?("Update literal") }
    match = Regexp.new(literal_manager.fetch("matchStrings").first).match(literal)
    assert_equal "v3.19.0", match["currentValue"]
    assert_includes literal_manager.fetch("autoReplaceStringTemplate"),
                    "{{{newValue}}}/vale_{{{replace '^v' '' newValue}}}"
    assert_includes literal_manager.fetch("autoReplaceStringTemplate"), "{{{newDigest}}}"
  end
end
