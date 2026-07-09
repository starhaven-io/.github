#!/usr/bin/env ruby
# frozen_string_literal: true

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
    "bundler" => "bundler-dependencies",
    "github-actions" => "github-actions",
    "cargo" => "cargo-dependencies",
    "npm" => "npm-dependencies",
    "swift" => "swift-dependencies",
    "terraform" => "terraform"
  }.freeze

  PARAM_KEYS = %w[
    astro-docs
    codeql
    codeql-languages
    dependabot
    link-check
    pinprick-audit
    readme
    zizmor
    zizmor-config
  ].freeze

  EXCEPTION_KEYS = %w[
    audit
    codeql
    pinprick-audit
    pinprick-audit-recipe
    zizmor
  ].freeze

  DEPENDABOT_DEPENDENCY_TYPES = %w[all direct indirect production development].freeze
  CODEQL_BUILD_MODES = ["", "none", "autobuild", "manual"].freeze
  CODEQL_BUILD_PROFILES = ["", "swift-package", "brewy-xcode"].freeze
  FLEET_MARKER_PATTERN = /<!--\s*fleet:(?:block|end)\b/
  REUSABLE_WORKFLOW_USES_PATTERN = %r{
    ^(?<prefix>\s*uses:\s*)
    (?<quote>["']?)
    (?<workflow>starhaven-io/\.github/\.github/workflows/reusable-[A-Za-z0-9_.-]+\.ya?ml)
    @(?<ref>[^"'\s#]+)
    \k<quote>
    (?<comment>\s*(?:\#.*)?)$
  }x
  REUSABLE_WORKFLOW_VALUE_PATTERN = %r{
    \A
    (?<workflow>starhaven-io/\.github/\.github/workflows/reusable-[A-Za-z0-9_.-]+\.ya?ml)
    @(?<ref>\S+)
    \z
  }x

  attr_reader :changes

  def initialize(hub_root:, repo_root:, repo_name:, check:, guard_base:, hub: false)
    @hub_root = Pathname(hub_root).expand_path
    @repo_root = Pathname(repo_root).expand_path
    @repo_name = repo_name
    @check = check || !guard_base.nil?
    @guard_base = guard_base
    @hub = hub
    @changes = []
  end

  def run
    config = load_config
    validate_config(config)
    assert_unique_marked_blocks(config)

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
    render_reusable_workflow_pins
  end

  def run_guard(config)
    head_managed = managed_surfaces(config)
    base_managed = guard_base_config ? managed_surfaces(guard_base_config) : []
    declassified_surfaces = base_managed - head_managed
    raise FleetError, guard_declassification_message(declassified_surfaces) if declassified_surfaces.any? && !hub_repo?

    reject_hidden_reusable_pins
    reject_symlinked_workflow_paths(config)

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
    raise FleetError, non_regular_file_message(".fleet.yml") if managed_path_present?(path) && !regular_file?(path)

    if regular_file?(path)
      text = read_path(path)
      validate_config_text(text, ".fleet.yml")
      begin
        return YAML.safe_load(text, permitted_classes: [], aliases: false)
      rescue Psych::Exception => e
        raise FleetError, ".fleet.yml could not be parsed: #{e.message}"
      end
    end

    raise FleetError, ".fleet.yml is missing; hand-author .fleet.yml before running fleet sync"
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

    validate_params(params)
    validate_exceptions(exceptions)
  end

  def validate_config_text(text, path)
    return unless control_char?(text, allow_lf: true)

    raise FleetError, "#{path} must not contain control characters"
  end

  def validate_params(params)
    reject_unknown_keys(params, PARAM_KEYS, ".fleet.yml params")
    validate_boolean(params, "astro-docs", ".fleet.yml params.astro-docs")
    validate_boolean(params, "zizmor-config", ".fleet.yml params.zizmor-config")
    validate_dependabot(params["dependabot"]) if params.key?("dependabot")
    validate_link_check(params["link-check"]) if params.key?("link-check")
    validate_codeql(params["codeql"]) if params.key?("codeql")
    validate_string_array(params, "codeql-languages", ".fleet.yml params.codeql-languages")
    validate_pinprick_audit(params["pinprick-audit"]) if params.key?("pinprick-audit")
    validate_zizmor(params["zizmor"]) if params.key?("zizmor")
    validate_readme(params["readme"]) if params.key?("readme")
  end

  def validate_exceptions(exceptions)
    reject_unknown_keys(exceptions, EXCEPTION_KEYS, ".fleet.yml exceptions")
    exceptions.each do |key, value|
      validate_plain_string(value, ".fleet.yml exceptions.#{key}")
    end
  end

  def validate_dependabot(value)
    if value.is_a?(Array)
      value.each_with_index do |entry, index|
        validate_dependabot_entry(entry, ".fleet.yml params.dependabot[#{index}]")
      end
    elsif value.is_a?(Hash)
      value.each do |ecosystem, directories|
        validate_dependabot_ecosystem(ecosystem, ".fleet.yml params.dependabot ecosystem")
        Array(directories).each_with_index do |directory, index|
          validate_plain_string(directory, ".fleet.yml params.dependabot.#{ecosystem}[#{index}]")
        end
      end
    else
      raise FleetError, ".fleet.yml params.dependabot must be a mapping or array"
    end
  end

  def validate_dependabot_entry(entry, path)
    raise FleetError, "#{path} must be a mapping" unless entry.is_a?(Hash)

    reject_unknown_keys(entry, %w[allow directories directory group package-ecosystem], path)
    ecosystem = entry["package-ecosystem"]
    validate_dependabot_ecosystem(ecosystem, "#{path}.package-ecosystem")
    validate_plain_string(entry["directory"], "#{path}.directory") if entry.key?("directory")
    validate_string_array(entry, "directories", "#{path}.directories")
    validate_identifier(entry["group"], "#{path}.group") if entry.key?("group")
    validate_dependabot_allow(entry["allow"], "#{path}.allow") if entry.key?("allow")
  end

  def validate_dependabot_allow(value, path)
    raise FleetError, "#{path} must be an array" unless value.is_a?(Array)

    value.each_with_index do |entry, index|
      entry_path = "#{path}[#{index}]"
      raise FleetError, "#{entry_path} must be a mapping" unless entry.is_a?(Hash)

      reject_unknown_keys(entry, %w[dependency-type], entry_path)
      validate_enum(entry["dependency-type"], DEPENDABOT_DEPENDENCY_TYPES, "#{entry_path}.dependency-type")
    end
  end

  def validate_dependabot_ecosystem(value, path)
    validate_plain_string(value, path)
    return if value.match?(/\A[a-z0-9][a-z0-9-]*\z/)

    raise FleetError, "#{path} must contain only lowercase letters, numbers, and hyphens"
  end

  def validate_link_check(value)
    path = ".fleet.yml params.link-check"
    raise FleetError, "#{path} must be a mapping" unless value.is_a?(Hash)

    reject_unknown_keys(
      value,
      %w[authenticated-github build-site concurrency-group pull-request-paths schedule site-directory targets],
      path
    )
    validate_plain_string(value["targets"], "#{path}.targets")
    validate_boolean(value, "build-site", "#{path}.build-site")
    validate_plain_string(value["site-directory"], "#{path}.site-directory") if value.key?("site-directory")
    validate_boolean(value, "authenticated-github", "#{path}.authenticated-github")
    validate_plain_string(value["schedule"], "#{path}.schedule") if value.key?("schedule")
    validate_string_array(value, "pull-request-paths", "#{path}.pull-request-paths")
    validate_plain_string(value["concurrency-group"], "#{path}.concurrency-group") if value.key?("concurrency-group")
  end

  def validate_codeql(value)
    path = ".fleet.yml params.codeql"
    raise FleetError, "#{path} must be a mapping" unless value.is_a?(Hash)

    reject_unknown_keys(value, %w[build-mode build-profile languages paths runner schedule timeout-minutes], path)
    validate_string_array(value, "languages", "#{path}.languages")
    validate_string_array(value, "paths", "#{path}.paths")
    validate_plain_string(value["runner"], "#{path}.runner") if value.key?("runner")
    validate_integer(value, "timeout-minutes", "#{path}.timeout-minutes")
    validate_enum(value["build-mode"].to_s, CODEQL_BUILD_MODES, "#{path}.build-mode") if value.key?("build-mode")
    if value.key?("build-profile")
      validate_enum(value["build-profile"].to_s, CODEQL_BUILD_PROFILES, "#{path}.build-profile")
    end
    validate_plain_string(value["schedule"], "#{path}.schedule") if value.key?("schedule")
  end

  def validate_pinprick_audit(value)
    path = ".fleet.yml params.pinprick-audit"
    raise FleetError, "#{path} must be a mapping" unless value.is_a?(Hash)

    reject_unknown_keys(value, %w[advanced-security fail-on-findings push-paths timeout-minutes], path)
    if value.key?("advanced-security")
      validate_advanced_security(value["advanced-security"], "#{path}.advanced-security")
    end
    validate_boolean(value, "fail-on-findings", "#{path}.fail-on-findings")
    validate_string_array(value, "push-paths", "#{path}.push-paths")
    validate_integer(value, "timeout-minutes", "#{path}.timeout-minutes")
  end

  def validate_zizmor(value)
    path = ".fleet.yml params.zizmor"
    raise FleetError, "#{path} must be a mapping" unless value.is_a?(Hash)

    reject_unknown_keys(value, %w[push-paths schedule timeout-minutes], path)
    validate_string_array(value, "push-paths", "#{path}.push-paths")
    validate_plain_string(value["schedule"], "#{path}.schedule") if value.key?("schedule")
    validate_integer(value, "timeout-minutes", "#{path}.timeout-minutes")
  end

  def validate_readme(value)
    path = ".fleet.yml params.readme"
    raise FleetError, "#{path} must be a mapping" unless value.is_a?(Hash)

    reject_unknown_keys(value, %w[badges license], path)
    validate_readme_badges(value["badges"], "#{path}.badges") if value.key?("badges")
    validate_readme_license(value["license"], "#{path}.license") if value.key?("license")
  end

  def validate_readme_badges(value, path)
    raise FleetError, "#{path} must be a mapping" unless value.is_a?(Hash)

    reject_unknown_keys(value, %w[extra workflow], path)
    validate_plain_string(value["workflow"], "#{path}.workflow")
    validate_string_array(value, "extra", "#{path}.extra")
    Array(value["extra"]).each_with_index do |line, index|
      validate_no_fleet_marker(line, "#{path}.extra[#{index}]")
    end
  end

  def validate_readme_license(value, path)
    raise FleetError, "#{path} must be a mapping" unless value.is_a?(Hash)

    reject_unknown_keys(value, %w[extra text], path)
    validate_markdown_text(value["text"], "#{path}.text") if value.key?("text")

    validate_string_array(value, "extra", "#{path}.extra")
    Array(value["extra"]).each_with_index do |line, index|
      validate_no_fleet_marker(line, "#{path}.extra[#{index}]")
    end
  end

  def reject_unknown_keys(hash, allowed, path)
    unknown = hash.keys - allowed
    return if unknown.empty?

    raise FleetError, "#{path} contains unknown keys: #{unknown.sort.join(", ")}"
  end

  def validate_boolean(hash, key, path)
    return unless hash.key?(key)
    return if [true, false].include?(hash[key])

    raise FleetError, "#{path} must be true or false"
  end

  def validate_integer(hash, key, path)
    return unless hash.key?(key)
    return if hash[key].is_a?(Integer)

    raise FleetError, "#{path} must be an integer"
  end

  def validate_string_array(hash, key, path)
    return unless hash.key?(key)
    raise FleetError, "#{path} must be an array" unless hash[key].is_a?(Array)

    hash[key].each_with_index do |value, index|
      validate_plain_string(value, "#{path}[#{index}]")
    end
  end

  def validate_plain_string(value, path)
    raise FleetError, "#{path} must be a string" unless value.is_a?(String)
    raise FleetError, "#{path} must not contain control characters" if control_char?(value)
  end

  def validate_markdown_text(value, path)
    raise FleetError, "#{path} must be a string" unless value.is_a?(String)
    raise FleetError, "#{path} must not contain control characters" if control_char?(value, allow_lf: true)

    validate_no_fleet_marker(value, path)
  end

  def validate_no_fleet_marker(value, path)
    return unless value.match?(FLEET_MARKER_PATTERN)

    raise FleetError, "#{path} must not contain fleet block markers"
  end

  def validate_identifier(value, path)
    validate_plain_string(value, path)
    return if value.match?(/\A[A-Za-z0-9_.-]+\z/)

    raise FleetError, "#{path} must contain only letters, numbers, dots, underscores, and hyphens"
  end

  def validate_enum(value, allowed, path)
    return if allowed.include?(value)

    raise FleetError, "#{path} must be one of: #{allowed.join(", ")}"
  end

  def validate_advanced_security(value, path)
    return if [true, false, "true", "false", SAME_ORG_ADVANCED_SECURITY].include?(value)

    raise FleetError, "#{path} must be true, false, or the canonical same-org expression"
  end

  def control_char?(value, allow_lf: false)
    value.each_codepoint.any? do |codepoint|
      next false if allow_lf && codepoint == 0x0a

      codepoint < 0x20 || codepoint == 0x7f || (0x80..0x9f).cover?(codepoint)
    end
  end

  def render_tier1(config)
    TIER1_FILES.each do |dest, source|
      write_file(dest, read_path(hub_path(source)), dest)
    end

    license = config.fetch("license")
    write_file("LICENSE", read_path(hub_path(LICENSE_FILES.fetch(license))), "LICENSE") if license != "none"

    params = config_params(config)
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
    params = config_params(config)

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

    readme = params["readme"].is_a?(Hash) ? params["readme"] : {}
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
    params = config_params(config)

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

  def render_reusable_workflow_pins
    ref, version = reusable_pin
    workflow_files.each do |relative_path|
      path = repo_path(relative_path)
      current = read_path(path)
      next_content = sync_reusable_pins(current, ref, version)
      next if next_content == current

      write_file(relative_path, next_content, reusable_pin_surface(relative_path))
    end
  end

  def sync_reusable_pins(text, ref, version)
    text.each_line.map do |line|
      newline = line.end_with?("\n") ? "\n" : ""
      body = line.delete_suffix("\n")
      match = body.match(REUSABLE_WORKFLOW_USES_PATTERN)
      next line unless match

      "#{match[:prefix]}#{match[:quote]}#{match[:workflow]}@#{ref}#{match[:quote]} # #{version}#{newline}"
    end.join
  end

  def workflow_files
    [".github/workflows/*.yml", ".github/workflows/*.yaml"].flat_map do |pattern|
      Dir.glob(repo_path(pattern).to_s).filter_map do |path|
        candidate = Pathname(path)
        next unless regular_file?(candidate)

        candidate.relative_path_from(@repo_root).to_s
      end
    end.sort
  end

  def workflow_file?(path)
    path.match?(%r{\A\.github/workflows/[^/]+\.ya?ml\z})
  end

  def reusable_pin_surface(path)
    "#{path}:reusable-pins"
  end

  def changed_managed_surfaces(config)
    changed_paths = guard_changed_paths
    return [] if changed_paths.empty?

    configs = [guard_base_config, config].compact
    managed = []
    whole_files = configs.flat_map { |candidate| managed_whole_files(candidate) }.uniq
    changed_paths.each do |path|
      managed << path if whole_files.include?(path)
    end

    managed_blocks = configs.flat_map { |candidate| guard_managed_blocks(candidate) }.uniq do |block|
      [block.fetch(:path), block.fetch(:name)]
    end
    managed_blocks.each do |block|
      next unless changed_paths.include?(block.fetch(:path))

      base_block = guard_base_block(block)
      current_block = current_marked_block(block)
      managed << block_surface(block) if base_block != current_block
    end

    changed_paths.each do |path|
      next unless workflow_file?(path)

      managed << reusable_pin_surface(path) if guard_base_reusable_pins(path) != current_reusable_pins(path)
    end

    managed.uniq.sort
  end

  def reject_hidden_reusable_pins
    guard_changed_paths.each do |path|
      next unless workflow_file?(path)

      full_path = repo_path(path)
      next unless regular_file?(full_path)

      hidden_pins = hidden_reusable_pins(read_path(full_path))
      next if hidden_pins.empty?

      raise FleetError, hidden_reusable_pin_message(path, hidden_pins)
    end
  end

  def reject_symlinked_workflow_paths(config)
    managed = [guard_base_config, config]
              .compact
              .flat_map { |candidate| managed_whole_files(candidate) }
              .uniq
    workflow_paths = guard_changed_paths.select { |path| workflow_file?(path) }
    workflow_paths.concat(workflow_files) if symlinked_workflow_root_changed?

    workflow_paths.uniq.each do |path|
      full_path = repo_path(path)
      next unless managed_path_present?(full_path)

      reject_symlinked_workflow_ancestors(path)
      next if managed.include?(path)

      raise FleetError, non_regular_file_message(path) unless regular_file?(full_path)
    end
  end

  def reject_symlinked_workflow_ancestors(path)
    Pathname(path).descend do |ancestor|
      next if ancestor.to_s == path

      full_ancestor = repo_path(ancestor)
      next unless full_ancestor.symlink?

      raise FleetError, symlinked_workflow_ancestor_message(path, ancestor.to_s)
    end
  end

  def symlinked_workflow_root_changed?
    guard_changed_paths.any? do |path|
      next false unless [".github", ".github/workflows"].include?(path)

      repo_path(path).symlink?
    end
  end

  def hidden_reusable_pins(text)
    line_pins = Hash.new(0)
    reusable_pins_from_text(text).each do |workflow, ref, _comment|
      line_pins[[workflow, ref]] += 1
    end

    yaml_reusable_pins(text).filter_map do |workflow, ref|
      key = [workflow, ref]
      if line_pins[key].positive?
        line_pins[key] -= 1
        next
      end

      key
    end
  end

  def yaml_reusable_pins(text)
    collect_yaml_reusable_pins(YAML.safe_load(text, permitted_classes: [], aliases: false))
  rescue Psych::Exception
    []
  end

  def collect_yaml_reusable_pins(node)
    case node
    when Hash
      node.flat_map { |key, value| collect_yaml_reusable_pins(key) + collect_yaml_reusable_pins(value) }
    when Array
      node.flat_map { |entry| collect_yaml_reusable_pins(entry) }
    when String
      match = node.match(REUSABLE_WORKFLOW_VALUE_PATTERN)
      match ? [[match[:workflow], match[:ref]]] : []
    else
      []
    end
  end

  def managed_surfaces(config)
    managed_blocks = guard_managed_blocks(config).map do |block|
      block_surface(block)
    end
    managed_whole_files(config) + managed_blocks
  end

  def managed_whole_files(config)
    params = config_params(config)
    files = TIER1_FILES.keys
    files << "LICENSE" unless config_license(config) == "none"
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
    params = config_params(config)
    blocks = [
      { path: "AGENTS.md", name: "commit-and-pr-conventions", style: :markdown },
      { path: ".gitignore", name: "local-state", style: :hash },
      { path: "justfile", name: "install-hooks", style: :hash }
    ]
    blocks << { path: "justfile", name: "audit", style: :hash } unless exception?(config, "audit")
    blocks << { path: "justfile", name: "pinprick-audit", style: :hash } unless exception?(config,
                                                                                           "pinprick-audit-recipe")

    readme = params["readme"].is_a?(Hash) ? params["readme"] : {}
    blocks << { path: "README.md", name: "badges", style: :markdown } if readme["badges"]
    blocks << { path: "README.md", name: "license-section", style: :markdown } if readme["license"]
    blocks
  end

  def block_surface(block)
    "#{block.fetch(:path)}:#{block.fetch(:name)}"
  end

  # A managed block must appear exactly once: guard and renderer both act on the
  # first marker match, so a duplicate could hide an edit behind the first copy.
  def assert_unique_marked_blocks(config)
    guard_managed_blocks(config).each do |block|
      path = repo_path(block.fetch(:path))
      next unless managed_path_present?(path)

      raise FleetError, non_regular_file_message(block.fetch(:path)) unless regular_file?(path)

      count = read_path(path).scan(block_start_marker(block.fetch(:name), block.fetch(:style))).length
      next if count <= 1

      raise FleetError, duplicate_marker_message(block, count)
    end
  end

  def block_start_marker(block_name, style)
    case style
    when :markdown
      /^<!-- fleet:block #{Regexp.escape(block_name)} -->$/
    when :hash
      /^# fleet:block #{Regexp.escape(block_name)}$/
    else
      raise FleetError, "unknown marker style #{style}"
    end
  end

  def duplicate_marker_message(block, count)
    "#{block.fetch(:path)} has #{count} '#{block.fetch(:name)}' fleet:block markers; " \
      "a managed block must appear exactly once so an edited duplicate cannot hide behind the first."
  end

  def config_params(config)
    params = config["params"]
    params.is_a?(Hash) ? params : {}
  end

  def config_exceptions(config)
    exceptions = config["exceptions"]
    exceptions.is_a?(Hash) ? exceptions : {}
  end

  def config_license(config)
    license = config["license"]
    %w[agpl mit none].include?(license) ? license : "none"
  end

  def hub_repo?
    @hub
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

  def guard_base_reusable_pins(path)
    reusable_pins_from_text(guard_base_file(path))
  end

  def guard_base_config
    return @guard_base_config if defined?(@guard_base_config)

    text = guard_base_file(".fleet.yml")
    return @guard_base_config = nil if text.nil?

    config = YAML.safe_load(text, permitted_classes: [], aliases: false)
    raise FleetError, "fleet guard: base .fleet.yml must be a mapping" unless config.is_a?(Hash)
    raise FleetError, "fleet guard: base .fleet.yml schema must be 1" unless config["schema"] == 1

    @guard_base_config = config
  rescue Psych::Exception => e
    raise FleetError, "fleet guard: base .fleet.yml could not be parsed: #{e.message}"
  end

  def current_marked_block(block)
    path = repo_path(block.fetch(:path))
    return nil unless regular_file?(path)

    marked_block_from_text(read_path(path), block.fetch(:name), block.fetch(:style))
  end

  def current_reusable_pins(path)
    full_path = repo_path(path)
    return [] unless regular_file?(full_path)

    reusable_pins_from_text(read_path(full_path))
  end

  def reusable_pins_from_text(text)
    return [] if text.nil?

    text.each_line.filter_map do |line|
      match = line.delete_suffix("\n").match(REUSABLE_WORKFLOW_USES_PATTERN)
      next unless match

      [match[:workflow], match[:ref], match[:comment].strip]
    end
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

  def guard_declassification_message(surfaces)
    "fleet guard: managed surface declassification rejected (#{surfaces.join(", ")}); " \
      "human pull requests cannot shrink the fleet-managed surface set. " \
      "Land opt-outs through the fleet sync bot after the hub canon changes."
  end

  def hidden_reusable_pin_message(path, pins)
    workflows = pins.map { |workflow, ref| "#{workflow}@#{ref}" }.uniq.sort.join(", ")
    "fleet guard: hidden reusable workflow pin rejected in #{path} (#{workflows}); " \
      "write every starhaven-io/.github reusable uses: as a single-line scalar because " \
      "folded, block, or escaped forms evade fleet pin management."
  end

  def symlinked_workflow_ancestor_message(path, ancestor)
    "fleet guard: #{path} has symlinked workflow ancestor #{ancestor}; " \
      "workflow files must remain under a real .github/workflows directory."
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
    raise FleetError, "#{relative_path} is missing" unless managed_path_present?(path)
    raise FleetError, non_regular_file_message(relative_path) unless regular_file?(path)

    current = read_path(path)
    replacement = fenced_block(block_name, style, body)
    marker = marker_regex(block_name, style)

    next_content =
      if current.match?(marker)
        current.sub(marker, replacement)
      else
        raise FleetError, "#{relative_path} is missing fleet:block #{block_name}"
      end

    write_file(relative_path, next_content, "#{relative_path}:#{block_name}")
  end

  def replace_just_recipe(block_name, body)
    path = repo_path("justfile")
    raise FleetError, "justfile is missing" unless managed_path_present?(path)
    raise FleetError, non_regular_file_message("justfile") unless regular_file?(path)

    current = read_path(path)
    replacement = fenced_block(block_name, :hash, body)
    marker = marker_regex(block_name, :hash)

    next_content =
      if current.match?(marker)
        current.sub(marker, replacement)
      else
        raise FleetError, "justfile is missing fleet:block #{block_name}"
      end

    write_file("justfile", next_content, "justfile:#{block_name}")
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
    # A managed file must be a real file: a symlink to canonical bytes is drift, not a match.
    current = regular_file?(path) ? read_path(path) : nil
    return if current == content

    @changes << surface
    return if @check

    FileUtils.mkdir_p(path.dirname)
    File.unlink(path) if path.symlink?
    write_path(path, content)
  end

  def chmod_executable(relative_path)
    path = repo_path(relative_path)
    return unless regular_file?(path)

    if @check
      @changes << relative_path unless path.executable?
      return
    end

    FileUtils.chmod(0o755, path)
  end

  def exception?(config, surface)
    config_exceptions(config).key?(surface)
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

  def repo_name_for_urls
    @repo_name || @repo_root.basename.to_s
  end

  def report_changes
    return if @changes.empty?

    @changes.each { |surface| warn "fleet: changed #{surface}" }
  end

  def repo_path(relative)
    @repo_root.join(relative)
  end

  def hub_path(relative)
    @hub_root.join("fleet", relative)
  end

  def regular_file?(path)
    !path.symlink? && path.file?
  end

  def managed_path_present?(path)
    path.exist? || path.symlink?
  end

  def non_regular_file_message(relative_path)
    "#{relative_path} is not a regular file"
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
  guard_base: nil,
  hub: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: sync.rb [options]"
  parser.on("--hub-root PATH", "Hub repository root") { |value| options[:hub_root] = value }
  parser.on("--repo-root PATH", "Consumer repository root") { |value| options[:repo_root] = value }
  parser.on("--repo-name NAME", "Consumer repository name") { |value| options[:repo_name] = value }
  parser.on("--check", "Report drift without writing") { options[:check] = true }
  parser.on("--hub", "Treat this repository as the canonical fleet hub") { options[:hub] = true }
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
