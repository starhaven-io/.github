# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
require "minitest/autorun"

# Renders every fleet/repos/*.yml into a synthetic consumer skeleton and
# asserts the output shape. This is the only pre-merge coverage possible for
# consumers the fleet-validate dry-run cannot check out, such as private
# repositories.
module GoldenHelpers
  ROOT = File.expand_path("../..", __dir__)
  # Only reached for a config entry that omits `group`. Every consumer sets one
  # today, so this mirror currently asserts nothing; it is here so the first
  # config that relies on the renderer's fallback is covered on arrival.
  DEPENDABOT_GROUPS = {
    "bundler" => "bundler-dependencies",
    "github-actions" => "github-actions",
    "cargo" => "cargo-dependencies",
    "npm" => "npm-dependencies",
    "swift" => "swift-dependencies",
    "terraform" => "terraform"
  }.freeze
  FLEET_PIN_IGNORE = "starhaven-io/.github/*"
  REUSABLE_USES_PATTERN = %r{
    uses:\s*"?
    (starhaven-io/\.github/\.github/workflows/reusable-[A-Za-z0-9_.-]+\.ya?ml)
    @(\S+?)"?
    \s*(\#.*)?$
  }x

  module_function

  def fleet_version
    File.read(File.join(ROOT, "fleet/VERSION")).strip
  end

  def repo_names
    YAML.safe_load_file(File.join(ROOT, "fleet/repos.yml"), permitted_classes: [], aliases: false).fetch("repos")
  end

  def repo_config(name)
    YAML.safe_load_file(File.join(ROOT, "fleet/repos/#{name}.yml"), permitted_classes: [], aliases: false)
  end

  def render(repo_root, name)
    stdout, stderr, status = Open3.capture3(
      "ruby", "-rpathname", File.join(ROOT, "fleet/sync.rb"),
      "--hub-root", ROOT,
      "--repo-root", repo_root,
      "--repo-name", name
    )
    [stdout + stderr, status]
  end

  def check(repo_root, name)
    stdout, stderr, status = Open3.capture3(
      "ruby", "-rpathname", File.join(ROOT, "fleet/sync.rb"),
      "--hub-root", ROOT,
      "--repo-root", repo_root,
      "--repo-name", name,
      "--check"
    )
    [stdout + stderr, status]
  end

  # The minimum host files a consumer must carry before its first sync: every
  # tier-2 fence, empty. Fences for surfaces the config does not enable are
  # harmless; the renderer only touches blocks it manages.
  def write_skeleton(repo_root, name)
    File.write(File.join(repo_root, "AGENTS.md"), <<~MARKDOWN)
      # Agent Instructions

      <!-- fleet:block commit-and-pr-conventions -->
      <!-- fleet:end -->
    MARKDOWN
    File.write(File.join(repo_root, ".gitignore"), <<~GITIGNORE)
      # fleet:block local-state
      # fleet:end
    GITIGNORE
    File.write(File.join(repo_root, "justfile"), <<~JUSTFILE)
      # fleet:block install-hooks
      # fleet:end

      # fleet:block npm-policy
      # fleet:end

      # fleet:block audit
      # fleet:end

      # fleet:block pinprick-audit
      # fleet:end
    JUSTFILE
    File.write(File.join(repo_root, "README.md"), <<~MARKDOWN)
      # #{name}

      <!-- fleet:block badges -->
      <!-- fleet:end -->

      <!-- fleet:block license-section -->
      <!-- fleet:end -->
    MARKDOWN
  end
end

GOLDEN_TMPDIR = Dir.mktmpdir("fleet-golden-render-")
Minitest.after_run { FileUtils.rm_rf(GOLDEN_TMPDIR) }

class GoldenRenderTest < Minitest::Test
  include GoldenHelpers

  GoldenHelpers.repo_names.each do |repo|
    define_method("test_renders_#{repo.tr(".", "_")}") do
      assert_golden_render(repo)
    end
  end

  def assert_golden_render(name)
    repo_root = File.join(GOLDEN_TMPDIR, "consumer-#{name}")
    FileUtils.mkdir_p(repo_root)
    write_skeleton(repo_root, name)

    output, status = render(repo_root, name)
    assert status.success?, "render failed for #{name}:\n#{output}"

    output, status = check(repo_root, name)
    assert status.success?, "render is not idempotent for #{name}:\n#{output}"

    config = repo_config(name)
    assert_rendered_inventory(repo_root, name, config)
    assert_workflow_shapes(repo_root, name, config)
  end

  private

  def params(config)
    config["params"] || {}
  end

  def exception?(config, key)
    (config["exceptions"] || {}).key?(key)
  end

  def expected_workflows(config)
    workflows = ["fleet-guard.yml"]
    workflows << "zizmor.yml" unless exception?(config, "zizmor")
    workflows << "pinprick-audit.yml" unless exception?(config, "pinprick-audit")
    workflows << "link-check.yml" if params(config)["link-check"]
    codeql = params(config)["codeql"] || {}
    workflows << "codeql.yml" if codeql["languages"] && !exception?(config, "codeql")
    workflows.sort
  end

  def assert_rendered_inventory(repo_root, name, config)
    rendered = Dir.children(File.join(repo_root, ".github/workflows")).sort
    assert_equal expected_workflows(config), rendered, "unexpected workflow inventory for #{name}"

    assert_equal File.read(File.join(ROOT, "fleet/repos/#{name}.yml")),
                 File.read(File.join(repo_root, ".fleet.yml")),
                 ".fleet.yml must be the hub config byte-for-byte for #{name}"

    license = config.fetch("license")
    if license == "none"
      refute_path_exists File.join(repo_root, "LICENSE")
    else
      assert_equal File.read(File.join(ROOT, "fleet/files/licenses/#{license}")),
                   File.read(File.join(repo_root, "LICENSE"))
    end

    assert_path_exists File.join(repo_root, ".mcp.json") if params(config)["astro-docs"]

    if params(config)["dependabot"]
      assert_dependabot(repo_root, name, config)
    else
      refute_path_exists File.join(repo_root, ".github/dependabot.yml")
    end

    if params(config)["renovate"]
      assert_renovate(repo_root, name)
    else
      refute_path_exists File.join(repo_root, "renovate.json")
    end

    assert_npm_policy(repo_root, config) if params(config)["npm-policy"]
  end

  def assert_renovate(repo_root, name)
    rendered = JSON.parse(File.read(File.join(repo_root, "renovate.json")))
    assert_equal ["local>starhaven-io/.github:renovate-config##{fleet_version}"],
                 rendered.fetch("extends"),
                 "renovate preset must pin the current fleet release for #{name}"
    assert_equal ["mergeConfidence:all-badges"], rendered.fetch("ignorePresets"),
                 "renovate stub must retain the Merge Confidence opt-out for #{name}"
  end

  def assert_dependabot(repo_root, name, config)
    rendered = YAML.safe_load_file(File.join(repo_root, ".github/dependabot.yml"),
                                   permitted_classes: [], aliases: false)
    assert_equal 2, rendered.fetch("version")

    updates = rendered.fetch("updates")
    updates.each { |entry| assert_dependabot_policy(entry, name) }

    # Comparing whole normalized entries, not ecosystem names: a dropped
    # `directories`, `allow`, or `ignore` still leaves the ecosystem intact.
    expected = config_dependabot_entries(config).map { |entry| normalized_config_entry(entry) }
    assert_equal expected.sort_by { |entry| dependabot_key(entry) },
                 updates.map { |entry| normalized_rendered_entry(entry) },
                 "dependabot entries mismatch for #{name}"
  end

  def assert_dependabot_policy(entry, name)
    label = "#{name}/#{entry.fetch("package-ecosystem")}"
    assert_equal({ "interval" => "daily" }, entry.fetch("schedule"), "#{label} must keep the daily schedule")
    assert_equal 7, entry.fetch("cooldown").fetch("default-days"), "#{label} must keep the 7-day cooldown"
    assert_equal 1, entry.fetch("groups").length, "#{label} must render exactly one group"
    return unless entry.fetch("package-ecosystem") == "github-actions"

    assert_includes entry.fetch("ignore").map { |ignore| ignore["dependency-name"] }, FLEET_PIN_IGNORE,
                    "#{label} must leave fleet pins to the sync"
    assert_includes entry.fetch("cooldown").fetch("exclude"), "starhaven-io/*",
                    "#{label} must not cool down first-party actions"
  end

  def config_dependabot_entries(config)
    raw = params(config).fetch("dependabot")
    return raw if raw.is_a?(Array)

    raw.flat_map do |ecosystem, directories|
      Array(directories).map { |directory| { "package-ecosystem" => ecosystem, "directory" => directory } }
    end
  end

  def normalized_config_entry(entry)
    ecosystem = entry.fetch("package-ecosystem")
    normalized = { "package-ecosystem" => ecosystem }
    normalized["directory"] = entry.fetch("directory") if entry.key?("directory")
    normalized["directories"] = entry.fetch("directories") if entry.key?("directories")
    normalized["allow"] = entry.fetch("allow").map { |allow| allow.fetch("dependency-type") } if entry["allow"]
    normalized["group"] = entry["group"] || DEPENDABOT_GROUPS.fetch(ecosystem, "#{ecosystem}-dependencies")
    normalized["ignore"] = Array(entry["ignore"]).map { |ignore| normalized_ignore(ignore) }
    normalized
  end

  def normalized_rendered_entry(entry)
    normalized = { "package-ecosystem" => entry.fetch("package-ecosystem") }
    normalized["directory"] = entry.fetch("directory") if entry.key?("directory")
    normalized["directories"] = entry.fetch("directories") if entry.key?("directories")
    normalized["allow"] = entry.fetch("allow").map { |allow| allow.fetch("dependency-type") } if entry["allow"]
    normalized["group"] = entry.fetch("groups").keys.fetch(0)
    normalized["ignore"] = entry.fetch("ignore", [])
                                .reject { |ignore| ignore.fetch("dependency-name") == FLEET_PIN_IGNORE }
                                .map { |ignore| normalized_ignore(ignore) }
    normalized
  end

  # `reason` renders as a YAML comment, so it is documentation, not data.
  def normalized_ignore(ignore)
    normalized = { "dependency-name" => ignore.fetch("dependency-name") }
    normalized["versions"] = ignore.fetch("versions") if ignore["versions"]
    normalized["update-types"] = ignore.fetch("update-types") if ignore["update-types"]
    normalized
  end

  def dependabot_key(entry)
    [entry.fetch("package-ecosystem"), entry["directory"].to_s, Array(entry["directories"]).join]
  end

  def assert_npm_policy(repo_root, config)
    checker = File.join(repo_root, "scripts/check-npm-install-policy.mjs")
    assert_equal File.read(File.join(ROOT, "fleet/files/check-npm-install-policy.mjs")), File.read(checker)

    projects = params(config).fetch("npm-policy").fetch("projects")
    assert_includes File.read(File.join(repo_root, "justfile")),
                    "node scripts/check-npm-install-policy.mjs #{projects.join(" ")}"
  end

  def assert_workflow_shapes(repo_root, name, config)
    version = fleet_version
    Dir.glob(File.join(repo_root, ".github/workflows/*.yml")).each do |path|
      text = File.read(path)
      workflow = YAML.safe_load(text, permitted_classes: [], aliases: false)
      label = "#{name}/#{File.basename(path)}"

      assert workflow.key?(true), "#{label} must declare triggers"
      assert_equal({}, workflow.fetch("permissions"), "#{label} must keep top-level permissions empty")

      pins = text.scan(REUSABLE_USES_PATTERN)
      assert pins.any?, "#{label} must call a reusable workflow"
      pins.each do |workflow_path, ref, comment|
        assert_match(/\A\h{40}\z/, ref, "#{label} pins #{workflow_path} to #{ref}, not a full SHA")
        assert_equal "# #{version}", comment, "#{label} pin comment must carry the fleet version"
      end
    end

    assert_link_check(repo_root, name, config)
    assert_codeql(repo_root, name, config)
    assert_zizmor(repo_root, name, config)
    assert_pinprick(repo_root, name, config)
  end

  def assert_link_check(repo_root, name, config)
    link = params(config)["link-check"]
    return unless link

    workflow = YAML.safe_load_file(File.join(repo_root, ".github/workflows/link-check.yml"),
                                   permitted_classes: [], aliases: false)
    triggers = workflow.fetch(true)
    assert_equal link.fetch("targets"),
                 workflow.fetch("jobs").fetch("lychee").fetch("with").fetch("args"),
                 "link-check args mismatch for #{name}"

    pull_request_paths = link.fetch("pull-request-paths", [])
    if pull_request_paths.empty?
      refute triggers.key?("pull_request"), "link-check for #{name} must not trigger on pull requests"
    else
      assert_equal pull_request_paths, triggers.fetch("pull_request").fetch("paths"),
                   "link-check pull-request paths mismatch for #{name}"
    end
  end

  def assert_codeql(repo_root, name, config)
    codeql = params(config)["codeql"] || {}
    return unless codeql["languages"] && !exception?(config, "codeql")

    workflow = YAML.safe_load_file(File.join(repo_root, ".github/workflows/codeql.yml"),
                                   permitted_classes: [], aliases: false)
    with = workflow.fetch("jobs").fetch("analyze").fetch("with")
    assert_equal codeql.fetch("languages"), JSON.parse(with.fetch("languages")),
                 "codeql languages mismatch for #{name}"

    paths = codeql.fetch("paths", [])
    assert_equal paths, workflow.fetch(true).fetch("push").fetch("paths", []), "codeql paths mismatch for #{name}" \
      unless paths.empty?
  end

  def assert_zizmor(repo_root, name, config)
    return if exception?(config, "zizmor")

    workflow = YAML.safe_load_file(File.join(repo_root, ".github/workflows/zizmor.yml"),
                                   permitted_classes: [], aliases: false)
    push_paths = workflow.fetch(true).fetch("push").fetch("paths")
    assert_includes push_paths, ".github/workflows/**", "zizmor must watch workflows for #{name}"
    (params(config).dig("zizmor", "push-paths") || []).each do |path|
      assert_includes push_paths, path, "zizmor must watch configured path #{path} for #{name}"
    end
  end

  def assert_pinprick(repo_root, name, config)
    return if exception?(config, "pinprick-audit")

    workflow = YAML.safe_load_file(File.join(repo_root, ".github/workflows/pinprick-audit.yml"),
                                   permitted_classes: [], aliases: false)
    with = workflow.fetch("jobs").fetch("audit").fetch("with")
    assert with.key?("advanced-security"), "pinprick-audit must pass advanced-security for #{name}"
    assert_equal params(config).dig("pinprick-audit", "fail-on-findings") != false,
                 with.fetch("fail-on-findings"),
                 "pinprick-audit fail-on-findings mismatch for #{name}"
  end
end
