import
  std/[algorithm, json, monotimes, os, times],
  polyworld/cli,
  ../examples/paintbot/[bots, sim]
when not defined(oldBasic):
  import bassy

const
  WarmupTicks = 240
  MeasuredTicks {.intdefine.} = 1200
  Samples {.intdefine.} = 3
  MatchSeed = 2026'i32

proc milliseconds(started: MonoTime): float64 =
  ## Measures elapsed monotonic time in milliseconds.
  float64((getMonoTime() - started).inNanoseconds) / 1_000_000

proc percentile(samples: seq[float64], fraction: float64): float64 =
  ## Returns one quantile from sorted samples.
  samples[min(samples.high, int(float64(samples.len) * fraction))]

proc measure(path: string, sample: int): JsonNode =
  ## Times warm decisions and simulation separately on a deterministic match.
  visionRulesVersion = 48
  gameMode = gmTeams
  var world = newWorld(MatchSeed)
  let startup = getMonoTime()
  let players = loadBots(@[BotGroup(path: path, count: Seats)])
  let startupMs = milliseconds(startup)
  when not defined(oldBasic):
    if jitSupported():
      for player in players:
        doAssert player.runtime.compileNative() > 0
  var
    decisions: seq[float64]
    totalMs, simulationMs: float64
  for i in 0 ..< WarmupTicks + MeasuredTicks:
    let started = getMonoTime()
    let commands = players.decide(world)
    let decisionMs = milliseconds(started)
    let stepping = getMonoTime()
    world.step(commands)
    let stepMs = milliseconds(stepping)
    if i >= WarmupTicks:
      decisions.add decisionMs
      totalMs += decisionMs + stepMs
      simulationMs += stepMs
  for player in players:
    doAssert not player.failed, player.error
  var decisionMs = 0.0
  for duration in decisions:
    decisionMs += duration
  decisions.sort()
  result = %*{
    "sample": sample,
    "seed": MatchSeed,
    "warmup_ticks": WarmupTicks,
    "measured_ticks": MeasuredTicks,
    "seats": Seats,
    "startup_ms": startupMs,
    "decision_ms": decisionMs,
    "simulation_ms": simulationMs,
    "total_ms": totalMs,
    "p50_decision_ms": percentile(decisions, 0.5),
    "p95_decision_ms": percentile(decisions, 0.95),
    "state_hash": world.stateHash()
  }

if paramCount() != 1:
  quit("usage: bench_paintbot_basic policy.bas", 1)
for sample in 0 ..< Samples:
  echo measure(paramStr(1), sample)
