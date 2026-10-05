# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

class ReusableGuardWorkflowTest < Minitest::Test
  def test_only_same_repository_sync_deliveries_and_dependabot_are_exempt
    path = File.expand_path("../../.github/workflows/reusable-fleet-guard.yml", __dir__)
    step = YAML.safe_load_file(path, aliases: false).fetch("jobs").fetch("guard").fetch("steps").first
    assert_equal "${{ github.event.pull_request.user.login }}", step.fetch("env").fetch("AUTHOR")
    assert_equal "${{ github.event.pull_request.head.ref }}", step.fetch("env").fetch("HEAD_REF")
    assert_equal "${{ github.event.pull_request.head.repo.full_name }}", step.fetch("env").fetch("HEAD_REPOSITORY")
    assert_equal "${{ github.triggering_actor }}", step.fetch("env").fetch("TRIGGERING_ACTOR")
    bot = "starhaven-bot[bot]"
    consumer = "starhaven-io/midden"
    hub = "starhaven-io/.github"
    branch = "fleet-sync-v2026.10.03.2"
    [
      [bot, branch, consumer, "maintainer", "maintainer", consumer, true],
      [bot, "feature", consumer, bot, bot, consumer, false],
      [bot, branch, "fork/midden", bot, bot, consumer, false],
      ["maintainer", branch, consumer, bot, bot, consumer, false],
      ["dependabot[bot]", "dependabot/ruby", consumer, "dependabot[bot]", "dependabot[bot]", consumer, true],
      [bot, branch, hub, bot, bot, hub, true],
      [bot, branch, hub, "maintainer", bot, hub, false],
      [bot, branch, hub, bot, "maintainer", hub, false]
    ].each do |author, head_ref, repository, actor, triggering_actor, caller, exempt|
      Dir.mktmpdir do |directory|
        output = File.join(directory, "output")
        _stdout, stderr, status = Open3.capture3(
          { "AUTHOR" => author, "HEAD_REF" => head_ref, "HEAD_REPOSITORY" => repository,
            "ACTOR" => actor, "TRIGGERING_ACTOR" => triggering_actor, "GITHUB_REPOSITORY" => caller,
            "GITHUB_OUTPUT" => output },
          "bash", "-euo", "pipefail", "-c", step.fetch("run")
        )
        assert status.success?, stderr
        assert_equal "exempt=#{exempt}\n", File.read(output)
      end
    end
  end
end
