# shellcheck shell=bash
# spend-gate: a budget trip that stops paid calls.
# Copyright DCYFR Labs. Licensed under the Apache License, Version 2.0.
#
# Source this file from bash (3.2+) or zsh. A trip is a Redis key plus a file
# marker. The key is what callers read on the hot path. The marker is what
# keeps the trip standing when Redis is down or comes back empty.
#
# Configuration (environment, read when a function runs):
#   SPEND_GATE_PREFIX        key prefix                   spend-gate:paused
#   SPEND_GATE_STATE_DIR     marker and log directory     ~/.local/state/spend-gate
#   SPEND_GATE_CLASS         class key name               autonomous
#   SPEND_GATE_EXEMPT_CLASS  class the class key skips    operator
#   SPEND_GATE_CALLER_CLASS  this caller's class          (SPEND_GATE_CLASS)
#   SPEND_GATE_REDIS_URL     passed to redis-cli -u       (redis-cli default)
#   SPEND_GATE_LOG           audit log                    $SPEND_GATE_STATE_DIR/spend-gate.log
#   SPEND_GATE_PRE_SET_HOOK  command run before a set     (none)
#   SPEND_GATE_WARN_PCT / _RESERVE_PCT / _PAUSE_PCT / _CAP_PCT   80 / 90 / 95 / 100
#   SPEND_GATE_RESERVE_TTL / _PAUSE_TTL / _CAP_TTL   90000 / 43200 / 86400 (seconds)
#
# Scopes: "" is global (every caller). $SPEND_GATE_CLASS is the class key
# (every caller except the exempt class). Any other name is a per-service key,
# which has no marker and does not survive a Redis restart.
#
# Marker format, a public contract for readers in other languages:
#   line 1  <reason>@<ISO-8601 UTC>   (the key's value)
#   line 2  expires=<epoch seconds>   (0 = no expiry)

_sg_prefix() { printf '%s' "${SPEND_GATE_PREFIX:-spend-gate:paused}"; }
_sg_class() { printf '%s' "${SPEND_GATE_CLASS:-autonomous}"; }
_sg_state() { printf '%s' "${SPEND_GATE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/spend-gate}"; }
_sg_logfile() { printf '%s' "${SPEND_GATE_LOG:-$(_sg_state)/spend-gate.log}"; }

_sg_log() {
  local f
  f=$(_sg_logfile)
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$f" 2>/dev/null || true
}

# Redis access. Define spend_gate_redis before sourcing to supply your own
# (a timeout wrapper, a socket, another client with the same arguments).
if ! typeset -f spend_gate_redis >/dev/null 2>&1; then
  spend_gate_redis() {
    if [[ -n "${SPEND_GATE_REDIS_URL:-}" ]]; then
      redis-cli -u "$SPEND_GATE_REDIS_URL" "$@"
    else
      redis-cli "$@"
    fi
  }
fi

_sg_key() {
  if [[ -n "${1:-}" ]]; then printf '%s:%s\n' "$(_sg_prefix)" "$1"; else printf '%s\n' "$(_sg_prefix)"; fi
}

# Marker path for a scope. Empty for per-service scopes.
_sg_marker() {
  local class
  class=$(_sg_class)
  if [[ -z "${1:-}" ]]; then
    printf '%s\n' "${SPEND_GATE_MARKER:-$(_sg_state)/paused}"
  elif [[ "$1" == "$class" ]]; then
    printf '%s\n' "${SPEND_GATE_CLASS_MARKER:-$(_sg_state)/paused-$class}"
  else
    printf '\n'
  fi
}

# Scopes a check reads, in order, one per line: the service key, then the
# class key unless the caller is the exempt class, then global (printed "-").
_sg_scopes() {
  local service="${1:-}" class caller
  class=$(_sg_class)
  caller="${2:-${SPEND_GATE_CALLER_CLASS:-$class}}"
  [[ -n "$service" ]] && printf '%s\n' "$service"
  if [[ "$caller" != "${SPEND_GATE_EXEMPT_CLASS:-operator}" && "$service" != "$class" ]]; then
    printf '%s\n' "$class"
  fi
  printf '%s\n' "-"
}

# Prints the marker's expiry when the marker is live. Exit 1 when it is spent:
# expiry in the past, or no valid expires= line.
_sg_marker_live() {
  local expires
  expires=$(sed -n '2s/^expires=//p' "$1" 2>/dev/null)
  case "$expires" in '' | *[!0-9]*) return 1 ;; esac
  if ((expires > 0 && expires <= $(date '+%s'))); then return 1; fi
  printf '%s\n' "$expires"
}

# Redis answered, the key is absent, the marker exists. A live marker sets
# the key again with the time it has left (exit 0, paused). A spent marker is
# removed (exit 1). NX: never overwrite a key set in the meantime.
_sg_rearm() {
  local key="$1" marker="$2" value expires
  value=$(head -1 "$marker" 2>/dev/null)
  if [[ -z "$value" ]] || ! expires=$(_sg_marker_live "$marker"); then
    rm -f "$marker" 2>/dev/null
    return 1
  fi
  if ((expires > 0)); then
    spend_gate_redis SET "$key" "$value" EX "$((expires - $(date '+%s')))" NX >/dev/null 2>&1
  else
    spend_gate_redis SET "$key" "$value" NX >/dev/null 2>&1
  fi
  _sg_log "KILL_SWITCH_REARM: key=$key value=\"$value\" expires=$expires marker=$marker"
  return 0
}

# spend_gate_set <reason> [ttl-seconds=86400] [scope]
# Exit 0 set, 2 bad arguments, 3 refused by the pre-set hook.
spend_gate_set() {
  local reason="${1:-unspecified}" ttl="${2:-86400}" scope="${3:-}"
  local key marker value expires=0
  case "$ttl" in '' | *[!0-9]*)
    echo "spend-gate: ttl must be a whole number of seconds" >&2
    return 2
    ;;
  esac
  if [[ -n "${SPEND_GATE_PRE_SET_HOOK:-}" ]]; then
    if ! "$SPEND_GATE_PRE_SET_HOOK" "$reason" "$ttl" "$scope"; then
      _sg_log "KILL_SWITCH_VETO: scope=${scope:-global} reason=\"$reason\" hook=$SPEND_GATE_PRE_SET_HOOK"
      echo "spend-gate: set refused by the pre-set hook (reason=$reason)" >&2
      return 3
    fi
  fi
  key=$(_sg_key "$scope")
  marker=$(_sg_marker "$scope")
  value="${reason}@$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  # Log first: a pause must never exist without its log line.
  _sg_log "KILL_SWITCH_SET: scope=${scope:-global} key=$key value=\"$value\" ttl=${ttl}s caller_pid=$$ caller_ppid=$PPID"
  if ((ttl > 0)); then
    spend_gate_redis SET "$key" "$value" EX "$ttl" >/dev/null 2>&1
    expires=$(($(date '+%s') + ttl))
  else
    spend_gate_redis SET "$key" "$value" >/dev/null 2>&1
  fi
  if [[ -n "$marker" ]]; then
    mkdir -p "$(dirname "$marker")" 2>/dev/null
    printf '%s\nexpires=%s\n' "$value" "$expires" >"$marker"
  fi
  echo "spend-gate: paused ${scope:-global}: $value (ttl=${ttl}s)" >&2
}

# spend_gate_key [service] [caller-class]
# Prints what refuses this caller: the first engaged key, or file:<marker>
# when a live marker stands without its key. Exit 1 and no output when open.
# A key lost from a reachable Redis is re-armed from its live marker; a spent
# marker is removed. With Redis unreachable, any marker refuses.
spend_gate_key() {
  local scope key marker exists hit=""
  # shellcheck disable=SC2046
  for scope in $(_sg_scopes "$@"); do
    [[ "$scope" == "-" ]] && scope=""
    key=$(_sg_key "$scope")
    marker=$(_sg_marker "$scope")
    exists=$(spend_gate_redis EXISTS "$key" 2>/dev/null)
    if [[ "$exists" == "1" ]]; then
      [[ -z "$hit" ]] && hit="$key"
      continue
    fi
    [[ -n "$marker" && -f "$marker" ]] || continue
    if [[ "$exists" == "0" ]]; then
      # The loop runs on, so one check after a restart re-arms every scope.
      _sg_rearm "$key" "$marker" || continue
      if [[ "$(spend_gate_redis EXISTS "$key" 2>/dev/null)" == "1" ]]; then
        [[ -z "$hit" ]] && hit="$key"
        continue
      fi
    fi
    [[ -z "$hit" ]] && hit="file:$marker"
  done
  [[ -n "$hit" ]] && printf '%s\n' "$hit"
}

# spend_gate_check [service] [caller-class]: exit 0 paused, 1 open.
spend_gate_check() { spend_gate_key "$@" >/dev/null; }

# spend_gate_reason [service] [caller-class]: the reason of what refuses.
spend_gate_reason() {
  local hit
  hit=$(spend_gate_key "$@") || return 1
  case "$hit" in
    file:*) head -1 "${hit#file:}" 2>/dev/null ;;
    *) spend_gate_redis GET "$hit" 2>/dev/null ;;
  esac
}

# spend_gate_clear [scope]: marker first, then the key, so a check between
# the two steps cannot find a live marker and re-arm.
spend_gate_clear() {
  local scope="${1:-}" marker
  marker=$(_sg_marker "$scope")
  [[ -n "$marker" ]] && rm -f "$marker" 2>/dev/null
  spend_gate_redis DEL "$(_sg_key "$scope")" >/dev/null 2>&1
  _sg_log "KILL_SWITCH_CLEAR: scope=${scope:-global}"
  echo "spend-gate: resumed ${scope:-global}" >&2
}

# spend_gate_decide <percent-of-budget>
# Prints the band (none, warn, reserve, pause, cap), then one line per scope
# to set: "set <scope|-> <ttl>". It decides and changes nothing; the caller
# computes the percentage and applies the lines (the CLI's `trip` does both).
spend_gate_decide() {
  local pct="${1:-}" class
  pct="${pct%%.*}"
  case "$pct" in '' | *[!0-9]*)
    echo "spend-gate: percent must be a number" >&2
    return 2
    ;;
  esac
  class=$(_sg_class)
  if ((pct >= ${SPEND_GATE_CAP_PCT:-100})); then
    printf 'cap\nset %s %s\nset - %s\n' "$class" "${SPEND_GATE_RESERVE_TTL:-90000}" "${SPEND_GATE_CAP_TTL:-86400}"
  elif ((pct >= ${SPEND_GATE_PAUSE_PCT:-95})); then
    printf 'pause\nset %s %s\nset - %s\n' "$class" "${SPEND_GATE_RESERVE_TTL:-90000}" "${SPEND_GATE_PAUSE_TTL:-43200}"
  elif ((pct >= ${SPEND_GATE_RESERVE_PCT:-90})); then
    printf 'reserve\nset %s %s\n' "$class" "${SPEND_GATE_RESERVE_TTL:-90000}"
  elif ((pct >= ${SPEND_GATE_WARN_PCT:-80})); then
    printf 'warn\n'
  else
    printf 'none\n'
  fi
}

# spend_gate_trip <percent-of-budget>: decide, then set each scope the band
# names that is not already set. Prints the band.
spend_gate_trip() {
  local out band line scope ttl rc=0
  out=$(spend_gate_decide "$1") || return 2
  band=$(printf '%s\n' "$out" | head -1)
  while IFS= read -r line; do
    case "$line" in set\ *) ;; *) continue ;; esac
    scope="${line#set }"
    ttl="${scope#* }"
    scope="${scope%% *}"
    [[ "$scope" == "-" ]] && scope=""
    if [[ "$(spend_gate_redis EXISTS "$(_sg_key "$scope")" 2>/dev/null)" == "1" ]]; then continue; fi
    spend_gate_set "budget-${band}-${1}%" "$ttl" "$scope" || rc=$?
  done <<EOF
$out
EOF
  printf '%s\n' "$band"
  return "$rc"
}
