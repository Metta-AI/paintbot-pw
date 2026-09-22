import std/[unittest, math]
import ../examples/paintbot/[sim, neural_contract]

suite "Neural policy contract":
  setup:
    visionRulesVersion = 36
  test "fixed finite observations for every seat and scratch buffers are cleared":
    let w = newWorld(2026)
    var obs: array[ObservationSize,float32]
    for slot in 0..<Seats:
      for i in 0..<obs.len: obs[i] = NaN.float32
      encodeObservation(w,slot,obs)
      for value in obs: check classify(value) notin {fcNan,fcInf,fcNegInf}
      for i in 442..<448: check obs[i] == 0
      check obs[19] == float32(slot div 2)/7
  test "hidden opponents cannot change the actor observation":
    var w = newWorld(7)
    w.cogs[0].pos = point(3200,2000)
    w.cogs[0].aim = point(6200,2000)
    w.cogs[1].pos = point(-4000,2000)
    check not w.visible(0,1)
    var before,after: array[ObservationSize,float32]
    encodeObservation(w,0,before)
    w.cogs[1].pos = point(-3900,2100)
    w.cogs[1].hp = 1
    w.equipment[1].armor = 3
    check not w.visible(0,1)
    encodeObservation(w,0,after)
    check before == after
  test "unavailable pickup locations cannot leak through observations or actions":
    var w = newWorld(7)
    w.pickups[0].readyAt = w.tick+100
    var before,after: array[ObservationSize,float32]
    encodeObservation(w,0,before)
    let action = [11'i32,0,0,0,0]
    let first = decodeActions(w,0,action)
    w.pickups[0].pos = point(1000,1000)
    encodeObservation(w,0,after)
    check before == after
    check decodeActions(w,0,action) == first
    check first.goal == w.cogs[0].pos
  test "categorical and argmax deployment decode identically":
    let w = newWorld(22)
    let actions = [3'i32,18,1,1,0]
    var logits: array[LogitSize,float32]
    var offset = 0
    for i,size in ActionSizes:
      logits[offset+actions[i].int] = 10
      offset += size
    check decodeActions(w,0,actions) == decodeLogits(w,0,logits)
    check decodeActions(w,0,actions).goal == w.controlHearts[2].pos
  test "dead seats and invalid network outputs are handled explicitly":
    var w = newWorld(9)
    w.cogs[0].hp = 0
    let dead = decodeActions(w,0,[1'i32,1,1,1,1])
    check not dead.walk and not dead.shoot and not dead.chargeGrenade
    expect ValueError: discard decodeActions(w,0,[51'i32,0,0,0,0])
    var logits: array[LogitSize,float32]
    logits[1] = Inf.float32
    expect ValueError: discard decodeLogits(w,0,logits)
