import std/[unittest, os, tempfiles]
import polyworld/[cli, tapes]
import ../examples/paintbot/[sim, game, bots]

proc eliminate(w: var World, side: int) =
  for i in 0..<Seats:
    if team(i) == side:
      w.cogs[i].hp = 0; w.cogs[i].respawn = 0
      w.equipment[i].lives = 0

proc idle(w: var World, ticks: int) =
  var commands: array[Seats, Command]
  for tick in 0..<ticks: w.step(commands)

proc secondsBetween(a, b: int): int32 =
  ## Whole-second boundaries crossed going from tick a to tick b: the countdown paid.
  int32(b div TickRate - a div TickRate)

# A live game must simulate the same rules it stamps on the recording; 0.3.32 shipped with these
# two defaults apart (35 vs 36), which made every hosted replay of that version unplayable.
doAssert visionRulesVersion == replayRulesVersion

suite "Glory":
  setup:
    visionRulesVersion = 37
    replayRulesVersion = 37
  test "glory starts at the match length in seconds and counts down one per second":
    var w = newWorld(2026)
    check w.endTick == 600*TickRate
    check w.glory == [600'i32, 600'i32]
    check newWorld(2026, 48).glory == [2'i32, 2'i32]
    w.pickups.setLen(0)
    w.idle(TickRate-1)
    check w.glory == [600'i32, 600'i32]
    w.idle(1)
    check w.glory == [599'i32, 599'i32]
    for i in 0..<Seats: check w.scores()[i] == 599
    check w.gloryEvents.len == 0
  test "thirty seconds without supplies pays ten; a pickup restarts the team's clock":
    var w = newWorld(2026)
    w.pickups.setLen(0)
    w.idle(GloryQuietSupplyTicks-1)
    check w.glory == [571'i32, 571'i32]
    check w.gloryEvents.len == 0
    w.idle(1)
    check w.tick == GloryQuietSupplyTicks
    check w.glory == [580'i32, 580'i32]
    check w.gloryEvents.len == 2
    for event in w.gloryEvents:
      check event.kind == gloryQuietSupplies
      check event.amount == GloryQuietSupplies
      check event.tick == GloryQuietSupplyTicks
    check w.lastSupplyTick == [GloryQuietSupplyTicks.int32, GloryQuietSupplyTicks.int32]
    # Awards are remembered for the viewer, then forgotten.
    w.idle(GloryEventLifetime-1)
    check w.gloryEvents.len == 2
    w.idle(1)
    check w.gloryEvents.len == 0
    # Red collects a medkit at tick 900; its next quiet award moves to 1620 while Blue's stays at 1440.
    w.idle(900-w.tick.int)
    w.cogs[0].hp = 1
    w.pickups.add Pickup(pos: w.cogs[0].pos, kind: medkitPickup)
    w.idle(1)
    check w.cogs[0].hp == 3
    check w.lastSupplyTick == [900'i32, GloryQuietSupplyTicks.int32]
    let before = w.glory
    check w.tick == 901
    w.idle(2*GloryQuietSupplyTicks-w.tick.int)
    check w.glory[1] == before[1]-secondsBetween(901, w.tick.int)+GloryQuietSupplies
    check w.glory[0] == before[0]-secondsBetween(901, w.tick.int)
    w.idle(900+GloryQuietSupplyTicks-w.tick.int)
    check w.glory[0] == before[0]-secondsBetween(901, w.tick.int)+GloryQuietSupplies
    check w.glory[1] == before[1]-secondsBetween(901, w.tick.int)+GloryQuietSupplies
  test "BASIC reads both teams' glory and rejects invalid teams":
    var w = newWorld(2026)
    w.glory = [587'i32, 300'i32]
    let (file, path) = createTempFile("glory-policy-", ".bas")
    file.write("walkTo(glory(0),glory(1))\nlookAt(glory(2),glory(-1))")
    file.close()
    defer: removeFile(path)
    let players = loadBots(@[BotGroup(path: path, count: Seats)])
    let commands = players.decide(w)
    check commands[0].goal == point(587, 300)
    check commands[0].aim == point(-1, -1)
    check commands[1].goal == point(587, 300)
  test "captures and tags pay nothing; early friendly fire pays the team that took it":
    var w = newWorld(2026)
    w.pickups.setLen(0)
    # Red cog 0 stands on neutral heart 2 until the claim completes: no glory for winning play.
    w.cogs[0].pos = w.controlHearts[2].pos
    w.cogs[0].goal = w.cogs[0].pos
    var commands: array[Seats, Command]
    var ticks = 0
    while w.controlHearts[2].owner != 0 and ticks < 100:
      w.step(commands); inc ticks
    check w.controlHearts[2].owner == 0
    check w.tick == HeartCaptureTicks
    check w.glory == [600'i32-HeartCaptureTicks div TickRate, 600'i32-HeartCaptureTicks div TickRate]
    check w.gloryEvents.len == 0
    var glory = w.glory
    # An enemy tag counts as a tag and nothing more.
    w.cogs[1].hp = 1; w.cogs[1].shield = 0
    w.damage(1, 0, 1)
    check w.cogs[1].hp == 0
    check w.cogs[0].tags == 1
    check w.glory == glory
    check w.gloryEvents.len == 0
    # Friendly fire in the opening thirty seconds pays the victim's team, per hit.
    check w.tick < GloryFriendlyFireTicks
    w.cogs[2].hp = 3; w.cogs[2].shield = 0; w.equipment[2].armor = 0
    w.damage(2, 0, 1)
    glory[0] += GloryFriendlyFire
    check w.glory == glory
    check w.gloryEvents[^1].kind == gloryFriendlyFire
    check w.gloryEvents[^1].amount == GloryFriendlyFire
    # A friendly kill is still not a tag.
    w.cogs[2].hp = 1
    w.damage(2, 0, 1)
    glory[0] += GloryFriendlyFire
    check w.glory == glory
    check w.cogs[2].hp == 0
    # Spawn protection and self-damage do not count.
    w.cogs[4].hp = 3; w.cogs[4].shield = 10
    w.damage(4, 0, 1)
    w.cogs[6].hp = 3; w.cogs[6].shield = 0
    w.damage(6, 6, 1)
    check w.glory == glory
    # After thirty seconds friendly fire is just friendly fire.
    w.tick = GloryFriendlyFireTicks
    w.cogs[8].hp = 3; w.cogs[8].shield = 0
    w.damage(8, 0, 1)
    check w.glory == glory
    check w.glory[1] == 600-HeartCaptureTicks div TickRate
  test "the loser's glory drops to zero and the winner's is every seat's score":
    for loser in 0..1:
      var w = newWorld(2026)
      var commands: array[Seats, Command]
      w.scoreTicks[1-loser] = w.heartMeterTarget()-1
      w.step(commands)
      check w.winner == 1-loser
      check w.glory[loser] == 0
      check w.glory[1-loser] == 600
      for i in 0..<Seats:
        check w.scores()[i] == (if team(i) == loser: 0.0 else: 600.0)
      let hash = w.stateHash()
      w.step(commands)
      check w.glory == [(if loser == 0: 0'i32 else: 600'i32), (if loser == 1: 0'i32 else: 600'i32)]
      check w.stateHash() == hash
  test "a draw pays nobody":
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    w.scoreTicks = [w.heartMeterTarget()-1, w.heartMeterTarget()-1]
    w.step(commands)
    check w.winner == -2
    check w.glory == [0'i32, 0'i32]
    for i in 0..<Seats: check w.scores()[i] == 0
  test "an eliminated team loses its glory":
    for loser in 0..1:
      var w = newWorld(2026)
      var commands: array[Seats, Command]
      w.eliminate(loser)
      w.step(commands)
      check w.winner == 1-loser
      check w.glory[loser] == 0
      check w.glory[1-loser] == 600
  test "glory floors at zero at the time limit":
    var w = newWorld(2026, 48)
    w.pickups.setLen(0)
    w.controlHearts[2].owner = 0
    w.idle(24)
    check w.glory == [1'i32, 1'i32]
    check w.winner == -1
    w.idle(24)
    check w.winner == 0
    check w.glory == [0'i32, 0'i32]
  test "rules 36 recordings play as rules 35: no glory, heart-point scores":
    visionRulesVersion = 36
    replayRulesVersion = 36
    var w = newWorld(2026)
    w.idle(TickRate)
    check w.glory == [0'i32, 0'i32]
    check w.gloryEvents.len == 0
    check w.scores()[0] == 1.0
    var tampered = w
    tampered.glory[0] = 99
    check tampered.stateHash() == w.stateHash()
  test "glory is part of the rules 37 hash and absent from rules 35":
    var w = newWorld(2026)
    w.idle(1)
    var tampered = w
    tampered.glory[0] += 1
    check tampered.stateHash() != w.stateHash()
    visionRulesVersion = 35
    replayRulesVersion = 35
    var old = newWorld(2026)
    old.idle(TickRate)
    check old.glory == [0'i32, 0'i32]
    check old.gloryEvents.len == 0
    check old.scores()[0] == 1.0
    old.cogs[1].hp = 1; old.cogs[1].shield = 0
    old.damage(1, 0, 1)
    check old.gloryEvents.len == 0
    var oldTampered = old
    oldTampered.glory[0] = 99
    check oldTampered.stateHash() == old.stateHash()
  test "rules 37 recording round trips to the same glory":
    var w = newWorld(2026, 48)
    var r = Recording(seed: w.seed, endTick: w.endTick)
    var commands: array[Seats, Command]
    for tick in 0..<48:
      w.step(commands)
      r.frames.add Frame(commands: commands, hash: w.stateHash())
    check w.winner == -2
    let path = getTempDir()/"paintbot-glory.replay"
    defer: removeFile(path)
    saveReplayFile(path, "paintbot_pw", 37, r)
    let loaded = loadRecording(path)
    check replayRulesVersion == 37
    var replay = newWorld(loaded.seed, loaded.endTick)
    check replay.glory == [2'i32, 2'i32]
    for frame in loaded.frames:
      replay.step(frame.commands)
      check replay.stateHash() == frame.hash
    check replay.winner == -2
    check replay.glory == w.glory
