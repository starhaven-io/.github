# frozen_string_literal: true

require "json"
require "yaml"
require "minitest/autorun"

class PinprickPolicyTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_only_the_explicitly_managed_consumers_can_load_repository_policy
    configured = Dir.glob(File.join(ROOT, "fleet/repos/*.yml")).filter_map do |path|
      policy = YAML.safe_load_file(path).fetch("params", {}).fetch("pinprick-audit", {})
      next unless policy.key?("accept-workflow-findings") || policy.key?("accept-action-findings")

      "starhaven-io/#{File.basename(path, ".yml")}"
    end
    assert_equal %w[starhaven-io/Brewy starhaven-io/homebrew-tap starhaven-io/macOSdb starhaven-io/pkgstory], configured

    workflow = YAML.safe_load_file(File.join(ROOT, ".github/workflows/reusable-pinprick-audit.yml"))
    inputs = workflow.fetch(true).fetch("workflow_call").fetch("inputs")
    refute inputs.key?("no-repo-config")
    step = workflow.fetch("jobs").fetch("audit").fetch("steps").find { |entry| entry["name"] == "Run pinprick" }
    assert_equal "${{ !contains(fromJSON('#{JSON.generate(configured)}'), github.repository) }}",
                 step.fetch("with").fetch("no-repo-config")
    assert_equal "${{ inputs.fail-on-findings }}", step.fetch("with").fetch("fail-on-findings")
  end
end
