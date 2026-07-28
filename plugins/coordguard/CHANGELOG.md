# Changelog

All notable changes to **coordguard** are documented here. This project follows
[Semantic Versioning](https://semver.org/). The plugin `version` field in
`.claude-plugin/plugin.json` is the canonical tooling-version axis — bump it to
ship an update to installed users.

coordguard is versioned independently of coordkit; entries below cover only the
guard. See `plugins/coordkit/CHANGELOG.md` for the bus and ledger.

## 1.2.0

Closes the guard's documented Bash blind spot.

### Fixed
- **Self-inflicted Bash edits no longer false-positive.** Files this session
  modified via its own Bash commands (`sed -i`, formatters, `git checkout`)
  used to go stale in the fingerprint store and deny the next Write/Edit.
  Every Bash call is now bracketed: a `snapshot` hook (PreToolUse Bash) lists
  the tracked files that still match their record, and an `absorb` hook
  (PostToolUse Bash) re-stamps any of those that changed while the command ran
  — a change inside this session's own Bash window is attributed to it. A file
  already stale *before* the Bash call (a sibling's edit) is deliberately not
  absorbed and still denies. The two halves of a call are paired by
  `tool_use_id` when the host provides it, with a shared-slot fallback that
  degrades to the old deny-and-re-Read behavior at worst, never to a wrong
  allow.

### Changed
- **Record format now stores the file path** (line 2, after the fingerprint)
  so `snapshot`/`absorb` can re-stat tracked files. Old single-line records
  from ≤1.1.0 are still honored by `check` and simply skipped by the
  bracketing (deny + re-Read once, then they upgrade on the next record).
- Deny messages updated: still-remaining untracked cases (files the session
  never Read, including files its Bash commands *create*) now say so
  explicitly.

## 1.1.0

Shipped alongside coordkit 2.1.0's hardening pass. coordguard had no changelog
of its own at the time; this entry is reconstructed from the "Notes" section of
coordkit 2.1.0, which is the only record of it.

### Fixed
- Hasher fallback chain (`sha1sum`→`shasum`→`md5sum`→`md5`, fail-open) fixes a
  fail-closed on macOS.
- mtime+size fingerprint catches same-second sibling writes.
- A `SessionEnd` cleanup phase removes the session's `/tmp` state.
