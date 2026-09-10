import std/[unittest, os]
import ../examples/paintbot/[sim, game, analysis]
import polyworld/tapes

suite "Paintbot replay analysis and metadata":
  test "checkpoint seeks preserve all recorded world hashes":
    recording=Recording(seed:2026)
    world=newWorld(recording.seed)
    var commands:array[Seats,Command]
    for i in 0..<Seats:
      commands[i]=Command(walk:true,goal:home(1-team(i)))
    for tick in 0..<720:
      world.step(commands)
      recording.frames.add Frame(commands:commands,hash:world.stateHash())
    replayMode=true
    let index=indexReplay()
    for tick in [719,1,240,480,721,0,333,600,240]:
      index.restore(tick)
      let target=min(tick,720)
      check world.tick==target
      check world.stateHash()==(if target==0:newWorld(2026).stateHash() else:recording.frames[target-1].hash)
  test "v1 remains readable and v6 preserves public metadata":
    type Legacy=object
      seed:int32
      frames:seq[Frame]
    let path=getTempDir()/"paintbot-replay-metadata-test.replay"
    defer:removeFile(path)
    saveReplayFile(path,"paintbot_pw",1,Legacy(seed:2026,frames: @[]))
    check loadRecording(path).names[0]=="Ember 1"
    recording.names[0]="Daveey <test>"
    recording.communications = @[Communication(tick:1,slot:0,text:"Guard the heart ♥")]
    saveReplayFile(path,"paintbot_pw",6,recording)
    let loaded=loadRecording(path)
    check loaded.names[0]=="Daveey <test>"
    check loaded.communications[0].text=="Guard the heart ♥"
    recording.communications[0].slot=16
    saveReplayFile(path,"paintbot_pw",6,recording)
    expect ReplayError:discard loadRecording(path)
  test "analysis refuses corrupt replay inputs":
    recording.communications = @[]
    recording.frames[13].hash=0
    expect ReplayError:discard indexReplay()
