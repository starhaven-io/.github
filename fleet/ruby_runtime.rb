# frozen_string_literal: true

require "yaml"

# This module treats repository contents as data. It never loads a Gemfile,
# runs Bundler, downloads code, writes a checkout, or publishes a commit.
module RubyRuntime
  class Error < StandardError; end

  VERSION = /\A[0-9]+\.[0-9]+\.[0-9]+\z/
  LOCK_HEADER = /^[ \t]*RUBY[ \t]+VERSION\b[^\r\n]*/
  LOCK_SECTION = /^RUBY VERSION\r?\n {2,3}ruby ([0-9]+\.[0-9]+\.[0-9]+)(p[0-9]+)?\r?\n(?=\r?\n|\z)/

  module_function

  def validate_config!(config)
    raise Error, "ruby-runtime must be a mapping" unless config.is_a?(Hash)

    allowed = %w[version-file lock-files checksum-file update-companions require-lock-version]
    raise Error, "unknown ruby-runtime setting" unless (config.keys - allowed).empty?

    version = config["version-file"]
    unless [".ruby-version", "fleet/.ruby-version"].include?(version)
      raise Error, "version-file must name .ruby-version or fleet/.ruby-version"
    end

    locks = config.fetch("lock-files", [])
    directory = File.dirname(version)
    expected_lock = directory == "." ? "Gemfile.lock" : "#{directory}/Gemfile.lock"
    unless locks.is_a?(Array) && [[], [expected_lock]].include?(locks)
      raise Error, "lock-files must name the adjacent Gemfile.lock, at most once"
    end
    if config.key?("checksum-file") && config["checksum-file"] != "#{version}.sha256"
      raise Error, "checksum-file must be the version file's .sha256 companion"
    end

    invalid_flag = %w[update-companions require-lock-version].any? do |key|
      config.key?(key) && ![true, false].include?(config[key])
    end
    return unless invalid_flag

    raise Error, "runtime flags must be boolean"
  end

  def paths(config)
    validate_config!(config)
    [config.fetch("version-file"), *config.fetch("lock-files", []), config["checksum-file"]].compact
  end

  def read_files(root, config)
    root = File.realpath(root)
    paths(config).to_h do |relative|
      Pathname(relative).descend do |part|
        raise Error, "#{relative}: symlink forbidden" if File.symlink?(File.join(root, part))
      end
      path = File.join(root, relative)
      raise Error, "#{relative}: missing regular file" unless File.file?(path)
      raise Error, "#{relative}: file too large" if File.size(path) > 4 * 1024 * 1024

      [relative, File.binread(path)]
    end
  end

  def version!(text)
    value = text.delete_suffix("\n")
    unless VERSION.match?(value) && text == "#{value}\n"
      raise Error,
            "runtime must be one exact release followed by a newline"
    end

    value
  end

  def lock_version!(text)
    return unless text.match?(LOCK_HEADER)

    matches = text.scan(LOCK_SECTION)
    unless text.scan(LOCK_HEADER).length == 1 && matches.length == 1
      raise Error, "malformed or duplicate RUBY VERSION section"
    end

    matches.first.first
  end

  def checksum!(text)
    match = /\A([a-f0-9]{64})  ruby-([0-9]+\.[0-9]+\.[0-9]+)-ubuntu-24\.04-x64\.tar\.gz\n\z/.match(text)
    raise Error, "malformed Ruby archive checksum or filename" unless match

    [match[1], match[2]]
  end

  def check!(files, config)
    version = version!(files.fetch(config.fetch("version-file")))
    config.fetch("lock-files", []).each do |path|
      locked = lock_version!(files.fetch(path))
      raise Error, "#{path}: required RUBY VERSION section missing" if config["require-lock-version"] && !locked
      raise Error, "#{path}: RUBY VERSION #{locked} differs from #{version}" if locked && locked != version
    end
    if (path = config["checksum-file"])
      _, archived = checksum!(files.fetch(path))
      raise Error, "#{path}: archive version #{archived} differs from #{version}" unless archived == version
    end
    files
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    command, root, config_path = ARGV
    abort "usage: ruby ruby_runtime.rb check REPO_ROOT CANONICAL_CONFIG" unless command == "check" && ARGV.length == 3
    config = YAML.safe_load_file(config_path, permitted_classes: [], aliases: false).fetch("params").fetch(
      "ruby-runtime", nil
    )
    RubyRuntime.check!(RubyRuntime.read_files(root, config), config) if config
  rescue RubyRuntime::Error, KeyError, SystemCallError, Psych::Exception => e
    abort "Ruby runtime consistency: #{e.message}"
  end
end
