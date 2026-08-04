#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${ROOT}/plugins/coordkit"
tmp="$(mktemp -d /tmp/coordkit-memory-gate.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

git -C "$tmp" init -q
git -C "$tmp" remote add origin git@github.com:acme/coordkit.git
mkdir -p "$tmp/src" "$tmp/notes" "$tmp/.claude/coord"
cat > "$tmp/package.json" <<'JSON'
{"name":"coordkit-local","private":true}
JSON

identity="$(bash "$PLUGIN/scripts/repo-memory-gate.sh" --identity "$tmp" "repo memory gate smoke test")"
jq -e --arg root "$tmp" '
  .root == $root
  and .workspace == "coordkit-local"
  and (.git_remotes | index("git@github.com:acme/coordkit"))
  and (.task_keywords | index("repo"))
  and (.task_keywords | index("memory"))
' <<<"$identity" >/dev/null

accepted_root="$(
  jq -nc --arg root "$tmp" --arg path "$tmp/notes/local.md" \
    '{repo_root:$root,workspace:"other",paths:[$path],keywords:["memory","gate"]}' \
  | bash "$PLUGIN/scripts/repo-memory-gate.sh" "$tmp" "repo memory gate smoke test"
)"
jq -e --arg root "$tmp" '.repo_root == $root' <<<"$accepted_root" >/dev/null

accepted_remote="$(
  jq -nc --arg remote "git@github.com:acme/coordkit.git" \
    '{git_remote:$remote,workspace:"handymate",keywords:["memory"]}' \
  | bash "$PLUGIN/scripts/repo-memory-gate.sh" "$tmp" "repo memory gate smoke test"
)"
jq -e '.git_remote == "git@github.com:acme/coordkit.git"' <<<"$accepted_remote" >/dev/null

accepted_path="$(
  jq -nc --arg path "$tmp/src/memory-note.md" \
    '{paths:[$path],workspace:"handymate",keywords:["memory"]}' \
  | bash "$PLUGIN/scripts/repo-memory-gate.sh" "$tmp" "repo memory gate smoke test"
)"
jq -e --arg path "$tmp/src/memory-note.md" '.paths[0] == $path' <<<"$accepted_path" >/dev/null

rejected_foreign="$(
  jq -nc --arg root "$tmp/../other-repo" --arg remote "git@github.com:other/handymate.git" \
    '{repo_root:$root,git_remote:$remote,workspace:"handymate",paths:["/tmp/nowhere.md"],keywords:["repo","memory","gate"]}' \
  | bash "$PLUGIN/scripts/repo-memory-gate.sh" "$tmp" "repo memory gate smoke test"
)"
test -z "$rejected_foreign"

echo "repo memory gate: ok"
