## Commit and PR conventions

- Conventional Commits: `type(scope): description`. Valid types: `feat`,
  `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`.
- Sign off every commit with `git commit -s` for DCO (enforced by the
  `.githooks/commit-msg` hook; run `just install-hooks` once per clone to
  enable it).
- When authored with an AI coding agent, add a `Co-authored-by` trailer before
  `Signed-off-by` (git-native order: `git commit -s` appends the sign-off last),
  naming the agent and model. Current example:
  `Co-authored-by: Claude Opus 4.8 <noreply@anthropic.com>`. Bump the model
  version as newer ones ship.
- Never commit directly to `main`; create a feature branch and open a PR.
- PR descriptions should contain only a concise summary of changes. Do not add
  test-plan sections, bot attribution, or generated-with footers.
- Keep each prose paragraph in a PR description on one source line. Do not
  hard-wrap PR body prose like a commit message; preserve intentional Markdown
  line breaks in lists, code blocks, and other structured content.
- Comments must earn their keep: a comment states a constraint or rationale the
  code cannot express. Never add comments that narrate what the code does,
  restate names, or explain a change to its reviewer.
