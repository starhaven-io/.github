# frozen_string_literal: true

require "minitest/autorun"
require_relative "../codecov_policy"

module CodecovPolicyFixtures
  module_function

  def workflow
    {
      "name" => "CI",
      "on" => { "push" => nil, "pull_request" => nil },
      "permissions" => {},
      "defaults" => { "run" => { "shell" => "bash -xeuo pipefail {0}" } },
      "jobs" => {
        "generate-matrix" => { "runs-on" => "ubuntu-slim", "steps" => [] },
        "check" => { "runs-on" => "ubuntu-24.04", "steps" => [] },
        "codecov" => {
          "name" => "Codecov",
          "needs" => %w[generate-matrix check],
          "if" => "needs.generate-matrix.outputs.run_codecov == 'true' && #{CodecovPolicy::SAME_REPOSITORY}",
          "runs-on" => "ubuntu-slim",
          "timeout-minutes" => 15,
          "permissions" => { "contents" => "read", "id-token" => "write" },
          "steps" => [
            {
              "name" => "Check out the trusted uploader",
              "uses" => "actions/checkout@#{"a" * 40}",
              "with" => CodecovPolicy::CHECKOUT_INPUTS.dup
            },
            {
              "name" => "Download reports",
              "uses" => "actions/download-artifact@#{"b" * 40}",
              "with" => { "name" => "coverage-reports", "path" => "reports" }
            },
            {
              "name" => "Upload reports",
              "run" => "python3 -I #{CodecovPolicy::HELPER} --coverage reports/lcov.info --junit reports/junit.xml"
            }
          ]
        },
        "conclusion" => { "needs" => %w[check codecov], "runs-on" => "ubuntu-slim", "steps" => [] }
      }
    }
  end

  def conditional_workflow
    value = workflow
    job = value.fetch("jobs").fetch("codecov")
    job["if"] = "${{ !cancelled() && #{job.fetch("if")} }}"
    job.fetch("steps").last.merge!(
      "env" => { "TEST_RESULT" => "${{ needs.check.result }}" },
      "run" => <<~BASH
        reports=(--junit reports/junit.xml)
        if [[ -f reports/lcov.info || "${TEST_RESULT}" != failure ]]; then
          reports+=(--coverage reports/lcov.info)
        fi
        python3 -I codecov-uploader/scripts/upload-codecov.py "${reports[@]}"
      BASH
    )
    value
  end
end

class CodecovPolicyTest < Minitest::Test
  def test_accepts_direct_and_failed_test_junit_uploads
    [CodecovPolicyFixtures.workflow, CodecovPolicyFixtures.conditional_workflow].each do |workflow|
      assert CodecovPolicy.validate!(workflow.to_yaml)
    end
  end

  def test_rejects_credential_and_execution_options
    mutations = {
      "additional uploader grant" => ->(w) { job(w)["permissions"]["contents"] = "write" },
      "producer OIDC grant" => ->(w) { w["jobs"]["check"]["permissions"] = { "id-token" => "write" } },
      "implicit producer OIDC grant" => ->(w) { w["jobs"]["check"]["permissions"] = "write-all" },
      "default grants" => ->(w) { w["permissions"] = { "id-token" => "write" } },
      "static token" => ->(w) { w["jobs"]["check"]["env"] = { "CODECOV_TOKEN" => "${{ secrets.CODECOV_TOKEN }}" } },
      "wrapper action" => ->(w) { w["jobs"]["check"]["steps"] = [{ "uses" => "codecov/codecov-action@#{"c" * 40}" }] },
      "job environment" => ->(w) { job(w)["environment"] = "codecov" },
      "job tolerance" => ->(w) { job(w)["continue-on-error"] = true },
      "container" => ->(w) { job(w)["container"] = "example/image:1" },
      "services" => ->(w) { job(w)["services"] = {} },
      "matrix" => ->(w) { job(w)["strategy"] = {} },
      "shell override" => ->(w) { w["defaults"]["run"]["shell"] = "sh {0}" },
      "global shell hook" => ->(w) { w["env"] = { "BASH_ENV" => "scripts/setup.sh" } }
    }
    mutations.each { |name, mutate| assert_mutation_rejected(name, &mutate) }
  end

  def test_rejects_untrusted_checkouts_and_cross_run_artifacts
    mutations = {
      "PR checkout" => ->(w) { steps(w).first["with"]["ref"] = "${{ github.sha }}" },
      "persistent credentials" => ->(w) { steps(w).first["with"]["persist-credentials"] = true },
      "broad checkout" => ->(w) { steps(w).first["with"]["sparse-checkout"] = "/scripts" },
      "cone checkout" => ->(w) { steps(w).first["with"]["sparse-checkout-cone-mode"] = true },
      "unversioned checkout" => ->(w) { steps(w).first["uses"] = "actions/checkout@main" },
      "other checkout repository" => ->(w) { steps(w).first["with"]["repository"] = "example/other" },
      "cross-run artifact" => ->(w) { steps(w)[1]["with"]["run-id"] = "1234" },
      "cross-repository artifact" => ->(w) { steps(w)[1]["with"]["repository"] = "example/other" },
      "dynamic artifact name" => ->(w) { steps(w)[1]["with"]["name"] = "${{ inputs.artifact }}" },
      "download over helper" => ->(w) { steps(w)[1]["with"]["path"] = "codecov-uploader" },
      "download traversal" => ->(w) { steps(w)[1]["with"]["path"] = "reports/../codecov-uploader" },
      "download tolerance" => ->(w) { steps(w)[1]["continue-on-error"] = true },
      "download condition" => ->(w) { steps(w)[1]["if"] = false }
    }
    mutations.each { |name, mutate| assert_mutation_rejected(name, &mutate) }
  end

  def test_rejects_extra_commands_or_different_report_selection
    mutations = {
      "extra step" => ->(w) { steps(w).insert(1, { "run" => "printf ready" }) },
      "extra command" => ->(w) { steps(w).last["run"] += "\nprintf ready\n" },
      "shell metacharacters" => ->(w) { steps(w).last["run"] += "; true" },
      "argument substitution" => ->(w) { steps(w).last["run"].sub!("reports/lcov.info", "${REPORT_FILE}") },
      "disable isolation" => ->(w) { steps(w).last["run"].sub!(" -I ", " ") },
      "report traversal" => ->(w) { steps(w).last["run"].sub!("reports/lcov.info", "reports/../source") },
      "report outside artifact" => ->(w) { steps(w)[1]["with"]["path"] = "reports/other" },
      "new helper switch" => ->(w) { steps(w).last["run"] += " --prepare" },
      "step shell override" => ->(w) { steps(w).last["shell"] = "sh" },
      "step workdir override" => ->(w) { steps(w).last["working-directory"] = "reports" }
    }
    mutations.each { |name, mutate| assert_mutation_rejected(name, &mutate) }
    workflow = CodecovPolicyFixtures.conditional_workflow
    steps(workflow).last["run"] = steps(workflow).last["run"].sub("!= failure", "== failure")
    assert_raises(CodecovPolicy::Error) { CodecovPolicy.validate!(workflow.to_yaml) }
    workflow = CodecovPolicyFixtures.conditional_workflow
    steps(workflow).last["env"]["TEST_RESULT"] = "failure"
    assert_raises(CodecovPolicy::Error) { CodecovPolicy.validate!(workflow.to_yaml) }
  end

  def test_rejects_ambiguous_yaml_and_missing_gate_relationships
    workflow = CodecovPolicyFixtures.workflow
    text = workflow.to_yaml.sub("jobs:\n", "jobs: {}\njobs:\n")
    assert_raises(CodecovPolicy::Error) { CodecovPolicy.validate!(text) }
    assert_mutation_rejected("missing aggregate dependency") { |w| w["jobs"]["conclusion"]["needs"].delete("codecov") }
    assert_mutation_rejected("unguarded fork upload") { |w| job(w)["if"] = "always()" }
    assert_mutation_rejected("missing producer dependency") { |w| job(w)["needs"] = ["missing"] }
    assert_mutation_rejected("producer omitted from dependencies") { |w| job(w)["needs"].delete("check") }
    assert_mutation_rejected("selection omitted from dependencies") { |w| job(w)["needs"].delete("generate-matrix") }
  end

  private

  def job(workflow)
    workflow.fetch("jobs").fetch("codecov")
  end

  def steps(workflow)
    job(workflow).fetch("steps")
  end

  def assert_mutation_rejected(label)
    workflow = CodecovPolicyFixtures.workflow
    yield workflow
    assert_raises(CodecovPolicy::Error, label) { CodecovPolicy.validate!(workflow.to_yaml) }
  end
end

require_relative "guard_regressions_test"

class CodecovGuardActivationTest < Minitest::Test
  include GuardHelpers

  def test_ci_only_change_is_checked_after_helper_arrives
    repo = fixture("codecov-guard-active", opted_in: true, helper: true)
    edit_ci(repo)
    result = consumer_guard(repo)

    refute result.success?, result.output
    assert_includes result.output, "Codecov CI contract rejected"
  end

  def test_does_not_block_helper_first_adoption_or_unrelated_changes
    [
      ["codecov-guard-before-helper", true, false],
      ["codecov-guard-without-opt-in", false, true]
    ].each do |name, opted_in, helper|
      repo = fixture(name, opted_in: opted_in, helper: helper)
      edit_ci(repo)
      assert_sync_success(consumer_guard(repo))
    end
    repo = fixture("codecov-guard-unrelated", opted_in: true, helper: true)
    edit_ci(repo)
    File.write(File.join(repo, "source.txt"), "unrelated source change\n")
    commit_all(repo, "change source")
    assert_sync_success(consumer_guard(repo))
  end

  private

  def assert_sync_success(result)
    assert result.success?, result.output
  end

  def fixture(name, opted_in:, helper:)
    repo = File.join(TMPDIR, name)
    run_command(TMPDIR, "git", "clone", "--quiet", "--no-hardlinks", BASE_REPO, repo)
    config = fleet_config(repo)
    config.fetch("params")["codecov"] = opted_in
    write_fleet_config(repo, config)
    assert_sync_success(sync(repo))
    path = File.join(repo, "scripts/upload-codecov.py")
    if helper
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, File.read(File.join(repo, "fleet/files/upload-codecov.py")))
    else
      FileUtils.rm_f(path)
    end
    File.write(File.join(repo, ".github/workflows/ci.yml"), CodecovPolicyFixtures.workflow.to_yaml)
    commit_all(repo, "prepare codecov guard fixture")
    repo
  end

  def edit_ci(repo)
    workflow = CodecovPolicyFixtures.workflow
    workflow.fetch("jobs").fetch("codecov")["continue-on-error"] = true
    File.write(File.join(repo, ".github/workflows/ci.yml"), workflow.to_yaml)
    commit_all(repo, "tolerate upload failure")
  end
end
