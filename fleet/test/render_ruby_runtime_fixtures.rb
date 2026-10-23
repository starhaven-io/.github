# frozen_string_literal: true

require "erb"
require "json"
require "yaml"
require_relative "../ruby_runtime"

root = File.expand_path("../..", __dir__)
destination = ARGV.fetch(0)
template = ERB.new(File.read(File.join(root, "fleet/templates/renovate.json.erb")))
fleet_version = File.read(File.join(root, "fleet/VERSION")).strip
profiles = YAML.safe_load_file(File.join(root, "fleet/repos.yml")).fetch("repos").filter_map do |name|
  runtime = YAML.safe_load_file(File.join(root, "fleet/repos/#{name}.yml")).dig("params", "ruby-runtime")
  { "name" => name, "runtime" => runtime } if runtime && runtime["update-companions"]
end

# No current consumer has both companion types; cover their composition too.
profiles << { "name" => "combined", "runtime" => {
  "version-file" => ".ruby-version", "checksum-file" => ".ruby-version.sha256",
  "lock-files" => ["Gemfile.lock"], "require-lock-version" => true, "update-companions" => true
} }

profiles.each do |profile|
  runtime = profile.fetch("runtime")
  RubyRuntime.validate_config!(runtime)
  path = File.join(destination, "#{profile.fetch("name")}.json")
  File.write(path, template.result_with_hash(fleet_version:, ruby_runtime: runtime))
  profile["stub"] = path
end
puts JSON.generate(profiles)
