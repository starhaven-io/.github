# Agent Instructions for starhaven-io/.github

Most importantly, keep this repository's public GitHub organization profile
accurate, restrained, and safe to publish. Changes here are visible at
<https://github.com/starhaven-io>.

## Project overview

This repository has two jobs for the `starhaven-io` organization:

1. Org-wide community health files. GitHub serves `SECURITY.md`,
   `CONTRIBUTING.md`, `.github/FUNDING.yml`, `.github/ISSUE_TEMPLATE/`, and
   `.github/PULL_REQUEST_TEMPLATE.md` from here to every org repository without
   its own copy, and renders `profile/README.md` as the public org landing
   page.
2. The fleet hub. `fleet/sync.rb`, a single stdlib-only Ruby renderer, manages
   shared surfaces across the repositories listed in `fleet/repos.yml`:
   byte-identical files, fenced `fleet:block` fragments, rendered workflow
   callers, Dependabot and Renovate configs, and SHA pins for this hub's
   reusable workflows inside repo-owned workflows. A GitHub App bot opens
   verified convergence PRs (`fleet-sync.yml`), releases are CalVer tags cut
   through `fleet-release.yml`, and a PR guard rejects consumer edits to
   managed surfaces. `fleet/README.md` documents the design.

The repository therefore contains Ruby source, an adversarial regression test
suite, and CI tooling. Treat it like a small production codebase, not a
Markdown-only profile repository.

## Required checks

- Run `just check` before finishing. It runs git diff hygiene, the fleet test
  suites under the locked bundle, RuboCop on `fleet/`, a zizmor workflow audit,
  a pinprick action supply-chain audit, and a lychee link check. Missing local
  tools count as failures with install hints.
- Run `BUNDLE_GEMFILE=fleet/Gemfile bundle install` once per clone so the test
  and lint steps run instead of being skipped.
- Run `just install-hooks` once per clone so DCO sign-off and pre-push checks
  are active.
- Review the rendered Markdown shape of any changed `.md` file, especially
  `profile/README.md`, before finishing.
- Check links and install snippets when adding or changing a project entry.
  Prefer exact GitHub repository URLs, canonical product/site URLs, and current
  Homebrew install commands. Run `just lychee` for the link check by itself.
- Confirm `git status --short` only shows intended changes.

## Repository structure

Top level:

- `README.md`: describes this repository. `profile/README.md` renders as the
  public profile at <https://github.com/starhaven-io>.
- `AGENTS.md`: shared instructions for AI coding agents. `CLAUDE.md` is a
  compatibility pointer; keep it as exactly `@AGENTS.md`.
- `CONTRIBUTING.md`, `SECURITY.md`, `.github/FUNDING.yml`,
  `.github/ISSUE_TEMPLATE/`, `.github/PULL_REQUEST_TEMPLATE.md`: org-wide
  inherited community-health files and default templates.
- `renovate-config.json`: shared Renovate preset for tool pins that sit outside
  the Dependabot-managed ecosystems. See "Shared Renovate preset" below.
- `.fleet.yml`: this hub's own rendered fleet config (the hub is also a fleet
  consumer). Managed by the sync; change `fleet/repos/.github.yml` instead.
- `justfile`: `check`, `rubocop`, `tests`, `lychee`, and `install-hooks`
  recipes, plus fleet-managed `audit` and `pinprick-audit` recipe blocks.
- `.githooks/`: `commit-msg` (rejects AI attribution trailers, requires DCO
  sign-off) and `pre-push` (`just check`).
- `lychee.toml`: profile and community-health link-check configuration.
- `.github/dependabot.yml`: bundler (`/fleet`) and github-actions updates with
  a 7-day cooldown.

`fleet/` (the renderer and its canon):

- `sync.rb`: renderer, drift checker, and PR guard in one stdlib-only file.
- `repos.yml` and `repos/<name>.yml`: consumer registry and per-repo config.
- `files/`, `blocks/`, `templates/`: tier-1 whole files, tier-2 fenced block
  content, and tier-3 ERB templates.
- `test/`: the commit-msg hook tests, the guard and renderer regression suite,
  the conclusion and conventional-commits workflow contract tests, and
  golden-render tests that render every consumer config into a synthetic
  skeleton; run them through the locked bundle (`just tests`).
- `VERSION`: the current CalVer fleet release, tagged on merge.

`.github/workflows/`, hub-facing:

- `conclusion.yml`: the required PR check. It classifies changed paths, fans
  out to the fleet guard, conventional commits, `fleet-validate.yml`, and the
  workflow audits, and requires every relevant result.
- `fleet-validate.yml`: renderer syntax, tests, and lint, plus a per-consumer
  dry-run render with an idempotence check.
- `fleet-guard.yml`: this repo's own rendered guard caller.
- `fleet-guard-required.yml`: run from `@main` by an org ruleset against
  consumer PRs; skips the hub itself.
- `fleet-sync.yml`: renders consumers and opens verified sync PRs using App
  credentials (push to `main`, weekly cron, dispatch).
- `fleet-release.yml`: dispatch opens a `fleet/VERSION` bump PR; the merge to
  `main` tags that version.
- `codeql.yml`, `zizmor.yml`, `pinprick-audit.yml`, `link-check.yml`,
  `warm-ruby-cache.yml`: analysis, security audits, link checking, and
  bundler cache warming for this repository itself.

`.github/workflows/reusable-*.yml`, called by consumers through SHA-pinned
thin callers: `reusable-codeql.yml`, `reusable-conventional-commits.yml`,
`reusable-fleet-guard.yml`, `reusable-link-check.yml`,
`reusable-pinprick-audit.yml`, and `reusable-zizmor.yml`.

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
11. Never hand-edit fleet-managed surfaces: content inside `fleet:block`
    fences, tier-1 and tier-3 rendered files, or reusable workflow pins, here
    or in consumers. Change the canon under `fleet/` and let the sync render
    it.
12. Keep every workflow action SHA-pinned with a version comment, keep
    top-level `permissions: {}` in every workflow that declares its own
    triggers, and keep `persist-credentials: false` on checkouts. A reusable
    workflow may omit `permissions` only to inherit the caller's grant, with
    the reason stated in the file. zizmor and pinprick stay at zero findings.

<!-- fleet:block commit-and-pr-conventions -->

## Commit and PR conventions

- Conventional Commits: `type(scope): description`. Valid types: `feat`,
  `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`.
  Mark a breaking change with `!` before the colon (`feat!:`,
  `feat(scope)!:`).
- Commits require DCO sign-off. Make all commits with `git commit -s` (enforced
  by the `.githooks/commit-msg` hook; run `just install-hooks` once per clone).
- Do not identify an AI tool or model as an author, co-author, committer, or
  signatory of a commit. Do not name an AI tool or model in `Co-authored-by`,
  `Assisted-by`, `Co-developed-by`, `Generated-by`, or similar trailers. Human
  `Co-authored-by` trailers are allowed.
- Never commit directly to `main`; create a feature branch and open a PR.
- PR descriptions should contain a concise summary of changes and any required
  AI/LLM disclosure. Do not add a standalone test-plan section.
- When AI/LLM was used to generate or assist with a pull request, disclose the
  tool and model in the initial PR description, briefly describe its role, and
  state how the output was reviewed or verified.
- Keep AI/LLM disclosure factual and concise. Do not add promotional
  "generated with" footers.
- Keep each prose paragraph in a PR description on one source line. Do not
  hard-wrap PR body prose like a commit message; preserve intentional Markdown
  line breaks in lists, code blocks, and other structured content.
- Comments must earn their keep: a comment states a constraint or rationale the
  code cannot express. Never add comments that narrate what the code does,
  restate names, or explain a change to its reviewer.

<!-- fleet:end -->
