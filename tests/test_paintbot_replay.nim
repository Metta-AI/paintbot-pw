import std/[unittest, os]
import ../examples/paintbot/[sim, game, analysis]
import polyworld/tapes
import flatty

suite "Paintbot replay analysis and metadata":
  test "checkpoint seeks preserve all recorded world hashes":
    recording=Recording(seed:2026,endTick:HeartMeterMatchTicks)
    world=newWorld(recording.seed)
    var commands:array[Seats,Command]
    for i in 0..<Seats:
      commands[i]=Command(walk:true,goal:home(1-team(i)))
    for tick in 0..<720:
      world.step(commands)
      recording.frames.add Frame(commands:commands,hash:world.stateHash())
    replayMode=true
    var updates: seq[int]
    let built = indexReplay(proc(tick, total: int) =
      check total == 720
      updates.add tick)
    check updates == @[240, 480, 720]
    # Exercise the same binary handoff as the worker, then seek against hashes.
    let index = built.toFlatty().fromFlatty(ReplayIndex)
    check index.momentum[0].tick == 0
    check index.momentum[^1].tick == 720
    for sample in index.momentum:
      index.restore(sample.tick)
      check graphSample(world) == sample
    for tick in [719,1,240,480,721,0,333,600,240]:
      index.restore(tick)
      let target=min(tick,720)
      check world.tick==target
      check world.stateHash()==(if target==0:newWorld(2026).stateHash() else:recording.frames[target-1].hash)
  test "v1 remains readable and v26 preserves public metadata":
    type Legacy=object
      seed:int32
      frames:seq[Frame]
    let path=getTempDir()/"paintbot-replay-metadata-test.replay"
    defer:removeFile(path)
    saveReplayFile(path,"paintbot_pw",1,Legacy(seed:2026,frames: @[]))
    check loadRecording(path).names[0]=="Ember 1"
    recording.names[0]="Daveey <test>"
    recording.communications = @[Communication(tick:1,slot:0,text:"Guard the heart ♥")]
    saveReplayFile(path,"paintbot_pw",26,recording)
    let loaded=loadRecording(path)
    check loaded.names[0]=="Daveey <test>"
    check loaded.communications[0].text=="Guard the heart ♥"
    recording.communications[0].slot=16
    saveReplayFile(path,"paintbot_pw",26,recording)
    expect ReplayError:discard loadRecording(path)
  test "analysis refuses corrupt replay inputs":
    recording.communications = @[]
    recording.frames[13].hash=0
    expect ReplayError:discard indexReplay()

  test "live graph history records ownership changes and ignores rewinds":
    visionRulesVersion = 23
    var w = newWorld(2026)
    var history: ReplayIndex
    history.sampleGraphs(w)
    w.tick = 7
    w.captures = [2'i32,1'i32]
    w.scoreTicks = [8'i32,7'i32]
    history.sampleGraphs(w)
    check history.momentum.len == 2
    check history.momentum[^1].tick == 7
    check history.momentum[^1].redHearts == 2
    w.tick = 3
    history.sampleGraphs(w)
    check history.momentum.len == 2
    w.tick = 9
    w.winner = 0
    w.scoreTicks[0] = 70000
    history.sampleGraphs(w)
    check history.momentum[^1].red == 70000.0/24

  test "combat counts completed shots and armor hits at the playhead":
    visionRulesVersion = 27
    replayRulesVersion = 27
    recording = Recording(seed: 42, endTick: 240)
    world = newWorld(42, 240)
    world.cover = @[]
    world.trenches = @[]
    world.pickups = @[]
    for i in 0..<Seats:
      world.cogs[i].shield = 0
      world.cogs[i].pos = point(1000+i*200, 1500)
      world.cogs[i].goal = world.cogs[i].pos
    world.cogs[0].pos = point(1000, 1000)
    world.cogs[0].goal = world.cogs[0].pos
    world.cogs[1].pos = point(1200, 1000)
    world.cogs[1].goal = world.cogs[1].pos
    world.equipment[1].armor = 1
    let initial = snapshot(world)
    var commands: array[Seats, Command]
    commands[0] = Command(shoot: true, aim: world.cogs[1].pos)
    for tick in 0..<30:
      world.step(commands)
      recording.frames.add Frame(commands: commands, hash: world.stateHash())
    world = snapshot(initial)
    replayMode = true
    var history = ReplayIndex(checkpoints: @[Checkpoint(state: snapshot(initial))])
    for tick in 0..<30: history.advanceIndexed()
    check history.combat.len == 31
    check history.combat[5][0] == CombatStats(shots: 0, hits: 0)
    check history.combat[6][0] == CombatStats(shots: 1, hits: 1)
    check history.combat[29][0] == CombatStats(shots: 1, hits: 1)
    check history.combat[30][0] == CombatStats(shots: 2, hits: 2)
    check history.combat[30][1] == CombatStats(shots: 0, hits: 0)
    let before = history.combat
    for tick in [30, 0, 6, 5, 29, 30]:
      history.restore(tick)
      check history.combat == before
      check world.tick == tick
      check world.stateHash() == (if tick == 0: initial.stateHash() else: recording.frames[tick-1].hash)
    check observeShot == nil
    check observeHit == nil

  test "heart hold durations follow ownership at the playhead":
    visionRulesVersion = 27
    var w = newWorld(42, 240)
    w.controlHearts = @[ControlHeart(owner: 0), ControlHeart(owner: -1)]
    var history: ReplayIndex
    history.sampleHeartTenures(w)
    w.tick = 24
    w.controlHearts[1].owner = 1
    history.sampleHeartTenures(w)
    w.tick = 72
    w.controlHearts[0].owner = 1
    history.sampleHeartTenures(w)
    w.tick = 96
    history.sampleHeartTenures(w)
    check history.heartTenures[0].len == 2
    check history.heartHeldTicks(0, 96) == 24
    check history.heartHeldTicks(0, 48) == 48
    check history.heartHeldTicks(0, 72) == 0
    check history.heartHeldTicks(1, 12) == 0
    check history.heartHeldTicks(1, 48) == 24
    check history.heartHeldTicks(1, 24) == 0
    check history.heartHeldTicks(0, 96) == 24
