# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

class NpmInstallPolicyTest < Minitest::Test
  CHECKER = File.expand_path("../files/check-npm-install-policy.mjs", __dir__)

  def test_accepts_exact_approval_and_name_wide_denial
    [{ "compiler@1.2.3" => true }, { "compiler" => false }].each do |policy|
      output, status = check(policy: policy)

      assert status.success?, output
      assert_includes output, "covers 1 locked package version(s)"
    end
  end

  def test_rejects_missing_broad_or_stale_approval
    [{}, { "compiler" => true }, { "compiler@1.2.2" => true }].each do |policy|
      output, status = check(policy: policy)

      refute status.success?, output
      assert_includes output, "install script is not denied or exactly approved"
    end
  end

  def test_accepts_an_empty_supported_lockfile
    output, status = check(policy: {}, lockfile: { "lockfileVersion" => 3, "packages" => {} })

    assert status.success?, output
    assert_includes output, "covers 0 locked package version(s)"
  end

  def test_rejects_missing_or_unsupported_package_metadata
    [
      {},
      { "lockfileVersion" => 1, "dependencies" => {} },
      { "lockfileVersion" => 3 },
      { "lockfileVersion" => 3, "packages" => [] },
      { "lockfileVersion" => 3, "packages" => nil }
    ].each do |lockfile|
      output, status = check(policy: {}, lockfile: lockfile)

      refute status.success?, "accepted malformed lockfile: #{lockfile.inspect}\n#{output}"
      assert_includes output, "package-lock.json must use lockfileVersion 2 or 3 with a packages object"
    end
  end

  private

  def check(policy:, lockfile: nil)
    lockfile ||= {
      "lockfileVersion" => 3,
      "packages" => {
        "node_modules/compiler" => { "version" => "1.2.3", "hasInstallScript" => true }
      }
    }
    Dir.mktmpdir("fleet-npm-policy-") do |directory|
      File.write(File.join(directory, "package.json"), JSON.generate({ "allowScripts" => policy }))
      File.write(File.join(directory, "package-lock.json"), JSON.generate(lockfile))
      Open3.capture2e("node", CHECKER, directory)
    end
  end
end
