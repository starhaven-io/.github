# Complete Ruby runtime updates

The native Renovate `ruby-version` manager has no artifact updater. Enabling
Bundler would introduce a second gem owner and does not establish that a broad
Ruby constraint updates the lock's runtime metadata.

## Update contract

Canonical `params.ruby-runtime` declares each repository-owned runtime and its
companions. `update-companions: true` opts paired runtimes into custom managers
sharing the same dependency identity, exact-asset datasource and branch group.
The group retains `renovate/ruby-<major>.x`, matching the established native
branch. Once eligible, a bot-controlled branch can update in place if normal
update policies and limits allow it. External edits can stop automatic updates.
During the cooldown, the pending branch remains desired but is not updated
unless an authorized age exception is applied.
Only that runtime's native manager is disabled. Single-file runtimes retain
the native manager. Dependabot remains the gem owner. Nothing runs Bundler or
changes Gemfiles, gem resolutions or Bundler pins.

The custom datasource selects exactly one official Ubuntu 24.04 x64 archive
from each stable `ruby/ruby-builder` release and requires its recorded SHA-256.
Missing, duplicate or malformed upstream asset/digest metadata yields no
eligible version, so it cannot produce a version-only update. The seven-day
cooldown starts at the later of release publication and the archive's last
update. Both timestamps must be valid GitHub UTC timestamps; missing or
malformed values fail closed. Checksum-only replacements
under an unchanged release version are disabled and require investigation.
A reviewed `minimumReleaseAge` config override can authorize an age exception.
An ordinary PR rebase request does not bypass the gate. Companion completeness
and integrity remain required.

For valid repository inputs, one Renovate branch updates the version file,
checksum and archive filename where present, and existing lock runtime metadata.
Lockfiles that legitimately omit `RUBY VERSION` remain byte-identical.
`require-lock-version: true` distinguishes existing required metadata from that
legitimate absence. Missing or malformed files/sections are corruption, not an
invitation to create or repair them silently.

## Proven limitation and CI boundary

`test/renovate_ruby_updates.mjs` invokes the locked Renovate extraction, custom
datasource, lookup, age filtering, branch generation, replacement and
re-extraction code. It proves a complete 4.0.7 to 4.0.8 branch, unchanged gem and
Bundler bytes, valid partial-baseline convergence and idempotence. Negative
upstream asset/digest cases produce no update.

This is an integration harness around Renovate's real modules, not a hosted
end-to-end run. The harness supplies file contents, matches configured paths,
and renders temporary stubs from the current template and every companion
declaration instead of resolving a published `local>` preset. It substitutes
`file://` release JSON for GitHub
HTTP, uses synthetic old publication times and fixture digests, and calls
lookup, branchification and replacement directly. It does not run the full
repository worker, reuse a live branch, write a Git commit or publish a PR.
Pending branches are asserted separately, including their complete companion
set and presence in the desired branch list. Existing branch-name equality is
tested. `processBranch`, branch-modification detection and pruning remain
hosted canary checks.
Official archive-byte verification is separate evidence, not a network step
inside this harness.

It also reproduces a limitation: when a repository's checksum file is missing
or malformed, regex extraction omits it while the other files still update.
Grouping cannot require a dependency that was never extracted. This proposal
therefore guarantees a complete normal path and rejection of corrupt results
by CI; it does **not** guarantee that Renovate never opens a partial branch.
Accept that distinction explicitly before rollout. If no partial branch may
exist even on corrupt inputs, use the stronger alternative below.

The trusted-main required fleet guard checks canonical declarations for every
actor in consumer repositories where the org ruleset requires it, including
Dependabot and fleet sync, using only read permissions. Other declaring
repositories must run an equivalent required check of their own. The checker
rejects version/checksum filename drift, malformed digests, missing files,
malformed/duplicate or required-but-absent lock sections and symlinks. The hub's
fleet tests check its nested runtime. The standalone installer repositories
carry equivalent scoped configuration and local read-only checks. Installer
archive-byte verification remains unchanged. Verify the live required-check
wiring before claiming these checks prevent merges; an advisory check alone
cannot provide that guarantee.

A consistency check compares the recorded values and shape; it cannot prove
that an arbitrary syntactically valid checksum came from upstream. The
Renovate datasource supplies that binding for normal updates, while the
installer verifies downloaded bytes. A manual checksum change still needs
review. The validator follows the existing no-install-script policy and uses
JavaScript regex fallback; the Node RE2 binding is explicitly denied an install
script. Native-pattern compatibility can be checked separately, but does not
establish that this harness used Node RE2. Hosted execution remains a rollout
check.

## Stronger alternative

Prefer an upstream Renovate manager/artifact updater if it can provide this
contract. Otherwise review a narrowly scoped existing-bot publisher before
implementation. It must use only trusted code and configured paths as data,
fetch a fresh base, verify metadata/bytes, prepare and validate every companion,
and publish one commit with compare-and-swap on that base. Failure or concurrent
movement must publish nothing. It must not run Gemfiles or repository commands,
use provider credentials, or accept arbitrary post-upgrade tasks. It needs
retrieval/pagination, retry, branch-ownership, atomic-publication and explicit
authorized-age-override tests.

## Delivery sequence

1. Review the complete normal path and the blocked-corruption-PR tradeoff.
2. Land the canonical checker and its tests first. The required workflow uses
   trusted hub main, so enforcement in covered consumers starts at hub merge
   rather than a fleet tag. Confirm baseline consistency and effective required
   gates, including equivalent checks in other declaring repositories.
3. Cut a new fleet release and use normal sync for per-runtime opt-ins and
   preset pins. Local renders are previews retaining the current published pin;
   they must not be published separately or point at an invented tag. Leave the
   hub's own generated files unchanged until that release's self-sync. Then land
   the equivalent standalone configs and checker integration.
4. Let Renovate re-evaluate existing branches after the new configuration is
   active. Inspect a real resulting bot PR for every companion and zero
   gem/Bundler churn, and confirm CI rejects a deliberately incomplete fixture.
   Do not treat a locally generated branch as hosted publication evidence.
5. Preserve each repository's operational review and runtime compatibility
   requirements before merging its runtime update.

Run the focused regression with Node 24 and the locked validator dependencies:

```sh
node fleet/test/renovate_ruby_updates.mjs
BUNDLE_GEMFILE=fleet/Gemfile bundle exec ruby fleet/test/ruby_runtime_test.rb
ruby fleet/ruby_runtime.rb check . fleet/repos/.github.yml
```

