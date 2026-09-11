import std/[unittest, os]
import ../examples/paintbot/[sim, game, analysis]
import polyworld/tapes

suite "Paintbot replay analysis and metadata":
  test "checkpoint seeks preserve all recorded world hashes":
    recording=Recording(seed:2026,endTick:MatchTicks)
    world=newWorld(recording.seed)
    var commands:array[Seats,Command]
    for i in 0..<Seats:
      commands[i]=Command(walk:true,goal:home(1-team(i)))
    for tick in 0..<720:
      world.step(commands)
      recording.frames.add Frame(commands:commands,hash:world.stateHash())
    replayMode=true
    let index=indexReplay()
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
  test "v1 remains readable and v25 preserves public metadata":
    type Legacy=object
      seed:int32
      frames:seq[Frame]
    let path=getTempDir()/"paintbot-replay-metadata-test.replay"
    defer:removeFile(path)
    saveReplayFile(path,"paintbot_pw",1,Legacy(seed:2026,frames: @[]))
    check loadRecording(path).names[0]=="Ember 1"
    recording.names[0]="Daveey <test>"
    recording.communications = @[Communication(tick:1,slot:0,text:"Guard the heart ♥")]
    saveReplayFile(path,"paintbot_pw",25,recording)
    let loaded=loadRecording(path)
    check loaded.names[0]=="Daveey <test>"
    check loaded.communications[0].text=="Guard the heart ♥"
    recording.communications[0].slot=16
    saveReplayFile(path,"paintbot_pw",25,recording)
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
