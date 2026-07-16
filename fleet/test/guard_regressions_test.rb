# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"
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

  def consumer_guard(repo)
    sync(repo, "--guard", "HEAD~1")
  end

  def fleet_config(repo)
    YAML.safe_load_file(File.join(repo, ".fleet.yml"), permitted_classes: [], aliases: false)
  end

  def write_fleet_config(repo, config)
    File.write(File.join(repo, ".fleet.yml"), config.to_yaml)
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
      File.write(File.join(repo, ".fleet.yml"), yaml)

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
    File.write(File.join(repo, ".fleet.yml"), "schema: [\n")
    commit_all(repo, "malformed base fleet config")

    head_config = config.merge("exceptions" => config.fetch("exceptions", {}).merge(
      "pinprick-audit" => "consumer opt-out"
    ))
    write_fleet_config(repo, head_config)
    commit_all(repo, "declassify pinprick audit")

    assert_rejects(["guard", consumer_guard(repo), "fleet guard: base .fleet.yml could not be parsed"])
  end

  def test_allows_absent_base_config_for_fleet_adoption
    repo = scenario("absent-base-config-adoption")
    config = fleet_config(repo)
    FileUtils.rm_f(File.join(repo, ".fleet.yml"))
    commit_all(repo, "remove fleet config at base")

    write_fleet_config(repo, config)
    commit_all(repo, "adopt fleet config")

    assert_sync_success(consumer_guard(repo))
  end

  def test_rejects_consumer_fleet_config_weakening_with_matching_render
    repo = scenario("consumer-config-weakening")
    config = fleet_config(repo)
    config.fetch("params").fetch("pinprick-audit")["fail-on-findings"] = false
    write_fleet_config(repo, config)
    assert_sync_success(sync(repo))
    assert_sync_success(sync(repo, "--check"))
    commit_all(repo, "weaken fleet config")

    assert_rejects(["guard", consumer_guard(repo), ".fleet.yml is hub-owned fleet configuration"])
  end

  def test_rejects_consumer_fleet_config_edit
    repo = scenario("consumer-config-edit")
    config = fleet_config(repo)
    config.fetch("params").fetch("pinprick-audit")["fail-on-findings"] = false
    write_fleet_config(repo, config)
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
