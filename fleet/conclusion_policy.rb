# frozen_string_literal: true

require "json"
require "yaml"

class ConclusionPolicy
  class Error < StandardError; end

  REQUIRED_PULL_REQUEST_TYPES = %w[opened reopened synchronize].freeze

  def self.validate!(repo_root:, contract:)
    new(repo_root:, contract:).validate!
  end

  def initialize(repo_root:, contract:)
    @repo_root = repo_root
    @contract = contract
  end

  def validate!
    workflow_path = @contract.fetch("workflow")
    full_path = File.join(@repo_root, workflow_path)
    require_value(File.file?(full_path) && !File.symlink?(full_path), "#{workflow_path} must be a regular file")

    text = File.read(full_path)
    stream = Psych.parse_stream(text)
    require_value(stream.children.one?, "#{workflow_path} must contain exactly one YAML document")
    workflow = mapping(YAML.safe_load(text, permitted_classes: [], aliases: false), workflow_path)
    validate_pull_request_trigger(mapping(workflow.fetch(true), "#{workflow_path} triggers"))

    jobs = mapping(workflow["jobs"], "#{workflow_path} jobs")
    conclusion = mapping(jobs["conclusion"], "conclusion job")
    require_value(conclusion["name"] == "conclusion", "conclusion job name must be exactly conclusion")
    require_value(normalized_condition(conclusion["if"]) == "always()", "conclusion must use if: always()")

    critical_jobs = dependency_closure(jobs, "conclusion")
    noncritical_jobs = @contract.fetch("noncritical-jobs", {})
    unclassified = jobs.keys - critical_jobs - ["conclusion"] - noncritical_jobs.keys
    require_value(unclassified.empty?, "jobs omitted from the conclusion graph: #{unclassified.sort.join(", ")}")
    misplaced = noncritical_jobs.keys & critical_jobs
    require_value(misplaced.empty?, "critical jobs cannot be declared noncritical: #{misplaced.sort.join(", ")}")
    unknown_noncritical = noncritical_jobs.keys - jobs.keys
    require_value(unknown_noncritical.empty?,
                  "declared noncritical jobs do not exist: #{unknown_noncritical.sort.join(", ")}")

    audit_jobs = @contract.fetch("audit-jobs")
    missing_audits = audit_jobs - critical_jobs
    require_value(missing_audits.empty?,
                  "merge-critical audit jobs are not in the conclusion graph: #{missing_audits.sort.join(", ")}")

    pinprick_jobs = @contract.fetch("pinprick-jobs", [])
    require_value((pinprick_jobs - audit_jobs).empty?, "pinprick-jobs must also be audit-jobs")
    pinprick_jobs.each { |job_id| validate_pinprick_job(job_id, mapping(jobs[job_id], "#{job_id} job")) }

    aggregate_jobs = ["conclusion", *@contract.fetch("intermediate-aggregates", [])]
    aggregate_jobs.each do |job_id|
      require_value(critical_jobs.include?(job_id) || job_id == "conclusion",
                    "aggregate job #{job_id} is not in the conclusion graph")
      validate_aggregate(job_id, mapping(jobs[job_id], "#{job_id} aggregate"), conclusion: job_id == "conclusion")
    end
    true
  rescue Psych::Exception => e
    raise Error, "workflow YAML could not be parsed: #{e.message}"
  end

  private

  def validate_pull_request_trigger(triggers)
    require_value(triggers.key?("pull_request"), "workflow must run on pull_request")
    pull_request = triggers["pull_request"]
    return if pull_request.nil?

    pull_request = mapping(pull_request, "pull_request trigger")
    forbidden = %w[branches branches-ignore paths paths-ignore] & pull_request.keys
    require_value(forbidden.empty?, "pull_request trigger must not filter #{forbidden.sort.join(", ")}")
    return unless pull_request.key?("types")

    types = pull_request["types"]
    require_value(types.is_a?(Array), "pull_request types must be an array")
    missing = REQUIRED_PULL_REQUEST_TYPES - types
    require_value(missing.empty?, "pull_request types omit #{missing.join(", ")}")
  end

  def dependency_closure(jobs, root)
    critical = []
    visiting = []
    visit = lambda do |job_id|
      require_value(jobs.key?(job_id), "job #{job_id} does not exist")
      require_value(!visiting.include?(job_id), "conclusion dependency graph contains a cycle at #{job_id}")
      return if critical.include?(job_id)

      visiting << job_id
      job = mapping(jobs[job_id], "#{job_id} job")
      Array(job["needs"]).each { |dependency| visit.call(dependency) }
      visiting.pop
      critical << job_id
    end
    visit.call(root)
    critical - [root]
  end

  def validate_pinprick_job(job_id, job)
    require_value(job["continue-on-error"] != true, "#{job_id} must not continue on error")
    uses = job["uses"].to_s
    # Temporary compatibility guard: relax this when the fleet-pinned Pinprick
    # can distinguish jobs.<id>.uses local workflows from step-level actions.
    require_value(uses.include?("/.github/workflows/reusable-pinprick-audit.yml@"),
                  "#{job_id} must call the fleet pinprick audit")
    require_value(job.dig("with", "fail-on-findings") == true,
                  "#{job_id} must set fail-on-findings: true")
  end

  def validate_aggregate(job_id, job, conclusion:)
    condition = normalized_condition(job["if"])
    if conclusion
      require_value(condition == "always()", "conclusion must use if: always()")
    else
      require_value(condition.start_with?("always()"), "#{job_id} aggregate must start with always()")
    end
    require_value(job["continue-on-error"] != true, "#{job_id} aggregate must not continue on error")

    dependencies = Array(job["needs"])
    require_value(dependencies.any?, "#{job_id} aggregate must have dependencies")
    serialized = JSON.generate(job)
    unread = dependencies.reject { |dependency| serialized.include?("needs.#{dependency}.result") }
    require_value(unread.empty?,
                  "#{job_id} aggregate does not inspect results for: #{unread.sort.join(", ")}")
  end

  def normalized_condition(value)
    condition = value.to_s.strip
    return condition unless condition.start_with?("${{") && condition.end_with?("}}")

    condition.delete_prefix("${{").delete_suffix("}}").strip
  end

  def mapping(value, label)
    require_value(value.is_a?(Hash), "#{label} must be a mapping")
    value
  end

  def require_value(condition, message)
    raise Error, message unless condition
  end
end
