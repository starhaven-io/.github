# frozen_string_literal: true

require "minitest/autorun"
require_relative "../pr_identity"

class FleetPullRequestIdentityTest < Minitest::Test
  def pull(number:, repository:, branch:, sha:, author:, base: "main")
    {
      "number" => number,
      "head" => { "repo" => { "full_name" => repository }, "ref" => branch, "sha" => sha },
      "base" => { "ref" => base },
      "user" => { "login" => author }
    }
  end

  def identity
    {
      repository: "starhaven-io/example", branch: "fleet-sync-v2026.09.02.1",
      base: "main", author: "starhaven-bot[bot]", head_oid: "good"
    }
  end

  def test_select_ignores_same_named_fork_before_canonical_pr
    pulls = [
      pull(number: 1, repository: "attacker/example", branch: identity[:branch], sha: "evil",
           author: "attacker"),
      pull(number: 2, repository: identity[:repository], branch: identity[:branch], sha: "good",
           author: identity[:author])
    ]

    assert_equal 2, FleetPullRequestIdentity.select(pulls, **identity)
  end

  def test_select_fails_without_one_exact_match
    assert_raises(FleetPullRequestIdentity::Error) { FleetPullRequestIdentity.select([], **identity) }
    canonical = pull(number: 2, repository: identity[:repository], branch: identity[:branch], sha: "good",
                     author: identity[:author])
    assert_raises(FleetPullRequestIdentity::Error) do
      FleetPullRequestIdentity.select([canonical, canonical.merge("number" => 3)], **identity)
    end
  end

  def test_optional_selection_rejects_a_same_repo_pr_with_the_wrong_author
    wrong = pull(number: 2, repository: identity[:repository], branch: identity[:branch], sha: "good",
                 author: "maintainer")

    assert_raises(FleetPullRequestIdentity::Error) do
      FleetPullRequestIdentity.select_optional([wrong], **identity)
    end
    assert_nil FleetPullRequestIdentity.select_optional([], **identity)
  end

  def test_preflight_rejects_non_app_ownership_before_branch_reset
    wrong = pull(number: 2, repository: identity[:repository], branch: identity[:branch], sha: "old",
                 author: "maintainer")

    assert_raises(FleetPullRequestIdentity::Error) do
      FleetPullRequestIdentity.assert_owned_or_absent([wrong], **identity.except(:head_oid))
    end
    FleetPullRequestIdentity.assert_owned_or_absent([], **identity.except(:head_oid))
  end

  def test_stale_cleanup_excludes_forks_and_non_app_authors
    pulls = [
      pull(number: 1, repository: "attacker/example", branch: "fleet-sync-old", sha: "a", author: "attacker"),
      pull(number: 2, repository: identity[:repository], branch: "fleet-sync-old", sha: "b", author: "maintainer"),
      pull(number: 3, repository: identity[:repository], branch: "fleet-sync-old", sha: "c",
           author: identity[:author]),
      pull(number: 4, repository: identity[:repository], branch: identity[:branch], sha: "good",
           author: identity[:author])
    ]

    assert_equal [3], FleetPullRequestIdentity.stale(
      pulls,
      repository: identity[:repository], prefix: "fleet-sync-", current_branch: identity[:branch],
      base: "main", author: identity[:author]
    )
  end
end
