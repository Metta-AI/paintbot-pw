import std/[unittest, os, tempfiles]
import polyworld/[cli, tapes]
import ../examples/paintbot/[sim, game, bots, analysis]

proc emptyArena(): World =
  result = newWorld(2026)
  for c in result.cogs.mitems: c.hp = 0

proc touch(w: var World, slot: int, heart = 2) =
  w.cogs[slot].hp = 3
  w.cogs[slot].pos = w.controlHearts[heart].pos
  w.cogs[slot].goal = w.cogs[slot].pos

suite "Three-second heart captures":
  setup:
    visionRulesVersion = 26
    replayRulesVersion = 26

  test "neutral heart changes owner on exactly tick 72":
    var w = emptyArena()
    w.touch(0)
    for tick in 1..<HeartCaptureTicks:
      w.updateTerritory()
      check w.controlHearts[2].owner == -1
      check w.heartCaptures[2].ticks == tick
    w.updateTerritory()
    check w.controlHearts[2].owner == 0
    check w.captures == [2'i32,1'i32]
    check w.cogs[0].captures == 1
    check w.heartCaptures[2] == HeartCapture(team: -1)
    w.updateTerritory()
    check w.cogs[0].captures == 1

  test "contesting pauses and removing defender resumes":
    var w = emptyArena()
    w.touch(0)
    for tick in 0..<30: w.updateTerritory()
    w.touch(1)
    for tick in 0..<100: w.updateTerritory()
    check w.heartCaptures[2] == HeartCapture(team: 0, ticks: 30, contested: true)
    check w.controlHearts[2].owner == -1
    w.cogs[1].hp = 0
    for tick in 0..<42: w.updateTerritory()
    check w.controlHearts[2].owner == 0

  test "abandoning or defenders clearing a capture resets it":
    for owner in [-1'i32, 1'i32]:
      var w = emptyArena()
      w.controlHearts[2].owner = owner
      w.touch(0)
      for tick in 0..<60: w.updateTerritory()
      w.cogs[0].pos = home(0)
      if owner == 1: w.touch(1)
      w.updateTerritory()
      check w.heartCaptures[2] == HeartCapture(team: -1)
      check w.controlHearts[2].owner == owner
      w.cogs[1].hp = 0
      w.touch(0)
      w.updateTerritory()
      check w.heartCaptures[2].ticks == 1

  test "opponent cannot inherit neutral capture progress":
    var w = emptyArena()
    w.touch(0)
    for tick in 0..<60: w.updateTerritory()
    w.cogs[0].hp = 0
    w.touch(1)
    w.updateTerritory()
    check w.heartCaptures[2] == HeartCapture(team: 1, ticks: 1)
    check w.controlHearts[2].owner == -1

  test "multiple allies do not accelerate capture":
    var w = emptyArena()
    for slot in [0,2,4]: w.touch(slot)
    w.updateTerritory()
    check w.heartCaptures[2].ticks == 1

  test "initial contest remains neutral with zero progress":
    var w = emptyArena()
    w.touch(0)
    w.touch(1)
    w.updateTerritory()
    check w.heartCaptures[2] == HeartCapture(team: -1, contested: true)
    check w.controlHearts[2].owner == -1

  test "capture radius includes 140 units but excludes 141":
    var w = emptyArena()
    w.touch(0)
    w.cogs[0].pos.x += 141
    w.updateTerritory()
    check w.heartCaptures[2].ticks == 0
    w.cogs[0].pos.x -= 1
    w.updateTerritory()
    check w.heartCaptures[2].ticks == 1

  test "enemy keeps scoring until capture completes and then loses income":
    var w = newWorld(2026)
    w.controlHearts[2].owner = 1
    w.touch(0)
    var commands: array[Seats, Command]
    for tick in 0..<71: w.step(commands)
    check w.scoreTicks == [71'i32,142'i32]
    check w.controlHearts[2].owner == 1
    w.step(commands)
    check w.controlHearts[2].owner == 0
    check w.scoreTicks == [73'i32,143'i32]

  test "last heart waits for completion before eliminating enemies":
    var w = emptyArena()
    for h in w.controlHearts.mitems: h.owner = 0
    w.controlHearts[2].owner = 1
    w.touch(0)
    w.cogs[1].hp = 3
    w.cogs[1].pos = point(3200,2000)
    for tick in 0..<71: w.updateTerritory()
    check w.cogs[1].hp == 3
    w.updateTerritory()
    check w.cogs[1].hp == 0
    check w.equipment[1].lives == 0

  test "BASIC reads progress and rejects invalid indices":
    var w = emptyArena()
    w.touch(0)
    for tick in 0..<25: w.updateTerritory()
    w.touch(1)
    w.updateTerritory()
    let (file,path) = createTempFile("capture-policy-", ".bas")
    file.write("walkTo(controlCaptureTeam(2),controlCaptureTicks(2))\nlookAt(controlContested(2),controlCaptureTicks(10))")
    file.close()
    defer: removeFile(path)
    let players = loadBots(@[BotGroup(path:path,count:Seats)])
    let commands = players.decide(w)
    check commands[0].goal == point(0,25)
    check commands[0].aim == point(1,-1)

  test "progress and contest are included in the world hash":
    var w = emptyArena()
    let initial = w.stateHash()
    w.heartCaptures[2].ticks = 1
    check w.stateHash() != initial
    let progressing = w.stateHash()
    w.heartCaptures[2].contested = true
    check w.stateHash() != progressing

  test "v24 replay seeking reconstructs partial progress and completion":
    let path = getTempDir()/"paintbot-timed-capture.replay"
    defer: removeFile(path)
    world = newWorld(2026,720)
    recording = Recording(seed:2026,endTick:720)
    var commands: array[Seats,Command]
    commands[0] = Command(walk:true,goal:world.controlHearts[8].pos)
    var partialTick = -1
    while world.tick < 720:
      world.step(commands)
      recording.frames.add Frame(commands:commands,hash:world.stateHash())
      if world.heartCaptures[8].ticks == 30: partialTick = world.tick.int
    require partialTick > 0
    check world.controlHearts[8].owner == 0
    saveReplayFile(path,"paintbot_pw",26,recording)
    recording = loadRecording(path)
    replayMode = true
    let index = indexReplay()
    for tick in [partialTick,720,partialTick,0,partialTick+42]:
      index.restore(tick)
      check world.stateHash() == (if tick == 0: newWorld(2026,720).stateHash() else: recording.frames[tick-1].hash)
      if tick == partialTick: check world.heartCaptures[8].ticks == 30
    replayMode = false

  test "rules 23 retain instant capture":
    visionRulesVersion = 23
    var w = emptyArena()
    w.touch(0)
    w.updateTerritory()
    check w.controlHearts[2].owner == 0
    check w.heartCaptures.len == 0
