#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/common.sh — the ONE canonical implementation of the primitives every
# coordkit entrypoint needs: repo-root resolution, branch naming, the persistent
# data dir, and this machine's stable actor identity.
#
# These four were previously hand-copied into bus.sh, ledger.sh,
# migrate.sh, gc.sh, bin/sync.sh, bootstrap.sh and transports/lib.sh. The copies
# drifted (one branch_of returned "" on a detached HEAD where another returned
# "detached"; one resolve_root ranked the workspace dir above the git toplevel),
# and a resolve_root drift is silently corrupting: two components resolve two
# DIFFERENT .coordkit-bus trees and the coordination state splits in half. Every
# caller now sources this file so that class of bug is structurally impossible.
#
# SOURCING IS SIDE-EFFECT-FREE: this file only defines functions. No I/O, no
# mkdir, no config reads. Everything is deferred to call time.
#
# Sourced as:
#   scripts/*    . "${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}}/scripts/common.sh"
#   transports/  via __logstore_common (COORDKIT_PLUGIN_ROOT, else legacy fallback)
#   bin/*        relative to the readlink-resolved ROOT

[ -n "${_CK_COMMON_SH:-}" ] && return 0
_CK_COMMON_SH=1

ck_first_env() {
  local name value
  for name in "$@"; do
    value="${!name:-}"
    [ -n "$value" ] && { printf '%s' "$value"; return 0; }
  done
  return 1
}

# --------------------------------------------------------------------------- #
# Runtime install root — the directory holding scripts/, transports/, schema/.
# Prefer the host adapter's env var; fall back to this file's own location
# (common.sh lives in scripts/, so its parent is the runtime root).
# --------------------------------------------------------------------------- #
ck_runtime_root() {
  if ck_first_env COORDKIT_PLUGIN_ROOT CLAUDE_PLUGIN_ROOT CODEX_PLUGIN_ROOT GEMINI_PLUGIN_ROOT; then return 0; fi
  ( cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd )
}

ck_plugin_root() {
  ck_runtime_root
}

# Persistent, cross-repo plugin data dir (site.json, clock.state, trust.json).
ck_data_dir() {
  if ck_first_env COORDKIT_DATA COORDKIT_PLUGIN_DATA CLAUDE_PLUGIN_DATA CODEX_PLUGIN_DATA GEMINI_PLUGIN_DATA; then return 0; fi
  printf '%s' "$HOME/.claude/coordkit-data"
}

# Repo-scoped helpers that accept both the neutral COORDKIT_* adapter names and
# the legacy CLAUDE_* names used by the current plugin runtime.
ck_project_dir() {
  if ck_first_env COORDKIT_PROJECT_DIR CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR GEMINI_PROJECT_DIR; then return 0; fi
  printf '%s' "${PWD:-.}"
}

ck_session_id() {
  if ck_first_env COORDKIT_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID GEMINI_SESSION_ID; then return 0; fi
  printf 'cli'
}

ck_coord_dir() {
  local root="${1:-$(resolve_root "$PWD")}"
  if ck_first_env COORDKIT_COORD_DIR CLAUDE_COORD_DIR CODEX_COORD_DIR GEMINI_COORD_DIR; then return 0; fi
  printf '%s/.claude/coord' "$root"
}

ck_coord_toml() {
  local root="${1:-$(resolve_root "$PWD")}"
  if ck_first_env COORDKIT_COORD_TOML CLAUDE_COORD_TOML CODEX_COORD_TOML GEMINI_COORD_TOML; then return 0; fi
  printf '%s/coord.toml' "$(ck_coord_dir "$root")"
}

# --------------------------------------------------------------------------- #
# resolve_root <cwd> — THE repo-root rule. Precedence:
#   COORDKIT_BUS_ROOT / CLAUDE_BUS_ROOT / CODEX_BUS_ROOT / GEMINI_BUS_ROOT >
#   git toplevel > nearest ancestor with .coordkit-bus/ >
#   COORDKIT_PROJECT_DIR / CLAUDE_PROJECT_DIR / CODEX_PROJECT_DIR /
#   GEMINI_PROJECT_DIR > cwd
#
# The git-toplevel-before-project-dir order matters in a workspace of nested git
# repos under a non-git parent project dir: preferring the workspace dir there
# would resolve some components to the PARENT while others resolved to the nested
# repo. The ancestor-.coordkit-bus probe is what lets a non-git subdir join a
# parent bus, so it must stay ahead of the project-dir fallback.
#
# "git toplevel" here means the MAIN checkout's root, not the linked worktree's
# own root — see ck_main_worktree.
# --------------------------------------------------------------------------- #

# Canonicalize a linked git worktree to the MAIN checkout's root.
#
# WHY: `rev-parse --show-toplevel` inside a linked worktree returns that
# worktree's own root, so every worktree would mint its own empty
# .coordkit-bus/ and be invisible to the sessions in the main checkout — a real
# bug where a worktree session's `bus.sh msg` reported "delivered to 0
# instances". Since CONCURRENCY.md tells sessions to work in worktrees, all
# worktrees of a repo MUST agree on one bus root.
#
# `git worktree list --porcelain` always lists the main worktree first, and it
# stays correct under separate-git-dir setups where deriving the root from
# --git-common-dir would not. Prints nothing if the main worktree can't be
# determined (old git, bare main repo) so the caller keeps the old behaviour.
ck_main_worktree() {
  local cwd="$1" line path
  line="$(git -C "$cwd" worktree list --porcelain 2>/dev/null | head -n 2)" || return 1
  case "$line" in worktree\ /*) ;; *) return 1 ;; esac
  # A bare main repo has no checkout to host the bus — let the caller fall back.
  case "$line" in *$'\n'bare*) return 1 ;; esac
  path="${line%%$'\n'*}"; path="${path#worktree }"
  [ -d "$path" ] || return 1
  printf '%s' "$path"
}

resolve_root() {
  local cwd="$1" top main dir
  # explicit pin wins over everything — lets sibling non-git subdirs share one bus
  if ck_first_env COORDKIT_BUS_ROOT CLAUDE_BUS_ROOT CODEX_BUS_ROOT GEMINI_BUS_ROOT; then return; fi
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$top" ]; then
    main="$(ck_main_worktree "$cwd")"
    printf '%s' "${main:-$top}"
    return
  fi
  dir="$cwd"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    [ -d "$dir/.coordkit-bus" ] && { printf '%s' "$dir"; return; }
    dir="$(dirname "$dir")"
  done
  if ck_first_env COORDKIT_PROJECT_DIR CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR GEMINI_PROJECT_DIR; then return; fi
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

# Deterministic subject slug from free text — the SAME transform ledger.sh
# uses for its task/decision/question subjects, so a caller (e.g. bus.sh's
# `claim`, which delegates to the ledger's task queue) can compute the identical
# subject a "task <desc>" call will mint, without parsing the ledger's own stdout.
slug() { printf '%s' "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9._-' | cut -c1-48; }

# --------------------------------------------------------------------------- #
# ENFORCEMENT MODE — "warn" (default) or "guard".
#
# This is the ONE gate that decides whether coordkit is allowed to hard-block a
# tool call. "warn" is coordkit's historical, shipped contract: the hooks observe
# and advise, they never deny. "guard" additionally arms scripts/guard.sh's
# anti-clobber deny (the former coordguard plugin). Nothing else in the codebase
# may reach a `permissionDecision:"deny"` without going through here.
#
# This is a DIFFERENT axis from the TRANSPORT mode ("local"|"git"|"relay") that
# transports/lib.sh's logstore_mode() resolves from COORDKIT_MODE and coord.toml's
# TOP-LEVEL `mode` key. The two are kept strictly apart by name:
#
#   transport   COORDKIT_MODE          coord.toml top-level  mode = "git"
#   enforcement COORDKIT_ENFORCEMENT   coord.toml            [enforcement]
#                                                            mode = "guard"
#
# Enforcement lives in its own `[enforcement]` TABLE. That placement is load
# bearing twice over: TOML forbids a bare `mode` key and a `[mode]` table sharing
# a name (a strict parser would reject the whole file), and the flat top-level
# reader in transports/lib.sh stops at the first `[`, so it never sees the
# enforcement key and git-mode config keeps parsing exactly as before.
#
# Precedence: env COORDKIT_ENFORCEMENT > repo coord.toml [enforcement].mode >
# per-user $(ck_data_dir)/config `enforcement=` > "warn". Values other than
# guard/warn fall through to the next level rather than erroring.
#
# Reads only: no mkdir, no writes. /guard on|off (scripts/guard.sh) is the
# writer.
# --------------------------------------------------------------------------- #

# Read `key = value` from inside a [table] of a TOML file. Quote handling mirrors
# transports/lib.sh's flat __logstore_toml_get: a quoted value keeps a '#' inside
# it, an unquoted one treats whitespace-then-'#' as an inline comment.
ck_toml_table_get() {  # <file> <table> <key>
  local file="$1" table="$2" key="$3" raw
  [ -f "$file" ] || return 1
  raw="$(awk -v tbl="$table" -v key="$key" '
    { t = $0; sub(/^[ \t]+/, "", t)
      if (t ~ /^\[/) {
        h = t; sub(/^\[[ \t]*/, "", h); sub(/[ \t]*\].*$/, "", h)
        intbl = (h == tbl); next
      }
      if (!intbl) next
      if (t !~ "^" key "[ \t]*=") next
      sub("^" key "[ \t]*=[ \t]*", "", t); print t; exit
    }' "$file" 2>/dev/null)"
  [ -n "$raw" ] || return 1
  case "$raw" in
    '"'*)  raw="${raw#\"}"; raw="${raw%%\"*}" ;;
    "'"*)  raw="${raw#\'}"; raw="${raw%%\'*}" ;;
    *)     raw="$(printf '%s' "$raw" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]*$//')" ;;
  esac
  printf '%s' "$raw"
}

# Resolve to "<mode>|<origin>" so a single pass answers both "which mode?" and
# "which precedence level supplied it?" (what /guard status reports).
_ck_enforcement_resolve() {
  local v toml f
  v="$(ck_first_env COORDKIT_ENFORCEMENT CLAUDE_ENFORCEMENT CODEX_ENFORCEMENT GEMINI_ENFORCEMENT | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    guard|warn) printf '%s|env COORDKIT_ENFORCEMENT' "$v"; return ;;
  esac

  toml="$(ck_coord_toml "$PWD")"
  v="$(ck_toml_table_get "$toml" enforcement mode 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    guard|warn) printf '%s|repo %s' "$v" "$toml"; return ;;
  esac

  f="$(ck_data_dir)/config"
  if [ -f "$f" ]; then
    v="$(sed -n -E 's/^[[:space:]]*enforcement[[:space:]]*=[[:space:]]*//p' "$f" 2>/dev/null \
         | tail -n1 | sed -E 's/[[:space:]]*#.*$//; s/[[:space:]]*$//' | tr -d "\"'" \
         | tr '[:upper:]' '[:lower:]')"
    case "$v" in
      guard|warn) printf '%s|user %s' "$v" "$f"; return ;;
    esac
  fi

  printf 'warn|default'
}

# THE gate. Prints "guard" or "warn"; anything unresolvable is "warn".
ck_enforcement_mode()   { local r; r="$(_ck_enforcement_resolve)"; printf '%s' "${r%%|*}"; }
# Which precedence level supplied the mode above (for /guard status).
ck_enforcement_origin() { local r; r="$(_ck_enforcement_resolve)"; printf '%s' "${r#*|}"; }

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
