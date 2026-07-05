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
- `AGENTS.md`: Shared instructions for AI coding agents working in this
  repository.
- `CLAUDE.md`: Compatibility pointer for Claude Code; keep it as `@AGENTS.md`.

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

## Commit and PR conventions

- Conventional Commits: `type(scope): description`. Valid types: `feat`,
  `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`.
- Sign off every commit with `git commit -s` for DCO (enforced by the
  `.githooks/commit-msg` hook; run `just install-hooks` once per clone to
  enable it).
- When authored with an AI coding agent, add a `Co-Authored-By` trailer after
  `Signed-off-by`, naming the agent and model. Current example:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Bump the model
  version as newer ones ship.
- Never commit directly to `main`; create a feature branch and open a PR.
- PR descriptions should contain only a concise summary of changes. Do not add
  test-plan sections, bot attribution, or generated-with footers.
