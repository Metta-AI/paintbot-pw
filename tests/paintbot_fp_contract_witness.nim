## Witness program for tests/test_paintbot_fp_contract.nim (not a test itself: that test builds it
## several ways and compares the outputs). It imports only the simulation, so it is a sim-only build,
## unless -d:withNeuralActor also imports the neural actor.
##
## It prints two lines:
##   fused=<0|1>   1 when this build rounds c + a*b once (a fused multiply-add) instead of twice
##   match ...     one scripted match (teams, LiveRules, seed 30): ticks, winner, the FNV-1a chain of
##                 every tick's stateHash and the final stateHash.
## Seed 30 is a known witness: walkCoverBlocks' round-cover test meets an exact float64 tie
## (`ex*ex+ez*ez == (r+Radius)^2`) at tick 1934, where a fused multiply-add blocks a shot the
## separately rounded test does not. A gcc -march=x86-64-v3 build with the compiler's default
## contraction ends this match at tick 3000 with no winner; without contraction it ends at
## tick 2620, team 1 winning.
import std/strutils
import ../examples/paintbot/sim
when defined(withNeuralActor):
  import ../examples/paintbot/neural_actor
  discard LayerKind.lkDense

proc multiplyAdd(c, a, b: float64): float64 {.noinline.} = c + a*b

proc fused(): int =
  ## a = 1 + 2^-27: a*a = 1 + 2^-26 + 2^-54 rounds to 1 + 2^-26 (2^-54 is under half an ulp), so
  ## c + a*a with c = -(1 + 2^-26) is exactly 0 rounded twice and 2^-54 rounded once. Parsed at run
  ## time, so the C compiler cannot fold them.
  let a = parseFloat("1.000000007450580596923828125")   # 1 + 2^-27
  let c = parseFloat("-1.0000000149011611938476562500") # -(1 + 2^-26)
  if multiplyAdd(c, a, a) == 0.0: 0 else: 1

var lcg: uint64
proc rnd(n: int): int =
  lcg = lcg * 6364136223846793005'u64 + 1442695040888963407'u64
  int((lcg shr 33) mod uint64(n))

proc fnv(h: var uint64, x: uint64) =
  h = (h xor x) * 1099511628211'u64

proc mapPoint(): Point = point(minX() + rnd(maxX() - minX()), minZ() + rnd(maxZ() - minZ()))

proc nearestShot(w: World, slot: int): (bool, Point) =
  var best = -1
  var bestD = int64.high
  for other in 0..<Seats:
    if other == slot or w.cogs[other].hp <= 0: continue
    if not ffa() and team(other) == team(slot): continue
    let d = distance2(w.cogs[slot].pos, w.cogs[other].pos)
    if d < bestD: best = other; bestD = d
  if best >= 0 and bestD <= ShotRange.int64 * ShotRange: (true, w.cogs[best].pos) else: (false, point(0, 0))

proc runMatch(seed: int32, ticks: int): string =
  ## Every living cog walks to a random goal (a new one every 150 ticks) and shoots the nearest enemy
  ## in range. The controller is seeded and integer-only, so only the simulation can differ.
  gameMode = gmTeams
  visionRulesVersion = LiveRules
  configureRules(LiveRules)
  var w = newWorld(seed)
  lcg = uint64(seed) * 0x9E3779B97F4A7C15'u64 + 1
  var goals = newSeq[Point](Seats)
  var h = 14695981039346656037'u64
  var commands = newSeq[Command](Seats)
  while w.tick < ticks and w.winner == -1:
    for slot in 0..<Seats:
      commands[slot] = Command()
      if w.cogs[slot].hp <= 0: continue
      if w.tick mod 150 == 0 or goals[slot] == point(0, 0): goals[slot] = mapPoint()
      commands[slot].walk = true
      commands[slot].goal = goals[slot]
      let (shoot, aim) = w.nearestShot(slot)
      if shoot:
        commands[slot].shoot = true
        commands[slot].aim = aim
    w.step(commands)
    fnv(h, uint64(w.stateHash()))
  "match teams seed=" & $seed & " ticks=" & $w.tick & " winner=" & $w.winner & " stateChain=" & h.toHex &
    " final=" & w.stateHash().toHex

when isMainModule:
  echo "fused=", fused()
  echo runMatch(30, 3000)
