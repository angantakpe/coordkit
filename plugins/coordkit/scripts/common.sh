#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/common.sh — the ONE canonical implementation of the primitives every
# coordkit entrypoint needs: repo-root resolution, branch naming, the persistent
# data dir, and this machine's stable actor identity.
#
# These four were previously hand-copied into claude-bus.sh, claude-ledger.sh,
# migrate.sh, gc.sh, bin/sync.sh, bootstrap.sh and transports/lib.sh. The copies
# drifted (one branch_of returned "" on a detached HEAD where another returned
# "detached"; one resolve_root ranked CLAUDE_PROJECT_DIR above the git toplevel),
# and a resolve_root drift is silently corrupting: two components resolve two
# DIFFERENT .claude-bus trees and the coordination state splits in half. Every
# caller now sources this file so that class of bug is structurally impossible.
#
# SOURCING IS SIDE-EFFECT-FREE: this file only defines functions. No I/O, no
# mkdir, no config reads. Everything is deferred to call time.
#
# Sourced as:
#   scripts/*    . "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}/scripts/common.sh"
#   transports/  via __logstore_common (CLAUDE_PLUGIN_ROOT, else ../scripts/)
#   bin/*        relative to the readlink-resolved ROOT

[ -n "${_CK_COMMON_SH:-}" ] && return 0
_CK_COMMON_SH=1

# --------------------------------------------------------------------------- #
# Plugin install root — the directory holding scripts/, transports/, schema/.
# Prefer the plugin runtime's env var; fall back to this file's own location
# (common.sh lives in scripts/, so its parent is the plugin root).
# --------------------------------------------------------------------------- #
ck_plugin_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then printf '%s' "$CLAUDE_PLUGIN_ROOT"; return 0; fi
  ( cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd )
}

# Persistent, cross-repo plugin data dir (site.json, clock.state, trust.json).
ck_data_dir() {
  printf '%s' "${COORDKIT_DATA:-${CLAUDE_PLUGIN_DATA:-$HOME/.claude/coordkit-data}}"
}

# --------------------------------------------------------------------------- #
# resolve_root <cwd> — THE repo-root rule. Precedence:
#   CLAUDE_BUS_ROOT > git toplevel > nearest ancestor with .claude-bus/ >
#   CLAUDE_PROJECT_DIR > cwd
#
# The git-toplevel-before-CLAUDE_PROJECT_DIR order matters in a workspace of
# nested git repos under a non-git parent project dir: preferring
# CLAUDE_PROJECT_DIR there would resolve some components to the PARENT while
# others resolved to the nested repo. The ancestor-.claude-bus probe is what lets
# a non-git subdir join a parent bus, so it must stay ahead of the
# CLAUDE_PROJECT_DIR fallback.
# --------------------------------------------------------------------------- #
resolve_root() {
  local cwd="$1" top dir
  # explicit pin wins over everything — lets sibling non-git subdirs share one bus
  if [ -n "${CLAUDE_BUS_ROOT:-}" ]; then printf '%s' "$CLAUDE_BUS_ROOT"; return; fi
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$top" ]; then printf '%s' "$top"; return; fi
  dir="$cwd"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    [ -d "$dir/.claude-bus" ] && { printf '%s' "$dir"; return; }
    dir="$(dirname "$dir")"
  done
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then printf '%s' "$CLAUDE_PROJECT_DIR"; return; fi
  printf '%s' "$cwd"
}

# Prints the branch name, or a sentinel that never matches a real branch:
#   no-git    -> not a git work tree (git command failed)
#   detached  -> detached HEAD (git prints empty on exit 0)
# Same-branch collision checks must treat both sentinels (and empty) as
# never-matching, otherwise two detached-HEAD instances look like a collision.
branch_of() {
  local b
  b="$(git -C "$1" branch --show-current 2>/dev/null)" || { printf 'no-git'; return; }
  if [ -n "$b" ]; then printf '%s' "$b"; else printf 'detached'; fi
}

# Deterministic subject slug from free text — the SAME transform claude-ledger.sh
# uses for its task/decision/question subjects, so a caller (e.g. claude-bus.sh's
# `claim`, which delegates to the ledger's task queue) can compute the identical
# subject a "task <desc>" call will mint, without parsing the ledger's own stdout.
slug() { printf '%s' "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9._-' | cut -c1-48; }

# --------------------------------------------------------------------------- #
# Actor identity — ONE stable id per (machine + user + home), persisted in
# ${data}/site.json. This is THIS machine's own identity; it is NOT the same
# concept as transports/lib.sh's __logstore_actor_of(), which reads the .actor
# field out of an event line that some other actor may have written.
# --------------------------------------------------------------------------- #

# Read the persisted actor, deriving (without persisting) if site.json is absent.
ck_actor() {
  local f a
  f="$(ck_data_dir)/site.json"
  a="$(jq -r '.actor // empty' "$f" 2>/dev/null)"
  [ -n "$a" ] && { printf '%s' "$a"; return; }
  local seed="${HOSTNAME:-host}-${USER:-user}-${HOME:-/}" h
  if command -v b3sum >/dev/null 2>&1; then h="$(printf '%s' "$seed" | b3sum 2>/dev/null | cut -c1-8)"
  else h="$(printf '%s' "$seed" | sha256sum 2>/dev/null | cut -c1-8)"; fi
  printf 'site-%s' "${h:-00000000}"
}

# Per-actor monotonic clock counter; advances under its own lock (fd 8).
ck_clock_c() {
  local d f c
  d="$(ck_data_dir)"; f="${d}/clock.state"
  mkdir -p "$d" 2>/dev/null
  ( flock 8
    c="$(cat "$f" 2>/dev/null)"; [ -z "$c" ] && c=0; c=$(( c + 1 )); printf '%s' "$c" > "$f"; printf '%s' "$c"
  ) 8>"${f}.lock"
}

# Materialize the stable actor identity into ${data}/site.json. Cheap and
# idempotent: a single jq validation once the file exists, a no-op after the
# first successful write. Best-effort — always returns 0 so a caller can chain
# it on an init path without risking a failure.
ck_ensure_site() {
  local d site seed h actor
  d="$(ck_data_dir)"; site="${d}/site.json"
  [ -s "$site" ] && jq -e '.actor' "$site" >/dev/null 2>&1 && return 0
  mkdir -p "$d" 2>/dev/null || return 0
  seed="${HOSTNAME:-$(hostname 2>/dev/null || echo host)}-${USER:-$(id -un 2>/dev/null || echo user)}-${HOME:-/}"
  if command -v b3sum >/dev/null 2>&1; then h="$(printf '%s' "$seed" | b3sum 2>/dev/null | cut -c1-8)"
  else h="$(printf '%s' "$seed" | sha256sum 2>/dev/null | cut -c1-8)"; fi
  actor="site-${h:-00000000}"
  jq -nc --arg actor "$actor" --arg user "${USER:-}" --arg host "${HOSTNAME:-}" \
    '{actor:$actor, user:$user, host:$host}' > "$site" 2>/dev/null || return 0
  return 0
}
