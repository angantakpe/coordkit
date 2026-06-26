#!/usr/bin/env bash
# 0001_v1_to_v2.sh — ON-READ up-converter, v1 → v2.
#
# APPEND-ONLY / NEVER MUTATES STORED EVENTS. This is a pure stdin->stdout
# transform: it reads ledger lines on stdin and emits v2-enveloped lines on
# stdout. It does not open, rewrite, or delete any file. Idempotent: a line
# that is already v2 (has schema_version) passes through unchanged.
#
# v1 -> v2 lift rules:
#   - missing schema_version            => "2.0"
#   - clock                             => { p: ts*1000, c: seq }   (synthetic, deterministic)
#   - actor                             => "legacy-site"
#   - id                                => "legacy-" + seq
#   - eid                               => "<hash>:" of the canonical original line (dedup-stable)
#   - lease (number/0)                  => object { until } | null   (never a bare scalar in v2)
#   - all other fields preserved verbatim; refs/tags defaulted to []
#
# Hash: prefers b3sum (blake3), falls back to sha256sum.
set -uo pipefail

HASHER="sha256"; HCMD="sha256sum"
if command -v b3sum >/dev/null 2>&1; then HASHER="blake3"; HCMD="b3sum"; fi

_hash() { "$HCMD" 2>/dev/null | cut -d' ' -f1 | cut -c1-32; }

while IFS= read -r line; do
  [ -z "$line" ] && continue
  # already v2? pass through untouched (idempotent)
  if printf '%s' "$line" | jq -e 'has("schema_version")' >/dev/null 2>&1; then
    printf '%s\n' "$line"; continue
  fi
  # not JSON? emit verbatim (tolerant)
  if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$line"; continue
  fi
  eid="${HASHER}:$(printf '%s' "$line" | _hash)"
  printf '%s' "$line" | jq -c --arg eid "$eid" --arg hasher "$HASHER" '
    ((.ts // 0)) as $ts | ((.seq // 0)) as $seq |
    {
      schema_version: "2.0",
      eid: $eid,
      id: ("legacy-" + ($seq|tostring)),
      actor: "legacy-site",
      clock: { p: (($ts) * 1000), c: $seq },
      seq: $seq,
      ts: $ts,
      sid: (.sid // ""),
      sid8: (.sid8 // ""),
      user: (.user // ""),
      branch: (.branch // "no-git"),
      type: (.type // "note"),
      subject: (.subject // "general"),
      body: (.body // ""),
      refs: (.refs // []),
      tags: (.tags // []),
      lease: (
        if (.lease|type) == "object" then .lease
        elif ((.lease // 0) | tonumber? // 0) > 0 then { until: (.lease|tonumber), owner: "legacy-site", sid8: (.sid8 // "") }
        else null end
      ),
      supersedes: null,
      sig: null
    }'
done
