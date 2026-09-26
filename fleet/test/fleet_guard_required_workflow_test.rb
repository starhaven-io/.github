# frozen_string_literal: true

require "date"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"
require "minitest/autorun"

module RequiredGuardWorkflow
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW = File.join(ROOT, ".github/workflows/fleet-guard-required.yml")
  SANDBOX = Dir.mktmpdir("fleet-guard-required-")
  CHECKOUT_GATE = "steps.mode.outputs.mode != 'exempt'"
  BOT = "starhaven-bot[bot]"

  module_function

  def git(repo, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: repo)
    raise "git #{args.join(" ")} failed:\n#{stdout}#{stderr}" unless status.success?

    stdout
  end

  def commit_all(repo, message)
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=Required Guard Test", "-c", "user.email=guard@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-qm", message)
  end

  # The ruleset job never runs on the hub, so the hub's own config stands in
  # for a consumer here and every run exercises consumer guard semantics.
  def self.base_repository
    @base_repository ||= begin
      repo = File.join(SANDBOX, "base")
      files = git(ROOT, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0")
      files.each do |path|
        source = File.join(ROOT, path)
        next unless File.file?(source)

        destination = File.join(repo, path)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(source, destination, preserve: true)
      end
      git(repo, "init", "-q", "-b", "main")
      commit_all(repo, "baseline")
      version = File.read(File.join(repo, "fleet/VERSION")).strip
      git(repo, "-c", "tag.gpgSign=false", "tag", "-a", version, "-m", "Fleet #{version}")
      _stdout, stderr, status = Open3.capture3(
        { "GITHUB_REPOSITORY" => nil },
        "ruby", "fleet/sync.rb", "--hub-root", ".", "--repo-root", ".", "--repo-name", ".github",
        chdir: repo
      )
      raise "fixture convergence failed:\n#{stderr}" unless status.success?

      commit_all(repo, "converge") unless git(repo, "status", "--porcelain").empty?
      repo
    end
  end
end

Minitest.after_run { FileUtils.rm_rf(RequiredGuardWorkflow::SANDBOX) }

class FleetGuardRequiredWorkflowTest < Minitest::Test
  include RequiredGuardWorkflow

  def setup
    @workflow = YAML.safe_load_file(WORKFLOW, permitted_classes: [], aliases: false)
    @job = @workflow.fetch("jobs").fetch("guard")
    @steps = @job.fetch("steps")
  end

  def test_runs_on_every_pull_request_with_read_only_contents
    assert_equal({ "pull_request" => nil }, @workflow.fetch(true))
    assert_equal({}, @workflow.fetch("permissions"))
    assert_equal({ "contents" => "read" }, @job.fetch("permissions"))
    refute_match(/\bsecrets\./, File.read(WORKFLOW))
  end

  def test_skips_only_the_hub_which_guards_itself_in_tree
    assert_equal "github.repository != 'starhaven-io/.github'", @job.fetch("if")
  end

  def test_render_checks_only_same_repository_sync_app_fleet_sync_pull_requests
    branch = "fleet-sync-v2026.09.23.1"
    assert_equal "sync", mode(author: BOT, head_ref: branch)
    assert_equal "sync", mode(author: BOT, head_ref: branch, actor: "human-maintainer")
    assert_equal "guard", mode(author: BOT, head_ref: "bump-cask")
    assert_equal "guard", mode(author: BOT, head_ref: branch, head_repository: "someone/.github")
    assert_equal "guard", mode(author: "human-maintainer", head_ref: branch, actor: BOT)
    assert_equal "guard", mode(author: "human-maintainer", head_ref: "feature", actor: BOT)
    ["starhaven-bot", "Starhaven-Bot[bot]", "x-starhaven-bot[bot]", "starhaven-bot[bot]x"].each do |author|
      assert_equal "guard", mode(author:, head_ref: branch), "#{author.inspect} must not select sync mode"
    end
  end

  def test_exempts_only_dependabot
    assert_equal "exempt", mode(author: "dependabot[bot]", head_ref: "dependabot/npm", actor: "dependabot[bot]")
    ["dependabot", "dependabot[bot]x", "x-dependabot[bot]", BOT, "human-maintainer", ""].each do |actor|
      assert_equal "guard", mode(author: "human-maintainer", head_ref: "feature", actor:),
                   "#{actor.inspect} must not be exempt"
    end
  end

  def test_every_later_step_waits_on_the_mode_decision
    mode_step = @steps.first
    assert_equal "mode", mode_step.fetch("id")
    refute mode_step.key?("if")

    gates = @steps.drop(1).to_h { |candidate| [candidate.fetch("name"), candidate["if"]] }
    assert_equal(
      {
        "Checkout consumer" => CHECKOUT_GATE,
        "Checkout fleet hub" => CHECKOUT_GATE,
        "Set up Ruby" => CHECKOUT_GATE,
        "Guard fleet-managed surfaces" => "steps.mode.outputs.mode == 'guard'",
        "Verify fleet sync pull request" => "steps.mode.outputs.mode == 'sync'"
      },
      gates
    )
  end

  def test_checks_out_trusted_hub_main_with_the_history_pin_resolution_needs
    consumer = step("Checkout consumer").fetch("with")
    assert_equal({ "fetch-depth" => 0, "persist-credentials" => false }, consumer)

    hub = step("Checkout fleet hub").fetch("with")
    assert_equal(
      {
        "repository" => "starhaven-io/.github",
        "ref" => "main",
        "path" => "hub",
        "fetch-depth" => 0,
        "fetch-tags" => true,
        "persist-credentials" => false
      },
      hub
    )
  end

  def test_guard_and_sync_inputs_come_from_the_pull_request_event
    assert_equal(
      {
        "BASE_SHA" => "${{ github.event.pull_request.base.sha }}",
        "REPO_NAME" => "${{ github.event.repository.name }}"
      },
      step("Guard fleet-managed surfaces").fetch("env")
    )
    assert_equal(
      {
        "BASE_SHA" => "${{ github.event.pull_request.base.sha }}",
        "HEAD_REF" => "${{ github.event.pull_request.head.ref }}",
        "HEAD_SHA" => "${{ github.event.pull_request.head.sha }}",
        "REPO_NAME" => "${{ github.event.repository.name }}"
      },
      step("Verify fleet sync pull request").fetch("env")
    )
  end

  def test_missing_base_sha_fails_closed
    repo = pull_request("missing-base") { |_path| nil }

    output, status = guard(repo, base_sha: "")
    refute status.success?
    assert_includes output, "fleet guard requires a pull_request base SHA"
  end

  def test_accepts_a_repository_owned_change
    repo = pull_request("repo-owned") do |path|
      File.write(File.join(path, "profile/README.md"), "\nRepository-owned edit.\n", mode: "a")
    end

    output, status = guard(repo)
    assert status.success?, output
  end

  def test_rejects_a_managed_file_edit
    repo = pull_request("managed-file") do |path|
      File.write(File.join(path, ".editorconfig"), "\n[*.md]\nindent_size = 8\n", mode: "a")
    end

    output, status = guard(repo)
    refute status.success?
    assert_includes output, "managed surface change rejected (.editorconfig)"
  end

  def test_applies_consumer_ownership_of_fleet_config
    repo = pull_request("fleet-config") do |path|
      File.write(File.join(path, ".fleet.yml"), "# consumer edit\n", mode: "a")
    end

    output, status = guard(repo)
    refute status.success?
    assert_includes output, ".fleet.yml is hub-owned fleet configuration"
  end

  def test_rejects_a_repository_name_that_does_not_match_the_event
    repo = pull_request("identity") { |_path| nil }

    output, status = guard(repo, repository: "starhaven-io/midden")
    refute status.success?
    assert_includes output, "--repo-name .github does not match guard repository starhaven-io/midden"
  end

  def test_accepts_a_sync_pull_request_that_matches_the_release_render
    repo, base, head = sync_pull_request("sync-exact")

    output, status = verify_sync(repo, base:, head:)
    assert status.success?, output
    assert_includes output, "matches the authenticated release render"
    [repo, File.join(repo, "hub")].each do |repository|
      assert_equal 1, git(repository, "worktree", "list", "--porcelain").scan(/^worktree /).length
    end
  end

  def test_accepts_a_sync_pull_request_updated_with_its_base_branch
    repo, _base, _head = sync_pull_request("sync-updated")
    branch = git(repo, "branch", "--show-current").strip
    git(repo, "switch", "-q", "main")
    File.write(File.join(repo, "notes.md"), "Unrelated base change.\n")
    commit_all(repo, "advance main")
    advanced = git(repo, "rev-parse", "HEAD").strip
    git(repo, "switch", "-q", branch)
    git(repo, "-c", "user.name=Required Guard Test", "-c", "user.email=guard@example.invalid",
        "-c", "commit.gpgsign=false", "merge", "-q", "--no-ff", "-m", "Update branch", "main")

    output, status = verify_sync(repo, base: advanced, head: git(repo, "rev-parse", "HEAD").strip)
    assert status.success?, output
  end

  def test_rejects_an_unmanaged_file_added_to_a_sync_pull_request
    repo, base, head = sync_pull_request("sync-extra") do |path|
      FileUtils.mkdir_p(File.join(path, "Casks"))
      File.write(File.join(path, "Casks/evil.rb"), "cask \"evil\" do\nend\n")
    end

    assert_sync_rejected(repo, base, head, 'unexpected: "Casks/evil.rb"')
  end

  def test_rejects_a_managed_hook_that_differs_from_the_render
    repo, base, head = sync_pull_request("sync-hook") do |path|
      File.write(File.join(path, ".githooks/pre-push"), "\nexit 0\n", mode: "a")
    end

    assert_sync_rejected(repo, base, head, 'differs: ".githooks/pre-push"')
  end

  def test_rejects_a_file_mode_change
    repo, base, head = sync_pull_request("sync-mode") do |path|
      FileUtils.chmod(0o755, File.join(path, "README.md"))
    end

    assert_sync_rejected(repo, base, head, 'differs: "README.md"')
  end

  def test_rejects_a_sync_pull_request_that_omits_rendered_changes
    repo, base, head = sync_pull_request("sync-partial") do |path|
      File.write(File.join(path, "CLAUDE.md"), "@AGENTS.md\n@README.md\n")
    end

    assert_sync_rejected(repo, base, head, 'differs: "CLAUDE.md"')
  end

  def test_rejects_a_deleted_file
    repo, base, head = sync_pull_request("sync-delete") do |path|
      File.delete(File.join(path, "SECURITY.md"))
    end

    assert_sync_rejected(repo, base, head, 'missing: "SECURITY.md"')
  end

  def test_rejects_a_branch_that_does_not_name_the_current_release
    repo, base, head = sync_pull_request("sync-branch")

    output, status = verify_sync(repo, base:, head:, branch: "fleet-sync-v2020.01.01.1")
    refute status.success?
    assert_includes output, "does not name the current fleet release"
  end

  def test_rejects_a_hub_main_version_without_an_authenticated_release
    repo, base, head = sync_pull_request("sync-untagged")
    hub = File.join(repo, "hub")
    unreleased = "v#{Date.today.strftime("%Y.%m.%d")}.9"
    File.write(File.join(hub, "fleet/VERSION"), "#{unreleased}\n")
    commit_all(hub, "unreleased version")

    output, status = verify_sync(repo, base:, head:, branch: "fleet-sync-#{unreleased}")
    refute status.success?
    assert_includes output, "release authentication failed"
  end

  private

  def step(name)
    @steps.find { |candidate| candidate["name"] == name } || flunk("missing step #{name}")
  end

  def mode(author:, head_ref:, actor: author, head_repository: "starhaven-io/.github")
    Dir.mktmpdir("mode-", SANDBOX) do |directory|
      output = File.join(directory, "github-output")
      _stdout, stderr, status = Open3.capture3(
        {
          "ACTOR" => actor,
          "AUTHOR" => author,
          "HEAD_REF" => head_ref,
          "HEAD_REPOSITORY" => head_repository,
          "GITHUB_REPOSITORY" => "starhaven-io/.github",
          "GITHUB_OUTPUT" => output
        },
        "bash", "-euo", "pipefail", "-c", step("Select guard mode").fetch("run")
      )
      assert status.success?, stderr

      File.readlines(output, chomp: true).to_h { |line| line.split("=", 2) }.fetch("mode")
    end
  end

  def pull_request(name)
    base = RequiredGuardWorkflow.base_repository
    repo = File.join(SANDBOX, name)
    git(SANDBOX, "clone", "--quiet", "--no-hardlinks", base, repo)
    git(SANDBOX, "clone", "--quiet", "--no-hardlinks", base, File.join(repo, "hub"))
    File.write(File.join(repo, ".git/info/exclude"), "/hub/\n", mode: "a")
    yield repo
    commit_all(repo, "pull request") unless git(repo, "status", "--porcelain").empty?
    repo
  end

  def sync_pull_request(name)
    repo = pull_request(name) do |path|
      File.delete(File.join(path, ".editorconfig"))
      File.write(File.join(path, "CLAUDE.md"), "@AGENTS.md\n@README.md\n")
    end
    base = git(repo, "rev-parse", "HEAD").strip
    git(repo, "switch", "-q", "-c", sync_branch(repo))
    _stdout, stderr, status = Open3.capture3(
      { "GITHUB_REPOSITORY" => nil },
      "ruby", "hub/fleet/sync.rb", "--hub-root", "hub", "--repo-root", ".", "--repo-name", ".github",
      chdir: repo
    )
    raise "sync fixture render failed:\n#{stderr}" unless status.success?

    commit_all(repo, "chore(fleet): sync managed surfaces")
    if block_given?
      yield repo
      commit_all(repo, "tamper")
    end
    [repo, base, git(repo, "rev-parse", "HEAD").strip]
  end

  def sync_branch(repo)
    "fleet-sync-#{File.read(File.join(repo, "hub/fleet/VERSION")).strip}"
  end

  def verify_sync(repo, base:, head:, branch: sync_branch(repo))
    stdout, stderr, status = Open3.capture3(
      {
        "BASE_SHA" => base,
        "HEAD_REF" => branch,
        "HEAD_SHA" => head,
        "REPO_NAME" => ".github",
        "GITHUB_REPOSITORY" => nil
      },
      "bash", "-euo", "pipefail", "-c", step("Verify fleet sync pull request").fetch("run"),
      chdir: repo
    )
    [[stdout, stderr].join, status]
  end

  def assert_sync_rejected(repo, base, head, detail)
    output, status = verify_sync(repo, base:, head:)
    refute status.success?, output
    assert_includes output, "differs from the"
    assert_includes output, detail
    fence = output[/^::stop-commands::(\h{32})$/, 1]
    refute_nil fence, output
    assert_operator output.index(detail), :<, output.index("::#{fence}::")
    assert_includes output, "::error::fleet sync pull request rejected; see the log above"
  end

  def guard(repo, base_sha: nil, repository: "starhaven-io/.github")
    base_sha ||= git(repo, "rev-parse", "origin/main").strip
    stdout, stderr, status = Open3.capture3(
      {
        "BASE_SHA" => base_sha,
        "GITHUB_REPOSITORY" => repository,
        "REPO_NAME" => ".github"
      },
      "bash", "-euo", "pipefail", "-c", step("Guard fleet-managed surfaces").fetch("run"),
      chdir: repo
    )
    [[stdout, stderr].join, status]
  end
end
