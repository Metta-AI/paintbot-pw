# Neural BASIC runtime canary — 2026-09-22

This is local evidence from the native binary and production Python host path,
not a hosted release, certification, trained policy, or promotion result.
The working tree includes the neural API and live-rules initialization fix.

## Fixture and complete match

Neutral FP32 actor, width 64, 448 inputs, `[51,25,2,2,2]` heads; all weights zero.
The binary came from the pinned Puffer-layout exporter and was packaged as the
three-file ZIP. Model SHA-256:
`6a52bb5a63266cba42aff0e2eabbdcc0b9196a76d9ab0ae3aa9811bb9d063bf7`.
BASIC SHA-256:
`316e4cf91ac9c7f9a0de848c2b59f7575a07666569efad89d9dc521bd69ea99d`.

The real `coworld/paintbot/local.py` handoff staged eight neural ZIP seats,
alternating with eight existing plain BASIC baseline seats, seed 2026, full
14,400-tick maximum. The complete match ended naturally at tick 1669. Rules36
scores were `[0,775]` by team. Every seat completed without runtime failure.
The standalone headless replay runner re-executed every recorded frame and
verified final hash **100826918**, matching the original host output.
Elapsed launch-to-result time was 11.86 seconds; this includes bridge overhead.

A separate malformed-model ZIP test finished its requested 24-tick match:
seat 0 alone had exit code 1 and explicit private log `Neural package failed:
invalid neural actor magic`; all other 15 seats had exit code 0. This uses the
existing BASIC status/private-log failure mechanism, not Python's WASM
`failure.json` mechanism.

## Live-rules bug discovered during verification

Before the fix, the live simulator defaulted to rules 35 while the game wrote
rules 36 replay headers. The same mixed match returned old meter-based scores
and a recording that failed replay verification at tick 1. The fresh setup now
configures its declared recording version before constructing the world; the
simulator's current default is also 36. `test_paintbot_live_rules.nim` exercises
normal CLI setup, initial glory, recording, and replay in a new subprocess.
Existing malformed historical recordings are not rewritten or silently accepted.

## Full 16-seat CPU inference benchmark

Host: Apple M3 Max, 16 logical CPUs, 128 GiB RAM; Nim 2.2.10 release build,
macOS ARM64. One native world with all 16 neural seats, full 14,400 ticks, seed 2026,
no replay hashing/recording in the timed loop. This is a neutral idle workload,
not representative combat/navigation stress or a hosted-Linux capacity claim.
Other development processes were running; there was no isolated CPU reservation.

| Metric | Result |
|---|---:|
| Full-match elapsed | 103.22 seconds |
| World ticks/second | 139.50 |
| Median 16-seat decision+simulation tick | 6.58 ms |
| p95 tick | 10.78 ms |
| p99 tick | 16.38 ms |
| p99 decision phase alone | 16.33 ms |
| Process maximum RSS (`/usr/bin/time -l`) | 7,995,392 bytes |
| Final hash | 232832027 |

Reproduce using `tools/bench_paintbot_neural.nim` with an unpacked neutral BASIC
fixture and its `.model.bin` sidecar. The measured width 64 canary fits the
proposed 41.7 ms tick target on this machine. Width 128/256, real trained behaviors,
hosted CPU limits, and independent repeated timing trials remain unmeasured.

Additional checks passed: five archive-boundary tests, four neural-host tests,
normal-launch replay regression, six existing BASIC-oracle tests, and all 34
Python host-runtime tests. CI runs the new package, neural contract, neural host,
and live-rules tests.

## PR review: legacy semantic equivalence

A clean `HEAD` archive and the implementation produced identical state hashes
for 18 independent explicit-rules traces: versions 1, 9, 23, 27, 35, and 36,
seeds 7, 31, and 99, 240 ticks each, with deterministic movement/fire commands.
This directly checks that extracting terrain configuration into `configureRules`
did not alter legacy simulator semantics. It does not claim cross-version
replays are interchangeable; the normal-launch regression separately checks the
intentional default-rules correction.
