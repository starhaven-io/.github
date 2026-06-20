# Agent Instructions for starhaven-io/.github

Most importantly, keep this repository's public GitHub organization profile
accurate, restrained, and safe to publish. Changes here are visible at
<https://github.com/starhaven-io>.

This is a small Markdown-only repository for GitHub community/profile files for
the `starhaven-io` organization. It does not contain application source code,
build tooling, or a test suite. Please follow these guidelines when
contributing:

## Required Before Each Commit

- Run `git diff --check` to catch trailing whitespace and malformed patches.
- Review the rendered Markdown shape of any changed `.md` file, especially
  `profile/README.md`, before finishing.
- Check links and install snippets when adding or changing a project entry.
  Prefer exact GitHub repository URLs, canonical product/site URLs, and current
  Homebrew install commands.
- Confirm `git status --short` only shows intended changes.

## Commit Conventions

- Use Conventional Commits: `type(scope): description` (`feat`, `fix`, `docs`,
  `chore`, and so on), consistent with the rest of the `starhaven-io` org.
- Sign off every commit with `git commit -s` for DCO.
- When a change is authored with Claude, add a
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer
  after `Signed-off-by`. Bump the model version as newer ones ship.
- Never commit directly to `main` — branch and open a pull request.
- Keep PR descriptions to a short summary of the change. No test-plan sections,
  no bot or tool attribution, and no "Generated with Claude Code" footers.

## Repository Structure

- `README.md`: Describes this `.github` repository and points to the rendered
  organization profile.
- `profile/README.md`: Renders as the public profile at
  <https://github.com/starhaven-io>.
- `AGENTS.md`: Shared instructions for AI coding agents working in this
  repository.
- `CLAUDE.md`: Compatibility pointer for Claude Code; keep it as `@AGENTS.md`.

## Content Guidelines

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
8. If adding GitHub community health files later, keep them organization-scoped
   and avoid policies that conflict with individual project repositories.
9. Do not add badges, metrics, sponsorship links, analytics, or generated assets
   unless the user asks for them and the source is trustworthy.
10. Preserve plain Markdown portability; avoid HTML unless GitHub-flavored
    Markdown cannot express the needed layout cleanly.
