# starhaven.io

Independent software by [Patrick Linnane](https://github.com/p-linnane).

## Projects

### [Brewy](https://github.com/starhaven-io/Brewy)

A native macOS GUI for [Homebrew](https://brew.sh). Browse, search, install, and update formulae and casks without opening Terminal. Mac App Store integration via `mas`, service management, package groups, menu bar extra, and auto-updates via Sparkle.

```sh
brew install brewy
```

### [macOSdb](https://github.com/starhaven-io/macOSdb)

A catalog of which versions of open-source components — `curl`, `OpenSSH`, `LibreSSL`, `Swift`, `Apple Clang`, and more — ship with each macOS and Xcode release. Native app, CLI, and a REST API at [macosdb.com](https://macosdb.com).

```sh
brew install starhaven-io/tap/macosdb
```

### [midden](https://github.com/starhaven-io/midden)

A CLI that resolves, audits, and garbage-collects the state Claude Code accumulates. Surfaces what's actually active for a given directory with provenance, flags what's stale or leaking, and prunes `~/.claude.json` entries and ephemeral worktrees that nothing else cleans up.

```sh
brew install starhaven-io/tap/midden
```

### [pinprick](https://github.com/starhaven-io/pinprick)

Supply-chain security for GitHub Actions. Pins action references to full SHAs, checks for updates, and audits pinned actions for runtime fetch patterns that bypass pinning — `curl | sh`, unpinned `git clone`, `FROM :latest`, and more. SARIF output for GitHub code scanning, and a hosted catalog of audited actions at [pinprick.rs](https://pinprick.rs).

```sh
brew install starhaven-io/tap/pinprick
```

### [pkgstory](https://github.com/starhaven-io/pkgstory)

Every package has a version story. pkgstory mines a package manager's git history into a browsable timeline — which version shipped, and when — for every Homebrew formula and cask. Deprecated, disabled, and removed packages are recorded with the date and Homebrew's own reason, instead of trailing off at a stale last version. The whole catalog is searchable, with a per-package RSS feed, live at [pkgstory.dev](https://pkgstory.dev).

## Website

[starhaven.io](https://starhaven.io)

## License

All projects are licensed under [AGPL-3.0-only](https://www.gnu.org/licenses/agpl-3.0.en.html) unless otherwise noted.
