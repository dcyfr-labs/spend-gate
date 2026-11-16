#!/usr/bin/env bash
# shellcheck disable=SC2015
# The proof: a budget trip stops paid calls, and keeps stopping them when
# Redis goes away or comes back empty.
#
#   bash proof/run.sh
#
# Everything is scratch: a private redis-server on a loopback port, a private
# state directory, a fixture ledger, and a stub in place of the paid model.
# The stub counts the calls that reach it. "Stopped" means the stub's count
# did not move, not that a key was set.
#
# Legs, in order:
#   control        spend under budget: no key, the call reaches the stub
#   trip           spend at 96% of budget: both keys set, the call is refused
#   redis-down     tripped, Redis unreachable: refused by the file marker
#   redis-restart  tripped, Redis back with an empty keyspace: refused, and
#                  the keys are set again from the markers
#   restore        cleared by hand: the call reaches the stub again
#   never-tripped  LIMIT: no marker and Redis unreachable: the call goes through
#
# Mutations (PROOF_MUTATE), each of which must make the proof fail:
#   gate     the caller skips the check
#   budget   the budget is raised a thousandfold, so the same ledger is far under it
#   restart  the marker no longer sets a lost key again
#
# Exit 0 when every leg holds, 1 when one does not, 2 when the scratch
# Redis could not start.
set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/spend-gate-proof.XXXXXX")
port=$((20000 + RANDOM % 20000))
server_pid=""
mutate="${PROOF_MUTATE:-}"
budget=100
[[ "$mutate" == "budget" ]] && budget=100000
failed=0

export SPEND_GATE_REDIS_URL="redis://127.0.0.1:$port"
export SPEND_GATE_PREFIX="proof:paused"
export SPEND_GATE_STATE_DIR="$work/state"
unset SPEND_GATE_CLASS SPEND_GATE_EXEMPT_CLASS SPEND_GATE_CALLER_CLASS SPEND_GATE_PRE_SET_HOOK \
  SPEND_GATE_LOG SPEND_GATE_MARKER SPEND_GATE_CLASS_MARKER
mkdir -p "$SPEND_GATE_STATE_DIR"

# shellcheck source=SCRIPTDIR/../spend-gate.sh
. "$root/spend-gate.sh"

case "$mutate" in
  '' | budget) ;;
  gate) spend_gate_key() { return 1; } ;;
  # What the check did before markers carried an expiry: key absent, drop the marker.
  restart) _sg_rearm() {
    rm -f "$2"
    return 1
  } ;;
  *)
    echo "unknown PROOF_MUTATE: $mutate (gate, budget, restart)" >&2
    exit 2
    ;;
esac

rc() { redis-cli -p "$port" "$@" 2>/dev/null; }

server_start() {
  redis-server --port "$port" --bind 127.0.0.1 --save '' --appendonly no \
    --dir "$work" >"$work/redis.log" 2>&1 &
  server_pid=$!
  local i=0
  while [[ "$(rc PING)" != "PONG" ]]; do
    i=$((i + 1))
    if ((i > 100)); then
      echo "redis-server did not start on port $port" >&2
      cat "$work/redis.log" >&2
      exit 2
    fi
    sleep 0.1
  done
}

server_stop() {
  [[ -n "$server_pid" ]] || return 0
  kill "$server_pid" 2>/dev/null
  wait "$server_pid" 2>/dev/null
  server_pid=""
}

cleanup() {
  server_stop
  rm -rf "$work"
}
trap cleanup EXIT

# The paid model. It only counts.
calls="$work/model-calls"
: >"$calls"
stub_model() { echo call >>"$calls"; }
stub_count() { wc -l <"$calls" | tr -d ' '; }

# One paid call the way a caller makes it: check the gate, then call.
# Prints "reached" or "refused by <what>".
paid_call() {
  local hit
  if hit=$(spend_gate_key 2>/dev/null); then
    echo "refused by $hit"
  else
    stub_model
    echo "reached"
  fi
}

# Month-to-date spend as a whole percent of the budget.
ledger_pct() { awk -v b="$budget" '{ s += $1 } END { printf "%d\n", s * 100 / b }' "$1"; }

keys() { rc KEYS 'proof:paused*' | sort | tr '\n' ' ' | sed 's/ $//'; }

leg() {
  leg_id="$1"
  leg_ok=1
  printf '\n[%s] %s\n' "$1" "$2"
}
note() { printf '    %s\n' "$1"; }
# want <what> <expected> <actual>
want() {
  if [[ "$2" == "$3" ]]; then
    note "ok    $1: $3"
  else
    note "FAIL  $1: expected \"$2\", got \"$3\""
    leg_ok=0
  fi
}
# want_refused <verdict>: refused, by a key or a marker.
want_refused() {
  case "$1" in
    "refused by "*) note "ok    paid call: $1" ;;
    *)
      note "FAIL  paid call: expected a refusal, got \"$1\""
      leg_ok=0
      ;;
  esac
}
end_leg() {
  if ((leg_ok)); then
    printf '  => %s holds\n' "$leg_id"
  else
    printf '  => %s DOES NOT HOLD\n' "$leg_id"
    failed=$((failed + 1))
  fi
}

printf 'spend-gate proof  commit=%s  redis=%s  shell=bash %s  mutate=%s\n' \
  "$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo "${PROOF_COMMIT:-unknown}")" \
  "$(redis-server --version | sed -n 's/.*v=\([0-9.]*\).*/\1/p')" \
  "${BASH_VERSION%%(*}" "${mutate:-none}"
printf 'budget=%s  substrate: scratch redis-server on 127.0.0.1, fixture ledger, counting stub as the model\n' "$budget"

server_start

# --- control ---------------------------------------------------------------
leg control "spend under budget: no key, the paid call reaches the model"
printf '20\n25\n15\n' >"$work/ledger"
pct=$(ledger_pct "$work/ledger")
note "ledger: 60 spent, ${pct}% of budget"
band=$(spend_gate_trip "$pct" 2>/dev/null)
want "band" "none" "$band"
want "keys" "" "$(keys)"
before=$(stub_count)
want "paid call" "reached" "$(paid_call)"
want "model calls added" "1" "$(($(stub_count) - before))"
end_leg

# --- trip ------------------------------------------------------------------
leg trip "spend at 96% of budget: both keys set, the paid call is refused, the model sees nothing"
printf '36\n' >>"$work/ledger"
pct=$(ledger_pct "$work/ledger")
note "ledger: 96 spent, ${pct}% of budget"
band=$(spend_gate_trip "$pct" 2>/dev/null)
want "band" "pause" "$band"
want "keys" "proof:paused proof:paused:autonomous" "$(keys)"
before=$(stub_count)
want_refused "$(paid_call)"
want "model calls added" "0" "$(($(stub_count) - before))"
end_leg

# --- redis-down ------------------------------------------------------------
leg redis-down "tripped and Redis unreachable: still refused, by the file marker"
server_stop
want "redis" "unreachable" "$([[ "$(rc PING)" == "PONG" ]] && echo up || echo unreachable)"
before=$(stub_count)
want_refused "$(paid_call)"
want "model calls added" "0" "$(($(stub_count) - before))"
end_leg

# --- redis-restart ---------------------------------------------------------
leg redis-restart "tripped and Redis restarted empty: still refused, and the keys are set again from the markers"
server_start
want "keys after restart, before any check" "" "$(keys)"
before=$(stub_count)
want_refused "$(paid_call)"
want "model calls added" "0" "$(($(stub_count) - before))"
want "keys after one check" "proof:paused proof:paused:autonomous" "$(keys)"
ttl=$(rc TTL proof:paused)
if ((ttl > 0 && ttl <= 43200)); then
  note "ok    global key expiry kept: ${ttl}s left of 43200s"
else
  note "FAIL  global key expiry: expected 1..43200s left, got \"$ttl\""
  leg_ok=0
fi
end_leg

# --- restore ---------------------------------------------------------------
leg restore "cleared by hand: keys and markers gone, the paid call reaches the model again"
spend_gate_clear "" 2>/dev/null
spend_gate_clear autonomous 2>/dev/null
want "keys" "" "$(keys)"
want "markers" "" "$(find "$SPEND_GATE_STATE_DIR" -type f ! -name spend-gate.log | sed 's|.*/||' | sort | tr '\n' ' ' | sed 's/ $//')"
before=$(stub_count)
want "paid call" "reached" "$(paid_call)"
want "model calls added" "1" "$(($(stub_count) - before))"
end_leg

# --- never-tripped ---------------------------------------------------------
leg never-tripped "LIMIT: no marker and Redis unreachable: the paid call goes through"
server_stop
before=$(stub_count)
want "paid call" "reached" "$(paid_call)"
want "model calls added" "1" "$(($(stub_count) - before))"
note "the gate fails open here by design: an outage must not stop a fleet that was never over budget"
end_leg

printf '\n'
if ((failed)); then
  printf 'RESULT: %s leg(s) do not hold\n' "$failed"
  exit 1
fi
printf 'RESULT: all 6 legs hold\n'
