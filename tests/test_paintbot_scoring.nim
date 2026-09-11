import std/[unittest, os]
import ../examples/paintbot/[sim, game]
import polyworld/tapes

suite "Heartwick points for time held":
  setup:
    visionRulesVersion = 23
    replayRulesVersion = 23
  test "one point per heart per second, including partial seconds":
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    for tick in 0..<24: w.step(commands)
    check w.scoreTicks == [24'i32,24'i32]
    check w.scores()[0] == 1.0
    for tick in 0..<12: w.step(commands)
    check w.scores()[0] == 1.5
  test "ownership changes affect subsequent accrual":
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    w.step(commands)
    w.controlHearts[2].owner = 0
    w.step(commands)
    check w.scoreTicks == [3'i32,2'i32]
  test "elimination credits all ten hearts for the remaining time once":
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    w.tick = 240
    w.scoreTicks = [240'i32,240'i32]
    for i in 0..<Seats:
      if team(i)==1:
        w.cogs[i].hp=0
        w.cogs[i].respawn=0
        w.equipment[i].lives=0
    w.step(commands)
    check w.scoreTicks[0] == 241 + 10*(MatchTicks-241)
    check w.scoreTicks[1] == 241
    let finalScore = w.scoreTicks
    w.step(commands)
    check w.scoreTicks == finalScore
    check w.winner == 0
  test "all hearts eliminates enemy including pending respawns":
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    for h in w.controlHearts.mitems: h.owner=0
    for i in 0..<Seats: w.cogs[i].pos=point(3200,2000)
    w.step(commands)
    for i in 0..<Seats:
      if team(i)==1:
        check w.cogs[i].hp==0
        check w.equipment[i].lives==0
        check w.cogs[i].respawn==0
    check w.winner==0
    check w.scoreTicks[0]==MatchTicks*10
  test "timeout uses points, permits ties and never bombards":
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    w.tick=MatchTicks-1
    w.scoreTicks=[48'i32,24'i32]
    w.step(commands)
    check w.winner==0
    check w.grenades.len==0
    check w.equipment[0].lives==4
    check w.tick==MatchTicks
    w.step(commands)
    check w.tick==MatchTicks
    w=newWorld(2026,24)
    for tick in 0..<24:w.step(commands)
    check w.winner == -2
  test "simultaneous elimination awards no survivor bonus":
    var w = newWorld(2026)
    var commands: array[Seats,Command]
    for i in 0..<Seats:
      w.cogs[i].hp=0
      w.cogs[i].respawn=0
      w.equipment[i].lives=0
    w.step(commands)
    check w.scoreTicks==[1'i32,1'i32]
    check w.winner == -2
  test "recorded duration and fractional score reproduce exactly":
    let path=getTempDir()/"paintbot-scoring.replay"
    defer:removeFile(path)
    var w=newWorld(2026,36)
    var r=Recording(seed:2026,endTick:36)
    var commands:array[Seats,Command]
    for tick in 0..<36:
      w.step(commands)
      r.frames.add Frame(commands:commands,hash:w.stateHash())
    saveReplayFile(path,"paintbot_pw",23,r)
    let loaded=loadRecording(path)
    var replay=newWorld(loaded.seed,loaded.endTick)
    for f in loaded.frames:
      replay.step(f.commands)
      check replay.stateHash()==f.hash
    check replay.scores()[0]==1.5
    check replay.winner == -2
