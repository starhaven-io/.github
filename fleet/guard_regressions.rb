#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
SYNC = ["ruby", "-rpathname", "fleet/sync.rb"].freeze

Result = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
  def output
    [stdout, stderr].join
  end

  def success?
    status.success?
  end
end

class GuardRegressionSuite
  def initialize
    @tmpdir = Dir.mktmpdir("fleet-guard-regressions-")
    @base_repo = File.join(@tmpdir, "base")
    @failures = []
  end

  def run
    prepare_base_repo

    test_clean_check
    test_legit_unmanaged_edit_passes
    test_real_managed_block_edit_fails
    test_duplicate_markdown_markers_fail_all_modes
    test_duplicate_hash_markers_fail_all_modes
    test_symlinked_block_host_fails
    test_symlinked_config_fails
    test_symlinked_whole_file_fails
    test_directory_whole_file_fails
    test_broken_symlink_whole_file_fails

    report
  ensure
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  private

  def prepare_base_repo
    copy_worktree(ROOT, @base_repo)
    git(@base_repo, "init", "-q")
    git(@base_repo, "add", "-A")
    git(@base_repo, "-c", "user.name=Fleet Guard Regression", "-c", "user.email=fleet@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-qm", "baseline")
    git(@base_repo, "tag", File.read(File.join(@base_repo, "fleet/VERSION")).strip)
    converge_base_repo
  end

  def copy_worktree(source, destination)
    FileUtils.mkdir_p(destination)
    Dir.children(source).each do |entry|
      next if entry == ".git"

      FileUtils.cp_r(File.join(source, entry), File.join(destination, entry), preserve: true)
    end
  end

  def scenario(name)
    path = File.join(@tmpdir, name)
    run_command(@tmpdir, "git", "clone", "--quiet", "--no-hardlinks", @base_repo, path)
    path
  end

  def git(repo, *args)
    result = run_command(repo, "git", *args)
    return result if result.success?

    raise "git #{args.join(" ")} failed:\n#{result.output}"
  end

  def commit_all(repo, message)
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=Fleet Guard Regression", "-c", "user.email=fleet@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-qm", message)
  end

  def converge_base_repo
    result = sync(@base_repo)
    raise "initial fixture convergence failed:\n#{result.output}" unless result.success?

    status = git(@base_repo, "status", "--short")
    commit_all(@base_repo, "converge fleet fixture") unless status.stdout.empty?
  end

  def run_command(cwd, *argv)
    stdout, stderr, status = Open3.capture3(*argv, chdir: cwd)
    Result.new(stdout: stdout, stderr: stderr, status: status)
  end

  def sync(repo, *)
    run_command(repo, *SYNC, "--hub-root", ".", "--repo-root", ".", "--repo-name", ".github", *)
  end

  def guard(repo)
    sync(repo, "--guard", "HEAD~1", "--hub")
  end

  def assert_success(name, result)
    if result.success?
      puts "ok - #{name}"
    else
      fail_test(name, "expected success, got exit #{result.status.exitstatus}:\n#{result.output}")
    end
  end

  def assert_failure(name, result, include_text)
    unless result.success?
      if result.output.include?(include_text)
        puts "ok - #{name}"
      else
        fail_test(name, "expected failure containing #{include_text.inspect}, got:\n#{result.output}")
      end
      return
    end

    fail_test(name, "expected failure containing #{include_text.inspect}, got success")
  end

  def fail_test(name, message)
    warn "not ok - #{name}"
    warn message
    @failures << name
  end

  def report
    return if @failures.empty?

    warn "\n#{@failures.length} guard regression(s) failed:"
    @failures.each { |name| warn "  - #{name}" }
    exit 1
  end

  def test_clean_check
    repo = scenario("clean-check")
    assert_success("clean --check", sync(repo, "--check"))
  end

  def test_legit_unmanaged_edit_passes
    repo = scenario("unmanaged-edit")
    File.open(File.join(repo, "SECURITY.md"), "a") { |file| file.puts("\nRegression harness unmanaged edit.") }
    commit_all(repo, "unmanaged edit")

    assert_success("unmanaged edit passes guard", guard(repo))
  end

  def test_real_managed_block_edit_fails
    repo = scenario("managed-block-edit")
    path = File.join(repo, "AGENTS.md")
    text = File.read(path)
    File.write(path, text.sub("Never commit directly to `main`", "Direct commits to `main` are allowed"))
    commit_all(repo, "managed block edit")

    assert_failure("managed block edit fails guard", guard(repo), "fleet guard: managed surface change rejected")
  end

  def test_duplicate_markdown_markers_fail_all_modes
    repo = scenario("duplicate-markdown")
    duplicate_block(repo, "AGENTS.md", /^<!-- fleet:block commit-and-pr-conventions -->\n.*?^<!-- fleet:end -->/m,
                    "Never commit directly to `main`", "Direct commits to `main` are allowed")
    commit_all(repo, "duplicate markdown marker")

    assert_failure("duplicate markdown marker fails guard", guard(repo),
                   "has 2 'commit-and-pr-conventions' fleet:block markers")
    assert_failure("duplicate markdown marker fails --check", sync(repo, "--check"),
                   "has 2 'commit-and-pr-conventions' fleet:block markers")
    assert_failure("duplicate markdown marker fails sync", sync(repo),
                   "has 2 'commit-and-pr-conventions' fleet:block markers")
  end

  def test_duplicate_hash_markers_fail_all_modes
    repo = scenario("duplicate-hash")
    duplicate_block(repo, "justfile", /^# fleet:block install-hooks\n.*?^# fleet:end/m,
                    "git config core.hooksPath .githooks", "git config core.hooksPath /tmp/hooks")
    commit_all(repo, "duplicate hash marker")

    assert_failure("duplicate hash marker fails guard", guard(repo), "has 2 'install-hooks' fleet:block markers")
    assert_failure("duplicate hash marker fails --check", sync(repo, "--check"),
                   "has 2 'install-hooks' fleet:block markers")
    assert_failure("duplicate hash marker fails sync", sync(repo), "has 2 'install-hooks' fleet:block markers")
  end

  def test_symlinked_block_host_fails
    repo = scenario("symlinked-block-host")
    symlink_path_to_copy(repo, "AGENTS.md", "AGENTS-target.md")
    commit_all(repo, "symlinked block host")

    assert_failure("symlinked block host fails guard", guard(repo), "AGENTS.md is not a regular file")
    assert_failure("symlinked block host fails --check", sync(repo, "--check"), "AGENTS.md is not a regular file")
  end

  def test_symlinked_config_fails
    repo = scenario("symlinked-config")
    symlink_path_to_copy(repo, ".fleet.yml", "fleet-config-target.yml")
    commit_all(repo, "symlinked config")

    assert_failure("symlinked .fleet.yml fails guard", guard(repo), ".fleet.yml is not a regular file")
    assert_failure("symlinked .fleet.yml fails --check", sync(repo, "--check"), ".fleet.yml is not a regular file")
  end

  def test_symlinked_whole_file_fails
    repo = scenario("symlinked-whole-file")
    symlink_path_to_copy(repo, ".github/workflows/zizmor.yml", ".github/workflows/zizmor-target.yml")
    commit_all(repo, "symlinked whole file")

    assert_failure("symlinked whole file fails guard", guard(repo), "managed surface change rejected")
    assert_failure("symlinked whole file fails --check", sync(repo, "--check"), "fleet sync drift detected")
  end

  def test_directory_whole_file_fails
    repo = scenario("directory-whole-file")
    workflow = File.join(repo, ".github/workflows/zizmor.yml")
    FileUtils.rm_f(workflow)
    FileUtils.mkdir_p(workflow)
    File.write(File.join(workflow, "payload"), "not a workflow\n")
    commit_all(repo, "directory whole file")

    assert_failure("directory whole file fails guard", guard(repo), "managed surface change rejected")
    assert_failure("directory whole file fails --check", sync(repo, "--check"), "fleet sync drift detected")
  end

  def test_broken_symlink_whole_file_fails
    repo = scenario("broken-symlink-whole-file")
    workflow = File.join(repo, ".github/workflows/zizmor.yml")
    FileUtils.rm_f(workflow)
    File.symlink("missing-zizmor.yml", workflow)
    commit_all(repo, "broken symlink whole file")

    assert_failure("broken symlink whole file fails guard", guard(repo), "managed surface change rejected")
    assert_failure("broken symlink whole file fails --check", sync(repo, "--check"), "fleet sync drift detected")
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

GuardRegressionSuite.new.run
