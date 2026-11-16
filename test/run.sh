# shellcheck shell=bash
# shellcheck disable=SC2015,SC2119
# Tests for spend-gate.sh. Run under each shell: `bash test/run.sh`, `zsh test/run.sh`.
# Needs redis-server and redis-cli on PATH. Starts its own server on a
# loopback port and never touches a Redis that was already running.

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/spend-gate-test.XXXXXX")
port=$((20000 + RANDOM % 20000))
server_pid=""
pass=0
fail=0

export SPEND_GATE_REDIS_URL="redis://127.0.0.1:$port"
export SPEND_GATE_PREFIX="sgtest:paused"
unset SPEND_GATE_CLASS SPEND_GATE_EXEMPT_CLASS SPEND_GATE_CALLER_CLASS SPEND_GATE_PRE_SET_HOOK \
  SPEND_GATE_LOG SPEND_GATE_MARKER SPEND_GATE_CLASS_MARKER

# shellcheck source=SCRIPTDIR/../spend-gate.sh
. "$root/spend-gate.sh"

rc() { redis-cli -p "$port" "$@" 2>/dev/null; }

server_start() {
  redis-server --port "$port" --bind 127.0.0.1 --save '' --appendonly no \
    --dir "$work" >"$work/redis.log" 2>&1 &
  server_pid=$!
  local i=0
  while [ "$(rc PING)" != "PONG" ]; do
    i=$((i + 1))
    if [ "$i" -gt 100 ]; then
      echo "redis-server did not start on port $port" >&2
      cat "$work/redis.log" >&2
      exit 2
    fi
    sleep 0.1
  done
}

server_stop() {
  [ -n "$server_pid" ] || return 0
  kill "$server_pid" 2>/dev/null
  wait "$server_pid" 2>/dev/null
  server_pid=""
}

cleanup() {
  server_stop
  rm -rf "$work"
}
trap cleanup EXIT

# Each case gets an empty state directory and an empty keyspace.
fresh() {
  case_n=$((${case_n:-0} + 1))
  export SPEND_GATE_STATE_DIR="$work/state-$case_n"
  mkdir -p "$SPEND_GATE_STATE_DIR"
  [ -n "$server_pid" ] && rc FLUSHALL >/dev/null
  return 0
}

ok() {
  pass=$((pass + 1))
  printf '  PASS  %s\n' "$1"
}
no() {
  fail=$((fail + 1))
  printf '  FAIL  %s\n' "$1"
}
# expect <description> <expected> <actual>
expect() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$2', got '$3')"; fi; }
# status <description> <expected-exit> <command...>
status() {
  local d="$1" want="$2" got
  shift 2
  "$@" >/dev/null 2>&1
  got=$?
  expect "$d" "$want" "$got"
}

gmark() { printf '%s' "$SPEND_GATE_STATE_DIR/paused"; }
cmark() { printf '%s' "$SPEND_GATE_STATE_DIR/paused-autonomous"; }

echo "spend-gate tests: ${ZSH_VERSION:+zsh $ZSH_VERSION}${BASH_VERSION:+bash $BASH_VERSION} on $(uname -s)"
server_start

echo "--- open by default"
fresh
status "never tripped: check is open" 1 spend_gate_check
expect "never tripped: key prints nothing" "" "$(spend_gate_key)"

echo "--- set, check, clear (global)"
fresh
spend_gate_set "test-trip" 600 2>/dev/null
status "tripped: check is paused" 0 spend_gate_check
expect "key is present" "1" "$(rc EXISTS sgtest:paused)"
expect "key names itself" "sgtest:paused" "$(spend_gate_key)"
expect "marker has two lines" "2" "$(wc -l <"$(gmark)" | tr -d ' ')"
expect "marker line 1 is the key's value" "$(rc GET sgtest:paused)" "$(head -1 "$(gmark)")"
case "$(sed -n 2p "$(gmark)")" in expires=[1-9]*) ok "marker line 2 is expires=<epoch>" ;; *) no "marker line 2 is expires=<epoch>" ;; esac
case "$(spend_gate_reason)" in test-trip@*Z) ok "reason is <reason>@<iso>" ;; *) no "reason is <reason>@<iso>" ;; esac
ttl=$(rc TTL sgtest:paused)
if [ "$ttl" -gt 0 ] && [ "$ttl" -le 600 ]; then ok "key carries the ttl"; else no "key carries the ttl ($ttl)"; fi
status "exempt class is paused by a global trip" 0 spend_gate_check "" operator
grep -q 'KILL_SWITCH_SET: scope=global key=sgtest:paused' "$SPEND_GATE_STATE_DIR/spend-gate.log" && ok "set is logged" || no "set is logged"
spend_gate_clear 2>/dev/null
status "cleared: check is open" 1 spend_gate_check
expect "cleared: key is gone" "0" "$(rc EXISTS sgtest:paused)"
[ -f "$(gmark)" ] && no "cleared: marker is gone" || ok "cleared: marker is gone"

echo "--- a key lost while Redis is up is re-armed from a live marker"
fresh
spend_gate_set "lost-key" 600 2>/dev/null
spend_gate_set "lost-key" 900 autonomous 2>/dev/null
before=$(head -1 "$(gmark)")
rc DEL sgtest:paused sgtest:paused:autonomous >/dev/null
status "key deleted: check is still paused" 0 spend_gate_check
expect "global key is back" "1" "$(rc EXISTS sgtest:paused)"
expect "class key is back from the same check" "1" "$(rc EXISTS sgtest:paused:autonomous)"
expect "re-armed value is the original" "$before" "$(rc GET sgtest:paused)"
ttl=$(rc TTL sgtest:paused)
if [ "$ttl" -gt 0 ] && [ "$ttl" -le 600 ]; then ok "re-armed ttl is the time left"; else no "re-armed ttl is the time left ($ttl)"; fi
grep -q 'KILL_SWITCH_REARM: key=sgtest:paused ' "$SPEND_GATE_STATE_DIR/spend-gate.log" && ok "re-arm is logged" || no "re-arm is logged"

echo "--- a trip with no expiry re-arms with no expiry"
fresh
spend_gate_set "forever" 0 2>/dev/null
expect "marker says expires=0" "expires=0" "$(sed -n 2p "$(gmark)")"
rc DEL sgtest:paused >/dev/null
status "check is paused" 0 spend_gate_check
expect "re-armed key has no ttl" "-1" "$(rc TTL sgtest:paused)"

echo "--- an expired trip lifts"
fresh
printf 'old-trip@2020-01-01T00:00:00Z\nexpires=%s\n' "$(($(date '+%s') - 5))" >"$(gmark)"
status "expired marker, no key: check is open" 1 spend_gate_check
[ -f "$(gmark)" ] && no "expired marker is removed" || ok "expired marker is removed"
expect "no key was set" "0" "$(rc EXISTS sgtest:paused)"

echo "--- a marker with no expires= line is spent"
fresh
printf 'legacy@2020-01-01T00:00:00Z\n' >"$(gmark)"
status "legacy marker, no key: check is open" 1 spend_gate_check
[ -f "$(gmark)" ] && no "legacy marker is removed" || ok "legacy marker is removed"
fresh
printf 'junk@2020-01-01T00:00:00Z\nexpires=soon\n' >"$(gmark)"
status "non-numeric expiry: check is open" 1 spend_gate_check

echo "--- re-arm does not overwrite a key set in the meantime"
fresh
spend_gate_set "first" 600 2>/dev/null
rc SET sgtest:paused "second@x" >/dev/null
status "check is paused" 0 spend_gate_check
expect "the other value stands" "second@x" "$(rc GET sgtest:paused)"

echo "--- class scope"
fresh
spend_gate_set "reserve" 600 autonomous 2>/dev/null
status "default caller is paused" 0 spend_gate_check
status "exempt class is open" 1 spend_gate_check "" operator
status "a named service is paused by the class key" 0 spend_gate_check some-job
expect "key names the class key" "sgtest:paused:autonomous" "$(spend_gate_key)"
[ -f "$(cmark)" ] && ok "class marker is written" || no "class marker is written"
SPEND_GATE_CALLER_CLASS=operator status "caller class from the environment" 1 spend_gate_check
spend_gate_clear autonomous 2>/dev/null
status "class cleared: open" 1 spend_gate_check

echo "--- per-service scope"
fresh
spend_gate_set "manual" 600 image-job 2>/dev/null
status "the service is paused" 0 spend_gate_check image-job
status "another service is open" 1 spend_gate_check other-job
status "an exempt caller of that service is paused" 0 spend_gate_check image-job operator
[ -z "$(find "$SPEND_GATE_STATE_DIR" -type f ! -name spend-gate.log)" ] && ok "per-service scope writes no marker" || no "per-service scope writes no marker"

echo "--- pre-set hook"
fresh
hook_calls="$work/hook-calls"
: >"$hook_calls"
hook_refuse() {
  printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$hook_calls"
  return 1
}
hook_allow() { return 0; }
export SPEND_GATE_PRE_SET_HOOK=hook_refuse
status "a refusing hook makes set exit 3" 3 spend_gate_set "vetoed" 600
expect "hook saw reason, ttl and scope" "vetoed|600|" "$(cat "$hook_calls")"
expect "no key after a veto" "0" "$(rc EXISTS sgtest:paused)"
[ -f "$(gmark)" ] && no "no marker after a veto" || ok "no marker after a veto"
grep -q 'KILL_SWITCH_VETO' "$SPEND_GATE_STATE_DIR/spend-gate.log" && ok "veto is logged" || no "veto is logged"
status "check is open after a veto" 1 spend_gate_check
SPEND_GATE_PRE_SET_HOOK=hook_allow
status "an allowing hook lets set through" 0 spend_gate_set "allowed" 600
status "check is paused" 0 spend_gate_check
unset SPEND_GATE_PRE_SET_HOOK

echo "--- arguments"
fresh
status "a non-numeric ttl is refused" 2 spend_gate_set "bad" soon
expect "nothing was set" "0" "$(rc EXISTS sgtest:paused)"
status "decide refuses a non-number" 2 spend_gate_decide lots

echo "--- decide"
fresh
expect "79 is none" "none" "$(spend_gate_decide 79)"
expect "80 is warn" "warn" "$(spend_gate_decide 80.9)"
expect "90 is reserve" "reserve|set autonomous 90000" "$(spend_gate_decide 90 | tr '\n' '|' | sed 's/|$//')"
expect "95 is pause" "pause|set autonomous 90000|set - 43200" "$(spend_gate_decide 95.5 | tr '\n' '|' | sed 's/|$//')"
expect "100 is cap" "cap|set autonomous 90000|set - 86400" "$(spend_gate_decide 250 | tr '\n' '|' | sed 's/|$//')"
expect "thresholds are inputs" "pause" "$(SPEND_GATE_PAUSE_PCT=50 spend_gate_decide 60 | head -1)"
expect "decide sets nothing" "0" "$(rc DBSIZE)"

echo "--- trip"
fresh
expect "trip at 91 reports reserve" "reserve" "$(spend_gate_trip 91 2>/dev/null)"
expect "class key set" "1" "$(rc EXISTS sgtest:paused:autonomous)"
expect "global key not set" "0" "$(rc EXISTS sgtest:paused)"
first=$(rc GET sgtest:paused:autonomous)
expect "trip at 100 reports cap" "cap" "$(spend_gate_trip 100 2>/dev/null)"
expect "global key set" "1" "$(rc EXISTS sgtest:paused)"
expect "a scope already set keeps its first trip" "$first" "$(rc GET sgtest:paused:autonomous)"
expect "trip below warn sets nothing" "none" "$(SPEND_GATE_STATE_DIR="$work/state-none" SPEND_GATE_PREFIX=sgtest:other spend_gate_trip 10 2>/dev/null)"
expect "nothing under the other prefix" "0" "$(rc EXISTS sgtest:other)"

echo "--- CLI"
fresh
cli="$root/bin/spend-gate"
status "cli check: open exits 1" 1 "$cli" check
status "cli set" 0 "$cli" set cli-trip 600
status "cli check: paused exits 0" 0 "$cli" check
expect "cli key" "sgtest:paused" "$("$cli" key)"
status "cli clear" 0 "$cli" clear
status "cli check: open again" 1 "$cli" check
status "cli unknown verb exits 2" 2 "$cli" nonsense
status "cli help exits 0" 0 "$cli" help

echo "--- Redis restart with an empty keyspace"
fresh
spend_gate_set "restart" 600 2>/dev/null
spend_gate_set "restart" 600 autonomous 2>/dev/null
fresh_never="$work/state-never"
mkdir -p "$fresh_never"
server_stop
server_start
expect "the new server is empty" "0" "$(rc DBSIZE)"
status "tripped before the restart: still paused" 0 spend_gate_check
expect "global key is back" "1" "$(rc EXISTS sgtest:paused)"
expect "class key is back" "1" "$(rc EXISTS sgtest:paused:autonomous)"
SPEND_GATE_STATE_DIR="$fresh_never" SPEND_GATE_PREFIX=sgtest:never status "never tripped: open after the restart" 1 spend_gate_check

echo "--- Redis down"
server_stop
status "tripped, Redis down: paused on the marker" 0 spend_gate_check
expect "key names the marker" "file:$(cmark)" "$(spend_gate_key)"
case "$(spend_gate_reason)" in restart@*Z) ok "reason comes from the marker" ;; *) no "reason comes from the marker" ;; esac
status "exempt class, Redis down: paused on the global marker" 0 spend_gate_check "" operator
[ -f "$(gmark)" ] && ok "a check with Redis down keeps the marker" || no "a check with Redis down keeps the marker"
SPEND_GATE_STATE_DIR="$fresh_never" status "never tripped, Redis down: open" 1 spend_gate_check
SPEND_GATE_STATE_DIR="$fresh_never" status "set with Redis down still writes the marker" 0 spend_gate_set "offline" 600
SPEND_GATE_STATE_DIR="$fresh_never" status "and that marker refuses" 0 spend_gate_check
server_start
SPEND_GATE_STATE_DIR="$fresh_never" status "Redis back: the offline trip is armed" 0 spend_gate_check
expect "its key now exists" "1" "$(rc EXISTS sgtest:paused)"

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
