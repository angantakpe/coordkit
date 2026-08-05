#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${ROOT}/plugins/coordkit"
PACKAGE_RUNTIME="${ROOT}/packages/core/scripts/agent-runtime.py"
PLUGIN_RUNTIME="${PLUGIN}/scripts/agent-runtime.py"
tmp="$(mktemp -d /tmp/coordkit-agent-runtime.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

validation="$(python3 "$PACKAGE_RUNTIME" validate --json)"
printf '%s' "$validation" | jq -e '
  .valid == true
  and .count == 10
  and .role_counts == {orchestration: 5, system: 5}
  and (.source_digest | length == 64)
' >/dev/null

listing="$(python3 "$PACKAGE_RUNTIME" list --json)"
printf '%s' "$listing" | jq -e 'map(.name) | index("work-graph-planner") != null' >/dev/null
printf '%s' "$listing" | jq -e 'all(.role_type == "orchestration" or .role_type == "system")' >/dev/null
printf '%s' "$listing" | jq -e 'all(.routing_keywords | length > 0)' >/dev/null
printf '%s' "$listing" | jq -e 'all(has("instructions") | not)' >/dev/null
printf '%s' "$listing" | jq -e '
  map(.name) | all(
    . != "auth-route-debugger"
    and . != "auth-route-tester"
    and . != "auto-error-resolver"
    and . != "code-architecture-reviewer"
    and . != "code-refactor-master"
    and . != "documentation-architect"
    and . != "frontend-error-fixer"
    and . != "plan-reviewer"
    and . != "refactor-planner"
    and . != "web-research-specialist"
  )
' >/dev/null

system_listing="$(python3 "$PACKAGE_RUNTIME" list --role-type system --json)"
printf '%s' "$system_listing" | jq -e '
  map(.name) == [
    "context-governor-auditor",
    "coordination-state-debugger",
    "host-adapter-engineer",
    "ledger-convergence-auditor",
    "transport-reliability-debugger"
  ]
' >/dev/null

workflow="$(python3 "$PACKAGE_RUNTIME" workflow --json)"
printf '%s' "$workflow" | jq -e '
  map(.name) == [
    "work-graph-planner",
    "dispatch-coordinator",
    "bounded-implementation-worker",
    "integration-coordinator",
    "goal-verifier"
  ]
' >/dev/null

planning="$(python3 "$PACKAGE_RUNTIME" route 'decompose this feature into dependency-aware parallel tasks with disjoint write scopes' --role-type orchestration --json)"
printf '%s' "$planning" | jq -e '.[0].name == "work-graph-planner" and .[0].lifecycle_stage == "planning"' >/dev/null

transport="$(python3 "$PACKAGE_RUNTIME" route 'diagnose an offline relay outbox that does not replay its cursor' --role-type system --json)"
printf '%s' "$transport" | jq -e '.[0].name == "transport-reliability-debugger"' >/dev/null

rendered="$(python3 "$PACKAGE_RUNTIME" render work-graph-planner --task 'Plan safe parallel implementation slices.' --cwd "$tmp")"
printf '%s' "$rendered" | grep -F 'Role: work-graph-planner' >/dev/null
printf '%s' "$rendered" | grep -F 'Role type: orchestration' >/dev/null
printf '%s' "$rendered" | grep -F 'Lifecycle stage: planning' >/dev/null
printf '%s' "$rendered" | grep -F 'Plan safe parallel implementation slices.' >/dev/null
printf '%s' "$rendered" | grep -F 'You design executable multi-agent work graphs.' >/dev/null
if python3 "$PACKAGE_RUNTIME" render goal-verifier --task 'Mismatch.' \
  --role-type system --stage diagnostics >/dev/null 2>&1; then
  echo "agent runtime: explicit render bypassed role filters" >&2
  exit 1
fi

catalog="${tmp}/plugin-data/agents/catalog.json"
compiled="$(python3 "$PACKAGE_RUNTIME" compile --output "$catalog")"
test "$compiled" = "$catalog"
jq -e '
  .schema_version == 2
  and (.agents | length) == 10
  and ([.agents[] | select(.role_type == "orchestration")] | length) == 5
  and ([.agents[] | select(.role_type == "system")] | length) == 5
' "$catalog" >/dev/null

pkg_listing="$(python3 "$PACKAGE_RUNTIME" list --json | jq -S '.')"
shim_listing="$(python3 "$PLUGIN_RUNTIME" list --json | jq -S '.')"
test "$pkg_listing" = "$shim_listing"

COORDKIT_PLUGIN_ROOT="$PLUGIN" "${PLUGIN}/bin/cobus" agents route \
  'verify that the integrated result satisfies every acceptance criterion' \
  --role-type orchestration --stage verification --json \
  | jq -e '.[0].name == "goal-verifier"' >/dev/null

bad="${tmp}/bad-agents"
mkdir -p "$bad"
printf '%s\n' 'not frontmatter' > "${bad}/broken.md"
if python3 "$PACKAGE_RUNTIME" --agents-dir "$bad" validate >/dev/null 2>&1; then
  echo "agent runtime: malformed definition unexpectedly validated" >&2
  exit 1
fi

stale_data="${tmp}/stale-plugin-data"
mkdir -p "$stale_data/agents"
printf '%s\n' '{"schema_version":1,"agents":[{"name":"stale-agent"}]}' \
  > "$stale_data/agents/catalog.json"
startup="$(jq -nc --arg cwd "$tmp" '{session_id:"catalog-failure",cwd:$cwd,hook_event_name:"SessionStart"}')"
warning="$(
  COORDKIT_AGENT_DIR="$bad" COORDKIT_PLUGIN_ROOT="$PLUGIN" \
    COORDKIT_PLUGIN_DATA="$stale_data" COORDKIT_PROJECT_DIR="$tmp" \
    COORDKIT_SESSION_ID=catalog-failure COORDKIT_HOST=codex \
    bash "$PLUGIN/scripts/swarm.sh" session-start <<<"$startup"
)"
test ! -e "$stale_data/agents/catalog.json"
jq -e '.valid == false and (.message | contains("missing opening YAML frontmatter"))' \
  "$stale_data/agents/catalog.error.json" >/dev/null
printf '%s' "$warning" | grep -F 'catalog unavailable; stale catalog removed' >/dev/null

invalid_role="${tmp}/invalid-role"
mkdir -p "$invalid_role"
sed 's/^role_type: orchestration$/role_type: generic/' \
  "$PLUGIN/agents/work-graph-planner.md" > "$invalid_role/work-graph-planner.md"
if python3 "$PACKAGE_RUNTIME" --agents-dir "$invalid_role" validate >/dev/null 2>&1; then
  echo "agent runtime: invalid role type unexpectedly validated" >&2
  exit 1
fi

echo "agent runtime: ok"
