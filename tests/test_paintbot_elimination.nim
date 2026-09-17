import std/[unittest, os]
import polyworld/tapes
import ../examples/paintbot/[sim, game]

proc eliminate(w: var World, side: int) =
  for i in 0..<Seats:
    if team(i) == side:
      w.cogs[i].hp = 0; w.cogs[i].respawn = 0
      w.equipment[i].lives = 0

suite "Team elimination":
  setup:
    visionRulesVersion = 34
    replayRulesVersion = 34
  test "an eliminated team loses immediately and the survivor's meter fills":
    for loser in 0..1:
      var w = newWorld(2026)
      var commands: array[Seats, Command]
      w.scoreTicks[loser] = 600*TickRate
      w.eliminate(loser)
      w.step(commands)
      check w.winner == 1-loser
      check w.tick == 1
      check w.scoreTicks[1-loser] == w.heartMeterTarget()
      check w.scoreTicks[loser] == 600*TickRate+1
      check w.scores()[1-loser] == 900
      check w.scores()[1-loser] > w.scores()[loser]
      let hash = w.stateHash()
      w.step(commands)
      check w.stateHash() == hash
  test "a team with a pending respawn is not eliminated":
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    w.eliminate(1)
    w.equipment[1].lives = 1
    w.cogs[1].respawn = 48
    w.step(commands)
    check w.winner == -1
    check w.scoreTicks == [1'i32, 1'i32]
  test "the last death ends the match on that tick":
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    w.eliminate(1)
    w.equipment[1].lives = 1
    w.cogs[1].hp = 1; w.cogs[1].shield = 0
    w.step(commands)
    check w.winner == -1
    w.damage(1, 0, 1)
    check w.equipment[1].lives == 0
    w.step(commands)
    check w.winner == 0
    check w.scoreTicks[0] == w.heartMeterTarget()
  test "mutual elimination awards no bonus and ranks the meters":
    var commands: array[Seats, Command]
    for tied in [false, true]:
      var w = newWorld(2026)
      w.scoreTicks = [24'i32, (if tied: 24'i32 else: 48'i32)]
      w.eliminate(0); w.eliminate(1)
      w.step(commands)
      check w.scoreTicks == [25'i32, (if tied: 25'i32 else: 49'i32)]
      check w.winner == (if tied: -2 else: 1)
  test "rules 33 and older keep playing after elimination":
    visionRulesVersion = 33
    replayRulesVersion = 33
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    w.eliminate(1)
    w.step(commands)
    check w.winner == -1
    check w.scoreTicks == [1'i32, 1'i32]
  test "rules 34 recording round trips to the same elimination result":
    var w = newWorld(2026)
    var r = Recording(seed: w.seed, endTick: w.endTick)
    var commands: array[Seats, Command]
    # Only commands replay, so Blue spends its lives on friendly fire while Red
    # marches over to finish the last cog.
    while w.winner == -1:
      for i in 0..<Seats:
        commands[i] = Command()
        var target = -1
        for j in 0..<Seats:
          if j == i or team(j) == 0 or w.cogs[j].hp <= 0: continue
          if target < 0 or distance2(w.cogs[i].pos, w.cogs[j].pos) <
              distance2(w.cogs[i].pos, w.cogs[target].pos): target = j
        if target >= 0:
          commands[i] = Command(walk: team(i) == 0, shoot: true,
              goal: w.cogs[target].pos, aim: w.cogs[target].pos)
      w.step(commands)
      r.frames.add Frame(commands: commands, hash: w.stateHash())
    check w.winner == 0
    check w.tick < w.endTick
    check w.scoreTicks[0] == w.heartMeterTarget()
    let path = getTempDir()/"paintbot-elimination.replay"
    defer: removeFile(path)
    saveReplayFile(path, "paintbot_pw", 34, r)
    let loaded = loadRecording(path)
    var replay = newWorld(loaded.seed, loaded.endTick)
    for frame in loaded.frames:
      replay.step(frame.commands)
      check replay.stateHash() == frame.hash
    check replay.winner == 0
    check replay.scoreTicks == w.scoreTicks
