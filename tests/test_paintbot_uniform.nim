import std/[unittest, os]
import polyworld/cli
import ../examples/paintbot/[sim, bots]

proc arena(): World =
  visionRulesVersion = 27
  result = newWorld(42)
  result.cover = @[]
  result.trenches = @[]
  result.pickups = @[]
  for i in 0..<Seats:
    result.cogs[i].shield = 0
    result.cogs[i].pos = point(100+i*150, 200)
    result.cogs[i].goal = result.cogs[i].pos

suite "Uniform disguises and friendly fire":
  test "pickup spoofs an opposing seat, preserves self and scoring, and respawns":
    var w = arena()
    w.pickups = @[Pickup(pos:w.cogs[0].pos,kind:uniformPickup)]
    w.scoreTicks = [24'i32, 48'i32]
    var commands: array[Seats,Command]
    w.step(commands)
    check w.uniforms[0]
    check w.apparentTeam(0) == 1
    check w.observedTeam(0,0) == 0
    check w.observedSeat(2,0) == 1
    check w.observedSeat(1,0) == 3
    check w.observedSeat(0,0) == 0
    check w.scores()[0] == w.scores()[2]
    check w.scores()[0] < w.scores()[1]
    check w.pickups[0].readyAt > w.tick
  test "gun and spray attacks reveal immediately":
    for spray in [false,true]:
      var w = arena()
      w.uniforms[0] = true
      w.equipment[0].sprayCan = spray
      var commands: array[Seats,Command]
      commands[0] = Command(shoot:true,aim:point(3000,200))
      w.step(commands)
      check not w.uniforms[0]
  test "grenade charging retains disguise and throwing reveals":
    var w = arena()
    w.uniforms[0] = true
    w.equipment[0].grenade = true
    var commands: array[Seats,Command]
    commands[0].chargeGrenade = true
    w.step(commands)
    check w.uniforms[0]
    commands[0].chargeGrenade = false
    w.pickups = @[Pickup(pos:w.cogs[0].pos,kind:uniformPickup)]
    w.step(commands)
    check not w.uniforms[0]
  test "friendly damage affects normal and disguised teammates equally":
    for disguised in [false,true]:
      var w = arena()
      w.uniforms[2] = disguised
      w.damage(2,0,3)
      check w.cogs[2].hp == 0
      check not w.uniforms[2]
  test "uniform state affects only new replay hashes":
    var w = arena()
    let current = w.stateHash()
    w.uniforms[0] = true
    check current != w.stateHash()
    visionRulesVersion = 25
    let prior = w.stateHash()
    w.uniforms[0] = false
    check prior == w.stateHash()
    check w.apparentTeam(0) == 0
  test "historical worlds do not spawn uniform stations":
    visionRulesVersion = 25
    let w = newWorld(42)
    for p in w.pickups: check p.kind != uniformPickup

  test "BASIC observations hide the real seat and expose a valid opposing identity":
    var w = arena()
    for i in 0..<Seats: w.cogs[i].hp = 0
    w.cogs[2].hp = 3
    w.cogs[0].hp = 3
    w.cogs[2].pos = point(3000,2000)
    w.cogs[2].aim = point(5000,2000)
    w.cogs[0].pos = point(3400,2000)
    w.uniforms[0] = true
    let path = getTempDir()/"paintbot-uniform-test.bas"
    defer: removeFile(path)
    writeFile(path,"if selfId = 2 and visible(1) and not visible(0) and playerTeam(1) = 1 then\n  walkTo(playerX(1), playerY(1))\nend if\n")
    let players = loadBots(@[BotGroup(path:path,count:Seats)])
    let commands = players.decide(w)
    check commands[2].walk
    check commands[2].goal == w.cogs[0].pos
