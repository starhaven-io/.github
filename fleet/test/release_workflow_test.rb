# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

class ReleaseWorkflowTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @release = YAML.safe_load_file(
      File.join(ROOT, ".github/workflows/fleet-release.yml"), permitted_classes: [], aliases: false
    )
    @sync = YAML.safe_load_file(
      File.join(ROOT, ".github/workflows/fleet-sync.yml"), permitted_classes: [], aliases: false
    )
    @link_check = YAML.safe_load_file(
      File.join(ROOT, ".github/workflows/reusable-link-check.yml"), permitted_classes: [], aliases: false
    )
    @validate = YAML.safe_load_file(
      File.join(ROOT, ".github/workflows/fleet-validate.yml"), permitted_classes: [], aliases: false
    )
  end

  def test_release_requests_queue_while_periodic_syncs_may_coalesce
    assert_equal(
      { "group" => "fleet-release", "cancel-in-progress" => false, "queue" => "max" },
      @release.fetch("concurrency")
    )
    assert_equal false, @sync.fetch("concurrency").fetch("cancel-in-progress")
    refute @sync.fetch("concurrency").key?("queue")
  end

  def test_release_pr_is_bound_to_app_owned_head_and_returned_commit
    script = step(@release, "release-pr", "Create verified release commit and open PR").fetch("run")

    assert_includes script, "COMMIT_OID=$(jq -er"
    assert_includes script, "pr_identity.rb preflight"
    assert_includes script, "verified_pull optional"
    assert_includes script, "verified_pull select"
    assert_includes script, '--head-oid "${COMMIT_OID}"'
    assert_includes script, 'gh api "repos/${REPOSITORY}/pulls" -X POST --input -'
    assert_operator script.index("pr_identity.rb preflight"), :<,
                    script.index("git/ref/heads/${BRANCH}")
    refute_includes script, "gh pr list"
    refute_includes script, "gh pr create"
    assert_includes script, "for attempt in 1 2 3 4 5"
    assert_includes script, "sleep 2"
  end

  def test_release_tag_is_monotonic_annotated_and_exactly_targeted
    compute = step(@release, "release-pr", "Compute next version").fetch("run")
    read = step(@release, "tag", "Read version").fetch("run")
    create = step(@release, "tag", "Create release tag").fetch("run")

    assert_includes compute, "--main-ref HEAD"
    assert_includes compute, 'test "${GITHUB_REF}" = "refs/heads/main"'
    assert_includes compute, 'test "$(git rev-parse HEAD)" = "${GITHUB_SHA}"'
    assert_includes read, "verify-transition"
    assert_includes create, '.object.type == "commit"'
    assert_includes create, ".object.sha == $commit"
    assert_includes create, '.message == ("Fleet " + $version)'
  end

  def test_release_tag_reads_retry_while_authentication_stays_fail_closed
    create = step(@release, "tag", "Create release tag").fetch("run")
    fetch = create[/^fetch_release_tag\(\) \{\n.*?^\}$/m]
    verify = create[/^verify_release_tag\(\) \{\n.*?^\}$/m]

    refute_nil fetch, "the tag reads must live in their own retrying helper"
    refute_nil verify

    assert_includes fetch, "for attempt in 1 2 3 4 5"
    assert_includes fetch, "sleep 2"
    assert_includes fetch, 'gh api "repos/${REPOSITORY}/git/tags/${TAG_SHA}"'
    refute_includes fetch, ".object.sha == $commit"

    assert_includes verify, "fetch_release_tag"
    assert_includes verify, ".object.sha == $commit"
    refute_includes verify, "for attempt"
  end

  def test_sync_preflights_with_main_and_renders_with_the_authenticated_release
    triggers = @sync.fetch(true)
    assert_equal ["fleet-sync"], triggers.fetch("repository_dispatch").fetch("types")
    refute triggers.key?("push")
    refute triggers.key?("workflow_dispatch")

    prepare = step(@sync, "prepare", "Authenticate release source").fetch("run")
    matrix = step(@sync, "prepare", "Build repository matrix").fetch("run")
    render = step(@sync, "sync", "Render fleet surfaces").fetch("run")
    protect = step(@sync, "sync", "Protect newer hub paths").fetch("run")
    preflight = command_block(render, "ruby tool/fleet/sync.rb")
    tagged_render = command_block(render, "ruby release/fleet/sync.rb")
    tool_checkout = step(@sync, "sync", "Checkout trusted main tooling").fetch("with")
    release_checkout = step(@sync, "sync", "Checkout authenticated release canon").fetch("with")
    consumer_checkout = step(@sync, "sync", "Checkout consumer").fetch("with")
    assert_includes prepare, "verify-tag"
    assert_includes prepare, '--main-ref "${MAIN_SHA}"'
    refute_includes prepare, "git checkout --detach"
    assert_includes matrix, '"--hub-root", "release"'
    assert_includes matrix, '"--publish"'
    assert_includes matrix, '"ruby", "fleet/sync.rb"'
    refute_includes matrix, '"ruby", "release/fleet/sync.rb"'
    refute_includes matrix, 'repos = repos.reject { |repo| repo == ".github" }'
    refute_includes matrix, "hub publication requires main to equal the authenticated release"
    assert_includes render, "ruby tool/fleet/sync.rb"
    assert_includes render, "--publication-preflight"
    assert_includes render, "ruby release/fleet/sync.rb"
    assert_operator render.index("ruby tool/fleet/sync.rb"), :<,
                    render.index("ruby release/fleet/sync.rb")
    assert_includes render, 'if [ "${REPO_NAME}" = ".github" ]'
    assert_includes render, 'test "$(git -C repo rev-parse HEAD)" = "${TRUSTED_MAIN_SHA}"'
    assert_includes render, "--publish"
    assert_includes render, "--main-ref"
    assert_includes preflight, "--publication-preflight"
    assert_includes tagged_render, "--hub-root release"
    refute_includes tagged_render, "--publish"
    refute_includes tagged_render, "--main-ref"
    refute_includes tagged_render, "--publication-preflight"
    assert_includes protect, "git -C tool diff --name-only -z --no-renames"
    assert_includes protect, "rendered & changed"
    assert_includes protect, "tagged hub render would overwrite paths changed after the authenticated release"
    assert_equal "${{ needs.prepare.outputs.main-sha }}", tool_checkout.fetch("ref")
    assert_equal "${{ needs.prepare.outputs.hub-sha }}", release_checkout.fetch("ref")
    assert_equal "${{ matrix.repo == '.github' && needs.prepare.outputs.main-sha || '' }}",
                 consumer_checkout.fetch("ref")

    steps = @sync.fetch("jobs").fetch("sync").fetch("steps")
    protect_index = steps.index { |candidate| candidate["name"] == "Protect newer hub paths" }
    mint_index = steps.index { |candidate| candidate["name"] == "Mint write token" }
    assert_operator protect_index, :<, mint_index
  end

  def test_sync_matrix_keeps_hub_when_main_is_newer_than_the_release
    Dir.mktmpdir("fleet-sync-matrix-") do |root|
      FileUtils.mkdir_p(File.join(root, "fleet"))
      FileUtils.mkdir_p(File.join(root, "release/fleet"))
      File.write(File.join(root, "fleet/sync.rb"), "")
      File.write(File.join(root, "release/fleet/repos.yml"), "repos:\n  - .github\n")
      output = File.join(root, "github-output")
      script = step(@sync, "prepare", "Build repository matrix").fetch("run")

      stdout, stderr, status = run_bash(
        script,
        cwd: root,
        env: {
          "GITHUB_OUTPUT" => output,
          "MAIN_SHA" => "main-is-newer",
          "SELECTED_REPO" => ".github"
        }
      )

      assert status.success?, "matrix failed:\n#{stdout}#{stderr}"
      matrix = JSON.parse(File.read(output).delete_prefix("matrix="))
      repos = matrix.fetch("include").map { |entry| entry.fetch("repo") }
      assert_equal [".github"], repos
    end
  end

  def test_hub_retry_rejects_only_paths_changed_after_the_release
    Dir.mktmpdir("fleet-sync-hub-overlap-") do |root|
      tool = File.join(root, "tool")
      FileUtils.mkdir_p(tool)
      git(tool, "init", "-q")
      File.write(File.join(tool, "managed.yml"), "release\n")
      File.write(File.join(tool, "notes.md"), "release\n")
      release_sha = commit_all(tool, "release")

      File.write(File.join(tool, "notes.md"), "newer main\n")
      unrelated_sha = commit_all(tool, "unrelated post-release change")
      File.binwrite(File.join(root, "changed-files.nul"), "managed.yml\0")
      script = step(@sync, "sync", "Protect newer hub paths").fetch("run")
      env = {
        "RELEASE_SHA" => release_sha,
        "RUNNER_TEMP" => root,
        "TRUSTED_MAIN_SHA" => unrelated_sha
      }

      stdout, stderr, status = run_bash(script, cwd: root, env: env)
      assert status.success?, "unrelated change blocked hub retry:\n#{stdout}#{stderr}"

      File.write(File.join(tool, "managed.yml"), "newer main\n")
      overlapping_sha = commit_all(tool, "overlapping post-release change")
      _stdout, stderr, status = run_bash(
        script,
        cwd: root,
        env: env.merge("TRUSTED_MAIN_SHA" => overlapping_sha)
      )

      refute status.success?, "overlapping hub retry unexpectedly passed"
      assert_includes stderr, '"managed.yml"'
    end
  end

  def test_sync_uses_current_main_pull_request_identity_helpers
    script = step(@sync, "sync", "Create verified sync commit and open PR").fetch("run")

    assert_includes script, "../tool/fleet/pr_identity.rb"
    refute_includes script, "../release/fleet/pr_identity.rb"
  end

  def test_release_dispatches_sync_only_after_authenticating_the_tag
    names = @release.fetch("jobs").fetch("tag").fetch("steps").map { |candidate| candidate["name"] }
    create = names.index("Create release tag")
    dispatch = names.index("Dispatch fleet sync from trusted main")
    script = step(@release, "tag", "Dispatch fleet sync from trusted main").fetch("run")

    assert_operator create, :<, dispatch
    assert_includes script, 'event_type: "fleet-sync"'
    assert_includes script, "client_payload: { version: $version }"
  end

  def test_link_build_validates_npm_policy_before_install
    steps = @link_check.fetch("jobs").fetch("lychee").fetch("steps")
    names = steps.map { |candidate| candidate["name"] }
    policy = names.index("Validate npm install policy")
    installs = names.each_index.select { |index| names[index] == "Install dependencies" }

    assert policy
    installs.each { |install| assert_operator policy, :<, install }
    assert_includes steps.fetch(policy).fetch("run"), "check-npm-install-policy.mjs"
  end

  def test_only_explicitly_private_checkout_failures_are_skipped
    private_notice = step(@validate, "dry-run", "Note skipped consumer")
    public_failure = step(@validate, "dry-run", "Reject unreadable public consumer")

    assert_equal "steps.clone.outcome == 'failure' && matrix.visibility == 'private'", private_notice.fetch("if")
    assert_equal "steps.clone.outcome == 'failure' && matrix.visibility == 'public'", public_failure.fetch("if")
    assert_includes public_failure.fetch("run"), "exit 1"
  end

  def test_consumer_workflow_audit_is_scoped_to_fleet_managed_workflows
    script = step(@validate, "dry-run", "Audit rendered workflows").fetch("run")

    assert_includes script, "--list-managed-workflows"
    assert_includes script, '> "${workflow_manifest}"'
    assert_includes script, '"${workflow_paths[@]}"'
    assert_includes script, "--offline --strict-collection --persona auditor --"
    assert_includes script, "--network none"
    assert_includes script, '"${GITHUB_WORKSPACE}/repo:/workspace:ro"'
    refute_includes script, "< <("
  end

  def test_strict_audit_images_have_one_automated_update_contract
    reusable = YAML.safe_load_file(
      File.join(ROOT, ".github/workflows/reusable-zizmor.yml"), permitted_classes: [], aliases: false
    )
    steps = [
      step(@validate, "prepare", "Audit hub workflows"),
      step(@validate, "dry-run", "Audit rendered workflows"),
      step(reusable, "zizmor", "Analyze workflows")
    ]
    images = steps.map { |candidate| candidate.fetch("env").fetch("ZIZMOR_IMAGE") }
    assert_equal 1, images.uniq.length
    steps.each { |candidate| assert_includes candidate.fetch("run"), "--strict-collection" }

    preset = JSON.parse(File.read(File.join(ROOT, "renovate-config.json")))
    manager = preset.fetch("customManagers").find { |candidate| candidate["datasourceTemplate"] == "docker" }
    refute_nil manager
    pattern = Regexp.new(manager.fetch("matchStrings").fetch(0))
    file_pattern = Regexp.new(manager.fetch("managerFilePatterns").fetch(0)[1...-1])
    matches = %w[.github/workflows/fleet-validate.yml .github/workflows/reusable-zizmor.yml].flat_map do |path|
      assert_match file_pattern, path
      File.read(File.join(ROOT, path)).scan(pattern)
    end
    assert_equal 3, matches.length
    matches.each do |name, version, digest|
      assert_equal "ghcr.io/zizmorcore/zizmor", name
      assert_match(/\A\d+\.\d+\.\d+\z/, version)
      assert_match(/\Asha256:\h{64}\z/, digest)
    end

    upload = step(reusable, "zizmor", "Upload SARIF")
    assert_equal "inputs.advanced-security", upload.fetch("if")
    assert_equal "${{ steps.analyze.outputs.sarif-file }}", upload.fetch("with").fetch("sarif_file")
  end

  def test_reusable_audit_preserves_private_failures_and_public_sarif
    reusable = YAML.safe_load_file(
      File.join(ROOT, ".github/workflows/reusable-zizmor.yml"), permitted_classes: [], aliases: false
    )
    script = step(reusable, "zizmor", "Analyze workflows").fetch("run")
    Dir.mktmpdir("fleet-zizmor-contract") do |directory|
      stub = File.join(directory, "docker")
      File.write(stub, <<~'SH')
        #!/bin/sh
        printf '%s\n' "$@" > "$ARGUMENT_LOG"
        printf 'audit report\n'
        exit "$AUDIT_STATUS"
      SH
      File.chmod(0o755, stub)
      %w[true false].product([0, 1, 3, 14]).each do |advanced, status|
        output = File.join(directory, "output")
        arguments = File.join(directory, "arguments")
        File.write(output, "")
        environment = {
          "PATH" => "#{directory}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}",
          "GITHUB_WORKSPACE" => directory, "RUNNER_TEMP" => directory, "GITHUB_OUTPUT" => output,
          "ZIZMOR_IMAGE" => "fixture-image", "ADVANCED_SECURITY" => advanced,
          "ARGUMENT_LOG" => arguments, "AUDIT_STATUS" => status.to_s
        }
        _stdout, stderr, result = run_bash(script, cwd: directory, env: environment)
        assert_equal status, result.exitstatus, stderr
        actual = File.readlines(arguments, chomp: true)
        assert_includes actual, "#{directory}:/workspace:ro"
        assert_includes actual, "--strict-collection"
        assert_equal ["--", "."], actual.last(2)
        assert_equal advanced == "true", actual.include?("sarif")
        assert_equal advanced == "true" && status.zero?, File.read(output).include?("sarif-file=")
      end
    end
  end

  def test_validator_installs_never_run_dependency_lifecycle_scripts
    prepare = step(@validate, "prepare", "Install Renovate validator").fetch("run")
    dry_run = step(@validate, "dry-run", "Install Renovate validator").fetch("run")

    assert_includes prepare, "npm ci --ignore-scripts"
    assert_includes dry_run, "npm ci --ignore-scripts"
  end

  def test_pull_request_identity_readback_is_bounded_and_retried
    release = step(@release, "release-pr", "Create verified release commit and open PR").fetch("run")
    sync = step(@sync, "sync", "Create verified sync commit and open PR").fetch("run")

    [release, sync].each do |script|
      assert_includes script, "for attempt in 1 2 3 4 5"
      assert_includes script, "sleep 2"
      assert_includes script, "verified_pull optional"
      assert_includes script, "verified_pull select"
    end
  end

  private

  def commit_all(repository, message)
    git(repository, "add", "-A")
    git(
      repository,
      "-c", "user.name=Fleet Workflow Test",
      "-c", "user.email=fleet@example.invalid",
      "-c", "commit.gpgsign=false",
      "commit", "-qm", message
    )
    git(repository, "rev-parse", "HEAD").strip
  end

  def git(repository, *arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments, chdir: repository)
    raise "git #{arguments.join(" ")} failed:\n#{stdout}#{stderr}" unless status.success?

    stdout
  end

  def run_bash(script, cwd:, env: {})
    Open3.capture3(env, "bash", "-e", "-u", "-o", "pipefail", "-c", script, chdir: cwd)
  end

  def command_block(script, command)
    lines = script.lines
    first = lines.index { |line| line.include?(command) }
    lines.drop(first).take_while { |line| !line.strip.empty? }.join
  end

  def step(workflow, job, name, uses: nil)
    workflow.fetch("jobs").fetch(job).fetch("steps").find do |candidate|
      next candidate["uses"]&.start_with?(uses) if uses

      candidate["name"] == name
    end
  end
end
