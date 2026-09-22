## Full-match native BASIC deployment benchmark; pass an unpacked policy.bas.
import std/[os, times, monotimes, algorithm, json]
import polyworld/cli
import ../examples/paintbot/[bots, sim]
if paramCount() != 1: quit("usage: bench_paintbot_neural policy.bas", 1)
let players = loadBots(@[BotGroup(path:paramStr(1),count:Seats)])
var w = newWorld(2026)
var durations: seq[float64]
var decisionTimes: seq[float64]
let start = getMonoTime()
while w.winner < 0 and w.tick < HeartMeterMatchTicks:
  let begin = getMonoTime()
  let commands = players.decide(w)
  decisionTimes.add (getMonoTime()-begin).inNanoseconds.float64 / 1e6
  w.step(commands)
  durations.add (getMonoTime()-begin).inNanoseconds.float64 / 1e6
let elapsed = (getMonoTime()-start).inNanoseconds.float64 / 1e9
for slot in 0..<Seats:
  if players[slot].failed: quit("policy failed in seat " & $slot, 1)
durations.sort()
decisionTimes.sort()
proc percentile(samples: seq[float64], fraction: float64): float64 =
  samples[min(samples.high, int(samples.len.float64 * fraction))]
echo $(%*{"ticks":w.tick,"seconds":elapsed,"world_ticks_per_second":w.tick.float64/elapsed,
  "p50_tick_ms":durations.percentile(0.5),"p95_tick_ms":durations.percentile(0.95),
  "p99_tick_ms":durations.percentile(0.99),"p99_16seat_decision_ms":decisionTimes.percentile(0.99),
  "winner":w.winner,"neural_seats":Seats,"state_hash":w.stateHash()})
