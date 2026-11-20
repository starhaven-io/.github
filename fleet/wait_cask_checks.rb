# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "uri"

module FleetCaskChecks
  TAP = "starhaven-io/homebrew-tap"
  PENDING = %w[EXPECTED REQUESTED WAITING QUEUED PENDING IN_PROGRESS].freeze
  QUERY = <<~GRAPHQL
    query($number: Int!, $head: GitObjectID!, $endCursor: String) {
      repository(owner: "starhaven-io", name: "homebrew-tap") {
        pullRequest(number: $number) {
          number state headRefOid headRefName headRepository { nameWithOwner }
          baseRefName mergeStateStatus reviewDecision isDraft
        }
        object(oid: $head) {
          ... on Commit {
            oid statusCheckRollup {
              contexts(first: 100, after: $endCursor) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  ... on CheckRun {
                    name status conclusion link: detailsUrl startedAt
                    checkSuite { createdAt app { slug } workflowRun { event workflow { id } } }
                    required: isRequired(pullRequestNumber: $number)
                  }
                  ... on StatusContext {
                    name: context state link: targetUrl createdAt
                    required: isRequired(pullRequestNumber: $number)
                  }
                }
              }
            }
          }
        }
      }
    }
  GRAPHQL

  class Error < StandardError; end

  module_function

  def gh(*)
    Open3.popen2("gh", "api", *) do |input, output, child|
      input.close
      data, status = Timeout.timeout(60) { [output.read, child.value] }
      raise Error, "GitHub API read failed (gh exit #{status.exitstatus})." unless status.success?

      JSON.parse(data)
    rescue Timeout::Error
      Process.kill("KILL", child.pid) if child.alive?
      raise Error, "GitHub API read timed out."
    end
  end

  def record_check(latest, item)
    name = item.fetch("name")
    if item.key?("status")
      suite = item.fetch("checkSuite")
      run = suite.fetch("workflowRun") || {}
      key = [name, suite.dig("app", "slug"), run.dig("workflow", "id"), run["event"]]
      started = item.fetch("startedAt") || suite.fetch("createdAt")
      state = item.fetch("status") == "COMPLETED" ? item.fetch("conclusion") : item.fetch("status")
    else
      key = [name]
      started = item.fetch("createdAt")
      state = item.fetch("state")
    end

    # Reruns supersede older results. Timestamps have second precision, so
    # preserve the more restrictive result when two attempts share one.
    priority = if state == "SUCCESS"
                 0
               elsif PENDING.include?(state)
                 1
               else
                 2
               end
    rank = [started, priority]
    return if latest.key?(key) && (rank <=> latest.fetch(key).fetch(:rank)) <= 0

    check = [name, state || "UNKNOWN", item.fetch("link") || ""]
    latest[key] = { rank:, required: item.fetch("required"), check: }
  end

  def read_status(number, head, branch)
    pages = gh("graphql", "--paginate", "--slurp", "-F", "number=#{number}",
               "-f", "head=#{head}", "-f", "query=#{QUERY}")
    latest = {}
    pr = nil
    more = true
    pages.each do |page|
      repo = page.fetch("data").fetch("repository")
      pr = repo.fetch("pullRequest")
      commit = repo.fetch("object")
      unless pr && pr.fetch("number") == number && pr.fetch("state") == "OPEN" && pr.fetch("headRefOid") == head &&
             pr.fetch("headRefName") == branch && pr.dig("headRepository", "nameWithOwner") == TAP &&
             commit && commit.fetch("oid") == head
        raise Error, "The PR is closed or its validated tap source, branch, or head changed."
      end

      rollup = commit.fetch("statusCheckRollup")
      unless rollup
        raise Error, "The commit's check rollup disappeared during pagination." unless pages.one?

        more = false
        next
      end
      contexts = rollup.fetch("contexts")
      more = contexts.fetch("pageInfo").fetch("hasNextPage")
      contexts.fetch("nodes").each { |item| record_check(latest, item) }
    end
    raise Error, "GitHub did not return all check pages for the validated commit." if more

    required, other = latest.values.partition { |entry| entry.fetch(:required) }
    [pr, required.map { |entry| entry.fetch(:check) }.sort, other.map { |entry| entry.fetch(:check) }.sort]
  end

  def show_rules(base)
    encoded = URI.encode_uri_component(base)
    puts "Effective branch rules: https://github.com/#{TAP}/rules?ref=refs%2Fheads%2F#{encoded}"
    gh("--paginate", "--slurp", "repos/#{TAP}/rules/branches/#{encoded}").each do |rules|
      rules.each do |rule|
        params = rule["parameters"] || {}
        case rule.fetch("type")
        when "workflows"
          puts "Required workflow paths: #{params.fetch("workflows").map { |workflow| workflow.fetch("path") }.to_json}"
        when "required_status_checks"
          names = params.fetch("required_status_checks").map { |check| check.fetch("context") }
          puts "Required status names: #{names.to_json} " \
               "up-to-date branch required: #{params.fetch("strict_required_status_checks_policy")}"
        when "pull_request"
          puts "Required approving reviews: #{params.fetch("required_approving_review_count")} " \
               "resolved threads required: #{params.fetch("required_review_thread_resolution")}"
        end
      end
    end
  rescue Error, SystemCallError, JSON::ParserError, KeyError, TypeError
    puts "GitHub could not return rule details. Inspect the branch rules link above."
  end

  def wait(number, head, branch, now: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
           sleeper: Kernel.method(:sleep))
    unless number.match?(/\A[1-9][0-9]*\z/) && head.match?(/\A[0-9a-f]{40}\z/) && !branch.empty?
      raise Error, "Expected a positive tap PR number, a full commit SHA and its source branch."
    end

    number = Integer(number)
    url = "https://github.com/#{TAP}/pull/#{number}"
    puts "Tap PR: #{url}  Checks: #{url}/checks  Commit: #{head}"
    start = now.call
    previous = nil
    loop do
      pr, checks, other = read_status(number, head, branch)
      merge, review, draft = pr.fetch_values("mergeStateStatus", "reviewDecision", "isDraft")
      snapshot = [merge, review, draft, checks]
      if snapshot != previous
        puts "Merge state #{merge}, review #{review || "none"}, draft #{draft}. " \
             "Required checks (name, state, link): #{checks.to_json}"
        previous = snapshot
      end
      states = checks.map { |_name, state, _link| state }.uniq
      unless (states - PENDING - ["SUCCESS"]).empty?
        raise Error, "A required check did not pass. Inspect its result above or #{url}/checks."
      end

      elapsed = now.call - start
      if elapsed >= 1500 || (checks.empty? && elapsed >= 300)
        puts "Other checks reported on the validated commit (name, state, link): #{other.to_json}"
        show_rules(pr.fetch("baseRefName"))
        reason = checks.empty? ? "No required checks appeared" : "Tap branch policy is still #{merge}"
        raise Error, "#{reason}. Inspect checks, required workflows and review requirements on #{url}."
      end
      return if states == ["SUCCESS"] && !draft && %w[CLEAN UNSTABLE].include?(merge)

      sleeper.call(10)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  begin
    FleetCaskChecks.wait(ENV.fetch("PR_NUMBER"), ENV.fetch("HEAD_SHA"), ENV.fetch("HEAD_BRANCH"))
  rescue FleetCaskChecks::Error, SystemCallError, JSON::ParserError, KeyError, ArgumentError, TypeError => e
    abort "Cask checks failed: #{e.message}"
  end
end
