#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="${ROOT}/scripts/validate-package.py"

fail() {
  printf 'validate-package test failed: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  expected="$1"
  fixture="$2"
  output="$(python3 "$VALIDATOR" "$fixture" 2>&1)" && fail "expected validation to fail: $expected"
  case "$output" in
    *"$expected"*) ;;
    *) fail "expected '$expected', got: $output" ;;
  esac
  case "$output" in
    *Traceback*) fail "validation leaked a Python traceback: $output" ;;
  esac
}

fixture="$(mktemp -d "${TMPDIR:-/tmp}/coordkit-package-validator.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/plugins" "$fixture/.claude-plugin" "$fixture/.agents/plugins"
cp -a "$ROOT/plugins/coordkit" "$fixture/plugins/coordkit"
cp "$ROOT/.claude-plugin/marketplace.json" "$fixture/.claude-plugin/marketplace.json"
cp "$ROOT/.agents/plugins/marketplace.json" "$fixture/.agents/plugins/marketplace.json"

python3 "$VALIDATOR" "$fixture" >/dev/null

agent="$fixture/plugins/coordkit/agents/work-graph-planner.md"
agent_backup="${agent}.test-backup"
mv "$agent" "$agent_backup"
expect_failure 'references missing file: ./agents/work-graph-planner.md' "$fixture"
mv "$agent_backup" "$agent"

codex_manifest="$fixture/plugins/coordkit/.codex-plugin/plugin.json"
codex_backup="${codex_manifest}.test-backup"
cp "$codex_manifest" "$codex_backup"
jq '.version = "9.9.9"' "$codex_backup" > "$codex_manifest"
expect_failure 'package versions do not match' "$fixture"
mv "$codex_backup" "$codex_manifest"

mv "$codex_manifest" "$codex_backup"
expect_failure 'missing JSON file:' "$fixture"
mv "$codex_backup" "$codex_manifest"

cp "$codex_manifest" "$codex_backup"
jq '.skills = "../outside"' "$codex_backup" > "$codex_manifest"
expect_failure 'manifest skills escapes the plugin directory' "$fixture"
mv "$codex_backup" "$codex_manifest"

claude_manifest="$fixture/plugins/coordkit/.claude-plugin/plugin.json"
claude_backup="${claude_manifest}.test-backup"
cp "$claude_manifest" "$claude_backup"
jq '.agents[0] = {"invalid": true}' "$claude_backup" > "$claude_manifest"
expect_failure 'manifest agents[0] must be a non-empty string' "$fixture"
mv "$claude_backup" "$claude_manifest"

mcp_manifest="$fixture/plugins/coordkit/.mcp.json"
mcp_backup="${mcp_manifest}.test-backup"
mv "$mcp_manifest" "$mcp_backup"
printf '{ invalid json\n' > "$mcp_manifest"
expect_failure 'invalid JSON' "$fixture"
mv "$mcp_backup" "$mcp_manifest"

echo "validate package: ok"
