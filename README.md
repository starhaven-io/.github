# .github

GitHub community health files for the [starhaven-io](https://github.com/starhaven-io) organization.

[`profile/README.md`](profile/README.md) renders as the org landing page at <https://github.com/starhaven-io>.

## Fleet

[`fleet/`](fleet/) holds the org's shared-surface renderer: a stdlib-only
Ruby tool that keeps editor config, git hooks, agent conventions, Dependabot
and Renovate policy, security audits, and SHA-pinned callers for this
repository's reusable workflows converged across every repository listed in
[`fleet/repos.yml`](fleet/repos.yml). Consumers never edit those surfaces
directly; changes land as reviewed pull requests from the fleet sync bot
(`starhaven-bot`), and a required guard check rejects hand edits. Design and
operations are documented in [`fleet/README.md`](fleet/README.md).

<!-- fleet:block license-section -->

## License

This community metadata repository is licensed under the [MIT License](LICENSE).

<!-- fleet:end -->
