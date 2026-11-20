# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../wait_cask_checks"

class WaitCaskChecksTest < Minitest::Test
  HEAD = "a" * 40
  BRANCH = "bump-sample-1.0"
  LINK = "https://github.com/starhaven-io/homebrew-tap/actions/runs/1/job/2"
  LATER = "2026-11-09T01:00:00Z"

  FAKE_GH = <<~'RUBY'
    require "json"

    if ARGV.first(4) == %w[api graphql --paginate --slurp]
      abort unless ARGV.include?("number=265") && ARGV.include?("head=#{"a" * 40}")
      query = ARGV.last
      abort unless query.include?("object(oid: $head)") && query.include?("isRequired(pullRequestNumber: $number)")
      counter = File.join(__dir__, "calls")
      index = File.exist?(counter) ? File.read(counter).to_i : 0
      File.write(counter, (index + 1).to_s)
      frames = JSON.parse(File.read(File.join(__dir__, "frames.json")))
      puts JSON.generate(frames.fetch(index) { frames.last })
    elsif ARGV == %w[api --paginate --slurp repos/starhaven-io/homebrew-tap/rules/branches/main]
      puts JSON.generate([[
        { type: "workflows", parameters: { workflows: [{ path: ".github/workflows/policy.yml" }] } },
        { type: "required_status_checks", parameters: { required_status_checks: [{ context: "conclusion" }],
                                                        strict_required_status_checks_policy: true } },
        { type: "pull_request", parameters: { required_approving_review_count: 0, required_review_thread_resolution: true } }
      ]])
    else
      abort "unexpected gh arguments"
    end
  RUBY

  def test_waiter_uses_only_the_called_workflow_source_and_read_token
    workflow = YAML.safe_load_file(File.expand_path("../../.github/workflows/reusable-cask-checks.yml", __dir__))
    assert_empty workflow.fetch("permissions")
    job = workflow.fetch("jobs").fetch("wait")
    assert_equal({ "contents" => "read" }, job.fetch("permissions"))
    refute job.key?("environment")
    checkout, setup, poll = job.fetch("steps")
    assert_equal "${{ job.workflow_repository }}", checkout.fetch("with").fetch("repository")
    assert_equal "${{ job.workflow_sha }}", checkout.fetch("with").fetch("ref")
    assert_equal false, checkout.fetch("with").fetch("persist-credentials")
    sparse = checkout.fetch("with").fetch("sparse-checkout").split
    assert_equal %w[fleet/.ruby-version fleet/wait_cask_checks.rb], sparse
    assert_match(%r{\Aruby/setup-ruby@[0-9a-f]{40}\z}, setup.fetch("uses"))
    guard_workflow = YAML.safe_load_file(File.expand_path("../../.github/workflows/reusable-fleet-guard.yml", __dir__))
    guard_setup = guard_workflow.fetch("jobs").fetch("guard").fetch("steps").find do |step|
      step["uses"]&.start_with?("ruby/setup-ruby@")
    end
    assert_equal guard_setup.fetch("uses"), setup.fetch("uses")
    assert_equal({ "working-directory" => "fleet" }, setup.fetch("with"))
    assert_equal "${{ github.token }}", poll.fetch("env").fetch("GH_TOKEN")
    assert_equal "ruby fleet/wait_cask_checks.rb", poll.fetch("run")
  end

  def test_discovery_pending_rerun_and_success
    status = { name: "external", state: "SUCCESS", link: LINK, required: true, createdAt: LATER }
    frames = [
      [page([])],
      [page([check("IN_PROGRESS")])],
      [page([check("FAILURE")], more: true),
       page([check(at: LATER), status, check("FAILURE", name: "optional", required: false)], "UNSTABLE")]
    ]
    output = run_wait(frames)
    assert_includes output, "IN_PROGRESS"
    assert_includes output, "UNSTABLE"
  end

  def test_passing_checks_blocked_by_rules_print_only_changes
    checks = [check, check("FAILURE", name: "secondary", required: false)]
    blocked = page(checks, "BLOCKED", reviewDecision: "REVIEW_REQUIRED")
    output = run_wait([[blocked]], tick: 750, error: /still BLOCKED/)
    assert_equal 1, output.scan("Merge state BLOCKED").size
    ["REVIEW_REQUIRED", LINK, "pull/265/checks", "/rules?ref=", "workflows/policy.yml", "secondary",
     "Required approving reviews: 0", 'Required status names: ["conclusion"]'].each do |term|
      assert_includes output, term
    end
  end

  def test_no_required_check_never_satisfies_mergeable_state
    output = run_wait([[page([check(required: false)])]], tick: 300, error: /No required checks appeared/)
    assert_includes output, "Required workflow paths"
  end

  def test_fails_for_changed_identity_or_incomplete_pages
    [{ headRefOid: "b" * 40 }, { oid: "b" * 40 }, { headRefName: "other" },
     { headRepository: { nameWithOwner: "contributor/tap" } }, { state: "CLOSED" }, { number: 3 }].each do |changed|
      run_wait([[page([check], "BLOCKED")], [page([check], **changed)]], error: /source, branch, or head/)
    end
    run_wait([[page([check], more: true)]], error: /all check pages/)
  end

  def test_unsuccessful_required_check_reports_its_link
    %w[FAILURE CANCELLED TIMED_OUT SKIPPED NEUTRAL].each do |state|
      output = run_wait([[page([check(state)])]], error: /required check did not pass/)
      assert_includes output, LINK
    end
  end

  def test_simultaneous_or_independent_checks_cannot_mask_failure
    [[check, check("FAILURE")], [check("FAILURE"), check]].each do |order|
      run_wait([[page(order)]], error: /required check did not pass/)
    end
    separate = check(at: LATER)
    separate[:checkSuite][:workflowRun][:workflow][:id] = "other-workflow"
    run_wait([[page([check("FAILURE"), separate])]], error: /required check did not pass/)
  end

  private

  def check(state = "SUCCESS", name: "conclusion", required: true, at: "2026-11-09T00:00:00Z")
    pending = FleetCaskChecks::PENDING.include?(state)
    {
      name:, status: pending ? state : "COMPLETED", conclusion: pending ? nil : state,
      link: LINK, required:, startedAt: at,
      checkSuite: { createdAt: at, app: { slug: "github-actions" },
                    workflowRun: { event: "pull_request", workflow: { id: "CI" } } }
    }
  end

  def page(checks, merge = "CLEAN", more: false, oid: HEAD, **overrides)
    pr = {
      number: 265, state: "OPEN", headRefOid: HEAD, headRefName: BRANCH,
      headRepository: { nameWithOwner: FleetCaskChecks::TAP },
      baseRefName: "main", mergeStateStatus: merge, reviewDecision: nil, isDraft: false, **overrides
    }
    contexts = { pageInfo: { hasNextPage: more, endCursor: more ? "next" : nil }, nodes: checks }
    { data: { repository: { pullRequest: pr, object: { oid:, statusCheckRollup: { contexts: } } } } }
  end

  def run_wait(frames, tick: 10, error: nil)
    path = ENV.fetch("PATH")
    Dir.mktmpdir("fleet-cask-checks") do |dir|
      gh = File.join(dir, "gh")
      File.write(gh, "#!#{RbConfig.ruby}\n#{FAKE_GH}")
      File.chmod(0o755, gh)
      File.write(File.join(dir, "frames.json"), JSON.generate(frames))
      ENV["PATH"] = [dir, path].join(File::PATH_SEPARATOR)
      elapsed = 0
      wait = lambda do
        FleetCaskChecks.wait("265", HEAD, BRANCH, now: -> { elapsed }, sleeper: ->(_seconds) { elapsed += tick })
      end
      capture_io do
        if error
          assert_match error, assert_raises(FleetCaskChecks::Error, &wait).message
        else
          wait.call
        end
      end.first
    end
  ensure
    ENV["PATH"] = path
  end
end
