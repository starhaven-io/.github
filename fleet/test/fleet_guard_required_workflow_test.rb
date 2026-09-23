# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"
require "minitest/autorun"

module RequiredGuardWorkflow
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW = File.join(ROOT, ".github/workflows/fleet-guard-required.yml")
  SANDBOX = Dir.mktmpdir("fleet-guard-required-")
  EXEMPTION_GATE = "steps.exemption.outputs.exempt != 'true'"

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
      git(repo, "tag", File.read(File.join(repo, "fleet/VERSION")).strip)
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

  def test_exempts_exactly_the_sync_app_and_dependabot
    assert_equal "true", exemption("starhaven-bot[bot]")
    assert_equal "true", exemption("dependabot[bot]")
    [
      "starhaven-bot",
      "dependabot",
      "starhaven-bot[bot]x",
      "x-dependabot[bot]",
      "Starhaven-Bot[bot]",
      "human-maintainer",
      ""
    ].each do |actor|
      assert_equal "false", exemption(actor), "#{actor.inspect} must not be exempt"
    end
  end

  def test_every_later_step_waits_on_the_exemption_decision
    exemption_step = @steps.first
    assert_equal "exemption", exemption_step.fetch("id")
    refute exemption_step.key?("if")

    @steps.drop(1).each do |step|
      assert_equal EXEMPTION_GATE, step["if"], "#{step.fetch("name")} must be gated by the exemption"
    end
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

  def test_guard_identity_comes_from_the_pull_request_event
    assert_equal(
      {
        "BASE_SHA" => "${{ github.event.pull_request.base.sha }}",
        "REPO_NAME" => "${{ github.event.repository.name }}"
      },
      step("Guard fleet-managed surfaces").fetch("env")
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

  private

  def step(name)
    @steps.find { |candidate| candidate["name"] == name } || flunk("missing step #{name}")
  end

  def exemption(actor)
    Dir.mktmpdir("exemption-", SANDBOX) do |directory|
      output = File.join(directory, "github-output")
      _stdout, stderr, status = Open3.capture3(
        { "ACTOR" => actor, "GITHUB_OUTPUT" => output },
        "bash", "-euo", "pipefail", "-c", step("Check actor exemption").fetch("run")
      )
      assert status.success?, stderr

      File.readlines(output, chomp: true).to_h { |line| line.split("=", 2) }.fetch("exempt")
    end
  end

  def pull_request(name)
    base = RequiredGuardWorkflow.base_repository
    repo = File.join(SANDBOX, name)
    git(SANDBOX, "clone", "--quiet", "--no-hardlinks", base, repo)
    git(SANDBOX, "clone", "--quiet", "--no-hardlinks", base, File.join(repo, "hub"))
    yield repo
    commit_all(repo, "pull request") unless git(repo, "status", "--porcelain", "--", ":!hub").empty?
    repo
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
