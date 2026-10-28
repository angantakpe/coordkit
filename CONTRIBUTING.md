# Contributing to CoordKit

CoordKit is a shell-first coordination runtime packaged for Claude Code and
Codex. Small changes with a focused regression check are easier to review and
safer to release than broad rewrites.

## Set up a checkout

Install Bash 4+, `jq`, Python 3.11+, Git, `make`, and Node 20+. The stock macOS
`/bin/bash` 3.2 is not sufficient for the runtime scripts.

```bash
git clone https://github.com/angantakpe/coordkit.git
cd coordkit
bash scripts/context.sh
```

The repository has no package-install step for its core test tooling. Tests use
the system commands above and create their own temporary state.

## Know which files are authoritative

- `plugins/coordkit/scripts/core/scripts/` contains the canonical coordination
  runtime.
- Shell files directly under `plugins/coordkit/scripts/` are distribution
  wrappers. Update the core implementation; change a wrapper only when its
  delegation contract changes.
- Non-shell runtime artifacts that exist in both trees must remain identical.
- `plugins/coordkit/scripts/core/commands/catalog.json` defines shared command
  intent. Host-facing Markdown files wrap that catalog.
- `plugins/coordkit/adapters/` contains host-specific translation and packaging.
- `WORKFLOW.md` is live Symphony orchestrator configuration, not archived
  documentation.

Keep unrelated edits intact. Runtime-facing behavior changes should update the
matching command spec or documentation in the same pull request.

## Verify only the behavior you changed

Start with the test selector and inspect its output:

```bash
python3 scripts/select-tests.py --base origin/main
```

Run the listed test files explicitly:

```bash
make test TESTS='tests/plugin-package.sh tests/codex-adapter.sh'
```

Use the smallest meaningful list. For example, package metadata and wrapper
changes use `tests/plugin-package.sh`; Codex hook translation uses
`tests/codex-adapter.sh`; context selection uses `tests/context-config.sh` or
`tests/hook-context-compact.sh`. A passing focused check proves only the paths
it covers. Name anything you did not run in the pull request.

`make test-all` explicitly opts into every regression test. CI and releases
select affected tests by default. Do not run the full suite as a routine check. Documentation-only changes
need link and command review rather than unrelated runtime tests.

For a bug fix, add or tighten a regression case that fails for the reported
behavior, then confirm the focused test passes with the fix. If shell code
changes, keep it compatible with Bash 4+ and avoid host-specific assumptions in
the shared core.

## Submit a change

Keep commits scoped and explain the user-visible reason for the change. A pull
request should include:

- the problem and resulting behavior;
- the source-of-truth files changed;
- exact focused checks and their results;
- documentation or command-spec changes;
- known platforms or flows that remain unverified.

## Release-related work

Versioning, changelog entries, both host manifests, and marketplace metadata
must stay aligned. Follow [docs/RELEASE.md](docs/RELEASE.md); do not create a
release tag from documentation or focused checks alone.
