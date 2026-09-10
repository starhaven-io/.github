# frozen_string_literal: true

require "yaml"
require "minitest/autorun"

class PinprickPolicyTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_only_the_explicitly_managed_consumer_can_load_repository_policy
    configured = Dir.glob(File.join(ROOT, "fleet/repos/*.yml")).filter_map do |path|
      config = YAML.safe_load_file(path)
      next unless config.fetch("params", {}).fetch("pinprick-audit", {}).key?("accept-workflow-findings")

      File.basename(path, ".yml")
    end
    assert_equal ["macOSdb"], configured

    workflow = YAML.safe_load_file(File.join(ROOT, ".github/workflows/reusable-pinprick-audit.yml"))
    inputs = workflow.fetch(true).fetch("workflow_call").fetch("inputs")
    refute inputs.key?("no-repo-config")
    step = workflow.fetch("jobs").fetch("audit").fetch("steps").find { |entry| entry["name"] == "Run pinprick" }
    assert_equal "${{ github.repository != 'starhaven-io/macOSdb' }}", step.fetch("with").fetch("no-repo-config")
    assert_equal "${{ inputs.fail-on-findings }}", step.fetch("with").fetch("fail-on-findings")
  end
end
