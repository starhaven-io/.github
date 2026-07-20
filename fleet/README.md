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
  callers for the reusable workflows in `.github/workflows/`. Each consumer's
  `.fleet.yml` is also rendered from its hub-owned per-repository config.
- Tier 4 files retain repo-owned orchestration. Fleet keeps first-party
  reusable workflow pins current and rejects consumer PRs that remove an
  established first-party reusable workflow call.

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
| `scripts/check-npm-install-policy.mjs` | deny-by-default install-script checker; consumers with `npm-policy` |

Tier 2 (managed blocks):

| Block | Host file | Scope |
|-------|-----------|-------|
| `commit-and-pr-conventions` | `AGENTS.md` | all consumers; commit, PR, and comment discipline |
| `local-state` | `.gitignore` | all consumers; the org-minimum header section |
| `install-hooks` | `justfile` | all consumers |
| `npm-policy` | `justfile` | consumers with `npm-policy`; parameterized by project directories |
| `audit` | `justfile` | all workflow-owning consumers |
| `pinprick-audit` | `justfile` | all consumers without a cited exception |
| `badges` + `license-section` | `README.md` | public project repos, parameterized by repo name and badge workflow |

Tier 3 (rendered files and thin callers):

| File | Mechanism | Parameters |
|------|-----------|------------|
| `.fleet.yml` | rendered copy of `fleet/repos/<name>.yml` | complete effective fleet config, kept consumer-side for discoverability and guard base-state classification |
| `.github/dependabot.yml` | rendered file | ecosystems, directories, and dependency policies |
| `.github/workflows/zizmor.yml` | caller of `reusable-zizmor.yml` | extra push paths, schedule, timeout; defaults render the canonical shape |
| `.github/workflows/pinprick-audit.yml` | caller of `reusable-pinprick-audit.yml` | `advanced-security` (false also drops the `security-events` grant), `fail-on-findings`, timeout |
| `.github/workflows/link-check.yml` | caller of `reusable-link-check.yml` | targets, `build-site`, site directory, schedule |
| `.github/workflows/codeql.yml` | caller of `reusable-codeql.yml` | languages, paths, runner, build mode and profile |
| `.github/workflows/fleet-guard.yml` | caller of `reusable-fleet-guard.yml` | none |
| first-party reusable workflow calls | `uses: starhaven-io/.github/.github/workflows/reusable-*.yml@...` jobs in any workflow | sync keeps the SHA and fleet version comment current; guard prevents consumer PRs from removing established calls |

Tier 4 includes repo-owned `ci.yml` orchestration, release and deploy
workflows, all AGENTS.md content outside the managed block, README bodies,
repo-specific justfile recipes, and all source code. Inside
repo-owned workflows, Fleet owns the identity, multiplicity, and pin of each
established first-party reusable workflow call within its workflow file.
Triggers, conditions, matrices, inputs, dependency edges, and surrounding job
logic remain repo-owned.

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

The renderer fails on missing or mangled markers. It reads configuration only
from the hub and renders the configured bytes to the consumer's `.fleet.yml`;
it never derives configuration from existing consumer workflow files.

## Per-Repo Config

`fleet/repos.yml` is the small, flat registry of consumer names. The canonical
parameters for each consumer live in `fleet/repos/<name>.yml`, so a single
repository's configuration has a focused, legible review diff without turning
the registry into one large nested document. For example, `starhaven.io` reads
`fleet/repos/starhaven.io.yml`, and this hub's own config is
`fleet/repos/.github.yml`.

The sync renders that file as the consumer's `.fleet.yml`. The copy stays in
the consumer so contributors can discover the effective policy without
visiting the hub, and so the guard can classify surfaces that were managed in
the pull request's base. It is not an edit surface: configuration changes start
in the hub file and arrive through the fleet sync bot.

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
  readme:
    badges:
      workflow: "ci.yml"
exceptions: {}
```

Use the array form when a Dependabot entry needs per-repository policy. For
example, this entry can be added to
`fleet/repos/starhaven.io.yml`. The `ignore` list accepts Dependabot dependency
names plus version ranges or semantic update types:

```yaml
params:
  dependabot:
    - package-ecosystem: "npm"
      group: "npm-dependencies"
      directory: "/"
      ignore:
        - dependency-name: "typescript"
          reason: "TypeScript 7.0 lacks Astro's required API; reassess with 7.1: https://github.com/withastro/astro/issues/17268"
          versions: [">=7.0.0 <7.1.0"]
```

The `npm-policy` param opts a consumer into the deny-by-default install-script
policy ahead of npm 12. It syncs `scripts/check-npm-install-policy.mjs` and
renders the `npm-policy` justfile recipe, parameterized by the project
directories the checker validates:

```yaml
params:
  npm-policy:
    projects: [".", "site", "trigger"]
```

The recipe renders into a repo-owned `# fleet:block npm-policy` fence in the
`justfile`, so a consumer must carry that fence before it is enabled, the same
as the other justfile blocks. The per-package `allowScripts` map in each
`package.json`, the CI and deploy steps that run the checker before
`npm ci --strict-allow-scripts`, and the `check` recipe's call stay repo-owned;
the checker and its recipe are the shared surfaces.

Exceptions are explicit and cited; a managed surface with an exception entry is
left untouched by the renderer, so every variant is self-documenting:

```yaml
exceptions:
  pinprick-audit: "build-from-source: audits the local checkout"
  pinprick-audit-recipe: "build-from-source: audits the local checkout"
```

Use `pinprick-audit` for the workflow and `pinprick-audit-recipe` for the
justfile recipe when only one of those surfaces is exempt.

To adopt a repository, add its name to `fleet/repos.yml` and add its validated
`fleet/repos/<name>.yml` config in the same hub change. The first sync bot pull
request creates `.fleet.yml` together with the other managed surfaces. A human
consumer pull request cannot create or change `.fleet.yml`, even when the base
branch has no copy; this keeps adoption on the same trusted path as later
configuration changes.

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
`fleet/repos.yml` it clones the repo, reads and validates the matching hub
config, renders `.fleet.yml`, tiers 1 through 3, and first-party reusable
workflow pins in repo-owned workflows, then diffs against the working tree. If
anything differs it opens or updates a single PR on branch
`fleet-sync-<version>` titled `chore(fleet): sync managed surfaces <version>`,
through a verified `createCommitOnBranch` commit; PRs from superseded versions
are closed by the next sync. The PR body lists each converged surface, and that
list is the drift alarm. A repo in canon produces no PR; scheduled silence is
the health signal.

## Pull Request Guard

Every consumer receives `.github/workflows/fleet-guard.yml`, a required PR
check that calls `reusable-fleet-guard.yml`. The guard rejects any human pull
request that creates or changes `.fleet.yml`, then looks for PR changes to tier
1 files, tier 3 rendered files, and the content inside tier 2 `fleet:block`
markers. If none changed, it exits silently. If managed surfaces changed, it
runs the renderer in check mode against the PR tree using the hub config pinned
by the base branch's guard caller. Direct edits to managed files or blocks fail
with the exact `fleet/repos/<name>.yml` path to change in this hub. Sync-bot and
Dependabot PRs are exempt, and the job always reports a conclusion so the check
can be required.

First-party reusable workflow calls inside Tier 4 workflows are monotonic for
consumer PRs: calls may be introduced, but a consumer PR cannot reduce the
number of calls to a given reusable workflow within an existing workflow file.
That prevents a policy job from being moved aside or replaced with a repo-local
copy while leaving the rest of the repo-owned CI topology flexible. Intentional
moves or removals are coordinated through the trusted hub and its sync bot.
This protects the reusable call itself, not its execution: repo-owned
conditions, inputs, path selection, and dependency edges can still cause the
job to be skipped, and the guard does not claim to enforce those surfaces.

The guard reads its hub version from the caller pin in the consumer checkout,
and in this hub it checks a PR against its own in-tree canon, since a hub PR
carries the canon it proposes. That hub exemption is enabled only from the
trusted workflow repository context, not from consumer-provided repo naming.
Stage two fails only on surfaces the PR itself touched: drift that predates the
branch belongs to the sync, not to the author. A PR that pairs parameter
changes with output rendered under a newer canon than the guard pin may still
need the fleet pins bumped first; that window closes with the next sync.

The in-tree guard is an authoring and drift check. It cannot be the sole
adversarial control for edits to its own caller workflow, because a
`pull_request` run resolves that caller from the PR tree. Consumers that require
tamper-resistant enforcement need an org ruleset or required workflow sourced
from a trusted ref.

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

Check for drift without writing:

```bash
ruby fleet/sync.rb --repo-root ../midden --repo-name midden --check
```

Guard a pull request branch against its base:

```bash
ruby fleet/sync.rb --repo-root ../midden --repo-name midden --guard origin/main
```

`--repo-name` is required and must name an entry in `fleet/repos.yml`; it
selects the matching hub-owned config file.
