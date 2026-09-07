# frozen_string_literal: true

require "minitest/autorun"
require "open3"

class CodecovUploadTest < Minitest::Test
  def test_hermetic_uploader_contract
    output, status = Open3.capture2e("python3", "-I", File.expand_path("codecov_upload_test.py", __dir__))

    assert status.success?, output
  end
end
