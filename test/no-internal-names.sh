#!/usr/bin/env bash
# Fails when a file names a private system, a home directory or a private key
# prefix. This module is consumed elsewhere; nothing of a consumer belongs here.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The private system's name is assembled from two halves so that this file,
# which is public, does not spell it.
name='re'
name="${name}i"
pattern="(^|[^[:alnum:]])${name}([^[:alnum:]]|\$)|/Users/|/home/[a-z]|cost[-_]ledger|cost_kill_switch|budget-paused"
if grep -rnIiE "$pattern" "$root" --exclude-dir=.git --exclude=no-internal-names.sh --exclude=LICENSE; then
  echo "internal names found (above)" >&2
  exit 1
fi
echo "no internal names"
