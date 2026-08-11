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
- PR descriptions should contain a concise summary of changes. Do not add a
  standalone test-plan section or checklists.
- When AI/LLM was used to generate or assist with a pull request, the initial
  PR description must end with exactly one unformatted line as the last line of
  the PR body: `AI disclosure: <model> with <how the output was verified>.`
  This is PR body text, not a commit trailer. Omit the line when no AI/LLM was
  used.
- Name the model as its vendor names it, for example `Claude Opus 5`. Do not
  also name a tool or harness unless the harness is the only identifier. Do not
  describe what the AI did.
- Do not format the disclosure as a heading, bullet, bold label, or horizontal
  rule, and do not add a promotional "generated with" footer.
- Keep each prose paragraph in a PR description on one source line. Do not
  hard-wrap PR body prose like a commit message; preserve intentional Markdown
  line breaks in lists, code blocks, and other structured content.
- Comments must earn their keep: a comment states a constraint or rationale the
  code cannot express. Never add comments that narrate what the code does,
  restate names, or explain a change to its reviewer.
