# frozen_string_literal: true

require "json"
require "optparse"

module FleetPullRequestIdentity
  class Error < StandardError; end

  module_function

  def exact?(pull, repository:, branch:, base:, author:, head_oid: nil)
    pull.dig("head", "repo", "full_name") == repository &&
      pull.dig("head", "ref") == branch &&
      pull.dig("base", "ref") == base &&
      pull.dig("user", "login") == author &&
      (!head_oid || pull.dig("head", "sha") == head_oid)
  end

  def select(pulls, **identity)
    matches = pulls.select { |pull| exact?(pull, **identity) }
    raise Error, "expected exactly one App-owned pull request, found #{matches.length}" unless matches.one?

    matches.first.fetch("number")
  end

  def select_optional(pulls, repository:, branch:, base:, author:, head_oid:)
    candidates = pulls.select do |pull|
      pull.dig("head", "repo", "full_name") == repository &&
        pull.dig("head", "ref") == branch &&
        pull.dig("base", "ref") == base
    end
    return nil if candidates.empty?
    raise Error, "expected at most one same-repository pull request, found #{candidates.length}" unless candidates.one?
    unless exact?(candidates.first, repository: repository, branch: branch, base: base, author: author,
                                    head_oid: head_oid)
      raise Error, "same-repository pull request does not match the App author and verified commit"
    end

    candidates.first.fetch("number")
  end

  def assert_owned_or_absent(pulls, repository:, branch:, base:, author:)
    candidates = pulls.select do |pull|
      pull.dig("head", "repo", "full_name") == repository &&
        pull.dig("head", "ref") == branch
    end
    return if candidates.empty?
    raise Error, "expected at most one same-repository pull request, found #{candidates.length}" unless candidates.one?
    return if exact?(candidates.first, repository: repository, branch: branch, base: base, author: author)

    raise Error, "reserved branch belongs to a pull request outside App ownership"
  end

  def stale(pulls, repository:, prefix:, current_branch:, base:, author:)
    pulls.filter_map do |pull|
      branch = pull.dig("head", "ref")
      next unless branch&.start_with?(prefix)
      next if branch == current_branch
      next unless exact?(pull, repository: repository, branch: branch, base: base, author: author)

      pull.fetch("number")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    command = ARGV.shift
    options = { base: "main" }
    OptionParser.new do |parser|
      parser.on("--repository OWNER/REPO") { |value| options[:repository] = value }
      parser.on("--branch BRANCH") { |value| options[:branch] = value }
      parser.on("--base BRANCH") { |value| options[:base] = value }
      parser.on("--author LOGIN") { |value| options[:author] = value }
      parser.on("--head-oid SHA") { |value| options[:head_oid] = value }
      parser.on("--prefix PREFIX") { |value| options[:prefix] = value }
      parser.on("--current-branch BRANCH") { |value| options[:current_branch] = value }
    end.parse!(ARGV)

    pulls = JSON.parse($stdin.read)
    raise FleetPullRequestIdentity::Error, "pull request response must be an array" unless pulls.is_a?(Array)

    case command
    when "preflight"
      required = options.slice(:repository, :branch, :base, :author)
      FleetPullRequestIdentity.assert_owned_or_absent(pulls, **required)
    when "select"
      required = options.slice(:repository, :branch, :base, :author, :head_oid)
      puts FleetPullRequestIdentity.select(pulls, **required)
    when "optional"
      required = options.slice(:repository, :branch, :base, :author, :head_oid)
      number = FleetPullRequestIdentity.select_optional(pulls, **required)
      puts number if number
    when "stale"
      required = options.slice(:repository, :prefix, :current_branch, :base, :author)
      puts FleetPullRequestIdentity.stale(pulls, **required)
    else
      raise FleetPullRequestIdentity::Error, "usage: pr_identity.rb preflight|select|optional|stale [options]"
    end
  rescue JSON::ParserError, KeyError, FleetPullRequestIdentity::Error => e
    warn "fleet pull request identity: #{e.message}"
    exit 1
  end
end
