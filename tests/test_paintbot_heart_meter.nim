import std/[unittest, os]
import polyworld/tapes
import ../examples/paintbot/[sim, game]

suite "Team heart meter":
  setup:
    visionRulesVersion = 28
    replayRulesVersion = 28
  test "half the hearts fill the meter in exactly three minutes":
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    # Keep cogs out of capture range so ownership stays fixed.
    for c in w.cogs.mitems: c.hp = 0; c.respawn = 0
    for e in w.equipment.mitems: e.lives = 0
    for i, h in w.controlHearts.mpairs: h.owner = if i < 5: 0 else: -1
    check w.heartMeterTarget() == 900*TickRate
    for tick in 0..<180*TickRate-1: w.step(commands)
    check w.winner == -1
    check w.scoreTicks[0] == 900*TickRate-5
    w.step(commands)
    check w.winner == 0
    check w.tick == 180*TickRate
    check w.scores()[0] == 900
    let hash = w.stateHash()
    w.step(commands)
    check w.stateHash() == hash
  test "all hearts and elimination do not award an instant victory or bonus":
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    for h in w.controlHearts.mitems: h.owner = 0
    w.step(commands)
    check w.winner == -1
    check w.scoreTicks == [10'i32, 0'i32]
    check w.cogs[1].hp > 0
    for c in w.cogs.mitems: c.hp = 0; c.respawn = 0
    for e in w.equipment.mitems: e.lives = 0
    w.step(commands)
    check w.winner == -1
    check w.scoreTicks == [20'i32, 0'i32]
  test "ten-minute cap ranks points and ties draw":
    var commands: array[Seats, Command]
    for tied in [false, true]:
      var w = newWorld(2026, 28800)
      check w.endTick == 600*TickRate
      w.tick = w.endTick-1
      w.scoreTicks = [24'i32, (if tied: 24'i32 else: 48'i32)]
      w.step(commands)
      check w.tick == 600*TickRate
      check w.winner == (if tied: -2 else: 1)
  test "both meters filling on the same tick draw":
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    w.scoreTicks = [w.heartMeterTarget()-1, w.heartMeterTarget()-1]
    w.step(commands)
    check w.winner == -2
  test "rules 28 recording round trips to the same terminal state":
    var w = newWorld(2026, 48)
    var r = Recording(seed: w.seed, endTick: w.endTick)
    var commands: array[Seats, Command]
    for tick in 0..<48:
      w.step(commands)
      r.frames.add Frame(commands: commands, hash: w.stateHash())
    let path = getTempDir()/"paintbot-heart-meter.replay"
    defer: removeFile(path)
    saveReplayFile(path, "paintbot_pw", 28, r)
    let loaded = loadRecording(path)
    var replay = newWorld(loaded.seed, loaded.endTick)
    for frame in loaded.frames:
      replay.step(frame.commands)
      check replay.stateHash() == frame.hash
    check replay.winner == -2
    check replay.scoreTicks == w.scoreTicks
