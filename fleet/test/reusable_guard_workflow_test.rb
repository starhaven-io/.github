# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"
require_relative "isolated_git_env"

class ReusableGuardWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../../.github/workflows/reusable-fleet-guard.yml", __dir__)
  CALLER = ".github/workflows/fleet-guard.yml"
  RELEASED = "1" * 40
  SYNCED = "2" * 40
  IDENTITY = ["-c", "user.name=Reusable Guard Test", "-c", "user.email=guard@example.invalid",
              "-c", "commit.gpgsign=false"].freeze

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

  def test_pin_and_guard_compare_against_the_merged_base
    resolve = step("Resolve the merged base")
    assert_equal "steps.exemption.outputs.exempt != 'true'", resolve.fetch("if")
    assert_equal({ "HEAD_SHA" => "${{ github.event.pull_request.head.sha }}" }, resolve.fetch("env"))
    ["Read the caller pin", "Guard fleet-managed surfaces"].each do |name|
      assert_equal "${{ steps.base.outputs.sha }}", step(name).fetch("env").fetch("BASE_SHA")
    end
    refute_includes File.read(WORKFLOW), "github.event.pull_request.base.sha"
  end

  def test_accepts_an_up_to_date_pull_request_that_keeps_the_pin
    consumer do |repo|
      head = merge_pull_request(repo, "main") { File.write(File.join(repo, "README.md"), "Edit.\n") }

      success, output, pin = read_caller_pin(repo, head)
      assert success, output
      assert_equal RELEASED, pin
    end
  end

  def test_accepts_a_stale_pull_request_after_the_base_moved_the_pin
    consumer do |repo|
      branched = git(repo, "rev-parse", "HEAD")
      write_pin(repo, SYNCED)
      commit_all(repo, "chore(fleet): sync managed surfaces")
      head = merge_pull_request(repo, branched) { File.write(File.join(repo, "README.md"), "Edit.\n") }

      success, output, base = resolve_base(repo, head)
      assert success, output
      assert_equal git(repo, "rev-parse", "main"), base
      success, output, pin = read_caller_pin(repo, head)
      assert success, output
      assert_equal SYNCED, pin
    end
  end

  def test_rejects_a_pull_request_that_changes_the_pin
    consumer do |repo|
      head = merge_pull_request(repo, "main") { write_pin(repo, SYNCED) }

      success, output, = read_caller_pin(repo, head)
      refute success, output
      assert_includes output, "fleet-guard pin changes land through a hub release, not a consumer PR"
    end
  end

  def test_requires_the_pull_request_merge_commit_checkout
    consumer do |repo|
      head = merge_pull_request(repo, "main") { File.write(File.join(repo, "README.md"), "Edit.\n") }
      merge = git(repo, "rev-parse", "HEAD")
      octopus = octopus_merge(repo, head)
      [["", merge], ["0" * 40, merge], [head, head], [head, octopus]].each do |head_sha, checkout|
        git(repo, "switch", "-q", "--detach", checkout)
        success, output, = resolve_base(repo, head_sha)
        refute success, "#{checkout} with head #{head_sha.inspect} must fail closed:\n#{output}"
        assert_includes output, "fleet guard requires the pull request merge commit checkout"
      end
    end
  end

  private

  def step(name)
    YAML.safe_load_file(WORKFLOW, aliases: false).fetch("jobs").fetch("guard").fetch("steps")
        .find { |candidate| candidate["name"] == name } || flunk("missing step #{name}")
  end

  def git(repo, *args)
    stdout, stderr, status = Open3.capture3(ISOLATED_GIT_ENV, "git", *args, chdir: repo)
    raise "git #{args.join(" ")} failed:\n#{stdout}#{stderr}" unless status.success?

    stdout.strip
  end

  def commit_all(repo, message)
    git(repo, "add", "-A")
    git(repo, *IDENTITY, "commit", "-qm", message)
  end

  def write_pin(repo, ref)
    File.write(File.join(repo, CALLER), <<~YAML)
      jobs:
        guard:
          uses: starhaven-io/.github/.github/workflows/reusable-fleet-guard.yml@#{ref} # v2026.10.22.2
    YAML
  end

  def consumer
    Dir.mktmpdir("reusable-guard-") do |repo|
      git(repo, "init", "-q", "-b", "main")
      FileUtils.mkdir_p(File.join(repo, File.dirname(CALLER)))
      write_pin(repo, RELEASED)
      commit_all(repo, "baseline")
      yield repo
    end
  end

  # GitHub checks out a merge commit whose first parent is the base tip and
  # whose second parent is the pull request head.
  def merge_pull_request(repo, branched)
    git(repo, "switch", "-q", "-c", "pull-request", branched)
    yield
    commit_all(repo, "pull request")
    head = git(repo, "rev-parse", "HEAD")
    git(repo, "switch", "-q", "--detach", "main")
    git(repo, *IDENTITY, "merge", "-q", "--no-ff", "-m", "Merge #{head} into main", head)
    head
  end

  def octopus_merge(repo, head)
    git(repo, "switch", "-q", "-c", "side", "main")
    File.write(File.join(repo, "side.md"), "Side.\n")
    commit_all(repo, "side")
    git(repo, "switch", "-q", "--detach", "main")
    git(repo, *IDENTITY, "merge", "-q", "--no-ff", "-m", "Octopus", head, "side")
    git(repo, "rev-parse", "HEAD")
  end

  def run_step(repo, name, env)
    output = File.join(repo, ".git", "github-output")
    File.write(output, "")
    stdout, stderr, status = Open3.capture3(
      ISOLATED_GIT_ENV.merge(env, "GITHUB_OUTPUT" => output),
      "bash", "-euo", "pipefail", "-c", step(name).fetch("run"),
      chdir: repo
    )
    [status.success?, stdout + stderr, File.readlines(output, chomp: true).to_h { |line| line.split("=", 2) }]
  end

  def resolve_base(repo, head_sha)
    success, output, outputs = run_step(repo, "Resolve the merged base", "HEAD_SHA" => head_sha)
    [success, output, outputs["sha"]]
  end

  def read_caller_pin(repo, head_sha)
    success, output, base = resolve_base(repo, head_sha)
    return [success, output, nil] unless success

    success, output, outputs = run_step(repo, "Read the caller pin", "BASE_SHA" => base)
    [success, output, outputs["ref"]]
  end
end
