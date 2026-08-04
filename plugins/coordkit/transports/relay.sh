# shellcheck shell=bash
# transports/relay.sh — authenticated, replayable cross-machine coordination.
#
# The relay accelerates delivery but never becomes the only copy of an event:
# append folds into local|git first, stages a durable outbox entry, then flushes
# to the server. Reads flush pending events and replay remote events after the
# last durably-folded server cursor. Network failure degrades to the backing.

__relay_backing() {
  local b="${COORDKIT_RELAY_BACKING:-local}"
  case "$b" in git|local) printf '%s' "$b" ;; *) printf 'local' ;; esac
}

__relay_lockfile() {
  case "$(__relay_backing)" in
    git) __git_lockfile ;;
    *)   __local_lockfile ;;
  esac
}

__relay_url() {
  if [ -n "${COORDKIT_RELAY_URL:-}" ]; then printf '%s' "$COORDKIT_RELAY_URL"; return 0; fi
  __logstore_toml_get "$(__logstore_coordtoml)" relay_url 2>/dev/null
}

__relay_url_allowed() { # <url>; HTTPS, or explicitly opted-in loopback HTTP
  local url="$1"
  case "$url" in
    https://*) return 0 ;;
    http://localhost|http://localhost:*|http://localhost/*|http://127.0.0.1|http://127.0.0.1:*|http://127.0.0.1/*|http://\[::1\]|http://\[::1\]:*|http://\[::1\]/*)
      [ "${COORDKIT_RELAY_ALLOW_INSECURE_HTTP:-0}" = "1" ]
      return
      ;;
    *) return 1 ;;
  esac
}

__relay_room() {
  local room
  if [ -n "${COORDKIT_ROOM_ID:-}" ]; then room="$COORDKIT_ROOM_ID"
  else room="$(__logstore_toml_get "$(__logstore_coordtoml)" room_id 2>/dev/null)"; fi
  [ -n "$room" ] || room="default"
  case "$room" in *$'\r'*|*$'\n'*) return 1 ;; esac
  [ "${#room}" -le 200 ] || return 1
  printf '%s' "$room"
}

__relay_state_root() {
  printf '%s' "${COORDKIT_BUS_DIR:-$(__logstore_repo_root)/.coordkit-bus}/relay"
}

__relay_hash() {
  local value="$1" out
  out="$(printf '%s' "$value" | sha256sum 2>/dev/null | cut -d' ' -f1)"
  [ -n "$out" ] || out="$(printf '%s' "$value" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  [ -n "$out" ] || out="$(printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-120)"
  printf '%s' "$out"
}

__relay_channel_dir() {
  local url room key
  url="$(__relay_url)"; room="$(__relay_room)" || return 1
  key="$(__relay_hash "${url}|${room}")"
  printf '%s/%s' "$(__relay_state_root)" "$key"
}

__relay_token_header() { # creates a 0600 curl header file, prints its path
  local dir file
  [ -n "${COORDKIT_RELAY_TOKEN:-}" ] || return 0
  case "$COORDKIT_RELAY_TOKEN" in *$'\r'*|*$'\n'*) return 1 ;; esac
  dir="$(__relay_state_root)"; mkdir -p "$dir" 2>/dev/null || return 1
  file="$(mktemp "${dir}/.auth.XXXXXX" 2>/dev/null)" || return 1
  chmod 600 "$file" 2>/dev/null || true
  printf 'Authorization: Bearer %s\n' "$COORDKIT_RELAY_TOKEN" > "$file" || { rm -f "$file"; return 1; }
  printf '%s' "$file"
}

__relay_curl_common() { # informational; callers build arrays to preserve args
  return 0
}

__relay_stage() { # <event-line>
  local line="$1" dir eid key tmp out
  dir="$(__relay_channel_dir)/outbox" || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  eid="$(printf '%s' "$line" | jq -r '.eid // empty' 2>/dev/null)"
  [ -n "$eid" ] || eid="$line"
  key="$(__relay_hash "$eid")"; out="${dir}/${key}.ndjson"
  [ -f "$out" ] && return 0
  tmp="${out}.tmp.$$"
  printf '%s\n' "$line" > "$tmp" 2>/dev/null && mv -f "$tmp" "$out" 2>/dev/null
}

__relay_post_file() { # <outbox-file>
  local file="$1" url room auth="" response="" rc=1
  url="$(__relay_url)"; room="$(__relay_room)" || return 1
  __relay_url_allowed "$url" || return 1
  command -v curl >/dev/null 2>&1 || return 1
  auth="$(__relay_token_header)" || return 1
  response="$(mktemp "$(__relay_state_root)/.ack.XXXXXX" 2>/dev/null)" || {
    [ -n "$auth" ] && rm -f "$auth" 2>/dev/null
    return 1
  }
  local -a args=( -fsS --connect-timeout 1 --max-time "${COORDKIT_RELAY_TIMEOUT:-3}"
    -o "$response" -X POST -H 'Content-Type: application/x-ndjson' -H "X-Coord-Room: $room" )
  [ -n "$auth" ] && args+=( -H "@$auth" )
  [ -n "${COORDKIT_RELAY_CA_FILE:-}" ] && args+=( --cacert "$COORDKIT_RELAY_CA_FILE" )
  args+=( --data-binary "@$file" --url "$url" )
  if curl "${args[@]}" >/dev/null 2>&1 \
    && jq -e '
      (.accepted | type == "number") and (.accepted >= 0)
      and (.duplicates | type == "number") and (.duplicates >= 0)
      and ((.accepted + .duplicates) >= 1)
      and (.cursor | type == "number") and (.cursor >= 1)
    ' "$response" >/dev/null 2>&1; then
    rc=0
  fi
  rm -f "$response" 2>/dev/null
  [ -n "$auth" ] && rm -f "$auth" 2>/dev/null
  return "$rc"
}

__relay_flush_unlocked() {
  local dir file sent=0 max="${COORDKIT_RELAY_FLUSH_MAX:-20}"
  case "$max" in ''|*[!0-9]*) max=20 ;; esac
  dir="$(__relay_channel_dir)/outbox" || return 0
  [ -d "$dir" ] || return 0
  for file in "$dir"/*.ndjson; do
    [ -e "$file" ] || continue
    __relay_post_file "$file" || return 0
    rm -f "$file" 2>/dev/null || return 0
    sent=$(( sent + 1 )); [ "$sent" -ge "$max" ] && break
  done
  return 0
}

__relay_flush_outbox() {
  local dir lock rc
  dir="$(__relay_channel_dir)" || return 0; mkdir -p "$dir" 2>/dev/null || return 0
  lock="${dir}/.outbox.lock"
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 2 9 || exit 0; __relay_flush_unlocked ) 9>"$lock"
  else
    __logstore_mkdir_lock "${lock}.d" || return 0
    __relay_flush_unlocked; rc=$?
    rmdir "${lock}.d" 2>/dev/null || true
    return "$rc"
  fi
}

__relay_append() {
  local line="$1" backing
  backing="$(__relay_backing)"
  __logstore_locked_append "$backing" "$line" || return 1
  if __relay_stage "$line"; then
    __relay_flush_outbox
  else
    # A read-only filesystem should not silently disable live delivery. Try one
    # direct POST; durability is already satisfied by the backing.
    local tmp dir
    dir="$(__relay_state_root)"; mkdir -p "$dir" 2>/dev/null || return 0
    tmp="$(mktemp "${dir}/.direct.XXXXXX" 2>/dev/null)" || return 0
    printf '%s\n' "$line" > "$tmp" 2>/dev/null
    __relay_post_file "$tmp" || true
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

__relay_fold_body() { # <ndjson-file>; fail if any valid event cannot persist
  local body="$1" line
  [ -s "$body" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    printf '%s' "$line" | jq -e 'type == "object" and ((.eid // "") | length > 0)' >/dev/null 2>&1 || return 1
    __logstore_locked_append "$(__relay_backing)" "$line" || return 1
  done < "$body"
}

__relay_pull_unlocked() {
  local url room dir cursor_file cursor auth="" page=0 pages limit query sep
  local headers body next latest more rc
  url="$(__relay_url)"; room="$(__relay_room)" || return 0
  __relay_url_allowed "$url" || return 0
  command -v curl >/dev/null 2>&1 || return 0
  dir="$(__relay_channel_dir)" || return 0; mkdir -p "$dir" 2>/dev/null || return 0
  cursor_file="${dir}/cursor"; cursor="$(cat "$cursor_file" 2>/dev/null)"
  case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
  pages="${COORDKIT_RELAY_PULL_PAGES:-5}"; limit="${COORDKIT_RELAY_PULL_LIMIT:-200}"
  case "$pages" in ''|*[!0-9]*) pages=5 ;; esac
  case "$limit" in ''|*[!0-9]*) limit=200 ;; esac
  [ "$limit" -gt 1000 ] && limit=1000
  auth="$(__relay_token_header)" || return 0
  sep='?'; case "$url" in *\?*) sep='&' ;; esac

  while [ "$page" -lt "$pages" ]; do
    headers="$(mktemp "${dir}/.headers.XXXXXX" 2>/dev/null)" || break
    body="$(mktemp "${dir}/.body.XXXXXX" 2>/dev/null)" || { rm -f "$headers"; break; }
    query="${url}${sep}since=${cursor}&limit=${limit}"
    local -a args=( -fsS --connect-timeout 1 --max-time "${COORDKIT_RELAY_TIMEOUT:-3}"
      -D "$headers" -o "$body" -H 'Accept: application/x-ndjson' -H "X-Coord-Room: $room" )
    [ -n "$auth" ] && args+=( -H "@$auth" )
    [ -n "${COORDKIT_RELAY_CA_FILE:-}" ] && args+=( --cacert "$COORDKIT_RELAY_CA_FILE" )
    args+=( --url "$query" )
    curl "${args[@]}" >/dev/null 2>&1; rc=$?
    if [ "$rc" -ne 0 ]; then rm -f "$headers" "$body"; break; fi
    next="$(awk 'tolower($0) ~ /^x-coord-cursor:/ {gsub("\\r", ""); sub(/^[^:]+:[[:space:]]*/, ""); v=$0} END{print v}' "$headers")"
    latest="$(awk 'tolower($0) ~ /^x-coord-latest:/ {gsub("\\r", ""); sub(/^[^:]+:[[:space:]]*/, ""); v=$0} END{print v}' "$headers")"
    more="$(awk 'tolower($0) ~ /^x-coord-more:/ {gsub("\\r", ""); sub(/^[^:]+:[[:space:]]*/, ""); v=$0} END{print v}' "$headers")"
    case "$next" in ''|*[!0-9]*) rm -f "$headers" "$body"; break ;; esac
    case "$latest" in ''|*[!0-9]*) rm -f "$headers" "$body"; break ;; esac
    # A restored/replaced server can legitimately have a lower cursor than the
    # client remembers. Rewind and replay; eid dedup makes that safer than
    # remaining stuck forever beyond the server's new sequence.
    if [ "$latest" -lt "$cursor" ]; then
      printf '0\n' > "${cursor_file}.tmp.$$" 2>/dev/null \
        && mv -f "${cursor_file}.tmp.$$" "$cursor_file" 2>/dev/null
      cursor=0; page=$(( page + 1 ))
      rm -f "$headers" "$body"
      continue
    fi
    if ! __relay_fold_body "$body"; then rm -f "$headers" "$body"; break; fi
    printf '%s\n' "$next" > "${cursor_file}.tmp.$$" 2>/dev/null \
      && mv -f "${cursor_file}.tmp.$$" "$cursor_file" 2>/dev/null
    cursor="$next"; page=$(( page + 1 ))
    rm -f "$headers" "$body"
    [ "$more" = "1" ] || break
  done
  [ -n "$auth" ] && rm -f "$auth" 2>/dev/null
  return 0
}

__relay_pull() {
  local dir lock rc
  dir="$(__relay_channel_dir)" || return 0; mkdir -p "$dir" 2>/dev/null || return 0
  lock="${dir}/.pull.lock"
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 2 9 || exit 0; __relay_pull_unlocked ) 9>"$lock"
  else
    __logstore_mkdir_lock "${lock}.d" || return 0
    __relay_pull_unlocked; rc=$?
    rmdir "${lock}.d" 2>/dev/null || true
    return "$rc"
  fi
}

__relay_sync() {
  __relay_flush_outbox
  __relay_pull
}

__relay_status() {
  local url room dir cursor pending=0
  url="$(__relay_url)"; room="$(__relay_room 2>/dev/null)"; dir="$(__relay_channel_dir 2>/dev/null)"
  [ -n "$dir" ] && cursor="$(cat "${dir}/cursor" 2>/dev/null)" || cursor=0
  case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
  if [ -n "$dir" ] && [ -d "${dir}/outbox" ]; then
    pending="$(find "${dir}/outbox" -maxdepth 1 -type f -name '*.ndjson' 2>/dev/null | wc -l | tr -d ' ')"
  fi
  printf 'mode: relay\nurl: %s\nroom: %s\nbacking: %s\ncursor: %s\npending_outbox: %s\nauth: %s\n' \
    "${url:-not configured}" "${room:-invalid}" "$(__relay_backing)" "$cursor" "${pending:-0}" \
    "$([ -n "${COORDKIT_RELAY_TOKEN:-}" ] && printf configured || printf missing)"
}

__relay_readall() {
  __relay_sync
  case "$(__relay_backing)" in git) __git_readall ;; *) __local_readall ;; esac
}

__relay_tail() {
  local n="${1:-0}"
  case "$n" in (*[!0-9]*|'') n=0 ;; esac
  __relay_sync
  case "$(__relay_backing)" in git) __git_tail "$n" ;; *) __local_tail "$n" ;; esac
}
