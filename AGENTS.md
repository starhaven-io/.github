# Agent Instructions for starhaven-io/.github

Most importantly, keep this repository's public GitHub organization profile
accurate, restrained, and safe to publish. Changes here are visible at
<https://github.com/starhaven-io>.

## Project overview

This is a small Markdown-only repository for GitHub community/profile files for
the `starhaven-io` organization. It does not contain application source code,
build tooling, or a test suite. Please follow these guidelines when
contributing:

## Required checks

- Run `just check` to catch diff hygiene issues, workflow audit findings,
  action supply-chain audit findings, and broken profile/community-health links.
- Run `just install-hooks` once per clone so DCO sign-off and pre-push checks are
  active.
- Review the rendered Markdown shape of any changed `.md` file, especially
  `profile/README.md`, before finishing.
- Check links and install snippets when adding or changing a project entry.
  Prefer exact GitHub repository URLs, canonical product/site URLs, and current
  Homebrew install commands.
- Run `just lychee` after changing README/profile links when you need the link
  check by itself.
- Confirm `git status --short` only shows intended changes.

## Repository structure

- `README.md`: Describes this `.github` repository and points to the rendered
  organization profile.
- `.github/workflows/codeql.yml`: actions-only CodeQL analysis for workflow
  changes.
- `.github/workflows/link-check.yml`: weekly profile and community-health link
  check.
- `.github/workflows/pinprick-audit.yml`: workflow supply-chain audit.
- `.github/workflows/zizmor.yml`: GitHub Actions security audit.
- `.github/FUNDING.yml`: inherited organization funding metadata.
- `CONTRIBUTING.md`: inherited contribution guidelines for repositories without
  a local policy.
- `profile/README.md`: Renders as the public profile at
  <https://github.com/starhaven-io>.
- `SECURITY.md`: inherited vulnerability disclosure policy.
- `lychee.toml`: profile and community-health link-check configuration.
- `renovate-config.json`: shared Renovate preset for tool pins that sit outside
  the Dependabot-managed ecosystems. See "Shared Renovate preset" below.
- `AGENTS.md`: Shared instructions for AI coding agents working in this
  repository.
- `CLAUDE.md`: Compatibility pointer for Claude Code; keep it as `@AGENTS.md`.

## Shared Renovate preset

`renovate-config.json` is the estate's shared Renovate policy for tool pins that
no Dependabot ecosystem owns: the `rust-toolchain` channel and `custom.regex`
matches for `cargo install` pins, the Vale release/SHA-256 pair, and
`TOFU_VERSION`. Dependabot keeps every ecosystem declared by each consumer's
fleet-rendered `.github/dependabot.yml`. Do not add a manager here that
duplicates one of those ecosystems.

Consumers opt in explicitly with
`local>starhaven-io/.github:renovate-config#<fleet-release>`. Renovate resolves
that to this file at the repository root of the immutable CalVer tag. Preset
changes therefore follow the existing fleet release boundary and reach
consumers only through reviewed pin changes. Two consequences:

- Merge and validate the preset first, then cut a fleet release before
  finalizing any consumer's `renovate.json`. A consumer must never reference a
  tag that does not contain the preset.
- `just check` does not validate Renovate configuration. Before merging a preset
  change, run `renovate-config-validator --strict --no-global
  renovate-config.json` with an explicit, reviewed Renovate version. Validate
  each consumer stub separately. For extraction tests, copy the preset over the
  stub in a disposable checkout because Renovate's local platform cannot resolve
  `local>` presets.

Consumers opt in through `params.renovate: true` in their
`fleet/repos/<name>.yml`; the renderer then owns the root `renovate.json` as a
tier-3 file and pins the preset to the current immutable fleet release. For
Renovate-enabled consumers, the publishing sync waits up to three minutes for
that release tag to resolve before it can open a consumer PR. The consumer-level
`ignorePresets` entry is the load-bearing opt-out from the Mend-hosted Merge
Confidence preset; retain it in the rendered stub.

Install the hosted Mend app with **Only select repositories** and expand its
repository selection one adopter at a time, only after that repository's
fleet-rendered config reaches `main`. The public preset repository does not need
the app installed. A repository that already automates its own tool-pin bumps
keeps that automation until Renovate parity is proven; retiring it is a separate
change, not part of adoption.

`dependencyDashboard` is off. With `internalChecksFilter` set to `strict`, fully
suppressed updates are visible only in Mend's run log; eligible PRs retain the
`Pending` column and rebase/retry controls.

On an adopter's first hosted PR, manually confirm that the `Signed-off-by`
trailer is present and non-empty, its identity matches the commit author, and
GitHub marks the commit `Verified`. No estate check currently enforces that
identity match. Keep cargo workflow pins in the canonical single-spaced form
`cargo install <tool> --locked --version <version>` so the deliberately narrow
regex manager can see them.

## Safety / do-not-touch rules

1. Keep the profile concise and factual. Prefer concrete product descriptions,
   maintained project links, and install commands over marketing language.
2. Treat `profile/README.md` as public, user-facing copy. Do not include
   private repository names, non-public roadmaps, unpublished security details,
   tokens, credentials, private email aliases, or operational notes.
3. Keep project entries consistent: project heading, repository link, short
   description, and install snippet when one exists.
4. When adding a project, verify that the repository is public or intentionally
   linked, the description matches the current project scope, and the install
   command is supported.
5. Keep license statements accurate. Do not claim a shared license for every
   project unless that remains true.
6. Prefer HTTPS links for public resources. Avoid link shorteners and tracking
   parameters.
7. Keep diffs minimal and avoid broad copy rewrites unless the user explicitly
   asks for a larger editorial pass.
8. Keep GitHub community health files organization-scoped and avoid policies
   that conflict with individual project repositories.
9. Do not add badges, metrics, sponsorship links, analytics, or generated assets
   unless the user asks for them and the source is trustworthy.
10. Preserve plain Markdown portability; avoid HTML unless GitHub-flavored
    Markdown cannot express the needed layout cleanly.

<!-- fleet:block commit-and-pr-conventions -->

## Commit and PR conventions

- Conventional Commits: `type(scope): description`. Valid types: `feat`,
  `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`.
- Sign off every commit with `git commit -s` for DCO (enforced by the
  `.githooks/commit-msg` hook; run `just install-hooks` once per clone to
  enable it).
- When authored with an AI coding agent, add a `Co-authored-by` trailer before
  `Signed-off-by` (git-native order: `git commit -s` appends the sign-off last),
  naming the agent and model. Current example:
  `Co-authored-by: Claude Opus 5 <noreply@anthropic.com>`. Bump the model
  version as newer ones ship.
- Never commit directly to `main`; create a feature branch and open a PR.
- PR descriptions should contain only a concise summary of changes. Do not add
  test-plan sections, bot attribution, or generated-with footers.
- Keep each prose paragraph in a PR description on one source line. Do not
  hard-wrap PR body prose like a commit message; preserve intentional Markdown
  line breaks in lists, code blocks, and other structured content.
- Comments must earn their keep: a comment states a constraint or rationale the
  code cannot express. Never add comments that narrate what the code does,
  restate names, or explain a change to its reviewer.

<!-- fleet:end -->
