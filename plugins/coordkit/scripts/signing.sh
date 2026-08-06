#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/signing.sh — Phase 1 PROTOTYPE ed25519 event signing library.
#
# ISOLATED BY DESIGN. Nothing in the live hook path sources this file:
# ledger.sh's append_event/_ck_emit_v2 (the write path every event goes
# through) and build_digest/the delta-injection read paths (the SessionStart/
# UserPromptSubmit hot path) never call into it. `sig` stays null on every
# real event exactly as packages/protocol/event.schema.json's field note says: "NOT YET
# IMPLEMENTED: nothing signs and nothing verifies; the emitter always writes
# null." This file makes that mechanism real and testable in isolation without
# flipping it live — see plugins/coordkit/docs/SIGNING-PROPOSAL.md for why
# wiring it into the write/read path is a separate, larger decision (it needs
# a key-distribution/trust story this file deliberately does not build).
#
# Mechanism: ed25519 via the `openssl` CLI. Verified locally (this box:
# OpenSSL 3.0.13) that the right invocation is `openssl pkeyutl -sign/-verify
# -rawin`, NOT `openssl dgst -sign` — `dgst -sign` rejects ed25519 keys
# outright ("Key type not supported for this operation") because EdDSA is a
# one-shot "sign the whole message" scheme, not OpenSSL's usual
# hash-then-sign-the-digest flow; `-rawin` is what feeds pkeyutl the raw
# message instead of a precomputed digest. b3sum is NOT installed on this box
# (verified) but ed25519 needs no external hasher — it hashes internally via
# SHA-512 as part of the algorithm.
#
# Signature encoding: base64, single line (`openssl base64 -A`), decoded the
# same way for verify. Chosen over hex to reuse the ONE tool this file already
# depends on (openssl) for both directions, rather than also requiring
# xxd/coreutils base64 to exist for hex<->binary round-tripping.
#
# Key management models ck_actor()/ck_ensure_site() in common.sh: a per-machine
# identity, generated once on first use and persisted to $(ck_data_dir)
# (identity.key / identity.pub), idempotent, best-effort, never hard-fails.
#
# Usage — as a library:
#   . signing.sh
#   ck_ensure_signing_key                  # idempotent; generates on first use
#   signed="$(ck_sign_event "$event_json")"       # sets .sig (base64) on success
#   ck_verify_event "$signed_event_json" "$pubkey_path"   # 0 = verified
#
# Usage — as a CLI:
#   bash signing.sh selftest   # throwaway keypair; sign+verify (pass), then
#                              # mutate one field and verify again (expect fail)
set -uo pipefail

[ -n "${_CK_SIGNING_SH:-}" ] && return 0 2>/dev/null
_CK_SIGNING_SH=1

# ck_data_dir() is the only thing pulled from common.sh (identity.key/.pub live
# alongside site.json/trust.json/clock.state there). A missing common.sh means
# a broken install; define nothing rather than fail into a half-working state.
# shellcheck source=./common.sh
. "${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}}/scripts/common.sh" || return 0 2>/dev/null

ck_sign_available() { command -v openssl >/dev/null 2>&1; }

ck_signing_key_path() { printf '%s/identity.key' "$(ck_data_dir)"; }
ck_signing_pub_path()  { printf '%s/identity.pub' "$(ck_data_dir)"; }

# Idempotent, best-effort. Mirrors ck_ensure_site()'s contract exactly: a
# single existence check once both files are there, mkdir -p + genpkey once,
# ALWAYS returns 0 so a caller can chain it without risking a failure.
ck_ensure_signing_key() {
  local d key pub
  ck_sign_available || return 0
  d="$(ck_data_dir)"; key="$(ck_signing_key_path)"; pub="$(ck_signing_pub_path)"
  [ -s "$key" ] && [ -s "$pub" ] && return 0
  mkdir -p "$d" 2>/dev/null || return 0
  openssl genpkey -algorithm ed25519 -out "$key" >/dev/null 2>&1 || return 0
  chmod 600 "$key" 2>/dev/null
  openssl pkey -in "$key" -pubout -out "$pub" >/dev/null 2>&1 || return 0
  return 0
}

# Canonicalize EXACTLY the way eid is computed in _ck_emit_v2 (ledger.sh,
# `_ck_emit_v2`, the `eid="${hasher}:$(... | jq -Sc 'del(.eid,.sig)' ...)"`
# line): sorted-keys compact JSON with BOTH eid and sig dropped. Signing over
# these same bytes is what keeps a signature and the eid computed over
# consistent, matching input — and keeps adding a signature from ever changing
# an event's eid, per the schema's `sig` field note.
ck_canonicalize_event() {  # $1 = event JSON
  printf '%s' "$1" | jq -Sc 'del(.eid,.sig)' 2>/dev/null
}

# ck_sign_event <event_json> [key_path] -> event JSON with .sig set (base64)
# on success. On ANY failure (no openssl, no key, bad JSON) prints the input
# event UNCHANGED — best-effort, never hard-fails the caller.
ck_sign_event() {
  local event="$1" key="${2:-$(ck_signing_key_path)}" canon tmp sigfile sig=""
  ck_sign_available || { printf '%s' "$event"; return 0; }
  [ -s "$key" ] || { printf '%s' "$event"; return 0; }
  canon="$(ck_canonicalize_event "$event")"
  [ -n "$canon" ] || { printf '%s' "$event"; return 0; }
  tmp="$(mktemp 2>/dev/null)" || { printf '%s' "$event"; return 0; }
  sigfile="${tmp}.sig"
  printf '%s' "$canon" > "$tmp"
  if openssl pkeyutl -sign -inkey "$key" -rawin -in "$tmp" -out "$sigfile" >/dev/null 2>&1; then
    sig="$(openssl base64 -A -in "$sigfile" 2>/dev/null)"
  fi
  rm -f "$tmp" "$sigfile" 2>/dev/null
  if [ -n "$sig" ]; then
    printf '%s' "$event" | jq -c --arg sig "$sig" '.sig = $sig' 2>/dev/null || printf '%s' "$event"
  else
    printf '%s' "$event"
  fi
}

# ck_verify_event <event_json> <pubkey_path> -> exit 0 = verified, 1 = failed
# or unverifiable (no openssl, no .sig, bad pubkey, tampered event, ...).
#
# NOTE — the whole reason this stays unwired: there is currently NO mechanism
# anywhere in coordkit for a reader to discover or fetch ANOTHER actor's public
# key. This function takes the pubkey path as an explicit caller-supplied
# argument for exactly that reason; it does not, and as shipped CANNOT, look
# one up on its own. Wiring verify into a read path (build_digest / delta
# injection) without first solving that lookup would mean every event fails
# verification except the reader's own. See docs/SIGNING-PROPOSAL.md.
ck_verify_event() {
  local event="$1" pub="$2" sig canon tmp sigfile rc
  ck_sign_available || return 1
  [ -s "$pub" ] || return 1
  sig="$(printf '%s' "$event" | jq -r '.sig // empty' 2>/dev/null)"
  [ -n "$sig" ] || return 1
  canon="$(ck_canonicalize_event "$event")"
  [ -n "$canon" ] || return 1
  tmp="$(mktemp 2>/dev/null)" || return 1
  sigfile="${tmp}.sig"
  printf '%s' "$canon" > "$tmp"
  printf '%s' "$sig" | openssl base64 -A -d -out "$sigfile" 2>/dev/null
  openssl pkeyutl -verify -pubin -inkey "$pub" -rawin -in "$tmp" -sigfile "$sigfile" >/dev/null 2>&1
  rc=$?
  rm -f "$tmp" "$sigfile" 2>/dev/null
  return "$rc"
}

# --------------------------------------------------------------------------- #
# Standalone selftest — a throwaway keypair in its own tmpdir, never touching
# $(ck_data_dir)'s real identity.key/.pub. Proves the mechanism end to end:
# sign a sample v2 event, verify (expect pass), mutate one field, verify again
# (expect fail).
# --------------------------------------------------------------------------- #
_ck_signing_selftest() {
  local tmpd key pub event signed sig mutated
  tmpd="$(mktemp -d 2>/dev/null)" || { echo "FAIL: mktemp -d"; return 1; }
  key="${tmpd}/id.key"; pub="${tmpd}/id.pub"

  echo "1. generate throwaway ed25519 keypair"
  if ! openssl genpkey -algorithm ed25519 -out "$key" >/dev/null 2>&1; then
    echo "FAIL: openssl genpkey"; rm -rf "$tmpd"; return 1
  fi
  chmod 600 "$key" 2>/dev/null
  if ! openssl pkey -in "$key" -pubout -out "$pub" >/dev/null 2>&1; then
    echo "FAIL: openssl pkey -pubout"; rm -rf "$tmpd"; return 1
  fi
  echo "   ok: ${key} / ${pub}"

  event='{"schema_version":"2.0","eid":"","id":"deadbeef0001","actor":"selftest","clock":{"p":1,"c":1},"seq":1,"ts":1,"sid":"s","sid8":"s","user":"","branch":"main","type":"note","subject":"general","body":"selftest event","refs":[],"tags":[],"lease":null,"supersedes":null,"sig":null}'

  echo "2. sign a sample v2 event"
  signed="$(ck_sign_event "$event" "$key")"
  sig="$(printf '%s' "$signed" | jq -r '.sig // empty' 2>/dev/null)"
  if [ -z "$sig" ]; then echo "FAIL: ck_sign_event produced no .sig"; rm -rf "$tmpd"; return 1; fi
  echo "   ok: sig=${sig:0:24}... ($(printf '%s' "$sig" | wc -c | tr -d ' ') base64 chars)"

  echo "3. verify the signed event (expect PASS)"
  if ck_verify_event "$signed" "$pub"; then
    echo "   PASS"
  else
    echo "FAIL: verify of an untouched signed event did not pass"; rm -rf "$tmpd"; return 1
  fi

  echo "4. mutate one field, verify again (expect FAIL)"
  mutated="$(printf '%s' "$signed" | jq -c '.body = "tampered"' 2>/dev/null)"
  if ck_verify_event "$mutated" "$pub"; then
    echo "FAIL: verify of a tampered event unexpectedly PASSED"; rm -rf "$tmpd"; return 1
  else
    echo "   PASS (verify correctly rejected the tampered event)"
  fi

  rm -rf "$tmpd" 2>/dev/null
  echo "SELFTEST: OK"
  return 0
}

# --------------------------------------------------------------------------- #
# Direct-execution CLI. Sourcing this file runs nothing.
# --------------------------------------------------------------------------- #
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-selftest}" in
    selftest) _ck_signing_selftest; exit $? ;;
    *) echo "usage: signing.sh selftest"; exit 0 ;;
  esac
fi
