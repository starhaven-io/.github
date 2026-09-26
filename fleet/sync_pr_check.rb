# frozen_string_literal: true

require "open3"
require "optparse"
require "securerandom"
require "tmpdir"
require_relative "version"

# An authorized but compromised sync App can open a fleet-sync-* pull request
# with any contents, so the required guard accepts one only when its tree is
# exactly what the release named by trusted hub main renders onto its merge base.
module FleetSyncPullRequest
  class Error < StandardError
    attr_reader :details

    def initialize(message, details = [])
      super(message)
      @details = details
    end
  end

  BRANCH_PREFIX = "fleet-sync-"
  SHA_PATTERN = /\A\h{40}\z/
  DIFFERENCE_LABELS = { "A" => "unexpected", "D" => "missing", "M" => "differs", "T" => "type differs" }.freeze

  module_function

  def verify!(hub_root:, repo_root:, repo_name:, base:, head:, branch:)
    [base, head].each { |sha| raise Error, "#{sha.inspect} is not a full commit SHA" unless sha.match?(SHA_PATTERN) }

    version_file = File.join(hub_root, "fleet/VERSION")
    version = FleetVersion.read(version_file)
    unless branch == "#{BRANCH_PREFIX}#{version}"
      raise Error, "branch #{branch.inspect} does not name the current fleet release #{version}"
    end

    main_ref = git(hub_root, "rev-parse", "--verify", "HEAD^{commit}")
    release = FleetVersion.verify_tag(repository: hub_root, version_file:, expected_version: version, main_ref:)
    merge_base = git(repo_root, "merge-base", base, head)
    expected = rendered_tree(hub_root:, repo_root:, repo_name:, release:, main_ref:, merge_base:)
    actual = git(repo_root, "rev-parse", "--verify", "#{head}^{tree}")
    return if expected == actual

    raise Error.new("pull request differs from the #{version} render of merge base #{merge_base}",
                    differences(repo_root, expected, actual))
  rescue FleetVersion::Error => e
    raise Error, "release authentication failed: #{e.message}"
  end

  # Mirrors fleet-sync.yml: current-main preflight, then the tagged renderer.
  def rendered_tree(hub_root:, repo_root:, repo_name:, release:, main_ref:, merge_base:)
    Dir.mktmpdir("fleet-sync-pr-") do |directory|
      release_root = File.join(directory, "release")
      render_root = File.join(directory, "render")
      begin
        git(hub_root, "worktree", "add", "--quiet", "--detach", release_root, release)
        git(repo_root, "worktree", "add", "--quiet", "--detach", render_root, merge_base)
        render("ruby", File.join(hub_root, "fleet/sync.rb"), "--hub-root", release_root, "--repo-root", render_root,
               "--repo-name", repo_name, "--publish", "--publication-preflight", "--main-ref", main_ref)
        render("ruby", File.join(release_root, "fleet/sync.rb"), "--hub-root", release_root,
               "--repo-root", render_root, "--repo-name", repo_name)
        git(render_root, "add", "--all")
        git(render_root, "write-tree")
      ensure
        [[hub_root, release_root], [repo_root, render_root]].each do |repository, worktree|
          system("git", "-C", repository, "worktree", "remove", "--force", worktree, out: File::NULL, err: File::NULL)
        end
      end
    end
  end

  def differences(repo_root, expected, actual)
    entries = git_raw(repo_root, "diff-tree", "-r", "-z", "--no-renames", "--name-status", expected, actual)
    entries.split("\0").each_slice(2).map do |status, path|
      "#{DIFFERENCE_LABELS.fetch(status, status)}: #{path.inspect}"
    end
  end

  def render(*command)
    _stdout, stderr, status = Open3.capture3(*command)
    raise Error, "release render of the merge base failed: #{stderr.strip}" unless status.success?
  end

  def git(repository, *)
    git_raw(repository, *).strip
  end

  def git_raw(repository, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", repository, *arguments)
    raise Error, "git #{arguments.first} failed: #{stderr.strip}" unless status.success?

    stdout
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.on("--hub-root PATH") { |value| options[:hub_root] = value }
    parser.on("--repo-root PATH") { |value| options[:repo_root] = value }
    parser.on("--repo-name NAME") { |value| options[:repo_name] = value }
    parser.on("--base SHA") { |value| options[:base] = value }
    parser.on("--head SHA") { |value| options[:head] = value }
    parser.on("--branch REF") { |value| options[:branch] = value }
  end.parse!(ARGV)

  begin
    missing = %i[hub_root repo_root repo_name base head branch] - options.keys
    raise FleetSyncPullRequest::Error, "missing --#{missing.first.to_s.tr("_", "-")}" if missing.any?

    FleetSyncPullRequest.verify!(**options)
    puts "fleet sync pull request matches the authenticated release render"
  rescue FleetSyncPullRequest::Error => e
    # Branch names and paths come from the pull request; keep them away from
    # the runner's workflow-command parser.
    token = SecureRandom.hex(16)
    puts "::stop-commands::#{token}"
    puts "fleet sync pull request rejected: #{e.message}"
    e.details.each { |detail| puts "  #{detail}" }
    puts "::#{token}::"
    puts "::error::fleet sync pull request rejected; see the log above"
    exit 1
  end
end
