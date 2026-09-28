## Rules-41 golden state hashes, recorded on the untouched upstream tree (Metta-AI/paintbot-pw
## main e60e489, rules 41 generated maps #122) before the FFA-kin mode was merged in. Any engine
## change that is meant to leave rules-41 teams play alone must keep every value here byte for
## byte; never edit `Golden` to make this pass. Same drivers, seeds and checkpoints as the
## rules-40 golden test, on the default island, plus both drivers on one generated map.
import std/[unittest, os, strutils, sequtils]
import polyworld/cli
import ../examples/paintbot/[sim, bots]

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
const Seeds = [1'i32, 7, 2026]
const Checkpoints = [240, 720, 1440]
const MapRun = (name: "crater", seed: 7'i32)

type Driver = enum scripted, basic

const Golden: array[Driver, array[3, array[3, uint32]]] = [
  scripted: [
    [1368252163'u32, 2384138862'u32, 2600436884'u32],  # seed 1
    [1715917542'u32, 971341815'u32, 139366119'u32],  # seed 7
    [3523574584'u32, 2548514901'u32, 1715848518'u32]],  # seed 2026
  basic: [
    [2962841437'u32, 2369461443'u32, 2833195611'u32],  # seed 1
    [3098977061'u32, 2754228622'u32, 628403883'u32],  # seed 7
    [507368414'u32, 717417816'u32, 1129494330'u32]]]  # seed 2026
const GoldenMap: array[Driver, array[3, uint32]] = [  # map crater, seed 7
  scripted: [3118672817'u32, 3368131015'u32, 2096818526'u32],
  basic: [3637015912'u32, 1169035448'u32, 1771586162'u32]]

proc scriptedCommands(w: World): array[Seats, Command] =
  ## Deterministic, integer-only, reads nothing but the world.
  for slot in 0..<Seats:
    let cog = w.cogs[slot]
    if cog.hp <= 0: continue
    if w.controlHearts.len > 0:
      result[slot].walk = true
      result[slot].goal = w.controlHearts[(slot div 2) mod w.controlHearts.len].pos
    var best = -1
    var bestD = int64.high
    for other in 0..<Seats:
      if team(other) == team(slot) or w.cogs[other].hp <= 0: continue
      let d = distance2(cog.pos, w.cogs[other].pos)
      if d < bestD: best = other; bestD = d
    if best >= 0 and bestD <= ShotRange.int64 * ShotRange:
      result[slot].aim = w.cogs[best].pos
      result[slot].shoot = true
      result[slot].chargeGrenade = w.equipment[slot].grenade and w.tick mod 96 < 48

proc run(driver: Driver, seed: int32): array[3, uint32] =
  visionRulesVersion = 41
  var w = newWorld(seed, 14400)
  var players: array[Seats, Bot]
  if driver == basic: players = loadBots(@[BotGroup(path: Base, count: Seats)])
  var at = 0
  var shots = 0
  while w.tick < Checkpoints[^1] and w.winner == -1:
    let commands = if driver == basic: players.decide(w) else: scriptedCommands(w)
    if driver == basic: deliverSpeech(w)
    w.step(commands)
    shots += w.balls.len
    if at < Checkpoints.len and w.tick == Checkpoints[at]:
      result[at] = w.stateHash()
      inc at
  doAssert at == Checkpoints.len, "match ended before tick " & $Checkpoints[^1]
  doAssert shots > 0, "a golden run must exercise combat"
  if driver == basic:
    for slot in 0..<Seats: doAssert not players[slot].failed, "seat " & $slot & " failed"

proc row(values: array[3, uint32]): string = "[" & values.mapIt($it & "'u32").join(", ") & "]"

suite "rules-41 golden state hashes":
  setup:
    visionRulesVersion = 41
    configureMap("")
  teardown:
    configureMap("")

  test "rules 41 is the live default":
    check visionRulesVersion == 41

  for driver in Driver:
    test "driver " & $driver:
      var table = ""
      var actual: array[3, array[3, uint32]]
      for i, seed in Seeds:
        actual[i] = run(driver, seed)
        table.add "    " & row(actual[i]) & ",  # seed " & $seed & "\n"
      if actual != Golden[driver]:
        echo $driver, " actual (seeds x ticks ", Checkpoints, "):\n", table
      check actual == Golden[driver]

  for driver in Driver:
    test "driver " & $driver & " on map " & MapRun.name:
      configureMap(MapRun.name)
      let actual = run(driver, MapRun.seed)
      if actual != GoldenMap[driver]: echo $driver, " map actual: ", row(actual)
      check actual == GoldenMap[driver]
