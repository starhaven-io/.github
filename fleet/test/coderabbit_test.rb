# frozen_string_literal: true

require "minitest/autorun"
require "open3"

class CodeRabbitTest < Minitest::Test
  def test_automatic_approval_boundaries
    output, status = Open3.capture2e("node", "--experimental-vm-modules",
                                     File.join(__dir__, "coderabbit_policy.mjs"))
    assert status.success?, output
  end
end
