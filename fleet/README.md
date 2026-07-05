# Fleet

Fleet renders shared repository surfaces for the `starhaven-io` estate from this
hub repository. The goal is to make shared files and blocks reviewable generated
artifacts instead of hand-synchronized copies.

## Tiers

- Tier 1 files are byte-identical whole files sourced from `fleet/files/`.
- Tier 2 blocks are hub-owned fragments fenced inside repo-owned files with
  `fleet:block` markers.
- Tier 3 files are rendered whole files, including thin callers for reusable
  workflows in `.github/workflows/`.
- Tier 4 files remain repo-owned and are not touched by `fleet/sync.rb`.

Optional Tier 1 files are still byte-identical, but render only when the
consumer opts in through `.fleet.yml`. The shared `.github/zizmor.yml` policy
uses `zizmor-config: true`.

The renderer fails on missing or mangled markers in normal mode. The sync
workflow uses bootstrap mode only when the consumer checkout has no
`.fleet.yml`. Bootstrap mode derives an initial config from the converged repo
state, writes markers around known managed sections, and renders the managed
surfaces.

## Per-Repo Config

Consumer parameters live in `.fleet.yml` in the consumer repository, not here.
The hub stores the canonical content and `fleet/repos.yml`, which is only the
consumer list.

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

Exceptions are explicit and cited. A managed surface with an exception entry is
left untouched by the renderer. Use `pinprick-audit` for the workflow and
`pinprick-audit-recipe` for the justfile recipe when only one of those surfaces
is exempt.

## Reusable Workflows

Thin caller workflows keep `on:`, `permissions`, and `concurrency` in the
consumer repo. The shared job bodies live in this hub:

- `reusable-zizmor.yml`
- `reusable-pinprick-audit.yml`
- `reusable-link-check.yml`
- `reusable-codeql.yml`
- `reusable-conventional-commits.yml`

Consumer callers pin reusable workflows by hub commit SHA with a fleet version
comment, and the comment's tag must point at the pinned SHA. `fleet/sync.rb`
seeds new pins at the current release's tag commit (falling back to the sync
push SHA only on the release push itself, which then receives the tag),
preserves valid pins even when newer releases exist, and repairs pins whose
comment does not name the pinned commit. Dependabot moves valid pins forward.
If rendered inputs require a newer reusable workflow than the pinned SHA
defines, the renderer treats the pin as invalid and reseeds it to the current
release tag. If a version comment names a tag that cannot resolve, the renderer
repairs it when the hub has tag data and preserves it only when the hub checkout
has no fleet tags at all.

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

Consumer CI never fetches canonical content at runtime. Convergence arrives as a
normal PR containing rendered artifacts.
