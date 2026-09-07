# frozen_string_literal: true

require "yaml"

# This deliberately accepts a small uploader vocabulary, not arbitrary shell.
class CodecovPolicy
  class Error < StandardError; end

  HELPER = "codecov-uploader/scripts/upload-codecov.py"
  TRUSTED_REF = "${{ github.event.pull_request.base.sha || github.sha }}"
  SAME_REPOSITORY = "(github.event_name == 'push' || " \
                    "github.event.pull_request.head.repo.full_name == github.repository)"
  PREREQUISITES = [
    "needs.generate-matrix.outputs.run_codecov == 'true'",
    "needs.generate-matrix.outputs.coverage == 'true'",
    "needs.engine.result == 'success' && needs.site.result == 'success'"
  ].freeze
  JOB_KEYS = %w[name needs if runs-on timeout-minutes permissions steps].freeze
  CHECKOUT_INPUTS = {
    "ref" => TRUSTED_REF,
    "persist-credentials" => false,
    "sparse-checkout" => "/scripts/upload-codecov.py",
    "sparse-checkout-cone-mode" => false,
    "path" => "codecov-uploader"
  }.freeze
  CONDITIONAL_UPLOAD = %r{
    \Areports=\(--junit\ (?<junit>reports/[A-Za-z0-9_./-]+)\)\n
    if\ \[\[\ -f\ (?<coverage>reports/[A-Za-z0-9_./-]+)\ \|\|\ "\$\{TEST_RESULT\}"\ !=\ failure\ \]\];\ then\n
    [\t\ ]+reports\+=\(--coverage\ \k<coverage>\)\n
    fi\n
    python3\ -I\ codecov-uploader/scripts/upload-codecov\.py\ "\$\{reports\[@\]\}"\z
  }x

  def self.validate!(text)
    new.validate!(text)
  end

  def validate!(text)
    stream = Psych.parse_stream(text)
    require_value(stream.children.one?, "CI must contain exactly one YAML document")
    reject_ambiguous_yaml(stream)
    workflow = YAML.safe_load(text, permitted_classes: [], aliases: false)
    mapping(workflow, "CI")
    reject_token_references(workflow)
    require_value(workflow["permissions"] == {}, "CI must have empty default permissions")
    require_value(workflow["defaults"] == { "run" => { "shell" => "bash -xeuo pipefail {0}" } },
                  "CI must retain the strict Bash default for the uploader")
    allowed_env = [{}, { "CARGO_INCREMENTAL" => 0 }, { "CARGO_INCREMENTAL" => "0" }]
    require_value(allowed_env.include?(workflow.fetch("env", {})),
                  "CI global environment must not alter the isolated uploader")
    jobs = mapping(workflow["jobs"], "CI jobs")
    jobs.each do |name, candidate|
      mapping(candidate, "CI job #{name}")
      next if name == "codecov"

      permissions = candidate.fetch("permissions", {})
      require_value(permissions.is_a?(Hash) && permissions["id-token"] != "write",
                    "only the codecov CI job may grant id-token: write")
    end
    conclusion = mapping(jobs["conclusion"], "conclusion job")
    require_value(Array(conclusion["needs"]).include?("codecov"), "conclusion must depend on codecov")
    validate_job(mapping(jobs["codecov"], "codecov job"), jobs)
    true
  rescue Psych::Exception => e
    raise Error, "CI YAML could not be parsed: #{e.message}"
  end

  private

  def validate_job(job, jobs)
    allowed_keys(job, JOB_KEYS, "codecov job")
    require_value(job["permissions"] == { "contents" => "read", "id-token" => "write" },
                  "codecov permissions must be exactly contents: read and id-token: write")
    require_value(%w[ubuntu-slim ubuntu-24.04].include?(job["runs-on"]), "codecov must use a supported Ubuntu runner")
    require_value(job["timeout-minutes"].is_a?(Integer) && job["timeout-minutes"].between?(1, 15),
                  "codecov timeout must be between 1 and 15 minutes")
    needs = job["needs"]
    require_value(needs.is_a?(Array) && needs.any? && needs.all? { |name| jobs.key?(name) },
                  "codecov must depend on existing report producer jobs")
    condition = job["if"].to_s.strip
    if condition.start_with?("${{")
      require_value(condition.end_with?("}}"), "codecov condition has an unclosed expression")
      condition = condition.delete_prefix("${{").delete_suffix("}}").strip
    end
    condition = condition.delete_prefix("!cancelled() && ")
    prerequisite = PREREQUISITES.find { |prefix| condition == "#{prefix} && #{SAME_REPOSITORY}" }
    require_value(prerequisite, "codecov must use a supported source selection and same-repository condition")
    required_jobs = prerequisite.start_with?("needs.engine.") ? %w[engine site] : %w[generate-matrix check]
    require_value((required_jobs - needs).empty?, "codecov must await its source selection and report producers")
    steps = job["steps"]
    require_value(steps.is_a?(Array) && steps.length >= 3, "codecov must checkout, download reports, then upload")
    validate_checkout(mapping(steps.first, "uploader checkout"))
    directories = steps[1...-1].map { |step| validate_download(mapping(step, "report download")) }
    paths = validate_upload(mapping(steps.last, "report upload"))
    paths.each do |path|
      require_value(directories.any? { |directory| path.start_with?("#{directory}/") },
                    "uploader report paths must be beneath named same-run artifact destinations")
    end
  end

  def validate_checkout(step)
    allowed_keys(step, %w[name uses with], "uploader checkout")
    require_value(step["uses"].to_s.match?(%r{\Aactions/checkout@[a-f0-9]{40}\z}),
                  "uploader checkout must use SHA-pinned actions/checkout")
    require_value(step["with"] == CHECKOUT_INPUTS, "uploader checkout must contain only the trusted sparse helper")
  end

  def validate_download(step)
    allowed_keys(step, %w[name uses with], "report download")
    require_value(step["uses"].to_s.match?(%r{\Aactions/download-artifact@[a-f0-9]{40}\z}),
                  "report downloads must use SHA-pinned actions/download-artifact")
    inputs = mapping(step["with"], "report download inputs")
    require_value(inputs.keys.sort == %w[name path], "report downloads must use only a same-run artifact name and path")
    require_value(inputs["name"].is_a?(String) && inputs["name"].match?(/\A[A-Za-z0-9_.-]+\z/),
                  "report artifact names must be literal")
    path = inputs["path"]
    require_value(path == "reports" || report_path?(path), "report downloads must stay under reports/")
    path
  end

  def validate_upload(step)
    allowed_keys(step, %w[name run env], "report upload")
    script = step["run"].to_s.strip
    if (match = CONDITIONAL_UPLOAD.match(script))
      require_value(step["env"] == { "TEST_RESULT" => "${{ needs.check.result }}" },
                    "conditional report selection must use the test job result")
      paths = [match[:coverage], match[:junit]]
    else
      require_value(!step.key?("env"), "the direct helper invocation must not receive extra environment")
      require_value(!script.include?("\n"), "direct uploads must use one folded helper command")
      tokens = script.split(/\s+/)
      require_value(tokens.shift(3) == ["python3", "-I", HELPER], "upload must invoke only the isolated managed helper")
      require_value(tokens.any? && tokens.length.even?, "upload must name at least one explicit report")
      paths = tokens.each_slice(2).map do |option, path|
        require_value(%w[--coverage --junit].include?(option),
                      "upload accepts only coverage and JUnit report arguments")
        path
      end
    end
    require_value(paths.all? { |path| report_path?(path) }, "upload report paths must be literal paths under reports/")
    paths
  end

  def report_path?(path)
    path.is_a?(String) && path.match?(%r{\Areports/[A-Za-z0-9_./-]+\z}) &&
      !path.split("/").intersect?(["", ".", ".."])
  end

  def reject_token_references(value)
    case value
    when Hash
      value.each do |key, child|
        reject_token_references(key)
        reject_token_references(child)
      end
    when Array
      value.each { |child| reject_token_references(child) }
    when String
      require_value(!value.match?(/\bCODECOV_TOKEN\b/), "CI must not reference static CODECOV_TOKEN credentials")
      require_value(!value.match?(%r{\Acodecov/[^\s]+@}),
                    "CI must use the managed uploader instead of Codecov wrapper actions")
    end
  end

  def reject_ambiguous_yaml(node)
    require_value(!node.is_a?(Psych::Nodes::Alias), "CI must not use YAML aliases")
    if node.is_a?(Psych::Nodes::Mapping)
      keys = node.children.each_slice(2).map do |key, _|
        require_value(key.is_a?(Psych::Nodes::Scalar), "CI mapping keys must be scalars")
        key.value
      end
      require_value(!keys.include?("<<") && keys.uniq == keys, "CI must not contain duplicate or merged YAML keys")
    end
    (node.children || []).each { |child| reject_ambiguous_yaml(child) }
  end

  def mapping(value, label)
    require_value(value.is_a?(Hash), "#{label} must be a mapping")
    value
  end

  def allowed_keys(value, keys, label)
    require_value((value.keys - keys).empty?, "#{label} contains unsupported execution or credential options")
  end

  def require_value(condition, message)
    raise Error, message unless condition
  end
end
