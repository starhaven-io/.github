# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class PrePushHookTest < Minitest::Test
  HOOK = File.expand_path("../files/pre-push", __dir__)
  ZERO_SHA = "0" * 40
  FAKE_JUST = <<~SCRIPT
    #!/bin/sh
    [ "$1" = check ] || exit 64
    printf 'check\\n' >> "$HOOK_TEST_MARKER"
  SCRIPT

  HookResult = Data.define(:stdout, :stderr, :status) do
    def success?
      status.success?
    end
  end

  def setup
    @sandbox = Dir.mktmpdir("pre-push-hook-")
    @repo = File.join(@sandbox, "repo")
    @bin = File.join(@sandbox, "bin")
    @marker = File.join(@sandbox, "just-ran")
    FileUtils.mkdir_p([@repo, @bin])
    File.write(File.join(@bin, "just"), FAKE_JUST)
    File.chmod(0o755, File.join(@bin, "just"))

    git("init", "-q")
    write_tracked("one\n")
    git("add", "tracked.txt")
    git("commit", "-qm", "initial")
    @first = git("rev-parse", "HEAD").strip
    git("tag", "-a", "v1", "-m", "v1", @first)
    git("tag", "lightweight", @first)
  end

  def teardown
    FileUtils.rm_rf(@sandbox)
  end

  def test_skips_checks_for_tag_only_pushes
    result = run_hook(tag_lines)

    assert result.success?, result.stderr
    refute File.exist?(@marker)
  end

  def test_checks_a_clean_head_branch_push_once
    result = run_hook(branch_line(@first))

    assert result.success?, result.stderr
    assert_equal "check\n", File.read(@marker)
  end

  def test_checks_once_when_auxiliary_tags_accompany_a_branch
    second = commit_second

    result = run_hook(branch_line(second) + tag_lines)

    assert result.success?, result.stderr
    assert_equal "check\n", File.read(@marker)
  end

  def test_rejects_a_branch_push_from_a_dirty_worktree
    write_tracked("dirty\n")

    result = run_hook(branch_line(@first))

    refute result.success?
    assert_includes result.stderr, "tracked or untracked changes"
    refute File.exist?(@marker)
  end

  def test_rejects_a_branch_push_with_untracked_files
    File.write(File.join(@repo, "untracked.txt"), "new\n")

    result = run_hook(branch_line(@first))

    refute result.success?
    assert_includes result.stderr, "tracked or untracked changes"
    refute File.exist?(@marker)
  end

  def test_rejects_a_branch_that_is_not_the_checked_out_head
    commit_second

    result = run_hook(branch_line(@first))

    refute result.success?
    assert_includes result.stderr, "does not point to the checked HEAD commit"
    refute File.exist?(@marker)
  end

  def test_rejects_a_ref_that_does_not_resolve_to_a_commit
    blob = git("rev-parse", "HEAD:tracked.txt").strip

    result = run_hook("refs/heads/main #{blob} refs/heads/main #{ZERO_SHA}\n")

    refute result.success?
    assert_includes result.stderr, "does not resolve to a commit"
    refute File.exist?(@marker)
  end

  def test_skips_checks_for_deletion_only_pushes
    File.write(File.join(@repo, "untracked.txt"), "still dirty\n")

    result = run_hook("refs/heads/main #{ZERO_SHA} refs/heads/main #{@first}\n")

    assert result.success?, result.stderr
    refute File.exist?(@marker)
  end

  def test_requires_just_for_branch_pushes
    result = run_hook(branch_line(@first), "PATH" => "/usr/bin:/bin")

    assert_equal 127, result.status.exitstatus
    assert_includes result.stderr, "'just' is required"
  end

  private

  def git_env(overrides = {})
    {
      "GIT_COMMON_DIR" => nil,
      "GIT_DIR" => nil,
      "GIT_INDEX_FILE" => nil,
      "GIT_OBJECT_DIRECTORY" => nil,
      "GIT_PREFIX" => nil,
      "GIT_WORK_TREE" => nil,
      "GIT_CONFIG_GLOBAL" => File::NULL,
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_AUTHOR_NAME" => "Fleet Hook Test",
      "GIT_AUTHOR_EMAIL" => "hooks@example.invalid",
      "GIT_COMMITTER_NAME" => "Fleet Hook Test",
      "GIT_COMMITTER_EMAIL" => "hooks@example.invalid",
      "HOOK_TEST_MARKER" => @marker,
      "PATH" => "#{@bin}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}"
    }.merge(overrides)
  end

  def git(*args)
    stdout, stderr, status = Open3.capture3(git_env, "git", *args, chdir: @repo)
    raise "git #{args.join(" ")} failed:\n#{stdout}#{stderr}" unless status.success?

    stdout
  end

  def write_tracked(content)
    File.write(File.join(@repo, "tracked.txt"), content)
  end

  def commit_second
    write_tracked("two\n")
    git("add", "tracked.txt")
    git("commit", "-qm", "second")
    git("rev-parse", "HEAD").strip
  end

  def branch_line(sha)
    "refs/heads/main #{sha} refs/heads/main #{ZERO_SHA}\n"
  end

  def tag_lines
    annotated = git("rev-parse", "refs/tags/v1").strip
    lightweight = git("rev-parse", "refs/tags/lightweight").strip
    "refs/tags/v1 #{annotated} refs/tags/v1 #{ZERO_SHA}\n" \
      "refs/tags/lightweight #{lightweight} refs/tags/lightweight #{ZERO_SHA}\n"
  end

  def run_hook(input, env = {})
    stdout, stderr, status = Open3.capture3(git_env(env), "sh", HOOK, stdin_data: input, chdir: @repo)
    HookResult.new(stdout:, stderr:, status:)
  end
end
