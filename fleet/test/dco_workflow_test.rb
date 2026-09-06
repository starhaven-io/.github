# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"
require "minitest/autorun"

DCO_ROOT = File.expand_path("../..", __dir__)
DCO_WORKFLOW = File.join(DCO_ROOT, ".github/workflows/fleet-guard-required.yml")

class DcoWorkflowTest < Minitest::Test
  def setup
    workflow = YAML.safe_load_file(DCO_WORKFLOW, permitted_classes: [], aliases: false)
    @steps = workflow.fetch("jobs").fetch("dco").fetch("steps")
    @script = @steps.find { |step| step["name"] == "Check DCO sign-offs" }.fetch("run")
  end

  def test_matching_author_signoff_passes
    repo, base = repository
    head = commit(repo, "feat: signed contribution", signoff: true)

    _output, status = check(repo, base, head)
    assert status.success?
  end

  def test_unsigned_commit_fails_with_its_sha
    repo, base = repository
    head = commit(repo, "feat: unsigned contribution")

    output, status = check(repo, base, head)
    refute status.success?
    assert_includes output, "Commit #{head} lacks a Signed-off-by trailer matching its author"
  end

  def test_mismatched_signoff_fails
    repo, base = repository
    head = commit(repo, "feat: mismatched contribution",
                  trailer: "Signed-off-by: Someone Else <else@example.invalid>")

    output, status = check(repo, base, head)
    refute status.success?
    assert_includes output, "Commit #{head} lacks a Signed-off-by trailer matching its author"
  end

  def test_unsigned_merge_commit_is_exempt
    repo, base = repository
    git(repo, "switch", "-qc", "topic")
    commit(repo, "feat: signed topic", signoff: true, path: "topic")
    git(repo, "switch", "-q", "main")
    commit(repo, "feat: signed main", signoff: true, path: "main")
    git(repo, "merge", "-q", "--no-ff", "topic", "-m", "Merge topic")
    head = git(repo, "rev-parse", "HEAD").strip

    _output, status = check(repo, base, head)
    assert status.success?
  end

  def test_trusted_automation_exemption_is_narrow
    exemption = @steps.find { |step| step["name"] == "Check actor exemption" }.fetch("run")
    assert_includes exemption, '"starhaven-bot[bot]"'
    assert_includes exemption, '"dependabot[bot]"'

    guarded_steps = @steps.select { |step| ["Checkout contribution", "Check DCO sign-offs"].include?(step["name"]) }
    assert_equal 2, guarded_steps.length
    guarded_steps.each do |step|
      assert_equal "steps.exemption.outputs.exempt != 'true'", step.fetch("if")
    end
  end

  private

  def repository
    repo = Dir.mktmpdir("dco-workflow-")
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.name", "DCO Contributor")
    git(repo, "config", "user.email", "contributor@example.invalid")
    File.write(File.join(repo, "baseline"), "baseline\n")
    git(repo, "add", "baseline")
    git(repo, "commit", "-qm", "chore: unsigned baseline")
    [repo, git(repo, "rev-parse", "HEAD").strip]
  end

  def commit(repo, message, signoff: false, trailer: nil, path: "change")
    File.write(File.join(repo, path), "#{message}\n")
    git(repo, "add", path)
    args = ["commit", "-q"]
    args << "-s" if signoff
    args.push("-m", message)
    args.push("-m", trailer) if trailer
    git(repo, *args)
    git(repo, "rev-parse", "HEAD").strip
  end

  def check(repo, base, head)
    stdout, stderr, status = Open3.capture3(
      { "BASE_SHA" => base, "HEAD_SHA" => head },
      "bash", "-euo", "pipefail", "-c", @script,
      chdir: repo
    )
    [[stdout, stderr].join, status]
  end

  def git(repo, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: repo)
    raise "git #{args.join(" ")} failed:\n#{stdout}#{stderr}" unless status.success?

    stdout
  end
end
