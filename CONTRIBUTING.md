# Contributing to CoordKit

Thanks for helping improve CoordKit.

## Before you send changes

- Keep unrelated edits intact, especially the checked-in plugin distribution
  files under `plugins/coordkit/`.
- Run the repo checks that apply to your change. The usual baseline is:

  ```bash
  make test
  ```

- If you change shell scripts, keep them POSIX/Bash-compatible with the
  existing test matrix and avoid adding host-specific assumptions.
- If you change release-visible behavior, update the README or the relevant
  doc alongside the code.

## What makes a good change

- Small, scoped commits with a clear reason.
- Tests that fail before the change and pass after it.
- Documentation that matches the shipped behavior.

## Release-related work

Versioning, changelog entries, and plugin manifest bumps should stay aligned.
If you are preparing a release, make sure the changelog, plugin manifest
version, and any release notes tell the same story.
