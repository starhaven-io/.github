# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"
require "minitest/autorun"

ROOT = File.expand_path("../..", __dir__)
SYNC = ["ruby", "-rpathname", "fleet/sync.rb"].freeze
CONCLUSION_WORKFLOW = File.join(ROOT, ".github/workflows/conclusion.yml")
PINPRICK_AUDIT_WORKFLOW = File.join(ROOT, ".github/workflows/pinprick-audit.yml")

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

  def run_command_env(env, cwd, *argv)
    stdout, stderr, status = Open3.capture3(env, *argv, chdir: cwd)
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

  def consumer_guard(repo)
    sync(repo, "--guard", "HEAD~1")
  end

  def fleet_config_path(repo)
    File.join(repo, "fleet/repos/.github.yml")
  end

  def rendered_fleet_config_path(repo)
    File.join(repo, ".fleet.yml")
  end

  def fleet_config(repo)
    YAML.safe_load_file(fleet_config_path(repo), permitted_classes: [], aliases: false)
  end

  def write_fleet_config(repo, config)
    File.write(fleet_config_path(repo), config.to_yaml)
  end

  def write_rendered_fleet_config(repo, config)
    File.write(rendered_fleet_config_path(repo), config.to_yaml)
  end

  def fleet_version(repo)
    File.read(File.join(repo, "fleet/VERSION")).strip
  end

  def fleet_ref(repo)
    git(repo, "rev-list", "-n1", "refs/tags/#{fleet_version(repo)}").stdout.strip
  end

  def reusable_workflow_line(repo, ref: nil, version: nil)
    ref ||= fleet_ref(repo)
    version ||= fleet_version(repo)
    "    uses: starhaven-io/.github/.github/workflows/reusable-conventional-commits.yml@#{ref} # #{version}"
  end

  def write_ci_workflow(repo, uses_line)
    File.write(File.join(repo, ".github/workflows/ci.yml"), <<~YAML)
      name: CI

      on:
        pull_request:

      permissions: {}

      jobs:
        commits:
          name: Conventional Commits
          if: github.event_name == 'pull_request'
          permissions:
            contents: read
            pull-requests: read
      #{uses_line}
    YAML
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

  def enable_npm_policy(repo, projects)
    config = fleet_config(repo)
    config.fetch("params")["npm-policy"] = { "projects" => projects }
    write_fleet_config(repo, config)
    File.open(File.join(repo, "justfile"), "a") do |file|
      file.puts
      file.puts("# fleet:block npm-policy")
      file.puts("# fleet:end")
    end
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

  def test_renders_fleet_config_for_adoption
    repo = scenario("render-fleet-config-adoption")
    FileUtils.rm_f(rendered_fleet_config_path(repo))

    assert_sync_success(sync(repo))

    assert_equal File.read(fleet_config_path(repo)), File.read(rendered_fleet_config_path(repo))
    assert_sync_success(sync(repo, "--check"))
  end

  def test_consumer_fleet_config_does_not_control_rendering
    repo = scenario("consumer-fleet-config-ignored")
    config = fleet_config(repo)
    config.fetch("params").fetch("pinprick-audit")["fail-on-findings"] = false
    write_rendered_fleet_config(repo, config)

    assert_sync_success(sync(repo))

    assert_equal File.read(fleet_config_path(repo)), File.read(rendered_fleet_config_path(repo))
    assert_sync_success(sync(repo, "--check"))
  end

  def test_rejects_unknown_repo_registry_key
    repo = scenario("unknown-repo-registry-key")
    registry_path = File.join(repo, "fleet/repos.yml")
    registry = YAML.safe_load_file(registry_path, permitted_classes: [], aliases: false)
    registry["unexpected"] = true
    File.write(registry_path, registry.to_yaml)

    assert_rejects(["sync", sync(repo), "fleet/repos.yml contains unknown keys: unexpected"])
  end

  def test_rejects_unlisted_repo
    repo = scenario("unlisted-repo")
    result = run_command(
      repo,
      *SYNC,
      "--hub-root", ".",
      "--repo-root", ".",
      "--repo-name", "unlisted"
    )

    assert_rejects(["sync", result, "unlisted is not listed in fleet/repos.yml"])
  end

  def test_rejects_missing_hub_fleet_config
    repo = scenario("missing-hub-fleet-config")
    FileUtils.rm_f(fleet_config_path(repo))

    assert_rejects(["sync", sync(repo), "fleet/repos inventory mismatch (missing: .github.yml)"])
  end

  def test_rejects_orphaned_hub_fleet_config
    repo = scenario("orphaned-hub-fleet-config")
    FileUtils.cp(fleet_config_path(repo), File.join(repo, "fleet/repos/orphaned.yml"))

    assert_rejects(["sync", sync(repo), "fleet/repos inventory mismatch (orphaned: orphaned.yml)"])
  end

  def test_requires_repo_name
    repo = scenario("missing-repo-name")
    result = run_command(repo, *SYNC, "--hub-root", ".", "--repo-root", ".")

    assert_rejects(["sync", result, "--repo-name is required"])
  end

  def test_rejects_unknown_fleet_config_key
    repo = scenario("unknown-fleet-config-key")
    config = fleet_config(repo)
    config["unexpected"] = true
    write_fleet_config(repo, config)

    assert_rejects(["sync", sync(repo), ".fleet.yml contains unknown keys: unexpected"])
  end

  def test_renders_dependabot_entry_policies
    repo = scenario("dependabot-entry-policies")
    config = fleet_config(repo)
    config.fetch("params").fetch("dependabot") << {
      "package-ecosystem" => "npm",
      "group" => "npm-dependencies",
      "directory" => "/",
      "ignore" => [
        {
          "dependency-name" => "typescript",
          "reason" => "TypeScript 7.0 lacks Astro's required API; reassess with 7.1: https://github.com/withastro/astro/issues/17268",
          "versions" => [">=7.0.0 <7.1.0"]
        },
        {
          "dependency-name" => "eslint",
          "update-types" => ["version-update:semver-major"]
        }
      ]
    }
    write_fleet_config(repo, config)

    assert_sync_success(sync(repo))

    rendered_path = File.join(repo, ".github/dependabot.yml")
    rendered_text = File.read(rendered_path)
    rendered = YAML.safe_load(rendered_text, permitted_classes: [], aliases: false)
    npm = rendered.fetch("updates").find { |entry| entry.fetch("package-ecosystem") == "npm" }
    assert_includes rendered_text,
                    "# TypeScript 7.0 lacks Astro's required API; reassess with 7.1: " \
                    "https://github.com/withastro/astro/issues/17268"
    assert_equal(
      [
        { "dependency-name" => "typescript", "versions" => [">=7.0.0 <7.1.0"] },
        { "dependency-name" => "eslint", "update-types" => ["version-update:semver-major"] }
      ],
      npm.fetch("ignore")
    )
  end

  def test_preserves_fleet_pin_ignore_with_custom_github_actions_policy
    repo = scenario("github-actions-custom-ignore")
    config = fleet_config(repo)
    github_actions = config.fetch("params").fetch("dependabot").find do |entry|
      entry.fetch("package-ecosystem") == "github-actions"
    end
    github_actions["ignore"] = [
      {
        "dependency-name" => "actions/setup-node",
        "update-types" => ["version-update:semver-major"]
      }
    ]
    write_fleet_config(repo, config)

    assert_sync_success(sync(repo))

    rendered = YAML.safe_load_file(File.join(repo, ".github/dependabot.yml"), permitted_classes: [], aliases: false)
    rendered_actions = rendered.fetch("updates").find { |entry| entry.fetch("package-ecosystem") == "github-actions" }
    assert_equal(
      [
        { "dependency-name" => "starhaven-io/.github/*" },
        { "dependency-name" => "actions/setup-node", "update-types" => ["version-update:semver-major"] }
      ],
      rendered_actions.fetch("ignore")
    )
  end

  def test_rejects_unknown_dependabot_ignore_key
    repo = scenario("unknown-dependabot-ignore-key")
    config = fleet_config(repo)
    config.fetch("params").fetch("dependabot").first["ignore"] = [
      { "dependency-name" => "typescript", "rationale" => "unsupported" }
    ]
    write_fleet_config(repo, config)

    assert_rejects(["sync", sync(repo), "contains unknown keys: rationale"])
  end

  def test_rejects_unicode_line_breaks_in_dependabot_reason
    ["\u2028", "\u2029"].each do |line_break|
      repo = scenario("dependabot-reason-u#{line_break.ord.to_s(16)}")
      config = fleet_config(repo)
      config.fetch("params").fetch("dependabot").first["ignore"] = [
        {
          "dependency-name" => "typescript",
          "reason" => "unsupported#{line_break}      - dependency-name: astro"
        }
      ]
      write_fleet_config(repo, config)

      assert_rejects(
        ["sync", sync(repo), ".reason must not contain control characters or line separators"]
      )
    end
  end

  def test_rejects_unicode_line_breaks_in_markdown_text
    ["\u2028", "\u2029"].each do |line_break|
      repo = scenario("readme-license-u#{line_break.ord.to_s(16)}")
      config = fleet_config(repo)
      config.fetch("params").fetch("readme").fetch("license")["text"] = "UNICODE_LINE_BREAK_TEST"
      yaml = config.to_yaml.sub(
        "UNICODE_LINE_BREAK_TEST",
        %("First line\\nSecond\\u#{line_break.ord.to_s(16)}hidden")
      )
      File.write(fleet_config_path(repo), yaml)

      assert_rejects(
        ["sync", sync(repo), ".text must not contain control characters or line separators"]
      )
    end
  end

  def test_sync_updates_reusable_pins_in_repo_owned_workflows
    repo = scenario("repo-owned-reusable-pin-sync")
    write_ci_workflow(repo, reusable_workflow_line(repo, ref: "0" * 40, version: "v2026.07.05.9"))

    assert_sync_success(sync(repo))

    ci = File.read(File.join(repo, ".github/workflows/ci.yml"))
    assert_includes ci, reusable_workflow_line(repo)
    refute_includes ci, "v2026.07.05.9"
  end

  def test_syncs_multiple_quoted_and_yaml_reusable_pins
    repo = scenario("multi-reusable-pin-sync")
    ref = fleet_ref(repo)
    version = fleet_version(repo)
    stale = "0" * 40
    path = File.join(repo, ".github/workflows/extra.yaml")
    File.write(path, <<~YAML)
      name: Extra

      on:
        pull_request:

      permissions: {}

      jobs:
        commits:
          uses: starhaven-io/.github/.github/workflows/reusable-conventional-commits.yml@#{stale} # v2026.07.05.9
        audit:
          uses: "starhaven-io/.github/.github/workflows/reusable-pinprick-audit.yml@#{stale}" # v2026.07.05.9
    YAML

    assert_sync_success(sync(repo))

    synced = File.read(path)
    quoted = "\"starhaven-io/.github/.github/workflows/reusable-pinprick-audit.yml@#{ref}\" # #{version}"
    assert_includes synced, "reusable-conventional-commits.yml@#{ref} # #{version}"
    assert_includes synced, quoted
    refute_includes synced, "v2026.07.05.9"
  end

  def test_check_reports_stale_reusable_pins_in_repo_owned_workflows
    repo = scenario("repo-owned-reusable-pin-check")
    write_ci_workflow(repo, reusable_workflow_line(repo, ref: "0" * 40, version: "v2026.07.05.9"))

    result = sync(repo, "--check")

    assert_rejects(["--check", result, ".github/workflows/ci.yml:reusable-pins"])
    assert_includes result.output, "fleet sync drift detected"
  end

  def test_allows_legitimate_unmanaged_edits
    repo = scenario("unmanaged-edit")
    File.open(File.join(repo, "SECURITY.md"), "a") { |file| file.puts("\nRegression harness unmanaged edit.") }
    commit_all(repo, "unmanaged edit")

    assert_sync_success(guard(repo))
  end

  def test_rejects_stale_reusable_pin_edits
    repo = scenario("stale-reusable-pin-edit")
    write_ci_workflow(repo, reusable_workflow_line(repo))
    commit_all(repo, "add ci workflow")
    write_ci_workflow(repo, reusable_workflow_line(repo, ref: "0" * 40, version: "v2026.07.05.9"))
    commit_all(repo, "stale reusable pin")

    assert_rejects(["guard", guard(repo), ".github/workflows/ci.yml:reusable-pins"])
  end

  def test_allows_adding_canonical_reusable_pin
    repo = scenario("add-canonical-reusable-pin")
    write_ci_workflow(repo, reusable_workflow_line(repo))
    commit_all(repo, "add ci workflow with canonical pin")

    assert_sync_success(consumer_guard(repo))
  end

  def test_rejects_removing_reusable_workflow_calls
    repo = scenario("remove-reusable-workflow-call")
    write_ci_workflow(repo, reusable_workflow_line(repo))
    commit_all(repo, "add reusable workflow call")

    FileUtils.rm_f(File.join(repo, ".github/workflows/ci.yml"))
    commit_all(repo, "remove reusable workflow call")

    result = consumer_guard(repo)
    assert_rejects(["guard", result, "reusable workflow declassification rejected"])
    assert_includes result.output, "reusable-conventional-commits.yml (1 -> 0)"
  end

  def test_rejects_reducing_reusable_workflow_call_multiplicity
    repo = scenario("reduce-reusable-workflow-call-multiplicity")
    path = File.join(repo, ".github/workflows/ci.yml")
    uses_line = reusable_workflow_line(repo)
    write_ci_workflow(repo, uses_line)
    second_job = "\n  second-commits-check:\n#{uses_line}\n"
    File.open(path, "a") { |file| file.write(second_job) }
    commit_all(repo, "add two reusable workflow calls")

    text = File.read(path)
    File.write(path, text.delete_suffix(second_job))
    commit_all(repo, "remove one reusable workflow call")

    result = consumer_guard(repo)
    assert_rejects(["guard", result, "reusable workflow declassification rejected"])
    assert_includes result.output, "reusable-conventional-commits.yml (2 -> 1)"
  end

  def test_rejects_moving_reusable_workflow_calls
    repo = scenario("move-reusable-workflow-call")
    write_ci_workflow(repo, reusable_workflow_line(repo))
    commit_all(repo, "add reusable workflow call")

    source = File.join(repo, ".github/workflows/ci.yml")
    destination = File.join(repo, ".github/workflows/policy.yml")
    FileUtils.mv(source, destination)
    commit_all(repo, "move reusable workflow call")

    result = consumer_guard(repo)
    assert_rejects(["guard", result, "reusable workflow declassification rejected"])
    assert_includes result.output, ".github/workflows/ci.yml: reusable-conventional-commits.yml (1 -> 0)"
  end

  def test_allows_hub_to_remove_reusable_workflow_calls
    repo = scenario("hub-remove-reusable-workflow-call")
    write_ci_workflow(repo, reusable_workflow_line(repo))
    commit_all(repo, "add reusable workflow call")

    FileUtils.rm_f(File.join(repo, ".github/workflows/ci.yml"))
    commit_all(repo, "remove reusable workflow call")

    assert_sync_success(guard(repo))
  end

  def test_allows_repo_owned_conditions_to_change
    repo = scenario("repo-owned-reusable-workflow-condition")
    path = File.join(repo, ".github/workflows/ci.yml")
    write_ci_workflow(repo, reusable_workflow_line(repo))
    commit_all(repo, "add reusable workflow call")

    text = File.read(path)
    File.write(path, text.sub("if: github.event_name == 'pull_request'", "if: false"))
    commit_all(repo, "change repo-owned condition")

    assert_sync_success(consumer_guard(repo))
  end

  def test_rejects_malformed_base_config_before_declassification_check
    repo = scenario("malformed-base-config-declassification")
    config = fleet_config(repo)
    File.write(rendered_fleet_config_path(repo), "schema: [\n")
    commit_all(repo, "malformed base fleet config")

    head_config = config.merge("exceptions" => config.fetch("exceptions", {}).merge(
      "pinprick-audit" => "consumer opt-out"
    ))
    write_rendered_fleet_config(repo, head_config)
    commit_all(repo, "declassify pinprick audit")

    assert_rejects(["guard", consumer_guard(repo), "fleet guard: base .fleet.yml could not be parsed"])
  end

  def test_rejects_consumer_adoption_when_base_config_is_absent
    repo = scenario("absent-base-config-adoption")
    config = fleet_config(repo)
    FileUtils.rm_f(rendered_fleet_config_path(repo))
    commit_all(repo, "remove fleet config at base")

    write_rendered_fleet_config(repo, config)
    commit_all(repo, "adopt fleet config")

    assert_rejects(["guard", consumer_guard(repo), ".fleet.yml is hub-owned fleet configuration"])
  end

  def test_rejects_guard_repo_name_mismatch
    repo = scenario("guard-repo-name-mismatch")
    result = run_command_env(
      { "GITHUB_REPOSITORY" => "starhaven-io/pinprick" },
      repo,
      *SYNC,
      "--hub-root", ".",
      "--repo-root", ".",
      "--repo-name", ".github",
      "--guard", "HEAD~1"
    )

    assert_rejects(["guard", result, "--repo-name .github does not match guard repository starhaven-io/pinprick"])
  end

  def test_rejects_consumer_fleet_config_weakening_with_matching_render
    repo = scenario("consumer-config-weakening")
    canonical = File.read(fleet_config_path(repo))
    config = fleet_config(repo)
    config.fetch("params").fetch("pinprick-audit")["fail-on-findings"] = false
    write_fleet_config(repo, config)
    assert_sync_success(sync(repo))
    File.write(fleet_config_path(repo), canonical)
    commit_all(repo, "weaken fleet config")

    assert_rejects(["guard", consumer_guard(repo), ".fleet.yml is hub-owned fleet configuration"])
  end

  def test_rejects_consumer_fleet_config_edit
    repo = scenario("consumer-config-edit")
    config = fleet_config(repo)
    config.fetch("params").fetch("pinprick-audit")["fail-on-findings"] = false
    write_rendered_fleet_config(repo, config)
    commit_all(repo, "edit fleet config")

    assert_rejects(["guard", consumer_guard(repo), ".fleet.yml is hub-owned fleet configuration"])
  end

  def test_allows_hub_fleet_config_edit
    repo = scenario("hub-config-edit")
    config = fleet_config(repo)
    config.fetch("params").fetch("pinprick-audit")["fail-on-findings"] = false
    write_fleet_config(repo, config)
    assert_sync_success(sync(repo))
    commit_all(repo, "edit hub fleet config")

    assert_sync_success(guard(repo))
  end

  def test_rejects_folded_reusable_pin
    repo = scenario("folded-reusable-pin")
    stale = "0" * 40
    path = File.join(repo, ".github/workflows/ci.yml")
    File.write(path, <<~YAML)
      name: CI

      on:
        pull_request:

      permissions: {}

      jobs:
        commits:
          uses: >-
            starhaven-io/.github/.github/workflows/reusable-conventional-commits.yml@#{stale}
    YAML
    commit_all(repo, "add folded reusable pin")

    assert_rejects(["guard", guard(repo), "write every starhaven-io/.github reusable uses: as a single-line scalar"])
  end

  def test_rejects_escaped_reusable_pin
    repo = scenario("escaped-reusable-pin")
    stale = "0" * 40
    path = File.join(repo, ".github/workflows/ci.yml")
    escaped = "starhaven\\x2Dio/.github/.github/workflows/reusable\\x2Dconventional\\x2Dcommits.yml@#{stale}"
    expected = "starhaven-io/.github/.github/workflows/reusable-conventional-commits.yml@#{stale}"
    File.write(path, <<~YAML)
      name: CI

      on:
        pull_request:

      permissions: {}

      jobs:
        commits:
          uses: "#{escaped}"
    YAML

    raw = File.read(path)
    refute_includes raw.lines.grep(/uses:/).first, expected
    decoded = YAML.safe_load(raw, permitted_classes: [], aliases: false)
                  .fetch("jobs")
                  .fetch("commits")
                  .fetch("uses")
    assert_equal expected, decoded
    assert_sync_success(sync(repo, "--check"))
    commit_all(repo, "add escaped reusable pin")

    assert_rejects(["guard", guard(repo), "hidden reusable workflow pin rejected"])
  end

  def test_allows_single_line_quoted_canonical_reusable_pin
    repo = scenario("quoted-canonical-reusable-pin")
    ref = fleet_ref(repo)
    version = fleet_version(repo)
    path = File.join(repo, ".github/workflows/ci.yml")
    File.write(path, <<~YAML)
      name: CI

      on:
        pull_request:

      permissions: {}

      jobs:
        commits:
          uses: "starhaven-io/.github/.github/workflows/reusable-conventional-commits.yml@#{ref}" # #{version}
    YAML
    commit_all(repo, "add quoted canonical reusable pin")

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

  def test_rejects_symlinked_workflow_directory
    repo = scenario("symlinked-workflow-dir")
    workflows = File.join(repo, ".github/workflows")
    real = File.join(repo, ".github/workflows-real")
    FileUtils.mv(workflows, real)
    File.symlink("workflows-real", workflows)
    commit_all(repo, "symlink workflows directory")

    assert_equal File.read(File.join(real, "zizmor.yml")), File.read(File.join(workflows, "zizmor.yml"))
    assert_rejects(["guard", guard(repo), "has symlinked workflow ancestor .github/workflows"])
  end

  def test_rejects_outside_glob_symlinked_reusable_workflow
    repo = scenario("outside-glob-symlinked-workflow")
    write_ci_workflow(repo, reusable_workflow_line(repo))
    commit_all(repo, "add ci workflow with canonical pin")

    workflow = File.join(repo, ".github/workflows/ci.yml")
    outside = File.join(repo, ".github/ci-real.yml")
    FileUtils.mv(workflow, outside)
    File.symlink("../ci-real.yml", workflow)
    commit_all(repo, "symlink ci workflow outside the glob")

    assert_rejects(["guard", guard(repo), "ci.yml is not a regular file"])
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

  def test_renders_npm_policy_surfaces
    repo = scenario("npm-policy-render")
    enable_npm_policy(repo, [".", "site"])

    assert_sync_success(sync(repo))

    checker = File.join(repo, "scripts/check-npm-install-policy.mjs")
    assert_equal File.read(File.join(repo, "fleet/files/check-npm-install-policy.mjs")), File.read(checker)
    assert_includes File.read(File.join(repo, "justfile")),
                    "node scripts/check-npm-install-policy.mjs . site"
    assert_sync_success(sync(repo, "--check"))
  end

  def test_rejects_npm_policy_recipe_edit
    repo = scenario("npm-policy-recipe-edit")
    enable_npm_policy(repo, ["site"])
    assert_sync_success(sync(repo))
    commit_all(repo, "adopt npm-policy surfaces")

    path = File.join(repo, "justfile")
    File.write(path, File.read(path).sub(
                       "node scripts/check-npm-install-policy.mjs site",
                       "node scripts/check-npm-install-policy.mjs site --allow-everything"
                     ))
    commit_all(repo, "edit npm-policy recipe")

    assert_rejects(["guard", guard(repo), "fleet guard: managed surface change rejected"])
  end

  def test_rejects_npm_policy_projects_without_projects_key
    repo = scenario("npm-policy-missing-projects")
    config = fleet_config(repo)
    config.fetch("params")["npm-policy"] = { "dirs" => ["site"] }
    write_fleet_config(repo, config)

    assert_rejects(["sync", sync(repo), ".fleet.yml params.npm-policy contains unknown keys: dirs"])
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

class ConclusionContractTest < Minitest::Test
  include GuardHelpers

  def setup
    @workflow = YAML.safe_load_file(CONCLUSION_WORKFLOW, permitted_classes: [], aliases: false)
    @jobs = @workflow.fetch("jobs")
    @pinprick_audit = YAML.safe_load_file(PINPRICK_AUDIT_WORKFLOW, permitted_classes: [], aliases: false)
  end

  def test_every_pull_request_reports_exact_lowercase_conclusion
    assert_equal({ "pull_request" => nil }, @workflow.fetch(true))
    refute @jobs.fetch("changes").key?("if")

    guard = @jobs.fetch("guard")
    refute guard.key?("if")
    assert_includes guard.fetch("uses"), "/.github/workflows/reusable-fleet-guard.yml@"

    conclusion = @jobs.fetch("conclusion")
    assert_equal "conclusion", conclusion.fetch("name")
    assert_equal "${{ always() }}", conclusion.fetch("if")
    assert_equal %w[changes guard fleet audit], conclusion.fetch("needs")
  end

  def test_docs_only_change_intentionally_skips_conditional_work
    assert_equal({ "audit" => "false", "fleet" => "false" }, classify("SECURITY.md"))

    assert_conclusion_success(
      "AUDIT_REQUIRED" => "false",
      "AUDIT_RESULT" => "skipped",
      "FLEET_REQUIRED" => "false",
      "FLEET_RESULT" => "skipped"
    )
  end

  def test_guard_failure_fails_conclusion
    assert_conclusion_failure("GUARD_RESULT" => "failure")
  end

  def test_change_classification_fails_closed_on_unknown_revision
    output_path = File.join(TMPDIR, "unknown-revision-output")
    result = run_command_env(
      {
        "BASE_SHA" => "missing-base",
        "GITHUB_OUTPUT" => output_path,
        "HEAD_SHA" => "missing-head",
        "RUNNER_TEMP" => TMPDIR
      },
      ROOT,
      "bash",
      "-euo",
      "pipefail",
      "-c",
      workflow_script("changes", "Classify changed paths")
    )

    refute result.success?, "expected change classification to fail on unknown revisions"
  end

  def test_change_classification_ignores_base_only_changes
    repo = Dir.mktmpdir("conclusion-diverged-", TMPDIR)
    git(repo, "init", "-q")
    File.write(File.join(repo, "baseline"), "baseline\n")
    commit_all(repo, "baseline")
    branch_point = git(repo, "rev-parse", "HEAD").stdout.strip

    git(repo, "checkout", "-q", "-b", "pull-request")
    File.write(File.join(repo, "SECURITY.md"), "pull request\n")
    commit_all(repo, "pull request")
    head_sha = git(repo, "rev-parse", "HEAD").stdout.strip

    git(repo, "checkout", "-q", "-b", "updated-base", branch_point)
    workflow = File.join(repo, ".github/workflows/base-only.yml")
    FileUtils.mkdir_p(File.dirname(workflow))
    File.write(workflow, "name: Base only\n")
    commit_all(repo, "base-only workflow")
    base_sha = git(repo, "rev-parse", "HEAD").stdout.strip

    assert_equal(
      { "audit" => "false", "fleet" => "false" },
      classify_revisions(repo, base_sha, head_sha)
    )
  end

  def test_fleet_change_requires_validation_and_propagates_failure
    assert_equal(
      { "audit" => "false", "fleet" => "true" },
      classify("fleet/templates/fleet-guard.yml.erb")
    )
    assert_equal "needs.changes.outputs.fleet == 'true'", @jobs.fetch("fleet").fetch("if")
    assert_equal "./.github/workflows/fleet-validate.yml", @jobs.fetch("fleet").fetch("uses")

    assert_conclusion_failure(
      "FLEET_REQUIRED" => "true",
      "FLEET_RESULT" => "failure"
    )
  end

  def test_workflow_audit_gates_without_duplicating_the_sarif_upload
    assert_equal(
      { "audit" => "true", "fleet" => "true" },
      classify(".github/workflows/reusable-fleet-guard.yml")
    )
    assert_equal(
      { "audit" => "true", "fleet" => "true" },
      classify(".github/workflows/pinprick-audit.yml")
    )
    assert_equal "false", classify("SECURITY.md").fetch("audit")

    audit = @jobs.fetch("audit")
    assert_equal "needs.changes.outputs.audit == 'true'", audit.fetch("if")
    assert_includes(
      audit.fetch("uses"),
      "/.github/workflows/reusable-pinprick-audit.yml@"
    )
    assert_equal({ "contents" => "read" }, audit.fetch("permissions"))
    assert_equal false, audit.fetch("with").fetch("advanced-security")
    assert_equal true, audit.fetch("with").fetch("fail-on-findings")
    assert_equal(
      [".github/workflows/**"],
      @pinprick_audit.fetch(true).fetch("pull_request").fetch("paths")
    )

    assert_conclusion_success(
      "AUDIT_REQUIRED" => "true",
      "AUDIT_RESULT" => "success"
    )
    assert_conclusion_failure(
      "AUDIT_REQUIRED" => "true",
      "AUDIT_RESULT" => "failure"
    )
  end

  def test_cancelled_or_unexpectedly_skipped_required_work_fails_conclusion
    [
      { "CHANGES_RESULT" => "failure" },
      { "CHANGES_RESULT" => "cancelled" },
      { "CHANGES_RESULT" => "skipped" },
      { "GUARD_RESULT" => "cancelled" },
      { "GUARD_RESULT" => "skipped" },
      { "FLEET_REQUIRED" => "true", "FLEET_RESULT" => "cancelled" },
      { "FLEET_REQUIRED" => "true", "FLEET_RESULT" => "skipped" },
      { "AUDIT_REQUIRED" => "true", "AUDIT_RESULT" => "cancelled" },
      { "AUDIT_REQUIRED" => "true", "AUDIT_RESULT" => "skipped" }
    ].each do |overrides|
      assert_conclusion_failure(overrides)
    end
  end

  private

  def classify(path)
    repo = Dir.mktmpdir("conclusion-classify-", TMPDIR)
    git(repo, "init", "-q")
    File.write(File.join(repo, "baseline"), "baseline\n")
    commit_all(repo, "baseline")
    base_sha = git(repo, "rev-parse", "HEAD").stdout.strip

    changed_path = File.join(repo, path)
    FileUtils.mkdir_p(File.dirname(changed_path))
    File.write(changed_path, "changed\n")
    commit_all(repo, "change #{path}")
    head_sha = git(repo, "rev-parse", "HEAD").stdout.strip

    classify_revisions(repo, base_sha, head_sha)
  end

  def classify_revisions(repo, base_sha, head_sha)
    output_path = File.join(repo, "github-output")
    result = run_command_env(
      {
        "BASE_SHA" => base_sha,
        "GITHUB_OUTPUT" => output_path,
        "HEAD_SHA" => head_sha,
        "RUNNER_TEMP" => repo
      },
      repo,
      "bash",
      "-euo",
      "pipefail",
      "-c",
      workflow_script("changes", "Classify changed paths")
    )
    assert result.success?, result.output

    File.readlines(output_path, chomp: true).to_h { |line| line.split("=", 2) }
  end

  def assert_conclusion_success(overrides = {})
    result = run_conclusion(overrides)

    assert result.success?, result.output
  end

  def assert_conclusion_failure(overrides)
    result = run_conclusion(overrides)

    refute result.success?, "expected conclusion failure for #{overrides.inspect}"
  end

  def run_conclusion(overrides)
    defaults = {
      "AUDIT_REQUIRED" => "false",
      "AUDIT_RESULT" => "skipped",
      "CHANGES_RESULT" => "success",
      "FLEET_REQUIRED" => "false",
      "FLEET_RESULT" => "skipped",
      "GUARD_RESULT" => "success"
    }
    run_command_env(
      defaults.merge(overrides),
      ROOT,
      "bash",
      "-euo",
      "pipefail",
      "-c",
      workflow_script("conclusion", "Require merge-critical results")
    )
  end

  def workflow_script(job, step_name)
    @jobs.fetch(job).fetch("steps").find { |step| step["name"] == step_name }.fetch("run")
  end
end
