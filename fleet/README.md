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
| `.githooks/commit-msg` | AI trailer-key and identifier guard on all commits; DCO sign-off required on every commit, including fixup, squash, and merge |
| `.githooks/pre-push` | tag- and deletion-only skip, exact clean `HEAD` for every other ref, just-guard, `just check` |
| `CLAUDE.md` | exactly `@AGENTS.md` |
| `LICENSE` | one canonical file per license type in `fleet/files/licenses/` |
| `.mcp.json` | astro-docs config; consumers with `astro-docs: true` |
| `scripts/check-npm-install-policy.mjs` | deny-by-default install-script checker; consumers with `npm-policy` |
| `scripts/upload-codecov.py` | fixed-version, SHA-256-verified OIDC uploader; consumers with `codecov: true` |

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
| `.pinprick.toml` | rendered audit policy | exact `pinprick-audit.accept-workflow-findings` decisions; the complete file is hub-owned |
| `.github/workflows/zizmor.yml` | caller of `reusable-zizmor.yml` | extra push paths, optional PR paths, SARIF or direct gate, schedule, timeout |
| `.github/workflows/pinprick-audit.yml` | caller of `reusable-pinprick-audit.yml` | `advanced-security` (false also drops the `security-events` grant), `fail-on-findings`, optional pull-request trigger, timeout |
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

Adding a new first-party call is repo-owned authoring, provided its identity,
full SHA and version comment match the canonical released workflow. The
renderer updates existing calls; it does not insert jobs or edit `needs`.
`params.conclusion` declares the required topology for validation, not job
generation. This keeps routing and legitimate skips with the repository that
can test them while Fleet enforces the shared contract. An established call
cannot subsequently be removed, moved, or repinned by a consumer PR.

Every repository targeted by the organization Require Conclusion ruleset
declares `params.conclusion`. The declaration names its repo-owned aggregate
workflow, merge-critical audit jobs, any intermediate aggregates, and every
deliberately noncritical job in that workflow. Orrery instead cites a
`conclusion` exception because its repo-specific exact-head `Plan` status is the
required gate. The guard validates the declared workflow on every human pull
request: the unfiltered pull-request trigger, exact always-reporting
`conclusion`, complete dependency graph, result inspection, and fail-closed
pinprick configuration must remain intact.

The organization-required `.github/workflows/dco-required.yml` and
`.github/workflows/fleet-guard-required.yml` run from trusted hub `main` against
pull requests. DCO validates commit sign-offs and bot provenance; Fleet Guard
protects fleet-managed surfaces independently of the consumer's pull-request
tree.

### Accepted workflow findings

`params.pinprick-audit.accept-workflow-findings` renders the entire
`.pinprick.toml`. Each acceptance names one workflow path and SHA-256, category,
severity, description, command, and review reason. It cannot accept third-party
action findings or incomplete source coverage. Pinprick reports accepted
findings explicitly, and any workflow byte change requires renewed review in
canon. Keep the key with an empty array when retiring the last entry so the
configuration remains managed while older releases can still load it.

The released audit enables repository config only for macOSdb, whose two Apple
archive downloads are reviewed in `fleet/repos/macOSdb.yml`. All other
consumers retain `no-repo-config: true`; callers have no policy opt-in input.
The required trusted-main guard rejects consumer edits, additions, deletions,
and mode changes to the managed policy. As elsewhere in fleet delivery, the
guard trusts Starhaven Bot and Dependabot writers. Introduce guard enforcement
first, then release the engine and wrapper, then release/sync the policy and
audit pin together. A successful local audit is not evidence that this hosted
sequence has completed.

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
  conclusion:
    workflow: ".github/workflows/ci.yml"
    audit-jobs: ["pinprick"]
    pinprick-jobs: ["pinprick"]
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
policy. It syncs `scripts/check-npm-install-policy.mjs` and
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
checker requires a lockfile with a `packages` mapping (lockfile versions 2 or 3).
The shared link-check workflow runs the checker against the configured site
directory before either `npm ci --strict-allow-scripts` path. Configuration
validation requires every built site directory to be enrolled in
`npm-policy.projects`.

The pinprick audit decision is merge-critical on every pull request: a selected
audit must succeed, and it may be skipped only after an explicit not-applicable
routing decision. It runs inside each repository's repo-owned gate workflow so
the required result observes the same workflow run. For Require Conclusion
repositories, `needs` carries the result to `conclusion`; Orrery's validation
workflow instead must succeed before its exact-head `Plan` status can pass. The
fleet-rendered standalone caller retains its push and SARIF role. Keep its PR
trigger during adoption, even though migrated consumers temporarily run the
audit twice. Retire duplication only in a subsequent canon change with
`params.pinprick-audit.pull-request: false`, after the inline gate is merged
and verified. Before writing any files, the renderer validates the replacement
conclusion contract in the consumer being rendered. Missing or invalid gates
block retirement in render, check, and publication-preflight modes, including
sync-bot delivery. A declaration alone or an open consumer PR is not enough.
This is a structural check; repository result/routing tests and exact-head
hosted results remain necessary evidence before approving retirement.

Repositories with a repository-specific gate rather than `conclusion` retain
the standalone PR audit until Fleet has a validator for that replacement;
an exception string alone cannot authorize retirement. Pinprick and
pinprick-action retain their repo-owned audit workflow exceptions. Retain
Pinprick's PR-time source dogfooding alongside its new released-engine gate;
local reusable-workflow scanning is now supported by the released engine, so
the scanner limitation no longer justifies making source dogfooding push-only.
Making the local source audit itself a dependency of `conclusion` requires a
coordinated Pinprick unit and an explicit local-audit contract in Fleet; it is
separate from canonical-call admission. Pinprick-action declares its self-test
jobs as its audit rather than adding a redundant wrapper invocation.

### Conclusion contract delivery

1. Merge canon and release/sync the contract and current audit pins, retaining
   the standalone PR audit. Existing repo-owned gates remain unchanged.
2. Refresh consumer PRs onto those synced bases. Introduce the inline call at
   the delivered pin together with its `needs` edge, fail-closed result handling
   and routing tests in one repo-owned unit. Do not edit existing managed calls
   or rendered files. Verify both guards and the exact-head aggregate before
   merge. Audit findings remain blockers, not migration exceptions.
3. After each gate is live, separately review canon retiring that consumer's
   duplicate PR audit, then release/sync it. The renderer checks the replacement
   again on the actual consumer tree before removal. Leave duplication where
   replacement validation is unavailable.

There is no audit-free handoff: old gate plus standalone audit, then old gate
plus the synced audit, then the new inline gate plus standalone audit, and only
then the new gate alone. Repositories whose old aggregate omitted the audit
remain incompletely gated until step 2; hold unrelated merges in those
repositories during migration. Retaining an advisory standalone result does
not retroactively make the old gate safe.

The `codecov: true` param syncs `scripts/upload-codecov.py`. Repository-owned CI
produces coverage and any JUnit reports without upload credentials, saves them
as artifacts, and downloads those exact same-run artifacts in a separate Ubuntu
upload job. Only that job receives `id-token: write`; it checks out the uploader
alone from the pull request's trusted base SHA or the push SHA, with credentials
disabled. Invoke it from the workspace root:

```bash
python3 -I scripts/upload-codecov.py --coverage reports/lcov.info --junit reports/junit.xml
```

Before saving artifacts, producers invoke the same arguments with `--prepare`:

```bash
python3 -I scripts/upload-codecov.py --prepare --coverage coverage.lcov --junit junit.xml
```

This mode needs no network or upload credentials. It converts LCOV `SF:` paths
and Cobertura filenames to paths relative to `GITHUB_WORKSPACE`, normalizes
Cobertura source roots, and rejects source paths outside that workspace. It
validates all reports before writing any of them and preserves JUnit bytes.
This keeps reports usable after moving from a macOS test runner to the Linux
upload job without giving that job the source checkout or CLI path-fixing tools.

Both report arguments are repeatable; at least one coverage or JUnit report is
required. A producer that generates JUnit on test failure can upload that report
alone, preserving failure diagnostics even when coverage was not generated.
Caller workflows must still require coverage after successful coverage tests
and must not hide missing reports behind blanket error tolerance. Reports must be
nonempty regular files under the workspace, with no symlinks. The helper uses
the pull request head SHA and PR number, or the push SHA, from GitHub's event
payload. The upload job handles pushes and same-repository pull requests,
including Dependabot. Fork pull requests retain their test gates and explicitly
skip authenticated uploads; the helper rejects fork and `pull_request_target`
invocations. Missing OIDC permissions, missing reports, integrity failures, and
upload errors fail the job. There is no static-token or unauthenticated fallback.

The uploader downloads the version and SHA-256 pair reviewed in fleet canon,
requests an OIDC token with audience `https://codecov.io`, and passes only the
short-lived upload token to the CLI. It runs in an isolated temporary directory
with an empty configuration, report discovery and file fixes disabled, and
`--plugin noop` to avoid the CLI's default coverage preparation commands. The
upload job must not build, install dependencies, restore executable caches, or
execute other repository code. Coverage generation and repository-specific
report paths remain repository-owned.

Update the CLI version and its independently recorded SHA-256 together in
`fleet/files/upload-codecov.py`, after reviewing the upstream release and its
[published integrity metadata](https://docs.codecov.com/docs/codecov-uploader).
The pair crosses the normal fleet release and sync boundary; CI never downloads
`latest` or trusts a runtime checksum download as its expected digest. On first
adoption, deliver the helper through fleet release and sync before merging the
repository-owned upload-job change, so a pull request's base already contains
the trusted helper. Do not introduce an unpublished reusable-workflow pin or
hand-copy the generated script to shorten this sequence.

After the helper exists in a consumer's base branch, Fleet Guard checks changes
to that consumer's `ci.yml` against `fleet/codecov_policy.rb` when `codecov` is
enabled in canon. The contract preserves the uploader's exact permissions,
trusted sparse checkout, named same-run artifact downloads, isolated helper
invocation, and `conclusion` dependency. It rejects OIDC grants in producer jobs,
static Codecov tokens, wrapper actions, upload error tolerance, executable
environment overrides, and extra uploader commands. The accepted command forms
are a direct invocation with literal report paths or the explicit failed-test
JUnit selection template. A new execution shape requires a reviewed canon
change; this is not a general shell analyzer. Producer path selection, report
completeness, aggregate result handling, and hosted OIDC acceptance still need
their repository-specific checks. Unrelated source changes and helper-first
adoption remain unblocked.

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
and each rendered adopter stub. Zizmor audits every hub workflow and each
consumer workflow whose complete contents the fleet renders with
`--strict-collection`, so syntax and schema failures fail validation; unrelated
repo-owned workflows remain the consumer's own CI responsibility. The shared
Zizmor workflow and local audit recipes use the same strict collection option.
This does not provide every expression-type or shell diagnostic from a general
workflow linter; repository policy tests and existing ShellCheck gates remain
separate checks. The shared workflow runs one digest-pinned Zizmor container,
mounts the checkout read-only, and uploads SARIF only when `advanced-security`
is enabled. `params.zizmor.advanced-security: false` renders a direct gate with
read-only permissions for repositories without code scanning; optional
`pull-request-paths` retains their PR audit route. The shared Renovate Docker
manager updates the `ZIZMOR_IMAGE` version and digest together in every hub
workflow that uses it. Ephemeral release-PR validation can propose a new version,
while publication requires the real authenticated tag.

Consumer Dependabot and the shared Renovate preset set a seven-day age gate
for eligible third-party updates. The Dependabot template exempts same-organization
actions and `ruby/setup-ruby`, which must recognize each requested Ruby version.
Fleet workflow pins instead cross the immutable fleet release boundary;
Dependabot never writes them.

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
consumer PRs: canonical calls may be introduced, but a consumer PR cannot reduce
the number of calls to a given reusable workflow within an existing workflow file.
That prevents a policy job from being moved aside or replaced with a repo-local
copy while leaving the rest of the repo-owned CI topology flexible. Intentional
moves or removals are coordinated through the trusted hub and its sync bot.
This protects the reusable call itself, not its execution: repo-owned
conditions, inputs, path selection, and dependency edges can still cause the
job to be skipped. The conclusion contract separately requires the aggregate
to inspect every direct dependency result, rejects unclassified jobs, and
requires audit jobs to be in the aggregate's dependency graph. Repository tests
remain responsible for their path router's applicable-versus-skipped decisions.

A changed pin set is a reason to run render validation, not an automatic
rejection. A new call at the expected release SHA and comment passes; a stale
or arbitrary pin fails. The diagnostic reports the expected release and the
offending call and line. GitHub tests the PR merge tree: a sync on the base can
update the guard and established calls while a newly added call on an older
branch remains stale. Compare the executed guard and effective merge tree,
not just the caller in the PR head. Refresh after sync and recreate the new
call at the delivered release; never hand-edit established pins to repair it.

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
  prerequisites: this repository cannot prove their live installation. Inspect
  effective GitHub rulesets and environment deployment policies to confirm that
  hub changes require PRs and passing checks, force-pushes and tag deletion are
  blocked, and `v*` tag creation is reserved for the release App. The `starhaven`
  environment must admit only `main` branch deployments, excluding tags, so a
  dispatch from another ref cannot receive App credentials. A sole maintainer
  reviews and merges through these gates; self-approval adds no independent
  security boundary. Reconsider independent review when another maintainer can
  provide it.
- Hub `main` is a high-trust boundary because its scheduled workflows can mint
  repository-scoped App tokens. Consumer changes still arrive through signed
  commits and required-check-gated PRs, but a compromised hub workflow must not
  be treated as contained by SHA pins alone.
- The org Actions policy implicitly allows same-org actions and reusable
  workflows; the explicit allowlist is reserved for third-party trust grants.
- The org-ruleset required workflows (`dco-required.yml` and
  `fleet-guard-required.yml`) deliberately run DCO enforcement and the renderer
  from hub `main` against pull requests so hardening applies without waiting for
  a release. Residual risk: a compromised hub `main` executes trusted workflow
  code in consumer PR context, mitigated by contents-read-only tokens, no
  secrets in that context, and hub `main` itself requiring gated pull requests.

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
