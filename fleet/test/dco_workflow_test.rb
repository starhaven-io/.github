# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"
require "minitest/autorun"

DCO_ROOT = File.expand_path("../..", __dir__)
DCO_WORKFLOW = File.join(DCO_ROOT, ".github/workflows/dco-required.yml")

class DcoWorkflowTest < Minitest::Test
  def setup
    workflow = YAML.safe_load_file(DCO_WORKFLOW, permitted_classes: [], aliases: false)
    @steps = workflow.fetch("jobs").fetch("dco").fetch("steps")
    @script = @steps.find { |step| step["name"] == "Check DCO sign-offs" }.fetch("run")
  end

  def test_matching_author_signoff_passes
    repo, = repository
    head = commit(repo, "feat: signed contribution", signoff: true)

    _output, status = check(repo, "main", head)
    assert status.success?
  end

  def test_unsigned_commit_fails_with_its_sha
    repo, = repository
    head = commit(repo, "feat: unsigned contribution")

    output, status = check(repo, "main", head)
    refute status.success?
    assert_includes output, "Commit #{head} lacks an accepted Signed-off-by trailer"
  end

  def test_mismatched_signoff_fails
    repo, = repository
    head = commit(repo, "feat: mismatched contribution",
                  trailer: "Signed-off-by: Someone Else <else@example.invalid>")

    output, status = check(repo, "main", head)
    refute status.success?
    assert_includes output, "Commit #{head} lacks an accepted Signed-off-by trailer"
  end

  def test_dependabot_support_signoff_passes_under_a_human_trigger
    repo, = repository
    head = commit(
      repo,
      "chore(deps): bump dependency",
      author_name: "dependabot[bot]",
      author_email: "49699333+dependabot[bot]@users.noreply.github.com",
      trailer: "Signed-off-by: dependabot[bot] <support@github.com>"
    )

    _output, status = check(
      repo,
      "main",
      head,
      actor: "human-maintainer",
      verified_dependabot_commits: [head]
    )
    assert status.success?
  end

  def test_unverified_dependabot_identity_fails
    repo, = repository
    head = commit(
      repo,
      "chore(deps): spoof dependency bump",
      author_name: "dependabot[bot]",
      author_email: "49699333+dependabot[bot]@users.noreply.github.com",
      trailer: "Signed-off-by: dependabot[bot] <support@github.com>"
    )

    output, status = check(repo, "main", head)
    refute status.success?
    assert_includes output, "Commit #{head} lacks an accepted Signed-off-by trailer"
  end

  def test_dependabot_identity_near_match_fails
    repo, = repository
    head = commit(
      repo,
      "chore(deps): spoof dependency bump",
      author_name: "dependabot[bot]",
      author_email: "someone@example.invalid",
      trailer: "Signed-off-by: dependabot[bot] <support@github.com>"
    )

    output, status = check(repo, "main", head)
    refute status.success?
    assert_includes output, "Commit #{head} lacks an accepted Signed-off-by trailer"
  end

  def test_dependabot_commit_does_not_exempt_unsigned_human_commit
    repo, = repository
    dependabot_commit = commit(
      repo,
      "chore(deps): bump dependency",
      author_name: "dependabot[bot]",
      author_email: "49699333+dependabot[bot]@users.noreply.github.com",
      trailer: "Signed-off-by: dependabot[bot] <support@github.com>"
    )
    head = commit(repo, "fix: unsigned maintainer follow-up")

    output, status = check(
      repo,
      "main",
      head,
      actor: "dependabot[bot]",
      verified_dependabot_commits: [dependabot_commit]
    )
    refute status.success?
    assert_includes output, "Commit #{head} lacks an accepted Signed-off-by trailer"
  end

  def test_unsigned_merge_commit_is_exempt
    repo, = repository
    git(repo, "switch", "-qc", "topic")
    commit(repo, "feat: signed topic", signoff: true, path: "topic")
    git(repo, "switch", "-q", "main")
    commit(repo, "feat: signed main", signoff: true, path: "main")
    git(repo, "merge", "-q", "--no-ff", "topic", "-m", "Merge topic")
    head = git(repo, "rev-parse", "HEAD").strip

    _output, status = check(repo, "main", head)
    assert status.success?
  end

  def test_current_base_ref_excludes_commits_added_after_event_payload
    repo, stale_base = repository
    advanced_base = commit(
      repo,
      "chore: advance base",
      trailer: "Signed-off-by: Someone Else <else@example.invalid>",
      path: "advanced-base"
    )
    git(repo, "update-ref", "refs/remotes/origin/main", advanced_base)
    git(repo, "switch", "-qc", "feature")
    head = commit(repo, "feat: signed contribution", signoff: true)

    _output, status = check(repo, "main", head, payload_base: stale_base)
    assert status.success?
  end

  def test_slash_containing_base_ref_resolves
    repo, base = repository
    git(repo, "update-ref", "refs/remotes/origin/release/next", base)
    head = commit(repo, "feat: signed contribution", signoff: true)

    _output, status = check(repo, "release/next", head)
    assert status.success?
  end

  def test_missing_base_ref_fails_closed
    repo, payload_base = repository
    head = commit(repo, "feat: signed contribution", signoff: true)

    output, status = check(repo, "missing", head, payload_base: payload_base)
    refute status.success?
    assert_includes output, "Could not resolve the current pull request base ref"
  end

  def test_checkout_fetches_every_branch_without_persisting_credentials
    checkout = @steps.find { |step| step["name"] == "Checkout contribution" }
    assert_equal 0, checkout.dig("with", "fetch-depth")
    assert_equal false, checkout.dig("with", "persist-credentials")

    refute(@steps.any? { |step| step["name"] == "Check actor exemption" })
    refute checkout.key?("if")
    refute @steps.find { |step| step["name"] == "Check DCO sign-offs" }.key?("if")
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
    base = git(repo, "rev-parse", "HEAD").strip
    git(repo, "update-ref", "refs/remotes/origin/main", base)
    [repo, base]
  end

  def commit(repo, message, signoff: false, trailer: nil, path: "change", author_name: nil, author_email: nil)
    File.write(File.join(repo, path), "#{message}\n")
    git(repo, "add", path)
    args = ["commit", "-q"]
    args.unshift("-c", "user.email=#{author_email}") if author_email
    args.unshift("-c", "user.name=#{author_name}") if author_name
    args << "-s" if signoff
    args.push("-m", message)
    args.push("-m", trailer) if trailer
    git(repo, *args)
    git(repo, "rev-parse", "HEAD").strip
  end

  def check(repo, base_ref, head, payload_base: nil, actor: "human-contributor", verified_dependabot_commits: [])
    payload_base ||= git(repo, "rev-parse", "refs/remotes/origin/#{base_ref}").strip
    shim_dir = Dir.mktmpdir("dco-gh-")
    gh = File.join(shim_dir, "gh")
    File.write(gh, <<~SH)
      #!/usr/bin/env bash
      set -euo pipefail
      commit=""
      for argument in "$@"; do
        case "${argument}" in
          */commits/*) commit="${argument##*/}" ;;
        esac
      done
      case ",${VERIFIED_DEPENDABOT_COMMITS}," in
        *",${commit},"*) printf 'true\n' ;;
        *) printf 'false\n' ;;
      esac
    SH
    FileUtils.chmod(0o755, gh)
    stdout, stderr, status = Open3.capture3(
      {
        "ACTOR" => actor,
        "BASE_REF" => base_ref,
        "BASE_SHA" => payload_base,
        "GH_TOKEN" => "test-token",
        "GITHUB_REPOSITORY" => "example/repository",
        "HEAD_SHA" => head,
        "PATH" => "#{shim_dir}:#{ENV.fetch("PATH")}",
        "VERIFIED_DEPENDABOT_COMMITS" => verified_dependabot_commits.join(",")
      },
      "bash", "-euo", "pipefail", "-c", @script,
      chdir: repo
    )
    [[stdout, stderr].join, status]
  ensure
    FileUtils.remove_entry(shim_dir) if shim_dir && File.exist?(shim_dir)
  end

  def git(repo, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: repo)
    raise "git #{args.join(" ")} failed:\n#{stdout}#{stderr}" unless status.success?

    stdout
  end
end
