#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "erb"
require "fileutils"
require "json"
require "optparse"
require "open3"
require "yaml"

class FleetError < StandardError; end

class TemplateContext
  def initialize(locals)
    locals.each do |key, value|
      define_singleton_method(key) { value }
    end
  end

  def scalar(value)
    value = value.to_s
    return "\"\"" if value.empty?

    if value.include?("\n")
      indented = value.lines.map { |line| line == "\n" ? line : "        #{line}" }.join
      "|-\n#{indented}"
    else
      "\"#{value.gsub(/["\\]/) { |char| "\\#{char}" }}\""
    end
  end

  def single_quoted(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end
end

class FleetSync
  SAME_ORG_ADVANCED_SECURITY =
    "${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository }}"

  TIER1_FILES = {
    ".editorconfig" => "files/editorconfig",
    ".githooks/commit-msg" => "files/commit-msg",
    ".githooks/pre-push" => "files/pre-push",
    "CLAUDE.md" => "files/CLAUDE.md"
  }.freeze

  OPTIONAL_TIER1_FILES = {
    "zizmor-config" => [".github/zizmor.yml", "files/zizmor-config.yml"]
  }.freeze

  EXECUTABLE_PATHS = [
    ".githooks/commit-msg",
    ".githooks/pre-push"
  ].freeze

  LICENSE_FILES = {
    "agpl" => "files/licenses/agpl",
    "mit" => "files/licenses/mit"
  }.freeze

  DEPENDABOT_GROUPS = {
    "github-actions" => "github-actions",
    "cargo" => "cargo-dependencies",
    "npm" => "npm-dependencies",
    "swift" => "swift-dependencies",
    "terraform" => "terraform"
  }.freeze

  attr_reader :changes

  def initialize(hub_root:, repo_root:, repo_name:, check:, bootstrap:, guard_base:)
    @hub_root = Pathname(hub_root).expand_path
    @repo_root = Pathname(repo_root).expand_path
    @repo_name = repo_name
    @check = check || !guard_base.nil?
    @bootstrap = bootstrap
    @guard_base = guard_base
    @changes = []
  end

  def run
    config = load_config
    validate_config(config)

    return run_guard(config) if @guard_base

    render_all(config)
    report_changes
    raise FleetError, "fleet sync drift detected" if @check && @changes.any?
  end

  private

  def render_all(config)
    render_tier1(config)
    render_tier2(config)
    render_tier3(config)
  end

  def run_guard(config)
    managed_changes = changed_managed_surfaces(config)
    return if managed_changes.empty?

    @changes.clear
    begin
      render_all(config)
    rescue FleetError
      raise FleetError, guard_failure_message(managed_changes)
    end

    # Only surfaces this pull request touched can fail it; drift that
    # predates the branch belongs to the sync, not to the author.
    touched = guard_changed_paths
    flagged = @changes.select { |surface| touched.include?(surface.split(":").first) }
    raise FleetError, guard_failure_message(flagged) if flagged.any?
  end

  def load_config
    path = repo_path(".fleet.yml")
    return YAML.safe_load(read_path(path), permitted_classes: [], aliases: false) if path.file?

    raise FleetError, ".fleet.yml is missing; rerun with --bootstrap to seed it" unless @bootstrap

    config = derive_config
    write_file(".fleet.yml", dump_config(config), ".fleet.yml")
    config
  end

  def validate_config(config)
    raise FleetError, ".fleet.yml must be a mapping" unless config.is_a?(Hash)
    raise FleetError, ".fleet.yml schema must be 1" unless config["schema"] == 1

    license = config["license"]
    raise FleetError, ".fleet.yml license must be agpl, mit, or none" unless %w[agpl mit none].include?(license)

    params = config["params"] || {}
    exceptions = config["exceptions"] || {}
    raise FleetError, ".fleet.yml params must be a mapping" unless params.is_a?(Hash)
    raise FleetError, ".fleet.yml exceptions must be a mapping" unless exceptions.is_a?(Hash)
  end

  def render_tier1(config)
    TIER1_FILES.each do |dest, source|
      write_file(dest, read_path(hub_path(source)), dest)
    end

    license = config.fetch("license")
    write_file("LICENSE", read_path(hub_path(LICENSE_FILES.fetch(license))), "LICENSE") if license != "none"

    params = config.fetch("params", {})
    write_file(".mcp.json", read_path(hub_path("files/mcp.json")), ".mcp.json") if params["astro-docs"]
    render_optional_tier1(params)

    EXECUTABLE_PATHS.each do |path|
      chmod_executable(path)
    end
  end

  def render_optional_tier1(params)
    OPTIONAL_TIER1_FILES.each do |param, (dest, source)|
      write_file(dest, read_path(hub_path(source)), dest) if params[param]
    end
  end

  def render_tier2(config)
    params = config.fetch("params", {})

    replace_marked_block(
      "AGENTS.md",
      "commit-and-pr-conventions",
      :markdown,
      read_path(hub_path("blocks/commit-and-pr-conventions.md"))
    )

    replace_marked_block(
      ".gitignore",
      "local-state",
      :hash,
      read_path(hub_path("blocks/local-state.gitignore"))
    )

    replace_just_recipe("install-hooks", read_path(hub_path("blocks/install-hooks.just")))
    replace_just_recipe("audit", read_path(hub_path("blocks/audit.just"))) unless exception?(config, "audit")
    unless exception?(config, "pinprick-audit-recipe")
      replace_just_recipe("pinprick-audit", read_path(hub_path("blocks/pinprick-audit.just")))
    end

    readme = params["readme"] || {}
    if readme["badges"]
      badges = render_template(
        "readme-badges.md.erb",
        repo_name: repo_name_for_urls,
        workflow: readme.fetch("badges").fetch("workflow"),
        license: config.fetch("license"),
        extra_badges: readme.fetch("badges").fetch("extra", [])
      )
      replace_marked_block("README.md", "badges", :markdown, badges)
    end

    return unless readme["license"]

    license_block = readme.fetch("license")
    body = render_template(
      "readme-license.md.erb",
      license: config.fetch("license"),
      license_text: license_block["text"],
      extra_license_lines: license_block.fetch("extra", [])
    )
    replace_marked_block("README.md", "license-section", :markdown, body)
  end

  def render_tier3(config)
    params = config.fetch("params", {})

    render_fleet_guard

    if params["dependabot"]
      write_file(
        ".github/dependabot.yml",
        render_template("dependabot.yml.erb", dependabot_entries: dependabot_entries(params.fetch("dependabot"))),
        ".github/dependabot.yml"
      )
    end

    render_zizmor(params.fetch("zizmor", {})) unless exception?(config, "zizmor")
    render_pinprick_audit(params.fetch("pinprick-audit", {}), config) unless exception?(config, "pinprick-audit")
    render_link_check(params.fetch("link-check")) if params["link-check"]
    render_codeql(params, config) unless exception?(config, "codeql")
  end

  def render_fleet_guard
    ref, version = reusable_pin
    write_file(
      ".github/workflows/fleet-guard.yml",
      render_template(
        "fleet-guard.yml.erb",
        reusable_ref: ref,
        reusable_version: version
      ),
      ".github/workflows/fleet-guard.yml"
    )
  end

  def render_zizmor(zizmor_config)
    timeout_minutes = zizmor_config.fetch("timeout-minutes", 15)
    ref, version = reusable_pin
    write_file(
      ".github/workflows/zizmor.yml",
      render_template(
        "zizmor.yml.erb",
        reusable_ref: ref,
        reusable_version: version,
        push_paths: zizmor_config.fetch("push-paths", []),
        schedule: zizmor_config["schedule"],
        timeout_minutes: timeout_minutes
      ),
      ".github/workflows/zizmor.yml"
    )
  end

  def render_pinprick_audit(pinprick_config, _config)
    advanced_security = pinprick_config.fetch("advanced-security", SAME_ORG_ADVANCED_SECURITY)
    advanced_security = advanced_security == "true" if %w[true false].include?(advanced_security)
    fail_on_findings = pinprick_config.fetch("fail-on-findings", true)
    push_paths = pinprick_config.fetch("push-paths", nil)
    timeout_minutes = pinprick_config.fetch("timeout-minutes", 15)

    ref, version = reusable_pin
    write_file(
      ".github/workflows/pinprick-audit.yml",
      render_template(
        "pinprick-audit.yml.erb",
        reusable_ref: ref,
        reusable_version: version,
        advanced_security: advanced_security,
        fail_on_findings: fail_on_findings,
        push_paths: push_paths,
        timeout_minutes: timeout_minutes
      ),
      ".github/workflows/pinprick-audit.yml"
    )
  end

  def render_link_check(link_config)
    ref, version = reusable_pin
    write_file(
      ".github/workflows/link-check.yml",
      render_template(
        "link-check.yml.erb",
        reusable_ref: ref,
        reusable_version: version,
        args: link_config.fetch("targets"),
        build_site: link_config.fetch("build-site", false),
        site_directory: link_config.fetch("site-directory", ""),
        authenticated_github: link_config.fetch("authenticated-github", false),
        schedule: link_config.fetch("schedule", "0 14 * * 1"),
        pull_request_paths: link_config.fetch("pull-request-paths", []),
        concurrency_group: link_config.fetch("concurrency-group", "link-check")
      ),
      ".github/workflows/link-check.yml"
    )
  end

  def render_codeql(params, _config)
    codeql = params["codeql"] || {}
    languages = codeql["languages"] || params["codeql-languages"]
    return unless languages

    ref, version = reusable_pin
    write_file(
      ".github/workflows/codeql.yml",
      render_template(
        "codeql.yml.erb",
        reusable_ref: ref,
        reusable_version: version,
        languages_json: JSON.generate(languages),
        paths: codeql.fetch("paths", []),
        schedule: codeql["schedule"],
        runner: codeql.fetch("runner", default_codeql_runner(languages)),
        timeout_minutes: codeql.fetch("timeout-minutes", 30),
        build_mode: codeql.fetch("build-mode", ""),
        build_profile: codeql.fetch("build-profile", "")
      ),
      ".github/workflows/codeql.yml"
    )
  end

  def derive_config
    config = {
      "schema" => 1,
      "license" => derive_license,
      "params" => {},
      "exceptions" => {}
    }

    params = config.fetch("params")
    params["astro-docs"] = true if repo_path(".mcp.json").file?
    params["zizmor-config"] = true if repo_path(".github/zizmor.yml").file?

    params["dependabot"] = derive_dependabot if repo_path(".github/dependabot.yml").file?

    params["link-check"] = derive_link_check if repo_path(".github/workflows/link-check.yml").file?

    params["codeql"] = derive_codeql if repo_path(".github/workflows/codeql.yml").file?

    if repo_path(".github/workflows/pinprick-audit.yml").file? && repo_name_for_urls != "pinprick"
      params["pinprick-audit"] = derive_pinprick_audit
    end

    if repo_path(".github/workflows/zizmor.yml").file? && repo_name_for_urls != "orrery"
      zizmor = derive_zizmor
      params["zizmor"] = zizmor unless zizmor.empty?
    end

    readme = derive_readme
    params["readme"] = readme unless readme.empty?

    if repo_name_for_urls == "pinprick"
      config.fetch("exceptions")["pinprick-audit"] =
        "build-from-source: audits the local checkout (GRAND_PARITY_PASS.md P0.2)"
      config.fetch("exceptions")["pinprick-audit-recipe"] =
        "build-from-source: audits the local checkout (GRAND_PARITY_PASS.md P0.2)"
    elsif repo_name_for_urls == "pinprick-action"
      config.fetch("exceptions")["pinprick-audit"] =
        "self-test: the action validates pinprick behavior through its dedicated workflow"
    end

    if repo_name_for_urls == "orrery"
      config.fetch("exceptions")["codeql"] = "terraform-only private infra; tofu.yml owns IaC validation"
      config.fetch("exceptions")["zizmor"] =
        "private repo without GHAS: no SARIF upload; zizmor.yml is a hand-rolled direct gate"
    end

    config
  end

  def derive_license
    license_path = repo_path("LICENSE")
    return "none" unless license_path.file?

    content = read_path(license_path)
    LICENSE_FILES.each do |name, relative|
      return name if content == read_path(hub_path(relative))
    end

    raise FleetError, "LICENSE does not match a canonical fleet license"
  end

  def derive_dependabot
    data = YAML.safe_load(read_path(repo_path(".github/dependabot.yml")), permitted_classes: [], aliases: false)
    data.fetch("updates").map do |entry|
      normalized = {
        "package-ecosystem" => entry.fetch("package-ecosystem"),
        "group" => entry.fetch("groups").keys.first
      }
      normalized["directory"] = entry["directory"] if entry["directory"]
      normalized["directories"] = entry["directories"] if entry["directories"]
      normalized["allow"] = entry["allow"] if entry["allow"]
      normalized
    end
  end

  def derive_link_check
    path = ".github/workflows/link-check.yml"
    data = workflow_data(path)
    if (caller = reusable_caller(data, "link-check"))
      with = caller.fetch("with", {})
      return {
        "targets" => with.fetch("args", "README.md"),
        "build-site" => with.fetch("build-site", false),
        "site-directory" => with.fetch("site-directory", "").to_s,
        "authenticated-github" => with.fetch("authenticated-github", false),
        "schedule" => workflow_schedule(data) || "0 14 * * 1",
        "pull-request-paths" => workflow_paths(data, "pull_request"),
        "concurrency-group" => workflow_concurrency_group(data) || "link-check"
      }.reject { |_key, value| blank?(value) }
    end

    text = read_path(repo_path(path))
    {
      "targets" => unquote_scalar(text[/^\s+args:\s*(.+)$/, 1]&.strip) || "README.md",
      "build-site" => text.include?("npm run build"),
      "site-directory" => text[/working-directory:\s*([^\s]+)/, 1].to_s,
      "authenticated-github" => text.include?("GITHUB_TOKEN: ${{ github.token }}"),
      "schedule" => text[/cron:\s*"([^"]+)"/, 1] || "0 14 * * 1",
      "pull-request-paths" => extract_list_after(text, "pull_request", "paths"),
      "concurrency-group" => text[/^\s+group:\s*(.+)$/, 1]&.strip || "link-check"
    }.reject { |_key, value| blank?(value) }
  end

  def derive_codeql
    path = ".github/workflows/codeql.yml"
    data = workflow_data(path)
    if (caller = reusable_caller(data, "codeql"))
      with = caller.fetch("with", {})
      languages = parse_json_array(with.fetch("languages"))
      return {
        "languages" => languages,
        "paths" => workflow_paths(data, "push"),
        "runner" => with["runner"] || default_codeql_runner(languages),
        "timeout-minutes" => with.fetch("timeout-minutes", 30),
        "build-mode" => with.fetch("build-mode", "").to_s,
        "build-profile" => with.fetch("build-profile", "").to_s,
        "schedule" => workflow_schedule(data)
      }.reject { |_key, value| blank?(value) }
    end

    text = read_path(repo_path(path))
    languages =
      if (matrix = text[/language:\s*\[([^\]]+)\]/, 1])
        matrix.split(",").map(&:strip)
      else
        [text[/^\s+languages:\s*([a-z-]+)$/, 1]].compact
      end

    {
      "languages" => languages,
      "paths" => extract_list_after(text, "push", "paths"),
      "runner" => text[/^\s+runs-on:\s*([^\s]+)$/, 1] || default_codeql_runner(languages),
      "timeout-minutes" => (text[/^\s+timeout-minutes:\s*(\d+)$/, 1] || "30").to_i,
      "build-mode" => unquote_scalar(text[/^\s+build-mode:\s*([^\s]+)$/, 1]).to_s,
      "build-profile" => extract_build_profile(text),
      "schedule" => text[/cron:\s*"([^"]+)"/, 1]
    }.reject { |_key, value| blank?(value) }
  end

  def derive_pinprick_audit
    path = ".github/workflows/pinprick-audit.yml"
    data = workflow_data(path)
    if (caller = reusable_caller(data, "pinprick-audit"))
      with = caller.fetch("with", {})
      return {
        "advanced-security" => derived_advanced_security(with.fetch("advanced-security", SAME_ORG_ADVANCED_SECURITY)),
        "fail-on-findings" => with.fetch("fail-on-findings", true),
        "timeout-minutes" => derived_timeout_from_value(with.fetch("timeout-minutes", 15)),
        "push-paths" => workflow_paths(data, "push")
      }.reject { |_key, value| blank?(value) }
    end

    text = read_path(repo_path(path))
    {
      "advanced-security" => text[/^\s+advanced-security:\s*(.+)$/, 1]&.strip || SAME_ORG_ADVANCED_SECURITY,
      "fail-on-findings" => (text[/^\s+fail-on-findings:\s*(.+)$/, 1]&.strip || "true") == "true",
      "timeout-minutes" => derived_timeout(text),
      "push-paths" => extract_push_paths_after_push(text)
    }.reject { |_key, value| blank?(value) }
  end

  def derive_zizmor
    path = ".github/workflows/zizmor.yml"
    data = workflow_data(path)
    if (caller = reusable_caller(data, "zizmor"))
      with = caller.fetch("with", {})
      return {
        "push-paths" => workflow_paths(data, "push").reject { |path| path == ".github/workflows/**" },
        "schedule" => workflow_schedule(data),
        "timeout-minutes" => derived_timeout_from_value(with.fetch("timeout-minutes", 15))
      }.reject { |_key, value| blank?(value) }
    end

    text = read_path(repo_path(path))
    {
      "push-paths" => extract_list_after(text, "push", "paths").reject { |path| path == ".github/workflows/**" },
      "schedule" => text[/cron:\s*"([^"]+)"/, 1],
      "timeout-minutes" => derived_timeout(text)
    }.reject { |_key, value| blank?(value) }
  end

  def derived_timeout(text)
    timeout = (text[/^\s+timeout-minutes:\s*(\d+)$/, 1] || "15").to_i
    timeout == 15 ? nil : timeout
  end

  def derived_timeout_from_value(value)
    timeout = value.to_i
    timeout == 15 ? nil : timeout
  end

  def derived_advanced_security(value)
    return value.to_s if [true, false].include?(value)

    value
  end

  def derive_readme
    path = repo_path("README.md")
    return {} unless path.file?

    text = read_path(path)
    result = {}

    badges_text = marked_block_body(text, "badges") || text
    badge_lines = badges_text.lines.select { |line| line.start_with?("[![") }.map(&:chomp)
    ci_badge = badge_lines.find { |line| line.include?("/actions/workflows/") }
    if ci_badge
      workflow = ci_badge[%r{/actions/workflows/([^/]+)/badge\.svg}, 1]
      extra = badge_lines.reject do |line|
        line == ci_badge || line.include?("License-AGPL--3.0--only") || line.include?("License-MIT")
      end
      result["badges"] = { "workflow" => workflow, "extra" => extra }
    end

    license_text = marked_block_body(text, "license-section") || text
    if (section = license_text[/^## License\n\n.*?(?=^## |\z)/m])
      body = section.sub(/^## License\n\n/, "").strip
      default = default_readme_license(config_license: derive_license)
      result["license"] = body == default ? {} : { "text" => body }
    end

    result
  end

  def changed_managed_surfaces(config)
    changed_paths = guard_changed_paths
    return [] if changed_paths.empty?

    managed = []
    whole_files = managed_whole_files(config)
    changed_paths.each do |path|
      managed << path if whole_files.include?(path)
    end

    guard_managed_blocks(config).each do |block|
      next unless changed_paths.include?(block.fetch(:path))

      base_block = guard_base_block(block)
      current_block = current_marked_block(block)
      managed << "#{block.fetch(:path)}:#{block.fetch(:name)}" if base_block != current_block
    end

    managed.uniq.sort
  end

  def managed_whole_files(config)
    params = config.fetch("params", {})
    files = TIER1_FILES.keys
    files << "LICENSE" unless config.fetch("license") == "none"
    files << ".mcp.json" if params["astro-docs"]
    OPTIONAL_TIER1_FILES.each do |param, (dest, _source)|
      files << dest if params[param]
    end

    files << ".github/workflows/fleet-guard.yml"
    files << ".github/dependabot.yml" if params["dependabot"]
    files << ".github/workflows/zizmor.yml" unless exception?(config, "zizmor")
    files << ".github/workflows/pinprick-audit.yml" unless exception?(config, "pinprick-audit")
    files << ".github/workflows/link-check.yml" if params["link-check"]
    files << ".github/workflows/codeql.yml" if (params["codeql"] || {})["languages"] || params["codeql-languages"]
    files
  end

  def guard_managed_blocks(config)
    params = config.fetch("params", {})
    blocks = [
      { path: "AGENTS.md", name: "commit-and-pr-conventions", style: :markdown },
      { path: ".gitignore", name: "local-state", style: :hash },
      { path: "justfile", name: "install-hooks", style: :hash }
    ]
    blocks << { path: "justfile", name: "audit", style: :hash } unless exception?(config, "audit")
    blocks << { path: "justfile", name: "pinprick-audit", style: :hash } unless exception?(config,
                                                                                           "pinprick-audit-recipe")

    readme = params["readme"] || {}
    blocks << { path: "README.md", name: "badges", style: :markdown } if readme["badges"]
    blocks << { path: "README.md", name: "license-section", style: :markdown } if readme["license"]
    blocks
  end

  def guard_changed_paths
    return @guard_changed_paths if @guard_changed_paths

    base = guard_merge_base
    stdout, stderr, status = Open3.capture3(
      "git", "-C", @repo_root.to_s, "diff", "--name-only", "-z", base, "HEAD"
    )
    raise FleetError, "could not diff guard base: #{stderr.strip}" unless status.success?

    @guard_changed_paths = stdout.split("\0").reject(&:empty?)
  end

  def guard_merge_base
    return @guard_merge_base if @guard_merge_base

    stdout, stderr, status = Open3.capture3(
      "git", "-C", @repo_root.to_s, "merge-base", @guard_base, "HEAD"
    )
    raise FleetError, "could not resolve guard base #{@guard_base}: #{stderr.strip}" unless status.success?

    @guard_merge_base = stdout.strip
  end

  def guard_base_block(block)
    text = guard_base_file(block.fetch(:path))
    marked_block_from_text(text, block.fetch(:name), block.fetch(:style))
  end

  def guard_base_file(path)
    base = guard_merge_base
    stdout, _stderr, status = Open3.capture3(
      "git", "-C", @repo_root.to_s, "show", "#{base}:#{path}"
    )
    return nil unless status.success?

    stdout
  end

  def current_marked_block(block)
    path = repo_path(block.fetch(:path))
    return nil unless path.file?

    marked_block_from_text(read_path(path), block.fetch(:name), block.fetch(:style))
  end

  def marked_block_from_text(text, block_name, style)
    return nil if text.nil?

    match = text.match(marker_regex(block_name, style))
    match&.to_s
  end

  def guard_failure_message(managed_changes)
    "fleet guard: managed surface change rejected (#{managed_changes.join(", ")}); " \
      "fleet-managed files and blocks change in starhaven-io/.github, or through .fleet.yml parameters. " \
      "If this PR combines parameter changes with rendered output after a fleet release, bump the fleet pins first."
  end

  def workflow_data(relative_path)
    YAML.safe_load(read_path(repo_path(relative_path)), permitted_classes: [], aliases: false)
  end

  def workflow_on(data)
    data["on"] || data[true] || {}
  end

  def workflow_paths(data, event)
    event_data = workflow_on(data)[event]
    return [] unless event_data.is_a?(Hash)

    Array(event_data["paths"])
  end

  def workflow_schedule(data)
    schedules = workflow_on(data)["schedule"]
    first = Array(schedules).first
    first["cron"] if first.is_a?(Hash)
  end

  def workflow_concurrency_group(data)
    concurrency = data["concurrency"]
    return concurrency if concurrency.is_a?(String)

    concurrency["group"] if concurrency.is_a?(Hash)
  end

  def reusable_caller(data, workflow_name)
    jobs = data["jobs"]
    return nil unless jobs.is_a?(Hash)

    jobs.values.find do |job|
      job.is_a?(Hash) &&
        job["uses"].to_s.include?("starhaven-io/.github/.github/workflows/reusable-#{workflow_name}.yml@")
    end
  end

  def parse_json_array(value)
    parsed = value.is_a?(Array) ? value : JSON.parse(value.to_s)
    raise FleetError, "workflow caller languages must be a JSON array" unless parsed.is_a?(Array)

    parsed
  end

  def marked_block_body(text, block_name)
    match = text.match(/^<!-- fleet:block #{Regexp.escape(block_name)} -->\n(?<body>.*?)^<!-- fleet:end -->/m)
    return nil unless match

    match[:body].strip
  end

  def unquote_scalar(value)
    return nil if value.nil?

    value.delete_prefix("\"").delete_suffix("\"")
  end

  def extract_build_profile(text)
    return "swift-package" if text.match?(/^\s+run:\s*swift build$/)
    return "brewy-xcode" if text.include?("xcodebuild \\") && text.include?("-project Brewy.xcodeproj")

    ""
  end

  def extract_list_after(text, parent_key, child_key)
    lines = text.lines
    parent_index = lines.index do |line|
      line.match?(/^\s{2}#{Regexp.escape(parent_key)}:/) || line.match?(/^#{Regexp.escape(parent_key)}:/)
    end
    return [] unless parent_index

    child_index = nil
    ((parent_index + 1)...lines.length).each do |index|
      line = lines[index]
      break if line.match?(/^\s{2}[a-zA-Z_-]+:/) && !line.include?("#{child_key}:")

      if line.match?(/^\s{4}#{Regexp.escape(child_key)}:/)
        child_index = index
        break
      end
    end
    return [] unless child_index

    values = []
    ((child_index + 1)...lines.length).each do |index|
      line = lines[index]
      break unless line.match?(/^\s{6}-\s+/)

      values << line.sub(/^\s{6}-\s*/, "").strip.delete_prefix("\"").delete_suffix("\"")
    end
    values
  end

  def extract_push_paths_after_push(text)
    lines = text.lines
    push_index = lines.index { |line| line.match?(/^\s{2}push:/) }
    return [] unless push_index

    paths_index = nil
    ((push_index + 1)...lines.length).each do |index|
      line = lines[index]
      break if line.match?(/^\s{2}[a-zA-Z_-]+:/)

      if line.match?(/^\s{4}paths:/)
        paths_index = index
        break
      end
    end
    return [] unless paths_index

    values = []
    ((paths_index + 1)...lines.length).each do |index|
      line = lines[index]
      break unless line.match?(/^\s{6}-\s+/)

      values << line.sub(/^\s{6}-\s*/, "").strip.delete_prefix("\"").delete_suffix("\"")
    end
    values
  end

  def dependabot_entries(raw)
    entries =
      if raw.is_a?(Array)
        raw.map do |entry|
          entry = entry.dup
          entry["group"] ||= DEPENDABOT_GROUPS.fetch(entry.fetch("package-ecosystem"),
                                                     "#{entry.fetch("package-ecosystem")}-dependencies")
          entry
        end
      else
        raw.flat_map do |ecosystem, directories|
          Array(directories).map do |directory|
            {
              "package-ecosystem" => ecosystem,
              "directory" => directory,
              "group" => DEPENDABOT_GROUPS.fetch(ecosystem, "#{ecosystem}-dependencies")
            }
          end
        end
      end

    entries.sort_by do |entry|
      [entry.fetch("package-ecosystem"), entry["directory"].to_s, Array(entry["directories"]).join]
    end
  end

  def replace_marked_block(relative_path, block_name, style, body)
    path = repo_path(relative_path)
    raise FleetError, "#{relative_path} is missing" unless path.file?

    current = read_path(path)
    replacement = fenced_block(block_name, style, body)
    marker = marker_regex(block_name, style)

    next_content =
      if current.match?(marker)
        current.sub(marker, replacement)
      elsif @bootstrap
        bootstrap_replace_block(relative_path, block_name, current, replacement)
      else
        raise FleetError, "#{relative_path} is missing fleet:block #{block_name}"
      end

    write_file(relative_path, next_content, "#{relative_path}:#{block_name}")
  end

  def replace_just_recipe(block_name, body)
    path = repo_path("justfile")
    raise FleetError, "justfile is missing" unless path.file?

    current = read_path(path)
    replacement = fenced_block(block_name, :hash, body)
    marker = marker_regex(block_name, :hash)

    next_content =
      if current.match?(marker)
        current.sub(marker, replacement)
      elsif @bootstrap
        bootstrap_replace_recipe(current, block_name, replacement)
      else
        raise FleetError, "justfile is missing fleet:block #{block_name}"
      end

    write_file("justfile", next_content, "justfile:#{block_name}")
  end

  def bootstrap_replace_block(relative_path, block_name, current, replacement)
    case [relative_path, block_name]
    when ["AGENTS.md", "commit-and-pr-conventions"]
      replace_section(current, "## Commit and PR conventions", replacement)
    when [".gitignore", "local-state"]
      replace_gitignore_local_state(current, replacement)
    when ["README.md", "badges"]
      replace_readme_badges(current, replacement)
    when ["README.md", "license-section"]
      replace_section(current, "## License", replacement)
    else
      raise FleetError, "#{relative_path} cannot bootstrap fleet:block #{block_name}"
    end
  end

  def replace_section(current, heading, replacement)
    pattern = /^#{Regexp.escape(heading)}\n.*?(?:(\n+)(?=^## )|\z)/m
    raise FleetError, "section #{heading} is missing" unless current.match?(pattern)

    current.sub(pattern) do |_match|
      suffix = Regexp.last_match(1) ? "\n\n" : "\n"
      "#{replacement}#{suffix}"
    end
  end

  def replace_gitignore_local_state(current, replacement)
    if current.start_with?("# Local machine/editor/agent state\n")
      current.sub(%r{\A# Local machine/editor/agent state\n.*?(?=\n# |\z)}m, replacement)
    else
      "#{replacement}\n\n#{current}"
    end
  end

  def replace_readme_badges(current, replacement)
    lines = current.lines
    heading_index = lines.index { |line| line.start_with?("# ") }
    raise FleetError, "README.md is missing an H1" unless heading_index

    start_index = heading_index + 1
    start_index += 1 while lines[start_index] == "\n"
    finish_index = start_index
    finish_index += 1 while lines[finish_index]&.start_with?("[![")
    finish_index += 1 while lines[finish_index] == "\n"

    lines[start_index...finish_index] = ["#{replacement}\n\n"]
    lines.join
  end

  def bootstrap_replace_recipe(current, block_name, replacement)
    lines = current.lines
    recipe_index = lines.index { |line| line.match?(/^#{Regexp.escape(block_name)}:/) }

    return "#{current.chomp}\n\n#{replacement}\n" unless recipe_index

    start_index = recipe_index
    while start_index.positive? &&
          lines[start_index - 1].start_with?("#") &&
          !lines[start_index - 1].start_with?("# fleet:")
      start_index -= 1
    end

    finish_index = recipe_index + 1
    finish_index += 1 while finish_index < lines.length && lines[finish_index].match?(/^(\s|$)/)
    separator = finish_index < lines.length ? "\n\n" : "\n"
    lines[start_index...finish_index] = ["#{replacement}#{separator}"]
    lines.join
  end

  def fenced_block(block_name, style, body)
    body = body.strip
    case style
    when :markdown
      # Blank padding keeps Prettier-checked consumers from reformatting inside the fence.
      "<!-- fleet:block #{block_name} -->\n\n#{body}\n\n<!-- fleet:end -->"
    when :hash
      "# fleet:block #{block_name}\n#{body}\n# fleet:end"
    else
      raise FleetError, "unknown marker style #{style}"
    end
  end

  def marker_regex(block_name, style)
    case style
    when :markdown
      /^<!-- fleet:block #{Regexp.escape(block_name)} -->\n.*?^<!-- fleet:end -->/m
    when :hash
      /^# fleet:block #{Regexp.escape(block_name)}\n.*?^# fleet:end/m
    else
      raise FleetError, "unknown marker style #{style}"
    end
  end

  def render_template(template_name, locals)
    template = read_path(hub_path("templates/#{template_name}"))
    context = TemplateContext.new(locals)
    ERB.new(template, trim_mode: "-").result(context.instance_eval { binding }).sub(/\s+\z/, "\n")
  end

  def write_file(relative_path, content, surface)
    content = "#{content}\n" unless content.end_with?("\n")
    path = repo_path(relative_path)
    current = path.file? ? read_path(path) : nil
    return if current == content

    @changes << surface
    return if @check

    FileUtils.mkdir_p(path.dirname)
    write_path(path, content)
  end

  def chmod_executable(relative_path)
    path = repo_path(relative_path)
    return unless path.file?

    if @check
      @changes << relative_path unless path.executable?
      return
    end

    FileUtils.chmod(0o755, path)
  end

  def exception?(config, surface)
    config.fetch("exceptions", {}).key?(surface)
  end

  # The sync is the only writer for fleet pins: every render seeds every
  # caller at the current release, so a release is one PR per consumer.
  # Dependabot ignores hub refs and owns third-party dependencies only.
  def reusable_pin
    @reusable_pin ||= [version_commit(fleet_version) || ENV["FLEET_HUB_SHA"] || git_hub_sha, fleet_version]
  end

  def version_commit(version)
    @version_commits ||= {}
    return @version_commits[version] if @version_commits.key?(version)

    stdout, _stderr, status = Open3.capture3("git", "-C", @hub_root.to_s, "rev-list", "-n1", "refs/tags/#{version}")
    sha = stdout.strip
    @version_commits[version] = status.success? && !sha.empty? ? sha : nil
  end

  def fleet_version
    @fleet_version ||= read_path(hub_path("VERSION")).strip
  end

  def git_hub_sha
    stdout, status = Open3.capture2("git", "-C", @hub_root.to_s, "rev-parse", "HEAD")
    raise FleetError, "could not resolve hub git SHA" unless status.success?

    stdout.strip
  end

  def default_codeql_runner(languages)
    Array(languages).include?("swift") ? "macos-26" : "ubuntu-slim"
  end

  def default_readme_license(config_license:)
    case config_license
    when "agpl"
      "This project is licensed under the [GNU Affero General Public License v3.0](LICENSE) " \
      "(`AGPL-3.0-only`).\n\nCopyright (C) 2026 Patrick Linnane"
    when "mit"
      "This project is licensed under the [MIT License](LICENSE)."
    else
      ""
    end
  end

  def repo_name_for_urls
    @repo_name || @repo_root.basename.to_s
  end

  def report_changes
    return if @changes.empty?

    @changes.each { |surface| warn "fleet: changed #{surface}" }
  end

  def dump_config(config)
    emit_mapping(config, 0)
  end

  def emit_mapping(hash, indent)
    hash.map do |key, value|
      rendered = emit_value(value, indent + 2)
      if (value.is_a?(Hash) && !value.empty?) || block_array?(value)
        "#{" " * indent}#{key}:\n#{rendered}"
      else
        "#{" " * indent}#{key}: #{rendered}"
      end
    end.join("\n").concat("\n")
  end

  def emit_value(value, indent)
    case value
    when Hash
      return "{}" if value.empty?

      emit_mapping(value, indent).chomp
    when Array
      return "[]" if value.empty?
      return "[#{value.map { |item| emit_inline(item) }.join(", ")}]" if inline_array?(value)

      value.map { |item| emit_array_item(item, indent) }.join("\n")
    when String
      if value.include?("\n")
        lines = value.lines.map { |line| line == "\n" ? line : "#{" " * indent}#{line}" }.join
        "|-\n#{lines}"
      else
        emit_inline(value)
      end
    when TrueClass, FalseClass, Integer
      value.to_s
    when NilClass
      "null"
    else
      raise FleetError, "cannot dump #{value.class}"
    end
  end

  def block_array?(value)
    value.is_a?(Array) && !inline_array?(value)
  end

  def inline_array?(value)
    value.is_a?(Array) &&
      value.all? { |item| item.is_a?(String) || item.is_a?(Integer) || item == true || item == false } &&
      value.join(", ").length <= 72
  end

  def blank?(value)
    value.nil? || (value.respond_to?(:empty?) && value.empty?)
  end

  def emit_array_item(item, indent)
    case item
    when Hash
      lines = emit_mapping(item, indent + 2).lines
      first = lines.shift.sub(/^#{" " * (indent + 2)}/, "")
      "#{" " * indent}- #{first}#{lines.join}".chomp
    when Array
      "#{" " * indent}- #{emit_value(item, indent + 2).strip}"
    else
      "#{" " * indent}- #{emit_inline(item)}"
    end
  end

  def emit_inline(value)
    case value
    when String
      "\"#{value.gsub(/["\\]/) { |char| "\\#{char}" }}\""
    when TrueClass, FalseClass, Integer
      value.to_s
    when Hash
      "{ #{value.map { |key, nested| "#{key}: #{emit_inline(nested)}" }.join(", ")} }"
    else
      raise FleetError, "cannot inline #{value.class}"
    end
  end

  def repo_path(relative)
    @repo_root.join(relative)
  end

  def hub_path(relative)
    @hub_root.join("fleet", relative)
  end

  def read_path(path)
    File.read(path.to_s, encoding: "UTF-8")
  end

  def write_path(path, content)
    File.write(path.to_s, content, encoding: "UTF-8")
  end
end

options = {
  hub_root: Pathname(__dir__).parent.to_s,
  repo_root: Dir.pwd,
  repo_name: nil,
  check: false,
  bootstrap: false,
  guard_base: nil
}

OptionParser.new do |parser|
  parser.banner = "Usage: sync.rb [options]"
  parser.on("--hub-root PATH", "Hub repository root") { |value| options[:hub_root] = value }
  parser.on("--repo-root PATH", "Consumer repository root") { |value| options[:repo_root] = value }
  parser.on("--repo-name NAME", "Consumer repository name") { |value| options[:repo_name] = value }
  parser.on("--check", "Report drift without writing") { options[:check] = true }
  parser.on("--bootstrap", "Derive and write an initial .fleet.yml if missing") { options[:bootstrap] = true }
  parser.on("--guard BASE_REF", "Reject unmanaged edits to fleet-managed surfaces") do |value|
    options[:guard_base] = value
  end
end.parse!

begin
  FleetSync.new(**options).run
rescue FleetError => e
  warn "fleet: #{e.message}"
  exit 1
end
