# AGENTS.md

## Project Context

CoordKit is coordination infrastructure for coding agents. Keep changes scoped
to the requested layer, preserve the checked-in plugin distribution, and avoid
editing generated copies unless the change explicitly requires it.

Start with `README.md` for the repository map and `CONTRIBUTING.md` for change
and release expectations. For plugin-runtime specifics, also read
`plugins/coordkit/scripts/CLAUDE.local.md`.

## Repo Layout

- `plugins/coordkit/scripts/core/`: source-of-truth coordination scripts.
- `plugins/coordkit/scripts/`: synced distribution copy that should stay in
  lockstep with `core/`.
- `plugins/coordkit/adapters/`: host-adapter docs and integration notes.
- `plugins/coordkit/commands/README.md`: shared command-spec source of truth.
- `docs/`: architecture, release, statusline, and transport docs.
- `scripts/context.sh`: repo snapshot helper for branch, status, PR, and
  metadata.
- `.codex/skills/context/SKILL.md`: repository-embedded context-gathering
  instructions.
- `WORKFLOW.md`: live configuration for the Symphony autonomous orchestrator, an
  external daemon that polls this repo's Linear project and drives unattended
  Codex agents through ticket automation. Not legacy docs; do not move, delete,
  or migrate it into `docs/`.

## Local Context Workflow

- Run `bash scripts/context.sh` before asking for manual repo state.
- Use `git` and `gh` directly from the repository root so branch and PR data
  come from the live checkout.
- For plugin behavior, combine the script output with the relevant docs and the
  files under `plugins/coordkit/scripts/core/`.
- If `gh` is unavailable, keep working from the Git output and the checked-in
  docs.

## Working Notes

- Keep unrelated edits intact, especially the plugin distribution copies under
  `plugins/coordkit/`.
- Prefer the smallest test slice that covers the change, then expand only if
  the change touches shared runtime behavior.
- When you change runtime-facing behavior, update the matching docs or command
  specs at the same time.
