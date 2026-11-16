# spend-gate

A budget trip for autonomous agents. When spend crosses a threshold, a gate is
set and every paid call that checks it stops. The trip survives a Redis outage
and a Redis restart.

A shell library (`spend-gate.sh`, bash 3.2+ or zsh) with a thin CLI
(`bin/spend-gate`). It needs `redis-cli`.

## Use

```sh
. ./spend-gate.sh

if spend_gate_check; then
  echo "paused: $(spend_gate_reason)" >&2
  exit 1
fi
# ... make the paid call
```

Trip it from whatever computes your spend:

```sh
spend_gate_trip 96        # percent of budget; sets the scopes that band names
spend_gate_set "manual" 3600 image-job   # or pause one scope by hand
spend_gate_clear          # resume
```

The CLI takes the same verbs: `check`, `key`, `reason`, `set`, `clear`,
`decide`, `trip`. `check` exits 0 when paused and 1 when open.

## What a trip is

A Redis key and a file marker. Callers read the key. The marker holds the
trip's reason and expiry, and it decides what happens when the key is missing:

| Redis | Key | Marker | Result |
|---|---|---|---|
| up | present | any | paused |
| up | absent | live | paused, and the key is set again with the time left |
| up | absent | expired or malformed | open, and the marker is removed |
| down | n/a | present | paused |
| down | n/a | absent | open |

A gate that was never tripped stays open when Redis is down.

Marker format, for readers in other languages:

```
<reason>@<ISO-8601 UTC>
expires=<epoch seconds, 0 for no expiry>
```

## Scopes

- Global (`""`): every caller.
- Class (`autonomous` by default): every caller except the exempt class
  (`operator` by default). This keeps a reserve for replies to a person after
  unattended work has been stopped.
- Per-service (any other name): one caller. It has no marker, so it does not
  survive a Redis restart.

## Bands

`spend_gate_decide <percent>` prints the band and the scopes it would set. It
changes nothing. `spend_gate_trip` applies it.

| Percent of budget | Band | Sets |
|---|---|---|
| under 80 | `none` | nothing |
| 80 | `warn` | nothing |
| 90 | `reserve` | class, 25 h |
| 95 | `pause` | class, and global for 12 h |
| 100 | `cap` | class, and global for 24 h |

You compute the percentage. The module does not read a ledger or a bill.

## Pre-set hook

Set `SPEND_GATE_PRE_SET_HOOK` to a command or function. It runs before every
set with the reason, TTL and scope. A non-zero exit refuses the set
(`spend_gate_set` exits 3) and writes a `KILL_SWITCH_VETO` log line.

## Configuration

Environment variables, with defaults, are listed at the top of
`spend-gate.sh`: key prefix, state directory, class names, Redis URL, log
path, thresholds and TTLs. To use your own Redis client or a timeout wrapper,
define a `spend_gate_redis` function before sourcing.

## Limits

- A reader that looks at the Redis key directly, without calling `check`, does
  not see the marker. After a Redis restart it allows calls until something
  calls `check` and the key is set again.
- Per-service keys have no marker.
- A marker with no valid `expires=` line is treated as spent.

## Tests

```sh
bash test/run.sh
zsh test/run.sh
```

The tests start their own `redis-server` on a loopback port, stop it, and
replace it with an empty one. They do not touch a Redis that is already
running.

## License

Apache-2.0. Copyright DCYFR Labs.
