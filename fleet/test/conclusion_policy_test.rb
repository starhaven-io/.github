# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "minitest/autorun"
require_relative "../conclusion_policy"

class ConclusionPolicyTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("conclusion-policy-")
    FileUtils.mkdir_p(File.join(@root, ".github/workflows"))
    @contract = {
      "workflow" => ".github/workflows/ci.yml",
      "audit-jobs" => ["pinprick"],
      "pinprick-jobs" => ["pinprick"]
    }
    write_workflow(<<~YAML)
      name: CI
      on:
        pull_request:
          types: [opened, synchronize, reopened, edited]
      jobs:
        test:
          runs-on: ubuntu-24.04
          steps:
            - run: true
        pinprick:
          uses: starhaven-io/.github/.github/workflows/reusable-pinprick-audit.yml@0123456789012345678901234567890123456789
          with:
            fail-on-findings: true
        conclusion:
          name: conclusion
          needs: [test, pinprick]
          if: always()
          runs-on: ubuntu-slim
          steps:
            - env:
                TEST_RESULT: ${{ needs.test.result }}
                PINPRICK_RESULT: ${{ needs.pinprick.result }}
              run: test "${TEST_RESULT}" = success && test "${PINPRICK_RESULT}" = success
    YAML
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_accepts_a_complete_fail_closed_contract
    assert ConclusionPolicy.validate!(repo_root: @root, contract: @contract)
  end

  def test_rejects_an_audit_omitted_from_the_aggregate
    mutate_workflow { |text| text.sub("needs: [test, pinprick]", "needs: [test]") }

    assert_rejected("jobs omitted from the conclusion graph: pinprick")
  end

  def test_rejects_an_unclassified_job
    mutate_workflow do |text|
      text.sub("  conclusion:\n", "  advisory:\n    runs-on: ubuntu-24.04\n  conclusion:\n")
    end

    assert_rejected("jobs omitted from the conclusion graph: advisory")
  end

  def test_accepts_a_cited_noncritical_job
    mutate_workflow do |text|
      text.sub("  conclusion:\n", "  advisory:\n    runs-on: ubuntu-24.04\n  conclusion:\n")
    end
    @contract["noncritical-jobs"] = { "advisory" => "reports preview compatibility only" }

    assert ConclusionPolicy.validate!(repo_root: @root, contract: @contract)
  end

  def test_rejects_an_aggregate_that_does_not_inspect_a_dependency
    mutate_workflow { |text| text.sub("        TEST_RESULT: ${{ needs.test.result }}\n", "") }

    assert_rejected("conclusion aggregate does not inspect results for: test")
  end

  def test_rejects_a_filtered_pull_request_trigger
    mutate_workflow { |text| text.sub("    types:", "    paths: ['src/**']\n    types:") }

    assert_rejected("pull_request trigger must not filter paths")
  end

  def test_rejects_advisory_pinprick_results
    mutate_workflow { |text| text.sub("fail-on-findings: true", "fail-on-findings: false") }

    assert_rejected("pinprick must set fail-on-findings: true")
  end

  def test_rejects_a_self_repository_local_reusable_audit
    mutate_workflow do |text|
      text.sub(
        %r{starhaven-io/\.github/\.github/workflows/reusable-pinprick-audit\.yml@\d+},
        "$/.github/workflows/local-audit.yml"
      ).sub("          with:\n            fail-on-findings: true\n", "")
    end
    File.write(
      File.join(@root, ".github/workflows/local-audit.yml"),
      "on:\n  workflow_call:\njobs:\n  audit:\n    runs-on: ubuntu-24.04\n"
    )

    assert_rejected("pinprick must call the fleet pinprick audit")
  end

  def test_rejects_a_workspace_relative_local_reusable_audit
    mutate_workflow do |text|
      text.sub(
        %r{starhaven-io/\.github/\.github/workflows/reusable-pinprick-audit\.yml@\d+},
        "./.github/workflows/local-audit.yml"
      ).sub("          with:\n            fail-on-findings: true\n", "")
    end

    assert_rejected("pinprick must call the fleet pinprick audit")
  end

  private

  def workflow_path
    File.join(@root, ".github/workflows/ci.yml")
  end

  def write_workflow(text)
    File.write(workflow_path, text)
  end

  def mutate_workflow
    write_workflow(yield(File.read(workflow_path)))
  end

  def assert_rejected(message)
    error = assert_raises(ConclusionPolicy::Error) do
      ConclusionPolicy.validate!(repo_root: @root, contract: @contract)
    end
    assert_includes error.message, message
  end
end
