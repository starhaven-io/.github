# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../version"

class FleetVersionTest < Minitest::Test
  def test_accepts_exact_calver_with_optional_trailing_newline
    assert_equal "v2026.09.02.1", FleetVersion.parse("v2026.09.02.1\n").text
    assert_equal "v2026.09.02.12", FleetVersion.parse("v2026.09.02.12").text
  end

  def test_rejects_invalid_versions
    [
      "v2026.02.30.1\n", "v2026.9.02.1\n", "v2026.09.02.0\n",
      "v2026.09.02.01\n", " v2026.09.02.1\n", "v2026.09.02.1\nextra\n"
    ].each { |value| assert_raises(FleetVersion::Error) { FleetVersion.parse(value) } }
  end

  def test_computes_next_monotonic_version_from_current_version
    assert_equal "v2026.09.02.4",
                 FleetVersion.next_version("v2026.09.02.3\n", today: Date.new(2026, 9, 2))
    assert_equal "v2026.09.03.1",
                 FleetVersion.next_version("v2026.09.02.3\n", today: Date.new(2026, 9, 3))
    assert_raises(FleetVersion::Error) do
      FleetVersion.next_version("v2026.09.03.1\n", today: Date.new(2026, 9, 2))
    end
  end

  def test_authenticates_annotated_tag_and_exact_commit
    Dir.mktmpdir("fleet-version-") do |repo|
      git(repo, "init", "-q")
      FileUtils.mkdir_p(File.join(repo, "fleet"))
      File.write(File.join(repo, "fleet/VERSION"), "v2026.09.02.1\n")
      git(repo, "add", "fleet/VERSION")
      git(repo, "-c", "user.name=Fleet Version Test", "-c", "user.email=fleet@example.invalid",
          "-c", "commit.gpgsign=false", "commit", "-qm", "release")
      commit = git(repo, "rev-parse", "HEAD").strip
      git(repo, "-c", "user.name=Fleet Version Test", "-c", "user.email=fleet@example.invalid",
          "tag", "-a", "v2026.09.02.1", "-m", "Fleet v2026.09.02.1")

      assert_equal commit, FleetVersion.verify_tag(
        repository: repo,
        version_file: File.join(repo, "fleet/VERSION"),
        expected_commit: commit,
        main_ref: "HEAD"
      )
      assert_raises(FleetVersion::Error) do
        FleetVersion.verify_tag(
          repository: repo, version_file: File.join(repo, "fleet/VERSION"), expected_commit: "0" * 40
        )
      end

      git(repo, "tag", "-d", "v2026.09.02.1")
      git(repo, "-c", "user.name=Fleet Version Test", "-c", "user.email=fleet@example.invalid",
          "tag", "-a", "v2026.09.02.1", "-m", "Fleet v2026.09.02.1", "-m", "unexpected body")
      assert_raises(FleetVersion::Error) do
        FleetVersion.verify_tag(repository: repo, version_file: File.join(repo, "fleet/VERSION"))
      end
    end
  end

  def test_rejects_tag_target_outside_trusted_main_history
    Dir.mktmpdir("fleet-version-") do |repo|
      git(repo, "init", "-q")
      FileUtils.mkdir_p(File.join(repo, "fleet"))
      File.write(File.join(repo, "fleet/VERSION"), "v2026.09.02.2\n")
      commit(repo, "main release")
      git(repo, "branch", "-M", "main")
      git(repo, "checkout", "-qb", "unmerged-release")
      File.write(File.join(repo, "README.md"), "unmerged canon\n")
      git(repo, "add", "README.md")
      git(repo, "-c", "user.name=Fleet Version Test", "-c", "user.email=fleet@example.invalid",
          "-c", "commit.gpgsign=false", "commit", "-qm", "unmerged release")
      git(repo, "-c", "user.name=Fleet Version Test", "-c", "user.email=fleet@example.invalid",
          "tag", "-a", "v2026.09.02.2", "-m", "Fleet v2026.09.02.2")

      error = assert_raises(FleetVersion::Error) do
        FleetVersion.verify_tag(
          repository: repo,
          version_file: File.join(repo, "fleet/VERSION"),
          main_ref: "main"
        )
      end
      assert_includes error.message, "not an authenticated release from main"
    end
  end

  def test_rejects_future_dated_transition
    Dir.mktmpdir("fleet-version-") do |repo|
      git(repo, "init", "-q")
      FileUtils.mkdir_p(File.join(repo, "fleet"))
      File.write(File.join(repo, "fleet/VERSION"), "v2998.09.02.1\n")
      commit(repo, "previous release")
      File.write(File.join(repo, "fleet/VERSION"), "v2999.09.02.1\n")
      commit(repo, "future release")
      current = git(repo, "rev-parse", "HEAD").strip

      error = assert_raises(FleetVersion::Error) do
        FleetVersion.verify_transition(
          repository: repo,
          commit: current,
          version_file: File.join(repo, "fleet/VERSION")
        )
      end
      assert_includes error.message, "must not be dated in the future"
    end
  end

  def test_rejects_future_dated_published_tag
    Dir.mktmpdir("fleet-version-") do |repo|
      git(repo, "init", "-q")
      FileUtils.mkdir_p(File.join(repo, "fleet"))
      File.write(File.join(repo, "fleet/VERSION"), "v2999.09.02.1\n")
      commit(repo, "future release")
      git(repo, "-c", "user.name=Fleet Version Test", "-c", "user.email=fleet@example.invalid",
          "tag", "-a", "v2999.09.02.1", "-m", "Fleet v2999.09.02.1")

      error = assert_raises(FleetVersion::Error) do
        FleetVersion.verify_tag(repository: repo, version_file: File.join(repo, "fleet/VERSION"))
      end
      assert_includes error.message, "must not be dated in the future"
    end
  end

  def test_rejects_rolled_back_main_version_even_when_old_tag_is_valid
    Dir.mktmpdir("fleet-version-") do |repo|
      git(repo, "init", "-q")
      FileUtils.mkdir_p(File.join(repo, "fleet"))
      File.write(File.join(repo, "fleet/VERSION"), "v2026.09.02.1\n")
      commit(repo, "first release")
      git(repo, "branch", "-M", "main")
      git(repo, "-c", "user.name=Fleet Version Test", "-c", "user.email=fleet@example.invalid",
          "tag", "-a", "v2026.09.02.1", "-m", "Fleet v2026.09.02.1")
      File.write(File.join(repo, "fleet/VERSION"), "v2026.09.02.2\n")
      commit(repo, "second release")
      File.write(File.join(repo, "fleet/VERSION"), "v2026.09.02.1\n")
      commit(repo, "roll back version")

      error = assert_raises(FleetVersion::Error) do
        FleetVersion.verify_tag(
          repository: repo,
          version_file: File.join(repo, "fleet/VERSION"),
          main_ref: "main"
        )
      end
      assert_includes error.message, "is not the commit that introduced the current main version"
    end
  end

  def test_accepts_release_tag_on_a_no_ff_merge_commit
    Dir.mktmpdir("fleet-version-") do |repo|
      git(repo, "init", "-q")
      FileUtils.mkdir_p(File.join(repo, "fleet"))
      File.write(File.join(repo, "fleet/VERSION"), "v2026.09.02.1\n")
      commit(repo, "first release")
      git(repo, "branch", "-M", "main")
      git(repo, "checkout", "-qb", "release")
      File.write(File.join(repo, "fleet/VERSION"), "v2026.09.02.2\n")
      commit(repo, "prepare release")
      git(repo, "checkout", "-q", "main")
      git(repo, "-c", "user.name=Fleet Version Test", "-c", "user.email=fleet@example.invalid",
          "-c", "commit.gpgsign=false", "merge", "--no-ff", "-qm", "merge release", "release")
      merge_commit = git(repo, "rev-parse", "HEAD").strip
      git(repo, "-c", "user.name=Fleet Version Test", "-c", "user.email=fleet@example.invalid",
          "tag", "-a", "v2026.09.02.2", "-m", "Fleet v2026.09.02.2")

      assert_equal merge_commit, FleetVersion.verify_tag(
        repository: repo,
        version_file: File.join(repo, "fleet/VERSION"),
        main_ref: "main"
      )
    end
  end

  def test_rejects_release_when_version_change_is_not_the_tip_commit
    Dir.mktmpdir("fleet-version-") do |repo|
      git(repo, "init", "-q")
      FileUtils.mkdir_p(File.join(repo, "fleet"))
      File.write(File.join(repo, "fleet/VERSION"), "v2026.09.02.1\n")
      commit(repo, "first release")
      File.write(File.join(repo, "fleet/VERSION"), "v2026.09.02.2\n")
      commit(repo, "prepare release")
      File.write(File.join(repo, "README.md"), "follow-up commit\n")
      git(repo, "add", "README.md")
      git(repo, "-c", "user.name=Fleet Version Test", "-c", "user.email=fleet@example.invalid",
          "-c", "commit.gpgsign=false", "commit", "-qm", "follow up")
      tip = git(repo, "rev-parse", "HEAD").strip

      error = assert_raises(FleetVersion::Error) do
        FleetVersion.verify_transition(
          repository: repo,
          commit: tip,
          version_file: File.join(repo, "fleet/VERSION")
        )
      end
      assert_includes error.message, "must advance monotonically"
    end
  end

  def test_rejects_lightweight_release_tag
    Dir.mktmpdir("fleet-version-") do |repo|
      git(repo, "init", "-q")
      FileUtils.mkdir_p(File.join(repo, "fleet"))
      File.write(File.join(repo, "fleet/VERSION"), "v2026.09.02.1\n")
      git(repo, "add", "fleet/VERSION")
      git(repo, "-c", "user.name=Fleet Version Test", "-c", "user.email=fleet@example.invalid",
          "-c", "commit.gpgsign=false", "commit", "-qm", "release")
      git(repo, "tag", "v2026.09.02.1")

      assert_raises(FleetVersion::Error) do
        FleetVersion.verify_tag(repository: repo, version_file: File.join(repo, "fleet/VERSION"))
      end
    end
  end

  private

  def commit(repo, message)
    git(repo, "add", "fleet/VERSION")
    git(repo, "-c", "user.name=Fleet Version Test", "-c", "user.email=fleet@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-qm", message)
  end

  def git(repo, *)
    stdout, stderr, status = Open3.capture3("git", *, chdir: repo)
    raise stderr unless status.success?

    stdout
  end
end
