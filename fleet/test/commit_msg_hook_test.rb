# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tempfile"
require "tmpdir"

HOOK = File.expand_path("../files/commit-msg", __dir__)

class CommitMsgHookTest < Minitest::Test
  HookResult = Data.define(:stdout, :stderr, :status) do
    def success?
      status.success?
    end
  end

  def test_accepts_human_coauthor
    result = run_hook(<<~MESSAGE)
      feat: add a feature

      Co-authored-by: Human Contributor <human@example.com>
      Signed-off-by: Accountable Contributor <accountable@example.com>
    MESSAGE

    assert result.success?, result.stderr
  end

  def test_accepts_ai_names_in_message_body
    result = run_hook(<<~MESSAGE)
      fix: document agent behavior

      Explain how Claude and Codex handle this case.

      Signed-off-by: Accountable Contributor <accountable@example.com>
    MESSAGE

    assert result.success?, result.stderr
  end

  def test_accepts_larger_words_containing_ai_names
    result = run_hook(<<~MESSAGE)
      feat: support a contributor

      Co-authored-by: Codextra Contributor <human@example.com>
      Signed-off-by: Accountable Contributor <accountable@example.com>
    MESSAGE

    assert result.success?, result.stderr
  end

  def test_rejects_claude_trailer
    result = run_hook(<<~MESSAGE)
      feat: add a feature

      Co-authored-by: Claude Opus <noreply@anthropic.com>
      Signed-off-by: Accountable Contributor <accountable@example.com>
    MESSAGE

    refute result.success?
    assert_includes result.stderr, "trailer contains a known AI identifier"
  end

  def test_rejects_codex_trailer_case_insensitively
    result = run_hook(<<~MESSAGE)
      feat: add a feature

      Generated-by: CODEX
      Signed-off-by: Accountable Contributor <accountable@example.com>
    MESSAGE

    refute result.success?
    assert_includes result.stderr, "trailer contains a known AI identifier"
  end

  def test_rejects_ai_trailer_after_divider
    result = run_hook(<<~MESSAGE)
      feat: add a feature

      Body text.

      ---

      Co-authored-by: Claude Opus <noreply@anthropic.com>
      Signed-off-by: Accountable Contributor <accountable@example.com>
    MESSAGE

    refute result.success?
    assert_includes result.stderr, "trailer contains a known AI identifier"
  end

  def test_rejects_ai_trailers_on_dco_exempt_commits
    ["fixup! feat: base", "squash! feat: base", "Merge branch 'feature'"].each do |subject|
      result = run_hook(<<~MESSAGE)
        #{subject}

        Co-authored-by: Claude Opus <noreply@anthropic.com>
      MESSAGE

      refute result.success?, subject
      assert_includes result.stderr, "trailer contains a known AI identifier"
    end
  end

  def test_preserves_dco_exempt_commits_without_ai_trailers
    ["fixup! feat: base", "squash! feat: base", "Merge branch 'feature'"].each do |subject|
      result = run_hook("#{subject}\n")

      assert result.success?, "#{subject}: #{result.stderr}"
    end
  end

  def test_accepts_git_comment_and_scissors_content
    result = run_hook(<<~MESSAGE)
      feat: add a feature

      Signed-off-by: Accountable Contributor <accountable@example.com>

      # Please enter the commit message for your changes.
      # ------------------------ >8 ------------------------
      # diff --git a/CLAUDE.md b/CLAUDE.md
      # +@AGENTS.md
    MESSAGE

    assert result.success?, result.stderr
  end

  def test_explains_human_name_false_positive
    result = run_hook(<<~MESSAGE)
      feat: add a feature

      Co-authored-by: Claude Dupont <claude.dupont@example.com>
      Signed-off-by: Accountable Contributor <accountable@example.com>
    MESSAGE

    refute result.success?
    assert_includes result.stderr, "If this identifies a human or file"
    assert_includes result.stderr, "--no-verify"
  end

  def test_rejects_when_trailer_parser_fails
    Dir.mktmpdir("git-stub") do |directory|
      git = File.join(directory, "git")
      File.write(git, "#!/bin/sh\nexit 128\n")
      File.chmod(0o755, git)
      result = run_hook(
        <<~MESSAGE,
          feat: add a feature

          Signed-off-by: Accountable Contributor <accountable@example.com>
        MESSAGE
        "PATH" => "#{directory}:#{ENV.fetch("PATH")}"
      )

      refute result.success?
      assert_includes result.stderr, "could not inspect commit trailers"
      assert_includes result.stderr, "Update Git"
      assert_includes result.stderr, "--no-verify"
    end
  end

  def test_requires_dco_signoff
    result = run_hook("feat: unsigned change\n")

    refute result.success?
    assert_includes result.stderr, "missing DCO sign-off"
  end

  private

  def run_hook(message, env = {})
    Tempfile.create("commit-message") do |file|
      file.write(message)
      file.flush
      stdout, stderr, status = Open3.capture3(env, "sh", HOOK, file.path)
      HookResult.new(stdout:, stderr:, status:)
    end
  end
end
