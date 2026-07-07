# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "minitest/autorun"

ROOT = File.expand_path("../..", __dir__)
SYNC = ["ruby", "-rpathname", "fleet/sync.rb"].freeze

CommandResult = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
  def output
    [stdout, stderr].join
  end

  def success?
    status.success?
  end
end

module GuardHelpers
  module_function

  def run_command(cwd, *argv)
    stdout, stderr, status = Open3.capture3(*argv, chdir: cwd)
    CommandResult.new(stdout: stdout, stderr: stderr, status: status)
  end

  def git(repo, *args)
    result = run_command(repo, "git", *args)
    return result if result.success?

    raise "git #{args.join(" ")} failed:\n#{result.output}"
  end

  def sync(repo, *extra)
    run_command(repo, *SYNC, "--hub-root", ".", "--repo-root", ".", "--repo-name", ".github", *extra)
  end

  def guard(repo)
    sync(repo, "--guard", "HEAD~1", "--hub")
  end

  def commit_all(repo, message)
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=Fleet Guard Regression", "-c", "user.email=fleet@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-qm", message)
  end

  def copy_worktree(source, destination)
    FileUtils.mkdir_p(destination)
    Dir.children(source).each do |entry|
      next if entry == ".git"

      FileUtils.cp_r(File.join(source, entry), File.join(destination, entry), preserve: true)
    end
  end

  def converge_base_repo(repo)
    result = sync(repo)
    raise "initial fixture convergence failed:\n#{result.output}" unless result.success?

    status = git(repo, "status", "--short")
    commit_all(repo, "converge fleet fixture") unless status.stdout.empty?
  end

  def duplicate_block(repo, relative_path, marker, from, to)
    path = File.join(repo, relative_path)
    text = File.read(path)
    block = text.match(marker)&.to_s
    raise "could not find managed block in #{relative_path}" unless block

    edited = block.sub(from, to)
    File.write(path, text.sub(block, "#{block}\n\n#{edited}"))
  end

  def symlink_path_to_copy(repo, relative_path, target_relative_path)
    path = File.join(repo, relative_path)
    target = File.join(repo, target_relative_path)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.mv(path, target)
    File.symlink(target_relative_path.split("/").last, path)
  end
end

TMPDIR = Dir.mktmpdir("fleet-guard-regressions-")
Minitest.after_run { FileUtils.rm_rf(TMPDIR) }

BASE_REPO = File.join(TMPDIR, "base")
GuardHelpers.copy_worktree(ROOT, BASE_REPO)
GuardHelpers.git(BASE_REPO, "init", "-q")
GuardHelpers.git(BASE_REPO, "add", "-A")
GuardHelpers.git(BASE_REPO, "-c", "user.name=Fleet Guard Regression", "-c", "user.email=fleet@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "baseline")
GuardHelpers.git(BASE_REPO, "tag", File.read(File.join(BASE_REPO, "fleet/VERSION")).strip)
GuardHelpers.converge_base_repo(BASE_REPO)

class GuardRegressionsTest < Minitest::Test
  include GuardHelpers

  def scenario(name)
    path = File.join(TMPDIR, name)
    run_command(TMPDIR, "git", "clone", "--quiet", "--no-hardlinks", BASE_REPO, path)
    path
  end

  def assert_sync_success(result)
    assert result.success?, "expected success, got exit #{result.status.exitstatus}:\n#{result.output}"
  end

  # Every rejection mode runs and reports, so one regressed mode never hides
  # the state of the others behind a first-assertion halt.
  def assert_rejects(*cases)
    failures = cases.filter_map do |mode, result, include_text|
      if result.success?
        "#{mode}: expected failure containing #{include_text.inspect}, got success:\n#{result.output}"
      elsif !result.output.include?(include_text)
        "#{mode}: expected output to contain #{include_text.inspect}:\n#{result.output}"
      end
    end

    assert failures.empty?, failures.join("\n\n")
  end

  def test_passes_clean_check
    repo = scenario("clean-check")

    assert_sync_success(sync(repo, "--check"))
  end

  def test_allows_legitimate_unmanaged_edits
    repo = scenario("unmanaged-edit")
    File.open(File.join(repo, "SECURITY.md"), "a") { |file| file.puts("\nRegression harness unmanaged edit.") }
    commit_all(repo, "unmanaged edit")

    assert_sync_success(guard(repo))
  end

  def test_rejects_real_managed_block_edits
    repo = scenario("managed-block-edit")
    path = File.join(repo, "AGENTS.md")
    text = File.read(path)
    File.write(path, text.sub("Never commit directly to `main`", "Direct commits to `main` are allowed"))
    commit_all(repo, "managed block edit")

    assert_rejects(["guard", guard(repo), "fleet guard: managed surface change rejected"])
  end

  def test_rejects_duplicate_markdown_markers_in_every_mode
    repo = scenario("duplicate-markdown")
    duplicate_block(repo, "AGENTS.md", /^<!-- fleet:block commit-and-pr-conventions -->\n.*?^<!-- fleet:end -->/m,
                    "Never commit directly to `main`", "Direct commits to `main` are allowed")
    commit_all(repo, "duplicate markdown marker")
    message = "has 2 'commit-and-pr-conventions' fleet:block markers"

    assert_rejects(
      ["guard", guard(repo), message],
      ["--check", sync(repo, "--check"), message],
      ["sync", sync(repo), message]
    )
  end

  def test_rejects_duplicate_hash_markers_in_every_mode
    repo = scenario("duplicate-hash")
    duplicate_block(repo, "justfile", /^# fleet:block install-hooks\n.*?^# fleet:end/m,
                    "git config core.hooksPath .githooks", "git config core.hooksPath /tmp/hooks")
    commit_all(repo, "duplicate hash marker")
    message = "has 2 'install-hooks' fleet:block markers"

    assert_rejects(
      ["guard", guard(repo), message],
      ["--check", sync(repo, "--check"), message],
      ["sync", sync(repo), message]
    )
  end

  def test_rejects_symlinked_block_hosts
    repo = scenario("symlinked-block-host")
    symlink_path_to_copy(repo, "AGENTS.md", "AGENTS-target.md")
    commit_all(repo, "symlinked block host")

    assert_rejects(
      ["guard", guard(repo), "AGENTS.md is not a regular file"],
      ["--check", sync(repo, "--check"), "AGENTS.md is not a regular file"]
    )
  end

  def test_rejects_symlinked_fleet_configs
    repo = scenario("symlinked-config")
    symlink_path_to_copy(repo, ".fleet.yml", "fleet-config-target.yml")
    commit_all(repo, "symlinked config")

    assert_rejects(
      ["guard", guard(repo), ".fleet.yml is not a regular file"],
      ["--check", sync(repo, "--check"), ".fleet.yml is not a regular file"]
    )
  end

  def test_rejects_symlinked_whole_files
    repo = scenario("symlinked-whole-file")
    symlink_path_to_copy(repo, ".github/workflows/zizmor.yml", ".github/workflows/zizmor-target.yml")
    commit_all(repo, "symlinked whole file")

    assert_rejects(
      ["guard", guard(repo), "managed surface change rejected"],
      ["--check", sync(repo, "--check"), "fleet sync drift detected"]
    )
  end

  def test_rejects_directory_whole_files
    repo = scenario("directory-whole-file")
    workflow = File.join(repo, ".github/workflows/zizmor.yml")
    FileUtils.rm_f(workflow)
    FileUtils.mkdir_p(workflow)
    File.write(File.join(workflow, "payload"), "not a workflow\n")
    commit_all(repo, "directory whole file")

    assert_rejects(
      ["guard", guard(repo), "managed surface change rejected"],
      ["--check", sync(repo, "--check"), "fleet sync drift detected"]
    )
  end

  def test_rejects_broken_symlink_whole_files
    repo = scenario("broken-symlink-whole-file")
    workflow = File.join(repo, ".github/workflows/zizmor.yml")
    FileUtils.rm_f(workflow)
    File.symlink("missing-zizmor.yml", workflow)
    commit_all(repo, "broken symlink whole file")

    assert_rejects(
      ["guard", guard(repo), "managed surface change rejected"],
      ["--check", sync(repo, "--check"), "fleet sync drift detected"]
    )
  end
end
