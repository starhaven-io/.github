# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"
require "minitest/autorun"

module FleetSyncWorkflowHelpers
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW = File.join(ROOT, ".github/workflows/fleet-sync.yml")
  TMPDIR = Dir.mktmpdir("fleet-sync-workflow-")

  CommandResult = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
    def output
      [stdout, stderr].join
    end

    def success?
      status.success?
    end
  end

  module_function

  def git(repo, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: repo)
    raise "git #{args.join(" ")} failed:\n#{stdout}#{stderr}" unless status.success?

    stdout
  end

  def committed_repo(path, mode: 0o644)
    repo = Dir.mktmpdir("consumer-", TMPDIR)
    absolute = File.join(repo, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(mode, absolute)
    git(repo, "init", "-q")
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=Fleet Sync Test", "-c", "user.email=fleet@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-qm", "baseline")
    repo
  end
end

Minitest.after_run { FileUtils.rm_rf(FleetSyncWorkflowHelpers::TMPDIR) }

class FleetSyncWorkflowTest < Minitest::Test
  include FleetSyncWorkflowHelpers

  def setup
    workflow = YAML.safe_load_file(WORKFLOW, permitted_classes: [], aliases: false)
    @steps = workflow.fetch("jobs").fetch("sync").fetch("steps")
  end

  def test_rejects_tracked_mode_only_drift
    repo = committed_repo(".githooks/commit-msg")
    FileUtils.chmod(0o755, File.join(repo, ".githooks/commit-msg"))

    result = run_publishability_check(repo, ".githooks/commit-msg")

    refute result.success?, result.output
    assert_includes result.output, "cannot publish mode 100644 -> 100755"
  end

  def test_rejects_new_executable_file
    repo = committed_repo("README.md")
    hook = File.join(repo, ".githooks/pre-push")
    FileUtils.mkdir_p(File.dirname(hook))
    File.write(hook, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, hook)

    result = run_publishability_check(repo, ".githooks/pre-push")

    refute result.success?, result.output
    assert_includes result.output, "cannot publish a new 100755 entry"
  end

  def test_accepts_content_drift_with_stable_executable_mode
    repo = committed_repo(".githooks/commit-msg", mode: 0o755)
    File.write(File.join(repo, ".githooks/commit-msg"), "#!/bin/sh\nexit 1\n")

    result = run_publishability_check(repo, ".githooks/commit-msg")

    assert result.success?, result.output
  end

  def test_gate_precedes_write_token_and_publication
    names = @steps.map { |step| step["name"] }
    gate = names.index("Require publishable file modes")

    assert_operator gate, :<, names.index("Mint write token")
    assert_operator gate, :<, names.index("Create verified sync commit and open PR")
    assert_equal "steps.drift.outputs.changed == 'true'", @steps.fetch(gate).fetch("if")
  end

  def test_treats_changed_paths_as_literals
    repo = committed_repo("a1.yml", mode: 0o755)
    literal = File.join(repo, "a[1].yml")
    File.write(literal, "literal\n")
    FileUtils.chmod(0o644, literal)
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=Fleet Sync Test", "-c", "user.email=fleet@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-qm", "add literal path")
    FileUtils.chmod(0o755, literal)

    result = run_publishability_check(repo, "a[1].yml")

    refute result.success?, result.output
    assert_includes result.output, "cannot publish mode 100644 -> 100755"
  end

  def test_rejects_symlinks
    repo = committed_repo("target")
    link = File.join(repo, "managed-link")
    File.symlink("target", link)
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=Fleet Sync Test", "-c", "user.email=fleet@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-qm", "add symlink")

    result = run_publishability_check(repo, "managed-link")

    refute result.success?, result.output
    assert_includes result.output, "cannot publish a symlink"
  end

  private

  def run_publishability_check(repo, path)
    File.write(File.join(File.dirname(repo), "changed-files.txt"), "#{path}\n")
    stdout, stderr, status = Open3.capture3(
      "bash", "-euo", "pipefail", "-c", publishability_script,
      chdir: repo
    )
    FleetSyncWorkflowHelpers::CommandResult.new(stdout: stdout, stderr: stderr, status: status)
  end

  def publishability_script
    @steps.find { |step| step["name"] == "Require publishable file modes" }.fetch("run")
  end
end
