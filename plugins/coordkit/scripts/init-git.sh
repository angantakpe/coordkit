#!/usr/bin/env bash
# init-git.sh — turn on coordkit GIT-MODE sharing for the current repo.
#
# Scaffolds the committed, secret-free coordination POINTER so every clone of this
# repo auto-joins the same coordination room with no further setup:
#   <repo>/.claude/coord/coord.toml        mode=git pointer (committed)
#   <repo>/.claude/coord/.gitattributes    *.ndjson merge=union (committed backstop)
#   <repo>/.claude/coord/MANIFEST.json     protocol/min_reader (committed)
#
# The event log itself is NOT committed on your branch. Actors append to plain files
# under <repo>/.claude/coord/log/ (gitignored here), and bin/sync.sh replicates them
# entirely inside a private, gitignored worktree at <repo>/.claude/coord/.sync on a
# dedicated log branch (COORDKIT_SYNC_BRANCH, default "coordkit/log"). That way sync
# never touches your checkout, index, or branch.
#
# On first run this also MIGRATES any prior local-mode log (.coordkit-bus/log/** and the
# legacy .coordkit-bus/ledger.jsonl) into .claude/coord/log/ so switching local→git is
# lossless — a one-time copy of append-only files (idempotent; never shrinks a file).
#
# It does NOT commit for you (so you can review) and writes NO secrets. After running:
# `git add .claude/coord .gitignore && git commit`, push, and drive replication with a
# timer on bin/sync.sh (cron / systemd / a background loop) — NEVER from a hook.
#
# Usage: init-git.sh [room_id] [remote]
#   room_id  logical channel (default "default"); all clones sharing it see each other
#   remote   git remote name/URL that carries the log (default: repo's existing remote)
set -uo pipefail

# shellcheck source=./common.sh
. "${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${GEMINI_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}}}/scripts/common.sh"

ROOT_PLUGIN="$(ck_plugin_root)"
TPL="${ROOT_PLUGIN}/templates"
SCHEMA="${ROOT_PLUGIN}/schema"
room="${1:-default}"
remote="${2:-}"

# Must be inside a git repo (git mode replicates over a git remote). This is
# deliberately NOT the shared resolve_root(): that one honours CLAUDE_BUS_ROOT
# verbatim and falls back to a non-git cwd, whereas git mode needs the true git
# toplevel and must HARD-FAIL when there isn't one.
repo="$(git -C "$(ck_project_dir)" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "coordkit init-git: not inside a git repo. git mode needs a git remote." >&2
  echo "  cd into your project repo first (or 'git init'), then re-run." >&2
  exit 1
}

coord="${repo}/.claude/coord"
mkdir -p "${coord}/log" || { echo "coordkit init-git: cannot create ${coord}" >&2; exit 1; }

# 1) .gitattributes (merge=union backstop) — inert on this branch, since step 4 gitignores
#    .claude/coord/log/ so no *.ndjson is ever tracked here; written defensively in case a
#    user un-ignores it. The load-bearing merge driver lives in the git.sh sync worktree.
if [ -f "${TPL}/gitattributes" ]; then cp -f "${TPL}/gitattributes" "${coord}/.gitattributes"
else printf '*.ndjson merge=union\n' > "${coord}/.gitattributes"; fi

# 2) MANIFEST.json (protocol / min_reader)
[ -f "${SCHEMA}/MANIFEST.json" ] && cp -f "${SCHEMA}/MANIFEST.json" "${coord}/MANIFEST.json"

# 3) coord.toml — start from template, then set mode=git (+ room/remote). Idempotent:
#    if a coord.toml already exists we only flip mode/room/remote, preserving the rest.
toml="${coord}/coord.toml"
if [ ! -f "$toml" ]; then
  if [ -f "${TPL}/coord.toml" ]; then cp -f "${TPL}/coord.toml" "$toml"
  else printf 'mode = "local"\nroom_id = "default"\nremote = ""\nproto = "2.0"\nmin_reader = "2.0"\n' > "$toml"; fi
fi
# flip the three pointer fields in place (top-level keys only)
_set() { # key value
  local k="$1" v="$2"
  if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$toml"; then
    sed -i -E "s|^([[:space:]]*${k}[[:space:]]*=).*|\1 \"${v}\"|" "$toml"
  else
    printf '%s = "%s"\n' "$k" "$v" >> "$toml"
  fi
}
_set mode git
_set room_id "$room"
[ -n "$remote" ] && _set remote "$remote"

# 4) ensure the project .gitignore keeps local-only coordination state out of the
#    user's branch. Three entries:
#      /.coordkit-bus/            ephemeral local bus (heartbeats/activity firehose)
#      /.claude/coord/log/      the event log — replicated via the private worktree
#                               on the coordkit/log branch, NEVER committed here
#      /.claude/coord/.sync/    the private sync worktree itself
#    Only the committed POINTER (coord.toml/.gitattributes/MANIFEST.json) is shared.
gi="${repo}/.gitignore"
_ignore() { # pattern
  local pat="$1"
  if [ -f "$gi" ]; then
    grep -qxF "$pat" "$gi" 2>/dev/null || printf '%s\n' "$pat" >> "$gi"
  else
    printf '%s\n' "$pat" > "$gi"
  fi
}
[ -f "$gi" ] && ! grep -q '^# coordkit:' "$gi" 2>/dev/null && \
  printf '\n# coordkit: local-only coordination state (never shared on your branch)\n' >> "$gi"
[ -f "$gi" ] || printf '# coordkit: local-only coordination state (never shared on your branch)\n' > "$gi"
_ignore '/.coordkit-bus/'
_ignore '/.claude/coord/log/'
_ignore '/.claude/coord/.sync/'
_ignore '/.claude/coord/.coord.lock*'

# 5) migrate any prior LOCAL-mode log into the git-mode tree so local→git is lossless.
#    Append-only files: copy each per-actor segment when the destination is missing or
#    the source is strictly larger; fold the legacy flat ledger under a synthetic actor
#    (readall globs *.ndjson under log/, dedups by eid, and orders by clock).
bus="${COORDKIT_BUS_DIR:-${repo}/.coordkit-bus}"
_copy_if_grown() { # src dst
  local src="$1" dst="$2" ssz dsz tmp
  [ -f "$src" ] || return 0
  if [ -f "$dst" ]; then
    ssz="$(wc -c < "$src" 2>/dev/null || echo 0)"
    dsz="$(wc -c < "$dst" 2>/dev/null || echo 0)"
    [ "${ssz:-0}" -gt "${dsz:-0}" ] || return 0
  fi
  mkdir -p "$(dirname "$dst")" 2>/dev/null || return 0
  tmp="${dst}.tmp.$$"
  cp -f "$src" "$tmp" 2>/dev/null && mv -f "$tmp" "$dst" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}
if [ -d "${bus}/log" ]; then
  find "${bus}/log" -type f -name '*.ndjson' 2>/dev/null | while IFS= read -r f; do
    rel="${f#"${bus}/log"/}"
    _copy_if_grown "$f" "${coord}/log/${rel}"
  done
fi
[ -f "${bus}/ledger.jsonl" ] && _copy_if_grown "${bus}/ledger.jsonl" "${coord}/log/_migrated/legacy-ledger.ndjson"

echo "coordkit init-git: git mode enabled for ${repo}"
echo "  room_id = ${room}"
echo "  committed pointer: ${coord}/coord.toml (mode=git)"
echo "  merge driver:      ${coord}/.gitattributes (*.ndjson merge=union)"
echo "  log (gitignored):  ${coord}/log/  → replicated on branch '${COORDKIT_SYNC_BRANCH:-coordkit/log}' via ${coord}/.sync"
echo
echo "Next steps:"
echo "  1) git add .claude/coord .gitignore && git commit -m 'coordkit: enable git-mode coordination'"
echo "     (this commits only the pointer — the log under .claude/coord/log/ is gitignored)"
echo "  2) push, and have teammates pull — they auto-join (the committed coord.toml self-describes)."
echo "  3) drive replication OUT of the hook path on a timer, e.g.:"
echo "       watch -n15 '${ROOT_PLUGIN}/bin/sync.sh'    # or cron / systemd timer / a background loop"
echo "     sync replicates the log on its own branch inside a private worktree; it never"
echo "     touches your checkout, index, or branch. (Never call sync.sh from a hook — git"
echo "     network must stay off the tool-call critical path.)"
exit 0
