# frozen_string_literal: true

require "date"
require "open3"
require "optparse"

module FleetVersion
  VERSION_PATTERN = /\Av(?<year>\d{4})\.(?<month>\d{2})\.(?<day>\d{2})\.(?<sequence>[1-9]\d*)\z/

  class Error < StandardError; end

  Version = Struct.new(:text, :date, :sequence, keyword_init: true) do
    include Comparable

    def <=>(other)
      [date, sequence] <=> [other.date, other.sequence]
    end
  end

  module_function

  def parse(text, source: "fleet/VERSION")
    unless text.match?(/\Av[^\r\n]*(?:\n)?\z/) && !text.end_with?("\n\n")
      raise Error, "#{source} must contain exactly one version line with an optional trailing newline"
    end

    value = text.delete_suffix("\n")
    match = value.match(VERSION_PATTERN)
    raise Error, "#{source} must match vYYYY.MM.DD.N with a positive, unpadded sequence" unless match

    date = Date.new(match[:year].to_i, match[:month].to_i, match[:day].to_i)
    Version.new(text: value, date: date, sequence: match[:sequence].to_i)
  rescue Date::Error
    raise Error, "#{source} contains an invalid calendar date"
  end

  def read(path)
    stat = File.lstat(path)
    raise Error, "#{path} must be a regular file, not a symlink" unless stat.file?

    parse(File.binread(path), source: path).text
  rescue Errno::ENOENT, Errno::ENOTDIR
    raise Error, "#{path} must be a regular file"
  end

  def next_version(current_text, today: Date.today)
    current = parse(current_text)
    raise Error, "fleet/VERSION is dated after the release date" if current.date > today

    sequence = current.date == today ? current.sequence + 1 : 1
    format("v%<year>04d.%<month>02d.%<day>02d.%<sequence>d",
           year: today.year, month: today.month, day: today.day, sequence: sequence)
  end

  def git(repository, *)
    git_raw(repository, *).strip
  end

  def git_raw(repository, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", repository, *arguments)
    raise Error, "git #{arguments.join(" ")} failed: #{stderr.strip}" unless status.success?

    stdout
  end

  def tag_target(repository:, version:)
    type = git(repository, "cat-file", "-t", "refs/tags/#{version}")
    raise Error, "#{version} must be an annotated tag, got #{type}" unless type == "tag"

    tagged_name = git(repository, "for-each-ref", "--format=%(tag)", "refs/tags/#{version}")
    raise Error, "annotated tag metadata does not name #{version}" unless tagged_name == version

    annotation = git_raw(repository, "for-each-ref", "--format=%(contents)", "refs/tags/#{version}")
    annotation = annotation.delete_suffix("\n").delete_suffix("\n")
    raise Error, "#{version} annotation must be exactly Fleet #{version}" unless annotation == "Fleet #{version}"

    target_type = git(repository, "for-each-ref", "--format=%(*objecttype)", "refs/tags/#{version}")
    raise Error, "#{version} must point directly to a commit" unless target_type == "commit"

    git(repository, "rev-parse", "refs/tags/#{version}^{}")
  end

  def verify_tag(repository:, version_file:, expected_commit: nil, expected_version: nil, main_ref: nil)
    version = read(version_file)
    parsed_version = parse(version, source: version_file)
    raise Error, "fleet/VERSION must not be dated in the future" if parsed_version.date > Date.today

    if expected_version && version != expected_version
      raise Error, "#{version_file} names #{version}, not triggering tag #{expected_version}"
    end

    target = tag_target(repository: repository, version: version)
    if expected_commit && target != expected_commit
      raise Error, "#{version} peels to #{target}, expected #{expected_commit}"
    end

    tagged_version = git_raw(repository, "show", "#{target}:fleet/VERSION")
    parsed_tagged_version = parse(tagged_version, source: "#{version}:fleet/VERSION").text
    unless parsed_tagged_version == version
      raise Error, "#{version} points to a commit whose fleet/VERSION is #{parsed_tagged_version}"
    end

    if main_ref
      verify_main_membership(
        repository: repository,
        main_ref: main_ref,
        target: target,
        version: version
      )
    end

    target
  end

  def verify_main_membership(repository:, main_ref:, target:, version:)
    main_version = parse(
      git_raw(repository, "show", "#{main_ref}:fleet/VERSION"),
      source: "#{main_ref}:fleet/VERSION"
    ).text
    raise Error, "#{main_ref} names fleet release #{main_version}, not #{version}" unless main_version == version

    _stdout, stderr, status = Open3.capture3(
      "git", "-C", repository, "merge-base", "--is-ancestor", target, main_ref
    )
    unless status.success?
      detail = stderr.strip
      detail = "tag target is not in trusted main history" if detail.empty?
      raise Error, "#{version} is not an authenticated release from #{main_ref}: #{detail}"
    end

    version_commit = git(repository, "log", "--first-parent", "-1", "--format=%H", main_ref, "--", "fleet/VERSION")
    return if version_commit == target

    raise Error, "#{version} tag target #{target} is not the commit that introduced the current main version"
  end

  def verify_transition(repository:, commit:, version_file:)
    current = parse("#{read(version_file)}\n", source: version_file)
    raise Error, "fleet/VERSION must not be dated in the future" if current.date > Date.today

    parent_text = git_raw(repository, "show", "#{commit}^:fleet/VERSION")
    previous = parse(parent_text, source: "#{commit}^:fleet/VERSION")
    unless current > previous
      raise Error, "fleet/VERSION must advance monotonically (#{previous.text} -> #{current.text})"
    end

    commit_version = git_raw(repository, "show", "#{commit}:fleet/VERSION")
    parsed_commit_version = parse(commit_version, source: "#{commit}:fleet/VERSION")
    unless parsed_commit_version.text == current.text
      raise Error, "#{version_file} does not match #{commit}:fleet/VERSION"
    end

    current.text
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    command = ARGV.shift
    options = { repository: ".", version_file: "fleet/VERSION" }
    OptionParser.new do |parser|
      parser.on("--repository PATH") { |value| options[:repository] = value }
      parser.on("--version-file PATH") { |value| options[:version_file] = value }
      parser.on("--expected-commit SHA") { |value| options[:expected_commit] = value }
      parser.on("--expected-version VERSION") { |value| options[:expected_version] = value }
      parser.on("--main-ref REF") { |value| options[:main_ref] = value }
      parser.on("--commit SHA") { |value| options[:commit] = value }
    end.parse!(ARGV)

    case command
    when "read"
      puts FleetVersion.read(options.fetch(:version_file))
    when "next"
      puts FleetVersion.next_version(FleetVersion.read(options.fetch(:version_file)))
    when "verify-tag"
      puts FleetVersion.verify_tag(
        **options.slice(:repository, :version_file, :expected_commit, :expected_version, :main_ref)
      )
    when "verify-transition"
      raise FleetVersion::Error, "--commit is required" unless options[:commit]

      puts FleetVersion.verify_transition(**options.slice(:repository, :commit, :version_file))
    else
      raise FleetVersion::Error, "usage: version.rb read|next|verify-tag|verify-transition [options]"
    end
  rescue FleetVersion::Error => e
    warn "fleet version: #{e.message}"
    exit 1
  end
end
