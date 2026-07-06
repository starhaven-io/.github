# Fleet

Fleet renders shared repository surfaces for the `starhaven-io` estate from this
hub repository. Shared surfaces maintained as hand-edited copies always drift,
and drift is only caught by a full-estate audit; fleet makes those surfaces
reviewable generated artifacts with one source of truth, leaving only genuine
repo idiosyncrasies as hand-maintained content. Consumer CI never fetches
canonical content at runtime; convergence arrives only as reviewable PRs.

## Tiers

Every fleet-relevant file in every consumer is assigned exactly one tier:

- Tier 1 files are byte-identical whole files sourced from `fleet/files/`.
  Never edited in-repo; the sync PR reverts any local change.
- Tier 2 blocks are hub-owned fragments fenced inside repo-owned files with
  `fleet:block` markers. Content inside the fence is hub-owned; everything
  outside is repo-owned.
- Tier 3 files are rendered whole files: `dependabot.yml` and thin SHA-pinned
  callers for the reusable workflows in `.github/workflows/`.
- Tier 4 files remain repo-owned and are not touched by `fleet/sync.rb`.

Optional Tier 1 files are still byte-identical, but render only when the
consumer opts in through `.fleet.yml`. The shared `.github/zizmor.yml` policy
uses `zizmor-config: true`.

## Surface Matrix

Tier 1:

| File | Notes |
|------|-------|
| `.editorconfig` | all consumers |
| `.githooks/commit-msg` | DCO hook with fixup/squash/merge skip |
| `.githooks/pre-push` | deletion-skip, just-guard, `just check` |
| `CLAUDE.md` | exactly `@AGENTS.md` |
| `LICENSE` | one canonical file per license type in `fleet/files/licenses/` |
| `.mcp.json` | astro-docs config; consumers with `astro-docs: true` |
| `.github/zizmor.yml` | shared Homebrew/actions policy; consumers with `zizmor-config: true` |

Tier 2 (managed blocks):

| Block | Host file | Scope |
|-------|-----------|-------|
| `commit-and-pr-conventions` | `AGENTS.md` | all consumers; commit, PR, and comment discipline |
| `local-state` | `.gitignore` | all consumers; the org-minimum header section |
| `install-hooks` | `justfile` | all consumers |
| `audit` | `justfile` | all workflow-owning consumers |
| `pinprick-audit` | `justfile` | all consumers without a cited exception |
| `badges` + `license-section` | `README.md` | public project repos, parameterized by repo name and badge workflow |

Tier 3 (rendered files and thin callers):

| File | Mechanism | Parameters |
|------|-----------|------------|
| `.github/dependabot.yml` | rendered file | ecosystems and directories |
| `.github/workflows/zizmor.yml` | caller of `reusable-zizmor.yml` | extra push paths, schedule, timeout; defaults render the canonical shape |
| `.github/workflows/pinprick-audit.yml` | caller of `reusable-pinprick-audit.yml` | `advanced-security` (false also drops the `security-events` grant), `fail-on-findings`, timeout |
| `.github/workflows/link-check.yml` | caller of `reusable-link-check.yml` | targets, `build-site`, site directory, schedule |
| `.github/workflows/codeql.yml` | caller of `reusable-codeql.yml` | languages, paths, runner, build mode and profile |
| `.github/workflows/fleet-guard.yml` | caller of `reusable-fleet-guard.yml` | none |
| conventional-commits job | reusable job consumed inside each repo's tier-4 `ci.yml` | none |

Tier 4 stays repo-owned forever: `ci.yml` cores, release and deploy workflows,
all AGENTS.md content outside the managed block, README bodies, repo-specific
justfile recipes, `.fleet.yml` itself, and all source code.

## Marker Convention

Tier 2 fences use the host file's comment syntax:

```markdown
<!-- fleet:block commit-and-pr-conventions -->

...hub-owned content...

<!-- fleet:end -->
```

```gitignore
# fleet:block local-state
...
# fleet:end
```

Markdown fences pad the hub-owned content with blank lines so Prettier-checked
consumers do not reformat inside the fence; hash fences stay tight. Markers
carry the constraint "do not hand-edit inside". A missing or mangled marker
fails the sync run loudly rather than guessing.

The renderer fails on missing or mangled markers in normal mode. The sync
workflow uses bootstrap mode only when the consumer checkout has no
`.fleet.yml`. Bootstrap mode derives an initial config from the converged repo
state, writes markers around known managed sections, and renders the managed
surfaces.

## Per-Repo Config

Consumer parameters live in `.fleet.yml` in the consumer repository, not here.
The hub stores the canonical content and `fleet/repos.yml`, which is only the
consumer list. Parameters live consumer-side so each repo's own PR history
shows its parameter changes.

```yaml
schema: 1
license: "agpl"
params:
  codeql:
    languages: ["actions", "javascript-typescript"]
    paths: ["src/**", ".github/workflows/**"]
  dependabot:
    github-actions: ["/"]
    npm: ["/"]
  link-check:
    targets: "README.md AGENTS.md"
    build-site: false
  zizmor-config: true
  readme:
    badges:
      workflow: "ci.yml"
exceptions: {}
```

Exceptions are explicit and cited; a managed surface with an exception entry is
left untouched by the renderer, so every variant is self-documenting:

```yaml
exceptions:
  pinprick-audit: "build-from-source: audits the local checkout"
  pinprick-audit-recipe: "build-from-source: audits the local checkout"
```

Use `pinprick-audit` for the workflow and `pinprick-audit-recipe` for the
justfile recipe when only one of those surfaces is exempt.

## Reusable Workflows

Thin caller workflows keep `on:`, `permissions`, and `concurrency` in the
consumer repo, so zizmor and pinprick audit the effective trigger and grant
surface where it executes. The shared job bodies live in this hub:

- `reusable-zizmor.yml`
- `reusable-pinprick-audit.yml`
- `reusable-link-check.yml`
- `reusable-codeql.yml`
- `reusable-conventional-commits.yml`
- `reusable-fleet-guard.yml`

## Versions, Pins, and Releases

Fleet releases are tagged with CalVer: `vYYYY.MM.DD.N`, N starting at 1 each
Pacific day, cut whenever `fleet/**` or a reusable workflow changes behavior.
The canon is a dated cut, not an API, so compatibility-semantic versions carry
no information here. Every tag carries all four segments: Dependabot cannot
compare mixed-arity versions, so a bare day tag strands pins (tags from
2026-07-05 predate this rule and stay as they are).

Consumer callers pin reusable workflows by hub commit SHA with a fleet version
comment. The sync is the only writer for fleet pins: every render seeds every
caller at the current release tag (falling back to the sync push SHA only on
the release push itself, which then receives the tag), so each release is one
PR per consumer carrying canon changes and pin movement together. Dependabot
ignores `starhaven-io/.github` refs entirely and owns third-party dependencies
only.

This hub is the seven-day supply-chain quarantine for everything first-party.
Consumer Dependabot keeps its cooldown for third-party actions and never
writes fleet pins; upstream changes reach consumers only as fleet releases.

Fleet releases are cut through `fleet-release.yml`. Manual dispatch opens a
release PR that bumps `fleet/VERSION` to the next Pacific CalVer tag name. The
merge to `main` creates an annotated tag for that exact version if it does not
already exist. Existing tags are never moved. Every VERSION bump is tagged on
its merge commit; a sync run that cannot resolve the VERSION tag is the release
push itself.

## Sync Workflow

`fleet-sync.yml` runs on pushes to `main` touching `fleet/**` or the reusable
workflows, on a weekly schedule, and by dispatch. Per consumer in
`fleet/repos.yml` it clones the repo, reads and validates `.fleet.yml`, renders
tiers 1 through 3, and diffs against the working tree. If anything differs it
opens or updates a single PR on branch `fleet-sync-<version>` titled
`chore(fleet): sync managed surfaces <version>`, through a verified
`createCommitOnBranch` commit; PRs from superseded versions are closed by the
next sync. The PR body lists each converged surface, and that list is the drift
alarm. A repo in canon produces no PR; scheduled silence is the health signal.

## Pull Request Guard

Every consumer receives `.github/workflows/fleet-guard.yml`, a required PR
check that calls `reusable-fleet-guard.yml`. The guard ignores `.fleet.yml`
itself, then looks for PR changes to tier 1 files, tier 3 rendered files, and
the content inside tier 2 `fleet:block` markers. If none changed, it exits
silently. If managed surfaces changed, it runs the renderer in check mode
against the PR tree. Parameter changes pass when their rendered output is
consistent; direct edits to managed files or blocks fail with a pointer back to
this hub or to `.fleet.yml` parameters. Sync-bot and Dependabot PRs are exempt,
and the job always reports a conclusion so the check can be required.

The guard reads its hub version from the caller pin in the consumer checkout,
and in this hub it checks a PR against its own in-tree canon, since a hub PR
carries the canon it proposes. Stage two fails only on surfaces the PR itself
touched: drift that predates the branch belongs to the sync, not to the
author. A PR that pairs parameter changes with output rendered under a newer
canon than the guard pin may still need the fleet pins bumped first; that
window closes with the next sync.

## Security Posture

- Hub writes are restricted to collaborator PRs, with org rulesets requiring
  PRs and blocking force-pushes.
- A compromised or bad hub `main` cannot silently propagate: consumers
  reference the hub only through SHA-pinned callers and receive changes only
  via reviewed PRs, whether Dependabot bumps or fleet-sync convergence.
- The org Actions policy implicitly allows same-org actions and reusable
  workflows; the explicit allowlist is reserved for third-party trust grants.

## Running Locally

Render a consumer checkout in place:

```bash
ruby fleet/sync.rb --repo-root ../midden --repo-name midden
```

Seed the first `.fleet.yml` and markers for a converged checkout:

```bash
ruby fleet/sync.rb --repo-root ../midden --repo-name midden --bootstrap
```

Check for drift without writing:

```bash
ruby fleet/sync.rb --repo-root ../midden --repo-name midden --check
```

Guard a pull request branch against its base:

```bash
ruby fleet/sync.rb --repo-root ../midden --repo-name midden --guard origin/main
```
