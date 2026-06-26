#!/usr/bin/env bash
# init-git.sh — turn on coordkit GIT-MODE sharing for the current repo.
#
# Scaffolds the committed, secret-free coordination pointer so every clone of this
# repo auto-joins the same coordination room with no further setup:
#   <repo>/.claude/coord/coord.toml        mode=git pointer (committed)
#   <repo>/.claude/coord/.gitattributes    *.ndjson merge=union (committed)
#   <repo>/.claude/coord/MANIFEST.json     protocol/min_reader (committed)
#   <repo>/.claude/coord/log/              actor-partitioned segments (committed as written)
#
# It does NOT commit for you (so you can review) and writes NO secrets. After
# running: `git add .claude/coord && git commit`, push, and drive replication with
# a timer on bin/sync.sh (cron / systemd / a background loop) — NEVER from a hook.
#
# Usage: init-git.sh [room_id] [remote]
#   room_id  logical channel (default "default"); all clones sharing it see each other
#   remote   git remote name/URL that carries the log (default: repo's existing remote)
set -uo pipefail

ROOT_PLUGIN="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}"
TPL="${ROOT_PLUGIN}/templates"
SCHEMA="${ROOT_PLUGIN}/schema"
room="${1:-default}"
remote="${2:-}"

# must be inside a git repo (git mode replicates over a git remote)
repo="$(git -C "${CLAUDE_BUS_ROOT:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "coordkit init-git: not inside a git repo. git mode needs a git remote." >&2
  echo "  cd into your project repo first (or 'git init'), then re-run." >&2
  exit 1
}

coord="${repo}/.claude/coord"
mkdir -p "${coord}/log" || { echo "coordkit init-git: cannot create ${coord}" >&2; exit 1; }

# 1) .gitattributes (merge=union backstop)
if [ -f "${TPL}/gitattributes" ]; then cp -f "${TPL}/gitattributes" "${coord}/.gitattributes"
else printf '*.ndjson merge=union\n' > "${coord}/.gitattributes"; fi

# 2) MANIFEST.json (protocol / min_reader)
[ -f "${SCHEMA}/MANIFEST.json" ] && cp -f "${SCHEMA}/MANIFEST.json" "${coord}/MANIFEST.json"

# 3) coord.toml — start from template, then set mode=git (+ room/remote). Idempotent:
#    if a coord.toml already exists we only flip mode/room/remote, preserving the rest.
toml="${coord}/coord.toml"
if [ ! -f "$toml" ]; then
  if [ -f "${TPL}/coord.toml" ]; then cp -f "${TPL}/coord.toml" "$toml"
  else printf 'mode = "local"\nroom_id = "default"\nremote = ""\nproto = "1"\nmin_reader = "2.0.0"\n' > "$toml"; fi
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

# 4) ensure the project .gitignore keeps the EPHEMERAL bus out of history (only the
#    committed .claude/coord/ is shared; .claude-bus/ heartbeats/activity stay local)
gi="${repo}/.gitignore"
if [ -f "$gi" ] && ! grep -qxF '/.claude-bus/' "$gi" 2>/dev/null; then
  printf '\n# coordkit: ephemeral local coordination state (never shared)\n/.claude-bus/\n' >> "$gi"
elif [ ! -f "$gi" ]; then
  printf '# coordkit: ephemeral local coordination state (never shared)\n/.claude-bus/\n' > "$gi"
fi

echo "coordkit init-git: git mode enabled for ${repo}"
echo "  room_id = ${room}"
echo "  committed pointer: ${coord}/coord.toml (mode=git)"
echo "  merge driver:      ${coord}/.gitattributes (*.ndjson merge=union)"
echo
echo "Next steps:"
echo "  1) git add .claude/coord .gitignore && git commit -m 'coordkit: enable git-mode coordination'"
echo "  2) push, and have teammates pull — they auto-join (the committed coord.toml self-describes)."
echo "  3) drive replication OUT of the hook path on a timer, e.g.:"
echo "       watch -n15 '${ROOT_PLUGIN}/bin/sync.sh'    # or cron / systemd timer / a background loop"
echo "  (Never call sync.sh from a hook — git network must stay off the tool-call critical path.)"
exit 0
