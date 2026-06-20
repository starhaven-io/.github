# Contributing to starhaven-io Projects

Thanks for taking the time to improve a Starhaven project. This organization
default applies to repositories that do not have their own `CONTRIBUTING.md`.
Repository-specific instructions in a README, `AGENTS.md`, or justfile take
precedence.

## Workflow

- Create a branch and open a pull request. Do not push directly to `main`.
- Use Conventional Commits for commit messages and PR titles, for example
  `fix: handle missing package metadata`.
- Sign off commits with `git commit -s` for DCO.
- Keep PR descriptions to a concise summary of the change. Avoid generated
  footers, tool-attribution blocks, and unrelated process notes.

## Local Checks

- Run `just check` before opening a PR when the repository has a justfile.
- Run any targeted build, test, lint, format, audit, or link-check commands
  named in the repository README or `AGENTS.md`.
- For docs-only changes, run the repository link checker when one exists,
  usually `just lychee`.

## Security Reports

Do not report suspected vulnerabilities in public issues or discussions. Follow
the inherited [security policy](SECURITY.md) or the affected repository's own
security policy when one exists.
