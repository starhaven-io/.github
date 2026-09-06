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
| `.githooks/commit-msg` | Claude/Codex trailer guard on all commits; DCO hook with fixup/squash/merge skip |
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
| `renovate.json` | rendered file | explicit shared-preset reference pinned to the current immutable fleet release; consumers with `renovate: true` |
| `.github/workflows/zizmor.yml` | caller of `reusable-zizmor.yml` | extra push paths, schedule, timeout; defaults render the canonical shape |
| `.github/workflows/pinprick-audit.yml` | caller of `reusable-pinprick-audit.yml` | `advanced-security` (false also drops the `security-events` grant), `fail-on-findings`, timeout |
| `.github/workflows/link-check.yml` | caller of `reusable-link-check.yml` | targets, `build-site`, site directory, schedule |
| `.github/workflows/codeql.yml` | caller of `reusable-codeql.yml` | languages, paths, runner, build mode and profile |
| `.github/workflows/fleet-guard.yml` | caller of `reusable-fleet-guard.yml` | none |
| first-party reusable workflow calls | semantic `jobs.<id>.uses` values matching `starhaven-io/.github/.github/workflows/reusable-*.yml@...` | sync keeps the SHA and fleet version comment current; guard prevents consumer PRs from removing established calls |

Tier 4 includes repo-owned `ci.yml` orchestration, release and deploy
workflows, all AGENTS.md content outside the managed block, README bodies,
repo-specific justfile recipes, and all source code. Inside
repo-owned workflows, Fleet owns the identity, multiplicity, and pin of each
established first-party reusable workflow call within its workflow file.
Triggers, conditions, matrices, inputs, dependency edges, and surrounding job
logic remain repo-owned.

The organization-required `.github/workflows/fleet-guard-required.yml` runs
from trusted hub `main` against pull requests. It enforces DCO sign-offs for
human-authored commits and guards fleet-managed surfaces independently of the
consumer's pull-request tree.

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
visibility: "public"
license: "agpl"
params:
  renovate: true
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
`package.json` and repo-specific CI and deploy integration stay repo-owned. The
shared link-check workflow runs the checker against the configured site
directory before either `npm ci --strict-allow-scripts` path. Configuration
validation requires every built site directory to be enrolled in
`npm-policy.projects`.

Exceptions are explicit and cited; a managed surface with an exception entry is
left untouched by the renderer, so every variant is self-documenting:

```yaml
exceptions:
  pinprick-audit: "build-from-source: audits the local checkout"
  pinprick-audit-recipe: "build-from-source: audits the local checkout"
```

Use `pinprick-audit` for the workflow and `pinprick-audit-recipe` for the
justfile recipe when only one of those surfaces is exempt.

When a parameter is removed, the renderer compares the prior consumer
`.fleet.yml` ownership ledger with the desired config. Former whole-file
surfaces are deleted and former managed blocks are cleared while retaining
their fences. A newly cited exception deliberately transfers the existing
surface to repository ownership instead of deleting it. Publication carries
both additions and deletions in the verified commit.

To adopt a repository, add its name to `fleet/repos.yml` and add its validated
`fleet/repos/<name>.yml` config in the same hub change. The first sync bot pull
request creates `.fleet.yml` together with the other managed surfaces. A human
consumer pull request cannot create or change `.fleet.yml`, even when the base
branch has no copy; this keeps adoption on the same trusted path as later
configuration changes.

Before enrollment, the consumer preparation pull request must establish
`.githooks/commit-msg` and `.githooks/pre-push` from `fleet/files/` with mode
`100755`. The signed `createCommitOnBranch` mutation publishes file contents
but has no file-mode field, so fleet sync fails closed rather than create a
non-executable hook or a mode-only empty pull request.

Every tier-2 fence must exist in its host file before the first render can
succeed; the renderer fails on a missing fence rather than guessing where the
block belongs. The consumer must carry, empty or populated:

- `AGENTS.md`: `<!-- fleet:block commit-and-pr-conventions -->`
- `.gitignore`: `# fleet:block local-state`
- `justfile`: `# fleet:block install-hooks`, plus `# fleet:block npm-policy`
  when `npm-policy` is configured, `# fleet:block audit` unless the `audit`
  exception is cited, and `# fleet:block pinprick-audit` unless the
  `pinprick-audit-recipe` exception is cited
- `README.md`: `<!-- fleet:block badges -->` when `readme.badges` is
  configured and `<!-- fleet:block license-section -->` when `readme.license`
  is configured

Repo-owned justfile recipes and aliases must not reuse a managed recipe name
(`install-hooks`, `npm-policy`, `audit`, `pinprick-audit`): just identifies a
recipe by name alone, and the renderer rejects the collision in every mode.

`ruby fleet/sync.rb --repo-root <checkout> --repo-name <name> --adopt`
appends any missing fences empty to existing host files and renders, which
covers most of the checklist mechanically; it never creates the host files
themselves.

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
Pacific day, cut whenever `fleet/**`, a reusable workflow, or the shared
`renovate-config.json` preset changes behavior. The canon is a dated cut, not an
API, so compatibility-semantic versions carry no information here. Every tag
carries all four segments: Dependabot cannot compare mixed-arity versions, so a
bare day tag strands pins (tags from 2026-07-05 predate this rule and stay as
they are).

Consumer callers pin reusable workflows by hub commit SHA with a fleet version
comment. The sync is the only writer for fleet pins: every render seeds every
caller from the authenticated release tag. Publication always starts from the
trusted default-branch workflow. Current-main code authenticates the release
and performs a no-write safety preflight against the consumer; the exact tagged
renderer then applies tagged canon from a separate checkout of the peeled
release commit. The annotated tag's name, exact annotation,
peeled commit, embedded `fleet/VERSION`, and identity as the latest first-parent
`main` commit that changed the version file must agree. Proposed releases remain
renderable during PR validation, but no consumer write can fall back to an
untagged or unmerged commit. The preflight bridges current safety checks to the
tagged renderer's stable command-line interface, so an older authenticated
release does not need current-main publication helpers and cannot inherit newer
rendering semantics. Because that bridge evaluates the authenticated release's
registry, configs, templates, helpers, locals, and surface set with the
current-main renderer, changes to those interfaces must remain backward
compatible with the active release. Stage removals across releases: first cut a
release whose canon no longer consumes the interface while retaining renderer
support, then remove that support only after the new tag is active. Each release
is one PR per consumer carrying canon changes and pin movement together.
Dependabot ignores `starhaven-io/.github` refs entirely and owns third-party
dependencies only.

Renovate consumers opt in with `params.renovate: true`. The renderer is the sole
writer for their root `renovate.json`, including the load-bearing Merge
Confidence opt-out, and pins the shared preset by immutable fleet release tag.
The fleet validation workflow uses the exact Renovate version declared in
`fleet/validator/package.json` for strict, no-global validation of the preset
and each rendered adopter stub. It actionlints every hub workflow and each
consumer workflow whose complete contents the fleet renders; unrelated
repo-owned workflows remain the consumer's own CI responsibility. Ephemeral
release-PR validation can propose a new version, while publication requires the
real authenticated tag.

Consumer Dependabot and the shared Renovate preset enforce the seven-day age
gate for their eligible third-party updates. Same-organization actions are
explicitly excluded from Dependabot's cooldown: first-party changes instead
cross the reviewed, immutable fleet release boundary. Dependabot never writes
fleet pins.

Fleet releases are cut through `fleet-release.yml`. Manual dispatch opens a
release PR that bumps `fleet/VERSION` to the next Pacific CalVer tag name. The
version parser requires exactly one valid `vYYYY.MM.DD.N` line and monotonic
progression. Keep the generated release change as one commit and merge it with
squash. The enforced invariant is that the VERSION change is in the resulting
`main` tip commit; an annotated tag is created for that exact commit. A rebased
history fails closed when any later commit separates the VERSION change from
the tip.
An existing tag is accepted only when its type, name, annotation, and peeled
commit match; mismatches fail rather than move the ref. After authentication,
the release workflow sends a `repository_dispatch` event, which makes the sync
load its workflow definition from the default branch rather than from the tag.
A root `renovate-config.json` change enters fleet validation but does not
publish until a maintainer dispatches the release workflow. Organization tag
rules should reserve `v*` creation and deletion for the release App.

## Sync Workflow

`fleet-sync.yml` runs on a weekly schedule and on the default branch for a
`fleet-sync` repository dispatch. A scoped manual run can set the dispatch's
`client_payload.repo` to one name from `fleet/repos.yml`; arbitrary workflow
refs are intentionally not accepted. Every entry declares validated `public`
or `private` visibility; pre-merge validation may skip a failed checkout only
for an explicitly private consumer. The sync authenticates the release tag and
checks out both current-main tooling and the release snapshot. Current-main
tooling first performs a no-write render preflight, including path, marker,
configuration, and release checks. The tagged renderer then applies only tagged
canon. It clones each consumer, renders `.fleet.yml`, tiers 1 through 3, and
first-party reusable workflow pins before diffing against the working tree. The
hub consumer is checked out at the exact `main` commit captured during release
authentication. Before write credentials are minted, the job intersects the
tagged render's changed paths with every path changed between the release and
that captured commit. A disjoint set permits a missed hub self-sync to retry
after unrelated commits; any overlap fails closed so tagged canon cannot revert
a newer hub path. Paths remain
NUL-delimited through mode checks and the GraphQL payload. If anything differs
it opens or updates a single PR on branch
`fleet-sync-<version>` titled `chore(fleet): sync managed surfaces <version>`,
through a verified `createCommitOnBranch` commit. Update and auto-merge require
the exact base repository, branch, App author, and returned commit OID; stale
cleanup uses the same repository, base, author, and reserved-prefix checks. A
same-named fork PR is never selected. The PR body lists each
converged or retired surface. A repo in canon produces no PR; scheduled silence
is the health signal.

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
branch belongs to the sync, not to the author. When current hub canon retires a
managed surface that a consumer still carries, unrelated consumer PRs remain
unblocked, but a human change or deletion of that retiring surface fails until
a new fleet release and sync transfer ownership. A PR that pairs parameter
changes with output rendered under a newer canon than the guard pin may still
need the fleet pins bumped first; that window also closes only after the canon
is released and synced.

The in-tree guard is an authoring and drift check. It cannot be the sole
adversarial control for edits to its own caller workflow, because a
`pull_request` run resolves that caller from the PR tree. Consumers that require
tamper-resistant enforcement need an org ruleset or required workflow sourced
from a trusted ref.

## Security Posture

- Hub branch, tag, environment, and required-check rules are external
  prerequisites: this repository cannot prove their live installation. They
  should require reviewed hub PRs, block force-pushes and tag deletion, reserve
  `v*` tag creation for the release App, and protect the `starhaven`
  environment.
- Hub `main` is a high-trust boundary because its scheduled workflows can mint
  repository-scoped App tokens. Consumer changes still arrive through signed
  commits and required-check-gated PRs, but a compromised hub workflow must not
  be treated as contained by SHA pins alone.
- The org Actions policy implicitly allows same-org actions and reusable
  workflows; the explicit allowlist is reserved for third-party trust grants.
- The org-ruleset required workflow (`fleet-guard-required.yml`) deliberately
  runs DCO enforcement and the renderer from hub `main` against pull requests
  so hardening applies without waiting for a release. Residual risk: a
  compromised hub `main` executes Ruby in consumer PR context, mitigated by a
  contents-read-only token, no secrets in that context, and hub `main` itself
  requiring reviewed pull requests.

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

Scaffold missing fences during adoption, then render (never with `--check` or
`--guard`):

```bash
ruby fleet/sync.rb --repo-root ../midden --repo-name midden --adopt
```

`--repo-name` is required and must name an entry in `fleet/repos.yml`; it
selects the matching hub-owned config file.
