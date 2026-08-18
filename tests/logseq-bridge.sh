#!/usr/bin/env bash
# tests/logseq-bridge.sh — `cobus logseq export|import|sync|status` against a
# temp Logseq graph + a temp repo with a direct-mode ledger.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${ROOT}/plugins/coordkit"
tmp="$(mktemp -d /tmp/coordkit-logseq.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
trap 'status=$?; printf "logseq-bridge: failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR

repo="$tmp/repo"; graph="$tmp/graph"
mkdir -p "$repo/.claude/coord" "$graph/pages" "$graph/journals" "$tmp/plugin-data"
git -C "$repo" init -q
printf 'mode = "local"\n\n[logseq]\ngraph_dir = "%s"\nlinear_workspace = "acme"\n' "$graph" > "$repo/.claude/coord/coord.toml"

export COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_PLUGIN_DATA="$tmp/plugin-data" \
       COORDKIT_PROJECT_DIR="$repo" COORDKIT_SESSION_ID="sess-aaaaaaaa-1111" COORDKIT_HOST=cli
cobus() { bash "$PLUGIN/bin/cobus" "$@"; }
tasks_page="$graph/pages/coordkit___tasks.md"
fleet_page="$graph/pages/coordkit___fleet.md"
journal="$graph/journals/$(date +%Y_%m_%d).md"
state="$repo/.claude/coord/logseq/state.json"

# ── unconfigured graph → clear error, no crash ───────────────────────────────
! COORDKIT_LOGSEQ_GRAPH_DIR="$tmp/does-not-exist" cobus logseq export >/dev/null 2>&1

# ── seed the ledger: an open task with a linear ref, a dependent task, a claim ─
printf "%s\n" "$(cobus task "linear:COD-123 fix the widget")" | grep -q "task 'linearcod-123-fix-the-widget' queued"
cobus task "second task dep:linearcod-123-fix-the-widget" >/dev/null
cobus task "blocked one" >/dev/null
cobus block blocked-one "waiting on api key" >/dev/null
printf "%s\n" "$(cobus claim linearcod-123-fix-the-widget)" | grep -q "claimed"
# a live heartbeat for the claiming session so the claim projects as claimed:
mkdir -p "$repo/.coordkit-bus/agents"
jq -nc --arg sid "$COORDKIT_SESSION_ID" --argjson t "$(date +%s)" \
  '{sid:$sid,last_seen:$t,host:"cli",branch:"main",cwd:"/x",task:"fixing widget",files:[]}' \
  > "$repo/.coordkit-bus/agents/${COORDKIT_SESSION_ID}.json"

# machine-readable projections the bridge is built on
cobus board --json | jq -e '
  length == 3
  and (.[0].subject == "linearcod-123-fix-the-widget" and (.[0].status|startswith("claimed:")) and .[0].owner_sid8 == "sess-aaa" and .[0].owner_host == "cli")
  and (.[1].subject == "second-task-deplinearcod-123-fix-the-widget" and .[1].status == "open" and .[1].ready == false)
  and (.[2].status == "blocked" and .[2].block_body == "waiting on api key")' >/dev/null
[ "$(cobus events --since 0 | wc -l)" -eq 5 ]
[ "$(cobus events --since 3 | wc -l)" -eq 2 ]
cobus fleet --json "$repo" | jq -e --arg r "$repo" '.repos | map(select(.path == $r)) | .[0] | .this_repo and .live == 1 and .agents[0].sid8 == "sess-aaa"' >/dev/null

# ── export creates both pages with markers + today's journal ─────────────────
printf "%s\n" "$(cobus logseq status)" | grep -q 'not exported yet'
out="$(cobus logseq export)"
printf '%s\n' "$out" | grep -q 'tasks .*(updated)'
printf '%s\n' "$out" | grep -q 'fleet .*(updated)'
printf '%s\n' "$out" | grep -Eq 'journal.*\+[0-9]+ event'
test -f "$tasks_page" && test -f "$fleet_page" && test -f "$journal"
grep -q '^title:: coordkit/tasks' "$tasks_page"
grep -q '^<!-- coordkit:begin tasks -->' "$tasks_page"
grep -q '^<!-- coordkit:end tasks -->' "$tasks_page"
grep -q '^- DOING linear:COD-123 fix the widget' "$tasks_page"
grep -q '^  coordkit-task:: linearcod-123-fix-the-widget' "$tasks_page"
grep -q '^  coordkit-owner:: sess-aaa' "$tasks_page"
grep -q '^  coordkit-host:: cli' "$tasks_page"
grep -q '^  coordkit-url:: https://linear.app/acme/issue/COD-123' "$tasks_page"
grep -q '^  coordkit-ref:: linear:COD-123' "$tasks_page"
grep -q '^- TODO second task dep:' "$tasks_page"
grep -q '^  coordkit-waiting-on:: deps' "$tasks_page"
grep -q '^- WAITING blocked one' "$tasks_page"
grep -q '^  coordkit-blocked:: waiting on api key' "$tasks_page"
grep -q '^<!-- coordkit:begin fleet -->' "$fleet_page"
grep -q 'This machine' "$fleet_page"
grep -q "$repo" "$fleet_page"
grep -q 'sess-aaa \[cli, live' "$fleet_page"
grep -q 'task: fixing widget' "$fleet_page"
grep -q 'Actors seen in the shared ledger' "$fleet_page"
grep -q '^- \[\[coordkit/log\]\]' "$journal"
grep -Eq $'^\t- [0-9]{2}:[0-9]{2} \\*\\*task\\*\\* `linearcod-123-fix-the-widget`' "$journal"
grep -Eq $'^\t- [0-9]{2}:[0-9]{2} \\*\\*claim\\*\\* `linearcod-123-fix-the-widget`' "$journal"
grep -Eq $'^\t- [0-9]{2}:[0-9]{2} \\*\\*block\\*\\* `blocked-one`' "$journal"
grep -q 'session\*\* sess-aaa@cli .* appeared' "$journal"
[ "$(grep -c '^- \[\[coordkit/log\]\]' "$journal")" -eq 1 ]
jq -e '.cursor_seq == 5 and (.seen_eids|length) == 5 and .exports == 1' "$state" >/dev/null
# state dir is excluded from git
git -C "$repo" status --porcelain | grep -q 'logseq' && exit 1

# ── re-export is idempotent: pages byte-identical, journal untouched ─────────
cp "$tasks_page" "$tmp/tasks.1"; cp "$fleet_page" "$tmp/fleet.1"; cp "$journal" "$tmp/journal.1"
sleep 1
out="$(cobus logseq export)"
printf '%s\n' "$out" | grep -q 'tasks .*(unchanged)'
printf '%s\n' "$out" | grep -q 'journal.*nothing new'
cmp -s "$tasks_page" "$tmp/tasks.1"
cmp -s "$journal" "$tmp/journal.1"
# fleet only differs by session age → the *structure* must be identical
diff <(sed -E 's/[0-9]+[smh] ago/N ago/' "$fleet_page") <(sed -E 's/[0-9]+[smh] ago/N ago/' "$tmp/fleet.1")

# ── hand-written content outside the markers survives a re-export ────────────
{
  printf 'my-note:: keep me\n'
  cat "$tasks_page"
  printf '\n- My own bullet under the export\n\t- nested hand-written child\n'
} > "$tmp/tasks.edited"
mv "$tmp/tasks.edited" "$tasks_page"
cobus task "third task" >/dev/null
printf "%s\n" "$(cobus logseq export --pages)" | grep -q 'tasks .*(updated)'
grep -q '^my-note:: keep me' "$tasks_page"
grep -q '^- My own bullet under the export' "$tasks_page"
grep -q $'^\t- nested hand-written child' "$tasks_page"
grep -q '^- TODO third task' "$tasks_page"
[ "$(grep -c '^<!-- coordkit:begin tasks -->' "$tasks_page")" -eq 1 ]
[ "$(grep -c '^  coordkit-task:: ' "$tasks_page")" -eq 4 ]
# region rewrite keeps ordering: note, then title, then one managed block
awk '/^<!-- coordkit:begin tasks -->/{b=NR} /^<!-- coordkit:end tasks -->/{e=NR} /^- My own bullet/{m=NR} END{exit !(b<e && e<m)}' "$tasks_page"

# ── journal is incremental: only the new events since the cursor ─────────────
printf "%s\n" "$(cobus logseq export --journal)" | grep -Eq 'journal.*\+1 event'
[ "$(grep -c '\*\*task\*\* `third-task`' "$journal")" -eq 1 ]
[ "$(grep -c '\*\*task\*\* `linearcod-123-fix-the-widget`' "$journal")" -eq 1 ]
[ "$(grep -c '^- \[\[coordkit/log\]\]' "$journal")" -eq 1 ]   # reused the parent bullet
jq -e '.cursor_seq == 6' "$state" >/dev/null

# ── import: a tagged TODO in a journal + an untagged one on the inbox page ────
printf -- '- Random journal thoughts\n- TODO ship the logseq bridge #coordkit\n\t- some child note\n- TODO not for coordkit\n' > "$graph/journals/2026_01_01.md"
printf 'title:: coordkit/inbox\n\n- LATER review the relay docs\n- DONE already finished, never had an id\n' > "$graph/pages/coordkit___inbox.md"
# CRLF file with a nested tagged block: indentation + line endings must survive
printf -- '- Project X\r\n\t- TODO write CRLF safe importer #coordkit\r\n\t- plain child\r\n' > "$graph/pages/crlf.md"

dry="$(cobus logseq import --dry-run)"
printf '%s\n' "$dry" | grep -q "would create 2026_01_01.md:2 → task 'ship-the-logseq-bridge'"
printf '%s\n' "$dry" | grep -q "would create coordkit___inbox.md:3 → task 'review-the-relay-docs'"
printf '%s\n' "$dry" | grep -q "would create crlf.md:2 → task 'write-crlf-safe-importer'"
printf '%s\n' "$dry" | grep -q 'dry-run'
[ "$(cobus board --json | jq length)" -eq 4 ]      # dry-run wrote nothing
grep -q 'coordkit-task' "$graph/journals/2026_01_01.md" && exit 1

printf "%s\n" "$(cobus logseq import)" | grep -q 'import: 3 created, 0 linked, 0 closed'
[ "$(cobus board --json | jq length)" -eq 7 ]
cobus board --json | jq -e '.[] | select(.subject == "ship-the-logseq-bridge") | .desc == "ship the logseq bridge" and .status == "open"' >/dev/null
# property written back into the exact block, indentation preserved
sed -n '2,3p' "$graph/journals/2026_01_01.md" | diff - <(printf -- '- TODO ship the logseq bridge #coordkit\n  coordkit-task:: ship-the-logseq-bridge\n')
grep -q '^- TODO not for coordkit$' "$graph/journals/2026_01_01.md"
sed -n '3,4p' "$graph/pages/coordkit___inbox.md" | diff - <(printf -- '- LATER review the relay docs\n  coordkit-task:: review-the-relay-docs\n')
# CRLF + tab indentation kept, property indented under the nested bullet
[ "$(grep -c $'\r$' "$graph/pages/crlf.md")" -eq 4 ]
sed -n '2,3p' "$graph/pages/crlf.md" | diff - <(printf -- '\t- TODO write CRLF safe importer #coordkit\r\n\t  coordkit-task:: write-crlf-safe-importer\r\n')
jq -e '.imported | has("ship-the-logseq-bridge") and has("review-the-relay-docs") and has("write-crlf-safe-importer")' "$state" >/dev/null

# second import is a no-op
printf "%s\n" "$(cobus logseq import)" | grep -q 'import: 0 created, 0 linked, 0 closed'
[ "$(cobus board --json | jq length)" -eq 7 ]
[ "$(grep -c 'coordkit-task::' "$graph/journals/2026_01_01.md")" -eq 1 ]

# ── DONE round-trip: Logseq DONE → ledger done ───────────────────────────────
sed -i 's/^- TODO ship the logseq bridge #coordkit$/- DONE ship the logseq bridge #coordkit/' "$graph/journals/2026_01_01.md"
printf "%s\n" "$(cobus logseq import)" | grep -q 'import: 0 created, 0 linked, 1 closed'
cobus board --json | jq -e '.[] | select(.subject == "ship-the-logseq-bridge") | .status == "done"' >/dev/null
printf "%s\n" "$(cobus logseq import)" | grep -q '0 closed'   # idempotent

# ── DONE round-trip: ledger done → Logseq block flipped on next export ────────
cobus done review-the-relay-docs >/dev/null
printf "%s\n" "$(cobus logseq export --pages)" | grep -q 'blocks → 1 Logseq block(s) flipped to DONE'
sed -n '3,4p' "$graph/pages/coordkit___inbox.md" | diff - <(printf -- '- DONE review the relay docs\n  coordkit-task:: review-the-relay-docs\n')
grep -q '^- DONE ship the logseq bridge #coordkit$' "$graph/journals/2026_01_01.md"   # untouched
# and the managed tasks page reflects both
grep -q '^- DONE ship the logseq bridge$' "$tasks_page"
grep -q '^- DONE review the relay docs$' "$tasks_page"
grep -q '^- TODO write CRLF safe importer$' "$tasks_page"

# ── sync = import + export in one go, then a bounded loop that exits on SIGINT ─
printf -- '- NOW hot item #coordkit\n' >> "$graph/journals/2026_01_01.md"
printf "%s\n" "$(cobus logseq sync)" | grep -q 'import: 1 created'
grep -q '^- TODO hot item$' "$tasks_page"
# `timeout -s INT` sends the loop's own trap target directly and reaps the
# process itself — avoids managing a background job/PID by hand, which proved
# flaky under this harness's process-group handling.
timeout -s INT 3 bash "$PLUGIN/bin/cobus" logseq sync --loop 1 >"$tmp/loop.out" 2>&1 || true
grep -q 'sync loop every 1s' "$tmp/loop.out"
grep -q 'stopped' "$tmp/loop.out"

# ── status reflects the state ────────────────────────────────────────────────
st="$(cobus logseq status)"
printf '%s\n' "$st" | grep -q "graph_dir:   $graph"
printf '%s\n' "$st" | grep -q '4 imported from Logseq'
printf '%s\n' "$st" | grep -q 'http api:    not configured'
printf "%s\n" "$(COORDKIT_LOGSEQ_API_URL=http://127.0.0.1:1/api LOGSEQ_API_TOKEN=x cobus logseq status)" | grep -q 'unreachable — file mode only'
printf "%s\n" "$(COORDKIT_LOGSEQ_API_URL=http://127.0.0.1:1/api cobus logseq status)" | grep -q 'LOGSEQ_API_TOKEN not set'
# an unreachable API never breaks a sync
COORDKIT_LOGSEQ_API_URL=http://127.0.0.1:1/api LOGSEQ_API_TOKEN=x cobus logseq sync >/dev/null

# ── namespace + tag are configurable ─────────────────────────────────────────
printf 'mode = "local"\n\n[logseq]\ngraph_dir = "%s"\nnamespace = "ops"\ntag = "#agents"\njournal_format = "yyyy-MM-dd"\n' "$graph" > "$repo/.claude/coord/coord.toml"
printf -- '- TODO other tag task #agents\n' > "$graph/pages/scratch.md"
cobus logseq sync >/dev/null
test -f "$graph/pages/ops___tasks.md" && test -f "$graph/pages/ops___fleet.md"
test -f "$graph/journals/$(date +%Y-%m-%d).md"
grep -q '^  coordkit-task:: other-tag-task' "$graph/pages/scratch.md"
grep -q '^title:: ops/tasks' "$graph/pages/ops___tasks.md"

echo "logseq-bridge: ok"
