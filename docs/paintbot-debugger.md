# Historical replay debugger

The ordinary headless `replay_debugger` implements open/seek/inspect/events/close
using hash-verified replay simulation, not the training/native backend. This is
an uninstalled development tool. Installation, sandbox isolation and downloaded
hosted-replay proof are separate release gates; local fixtures are not hosted parity.

## Build and synthetic tests

From the engine root, with Nim 2.2.10 and synchronized dependencies:

```sh
export POLYWORLD_DEPS="$PWD/tmp/coworld/deps"
nim c -d:headless -d:release --hints:off -o:tmp/replay_debugger examples/paintbot/replay_debugger.nim
PW_TEST_REPLAY_DEBUGGER="$PWD/tmp/replay_debugger" nim c -r -d:headless -d:release --hints:off -o:tmp/test_paintbot_debugger tests/test_paintbot_debugger.nim
```

Linux needs OpenSSL libcrypto for SHA-256. Synthetic tests use sha256sum and git
for actual local artifact identities. No private fixtures or policies are needed.

## Trusted launch boundary

One process owns one session and the game globals. The launcher supplies immutable,
read-only decoded replay bytes on fd 3 (opened through `/proc/self/fd/3`),
`PW_DEBUG_SESSION_ID`, and trusted `PW_DEBUG_ENGINE_BINDING` JSON. Requests cannot
choose paths or provide provenance. The binding is compared for JSON equality,
not reconstructed from attacker metadata. `configureReplayDebugger(path, engine)`
is a trusted embedding/test seam that deliberately resets session lifecycle.
A successful wire open cannot be repeated, including after idempotent close.

The launcher must prevent mutation: the loader rereads the fd-backed bytes, so
read-only access alone does not establish immutable staging. It must also enforce
CPU, memory, wallclock and process limits. No supervisor or service isolation is
installed here. Files larger than 64 MiB are rejected before digest/loading;
the ordinary replay loader rejects durations/frame counts beyond 28,800 ticks.

`engine.replay_version` means the **Paintbot game header version** (49 for current
team rules), not the shared replay envelope version (1).

## Inspection

Open checks SHA-256, exact binding, versions, all frame hashes and actual terminal
completion before returning verified history at tick 0. Seek exposes start-of-tick
state after frames [0,t), supports backward/forward seeks and includes terminal.
Inspection and event queries do not decide policies or move the playhead.

`inspect.data.session.visibility` describes the **requested lens**, not the
launcher's maximum permission or the presence of a seat selector. An authorized
`lens: "omniscient"` inspection remains labeled `omniscient` even with a non-null
seat; `lens: "seat"` remains labeled `seat`. `open.data.visibility` and
`seek.data.visibility` are always `seat`, including for omniscient-authorized
sessions and after an omniscient inspection. Navigation returns session metadata,
not inspected entity values; this label does not revoke the launcher's permission.
These semantics come from `session(visibility = "seat")` and the open/seek
`session()` versus inspect `session(lens)` calls in
`examples/paintbot/replay_debugger.nim`.

Seat inspection uses SeatView `identityRow`, not row ordering. The entity selector
is cog identity in `0..<Seats`; unknown identities refuse. Invisible position,
hp and team are null with `not_visible`. Position is integer hundredths of a tile.
World hashes are decimal strings and remain exposed under the seat lens.

Omniscient inspection and all event queries require the trusted launcher flag
`PW_DEBUG_ALLOW_OMNISCIENT=1`; absent/other values refuse. A null seat is valid only
for omniscient inspection. A null entity selects global fields; entity fields are
null with `not_applicable`. Observation/variables for an entity are `not_captured`.
Scores are two red/blue entries from `world.scores()[0..1]`: current match scoring
(including glory for current rules), **not** the ownership graph's scoreTicks.

## Events

The inclusive start/end window is bounded by the replay horizon and 28,800.
Page size is 1–256. Cursors bind session, start/end, ordered event filter and page
size; changing these refuses. Events are sorted by source (pre-step) tick.

- `shot`: observed differences of indexed cumulative combat shot counters.
- `hit`: observed indexed hit callbacks, converting post-step tick to source tick.
- `down`: observed indexed alive-to-zero-hp transitions, likewise tick minus one.
- `heart_owner_change`: inferred tenure changes, including loss to neutral; no
  fabricated actor seat.
- `equipment_net_increase`: inferred grenade/spray-can/armor/burst increases from
  analysis moments, **not** an exact pickup log.

Event evidence arrays are empty: the worker does not invent artifact references.
Unit projection tests cover hit/ownership/equipment mapping. The synthetic replay
lifecycle exercises actual hit/shot/down events and source-tick correctness; it
does not generate actual ownership/equipment witnesses.

## Validation and verification status

Release synthetic suites exercise corrupt/missing-final-frame refusal,
seat visibility, nullable/authorized inspection, single-open lifecycle, pure
pagination and cursor session/range/filter/limit mismatch, digest shape, 64 MiB
refusal and oversized duration/frame counts. FFA explicitly returns unsupported.
Wrong envelope/game headers and rules bindings, physically truncated payloads,
malformed binding types, and frames after terminal refuse. Failed open permits a
subsequent valid open. The existing replay regression also passes in release.
A separately compiled release executable is exercised via fd3 and JSONL for
open, terminal seek, duplicate keys, invalid UTF-8, BOM, excessive depth,
nonfinite tokens, trailing JSON, oversized input, recovery and unterminated EOF.

JSONL accepts at most 1 MiB and rejects duplicate keys, depth above 32, invalid
UTF-8, BOM and trailing JSON. Adversarial tests include these cases, oversized
input and nonfinite root tokens. Output above 1 MiB becomes a resource_limit
error and closes the session, never truncated success. Trusted in-process
`handleRequest` is not the bounded wire transport.

## Synthetic fixture export

Set `PW_TEST_FIXTURE_DIR` when running the test executable to retain
`synthetic.replay`, `config.json`, and `metadata.json`. Metadata contains the
actual replay digest, binding (with the separately compiled worker's executable
digest), session ID, horizon and decimal world hashes for every pre-step state
including terminal. The export contains only generated public synthetic data.
For example, after building both executables:

```sh
PW_TEST_REPLAY_DEBUGGER="$PWD/tmp/replay_debugger" \
PW_TEST_FIXTURE_DIR="$PWD/tmp/debugger-fixture" tmp/test_paintbot_debugger
```

## Verification boundary and deployment gates

The worker opts into `replayDebuggerStrict` in the existing envelope-v1 loader:
Flatty payload bytes must equal their decoded re-encoding before game-specific
normalization. Trailing binary bytes and noncanonical payloads refuse. This is
not an envelope upgrade and does not change ordinary replay consumers.

`verified` describes complete historical frame/hash verification under the
trusted launch binding. The worker does not discover source/dependency identity
or derive a config artifact digest from replay fields. The trusted launcher must
bind replay evidence to the exact compiled map/config/build before launch; a
self-consistent false trusted binding is not independently authenticated here.
Untrusted requests cannot replace the launcher binding.

Independent facade integration tests exercise sealed immutable fd staging,
CPU/address-space/time/output bounds, cross-principal and lens denial, actual
CLI and MCP JSONL clients through authenticated Unix RPC, and comparison with
existing replay auditors on the same synthetic artifact. The public repository
contains only generated fixtures, not competitive policy/controller state.

Remaining coverage limits: exact 1 MiB boundary acceptance is not exhaustively
tested; actual replay witnesses for heart-owner and equipment projection are
not generated (their mappings have unit coverage). Hit/shot/down and source-tick
projections are compared with existing replay auditors. Current glory scores
are not equated with older auditors' territory scoreTicks. Installed sandbox and
hosted-replay identity/compatibility remain deployment gates, not fixture claims.
