# AGENTS.md

`spend-gate` is a shell library (`spend-gate.sh`, bash 3.2+ or zsh) with a thin CLI (`bin/spend-gate`). When spend crosses a threshold it sets a gate, and every paid call that checks the gate stops, including after a Redis outage or a Redis restart.

## Stack

- Bash and zsh, no build step, no package manifest. Apache-2.0.
- Runtime needs `redis-cli`. Tests and the proof also need `redis-server`, and `zsh` for the zsh run.
- Lint is `shellcheck` with `.shellcheckrc` (`external-sources=true`).

## Layout

```
spend-gate.sh        the library; configuration is documented in its header comment
bin/spend-gate       CLI: check, key, reason, set, clear, decide, trip (exit 2 on unknown verb)
test/run.sh          92 assertions; starts its own redis-server on a random loopback port
test/proof.sh        runs proof/run.sh as written, then under three mutations; each must fail at the named leg
test/no-internal-names.sh   fails if any file contains a private-system name, a home-directory path or a ledger-style key name
proof/run.sh         the end-to-end proof: six legs against a scratch Redis and a counting stub in place of a paid model
proof/recorded-run.txt      a recorded CI run of the proof (do not hand-edit)
.github/workflows/ci.yml
```

## Commands

| Command | What it does |
|---|---|
| `bash test/run.sh` | Unit tests. Run under `bash`, `zsh`, and on macOS also `/bin/bash` (3.2). Expect `=== 92 passed, 0 failed ===`. |
| `zsh test/run.sh` | Same tests under zsh. |
| `bash test/proof.sh` | Proof passes, and fails under `PROOF_MUTATE=gate`, `budget`, `restart`. Expect four `PASS` lines. |
| `bash proof/run.sh` | The proof alone. Expect `RESULT: all 6 legs hold`. Exit 0 holds, 1 a leg failed, 2 scratch Redis did not start. |
| `shellcheck -x spend-gate.sh bin/spend-gate test/run.sh test/no-internal-names.sh proof/run.sh test/proof.sh` | Lint, exactly as CI runs it. |
| `bash test/no-internal-names.sh` | Name and path scan. |
| `bin/spend-gate decide <percent>` | Prints the band and the scopes it would set; changes nothing. |

Tests start their own `redis-server`, stop it and replace it with an empty one. They never touch a Redis that is already running.

## What the library guarantees, and what pins it

- **Open by default.** A gate that was never tripped stays open, even with Redis down. Pinned by "never tripped, Redis down: open" and the proof's `never-tripped` leg.
- **A trip is a Redis key plus a file marker.** The marker (`<reason>@<ISO-8601 UTC>` then `expires=<epoch>`, 0 for none) is a public contract for readers in other languages. Pinned by "marker has two lines" and "marker line 2 is expires=<epoch>".
- **Survives a Redis restart.** A lost key is set again from a live marker with the time left, with `SET ... NX` so a newer key is never overwritten. Pinned by the "re-armed" cases and the proof's `redis-restart` leg.
- **Survives a Redis outage.** With Redis down, any marker refuses. Pinned by the "Redis down" section.
- **Spent or malformed markers lift.** Past expiry or no valid `expires=` line removes the marker and leaves the gate open.
- **Scopes.** Global (`""`), class (`autonomous` by default, skipped by the exempt class `operator`), per-service (no marker, so no restart survival). Pinned by the class and per-service sections.
- **Bands.** under 80 none, 80 warn, 90 reserve, 95 pause, 100 cap; `decide` changes nothing, `trip` applies and skips scopes already set. Pinned by the `decide` and `trip` sections.
- **Pre-set hook.** `SPEND_GATE_PRE_SET_HOOK` non-zero refuses the set (exit 3) and logs `KILL_SWITCH_VETO`. Pinned by the "pre-set hook" section.
- **Clear order.** `spend_gate_clear` removes the marker before the key so a concurrent check cannot re-arm it.
- **The proof can fail.** `test/proof.sh` mutates the proof (skip the check, raise the budget, stop restoring keys) and requires failure at the right leg.

## CI

`.github/workflows/ci.yml` (name `ci`) runs on pull requests and pushes to `main`. Checks a PR must pass:

- `test (ubuntu-latest)` and `test (macos-latest)`: `bash test/run.sh`, macOS also `/bin/bash test/run.sh`, `zsh test/run.sh`, then `bash test/proof.sh`.
- `proof`: `bash proof/run.sh` and `bash test/proof.sh` in a `redis:7.4-bookworm` container with `PROOF_COMMIT` set to the commit.
- `lint`: the `shellcheck` command above, then `bash test/no-internal-names.sh`.

## Gotchas

- Keep the file portable to bash 3.2 and zsh: no associative arrays, no `${var,,}`, no `mapfile`. Both test runs must stay green.
- The marker format and the key names are consumed by other tools. Changing either is a breaking change; update the README and the marker tests together.
- Per-service scopes have no marker by design; do not add one without updating the README "Limits" section.
- `test/no-internal-names.sh` fails on any private-system name or home-directory path anywhere in the repo, including docs. Keep examples generic.
- If you change what the proof prints, `proof/recorded-run.txt` becomes stale; it is a recording of a CI run, regenerate it only from a real CI run.

## Never

- Commit secrets, Redis URLs with credentials, or real spend data.
- Point tests at a shared or production Redis. They must use their own loopback `redis-server`.
- Weaken a test or a mutation to make CI pass; the mutations exist to show the proof can fail.
- Hand-edit `proof/recorded-run.txt`.
- Push to `main`.
