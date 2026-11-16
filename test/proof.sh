#!/usr/bin/env bash
# The proof must pass as written and fail under each mutation, at the leg
# that mutation attacks. A proof that cannot fail proves nothing.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bad=0

# run <mutation|-> <expected exit> <leg that must not hold|->
run() {
  local mutate="$1" want_rc="$2" leg="$3" out rc
  if [[ "$mutate" == "-" ]]; then
    out=$(env -u PROOF_MUTATE bash "$root/proof/run.sh" 2>&1)
  else
    out=$(PROOF_MUTATE="$mutate" bash "$root/proof/run.sh" 2>&1)
  fi
  rc=$?
  if [[ "$rc" != "$want_rc" ]]; then
    echo "FAIL  mutate=$mutate: exit $rc, expected $want_rc"
    printf '%s\n' "$out"
    bad=1
    return
  fi
  if [[ "$leg" != "-" ]] && ! printf '%s\n' "$out" | grep -q "=> $leg DOES NOT HOLD"; then
    echo "FAIL  mutate=$mutate: leg $leg was expected not to hold"
    printf '%s\n' "$out"
    bad=1
    return
  fi
  echo "PASS  mutate=$mutate: exit $rc${leg:+ }$([[ "$leg" != "-" ]] && echo "($leg does not hold)")"
}

run - 0 -
run gate 1 trip
run budget 1 trip
run restart 1 redis-restart
exit "$bad"
