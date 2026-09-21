# Paired advisor benchmark

`benchmark.py` measures one candidate policy against one non-advisor opponent through
`local.py` and the hosted BASIC/WASM bridge. Each seed runs four episodes: advisor
on/off, then the same pair with teams swapped. Policy bytes stay identical between
conditions. Candidate seats occupy one team; opponents occupy the other. The runner
rejects opponent advice requests because those would confound the treatment.

Build the pinned engine:

```sh
python coworld/tools/sync_dependencies.py
POLYWORLD_DEPS="$PWD/tmp/coworld/deps" nim c -d:coworld -o:tmp/paintbot-coworld examples/paintbot/paintbot.nim
```

Choose an authorized endpoint explicitly, then run a bounded comparison:

```sh
export COGAME_ORACLE_URL=https://your-authorized-endpoint/v1/systemone
# Supply COGAME_ORACLE_KEY through your credential environment when required.
uv run --script coworld/paintbot/benchmark.py \
  --candidate examples/paintbot/players/advised.bas \
  --opponent examples/paintbot/players/base.bas \
  --engine tmp/paintbot-coworld --seeds 2026 2027 \
  --output /tmp/paintbot-advisor-comparison
```

The alternative `AWS_ENDPOINT_URL_BEDROCK_RUNTIME` selects the existing sidecar
route, including its player-slot attribution. An explicit oracle URL takes
precedence. No endpoint is selected automatically. Every seed costs four games;
`--ticks` defaults to 14,400 and each game has a 900-second timeout.

The default model is `typesafe/jev-1.13`, with 24-tick request spacing and 24 Hz
pacing. Use pacing for provider comparisons: faster simulated time changes when
asynchronous advice becomes actionable. `--tick-seconds 0` is suitable for local
plumbing proofs, not equivalent to hosted provider timing. `--interval`,
`--deadline`, and `--model` are recorded in the manifest. Runtime timing and
provider responses are not deterministic even with a fixed game seed.

The manifest records candidate and opponent scores, paired score and score-margin
deltas, terminal outcomes, ticks, wall time, policy failures, completed oracle
requests, failed answers, mean/p95 latency, and SHA-256 artifact hashes. It retains
both team rotations separately and averages paired deltas without claiming
statistical significance. Scores are mean per-seat scores within each team;
current Paintbot gives teammates the same score. Outcomes remain separate because
elimination can decide the winner independently of accumulated score.

Cost defaults to unknown (`null`). `--cost-per-request-usd` supplies an estimate
per journaled request, including failures; this is not provider billing. Journals
contain completed calls only. A deadline-plus-one-second drain permits final calls
to finish, but accepted, cancelled, or unjournaled requests are not measured.
Token usage and true billed cost require separate provider accounting.

Every episode retains its config, seats, results, replay, player status, logs, and
oracle journal. Policy snapshots and engine/code hashes identify the inputs.
A partial run remains `running`; only a finished comparison becomes `complete`.
Policy failures or all-failed advisor episodes produce a nonzero exit. No oracle calls in an on episode also
fail instead of silently reporting an advisor comparison. Output directories must
be new, which prevents accidental mixing of runs. Keep artifacts private: policy
snapshots and oracle journals may contain private strategy data.

## Local proof without provider requests

```sh
BENCHMARK_EVIDENCE=/tmp/paintbot-benchmark-proof \
  uv run --no-project --with pydantic --with wasmtime==48.0.0 \
  python coworld/paintbot/test_benchmark.py
```

This runs four complete games against a local HTTP stub, validates both rotations
and policy hashes, and checks successful oracle traffic with zero estimated cost.
It proves the benchmark path; it does not measure Jev quality. The default test
port is 18088. Set `BENCHMARK_EVIDENCE` only to a new directory. If a local uv policy
excludes Wasmtime 48, add `--exclude-newer-package wasmtime=2026-09-21`.
