---
description: Verify the current change — run tests/linters and manually exercise the feature or bug repro
argument-hint: "[what to verify / repro steps] (optional)"
allowed-tools: Bash(git:*), Bash(make:*), Bash(php:*), Read, Edit
tags: [routine, test, verify]
---

You are running **stage 4: Test & Verify** for the current change. Evidence before claims — do not say it works until a command or observation shows it.

## 1. See what changed
- `git status -sb` and `git diff --stat` to scope the change.
- Identify the repo (`basename $(git rev-parse --show-toplevel)`) so you pick the right test tooling.

## 2. Automated checks
- Find the test entrypoint: a `Makefile` (`make test`, `make test-fast`, `make lint`), `composer.json` scripts (intranet/Laravel: `php artisan test`), or `package.json` scripts.
- Run lin/format checks where cheap (`make lint` / `make format-check`).
- Run the relevant tests — narrow to the changed area first, then broaden if green.
- Paste the actual pass/fail output. If something fails, diagnose and fix, then re-run.

## 3. Manual verification
- Using `$ARGUMENTS` (or the ticket's acceptance criteria) as the script, exercise the actual behavior:
  - Intranet UI bug → use the `effenco-bug` skill to reproduce in the browser, or `debug-intranet-staging` for backend probing via kubectl + tinker.
  - Backend/data → run the code path (`php artisan tinker`, a script, or the module's CLI).
- Confirm the bug is gone / the feature meets each acceptance criterion. Capture a screenshot (`shot-latest`) if it's visual.

## 4. Verdict
State plainly: what passed, what you ran to prove it, and anything still unverified. If all green, suggest `/open-mr`. If not, list what's left.
