# Contributing

## Commit messages

Subjects are Conventional Commits:

```
type(scope): subject
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `ci`.

Scope is required. A body after a blank line is fine; only the subject is checked.

```
ci(hooks): check commit subjects
fix(contracts): reject an illegal move
```

Pull request titles use the same form. A squash merge writes the title
as the commit on `main`.

## Install the hooks

The hooks live in `.githooks/` in the repo. A fresh clone does not run
them until you point Git at that directory:

```bash
bash scripts/install-hooks.sh
```

That is the only install step. It does not need Node, Flutter, or Cargo.
It sets `core.hooksPath` to `.githooks`, which covers both hooks below.

### Protected branch

`.githooks/pre-commit` refuses `git commit` while the current branch is
`main` or `master`. Commit on a feature branch instead. This runs only in
a clone where the hooks are installed.

### Commit messages

`.githooks/commit-msg` checks the subject. CI runs the same check on
commit subjects and on pull request titles. Skipping the local hook with
`--no-verify` still fails the workflow.
