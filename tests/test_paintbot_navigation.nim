import std/unittest
import ../examples/paintbot/sim
suite "Expanded Heartwick navigation":
  test "map area doubles and every heart can be reached":
    visionRulesVersion=22
    let initial=newWorld(930220186)
    check (maxX()-minX())*(maxZ()-minZ()) == 2*12000*6400
    for target in 0..<initial.controlHearts.len:
      var w=initial
      for i in 1..<Seats:w.cogs[i].hp=0;w.equipment[i].lives=0
      var commands:array[Seats,Command]
      let goal=w.controlHearts[target].pos
      for tick in 0..<1200:
        commands[0]=Command(walk:true,goal:goal)
        w.winner = -1
        w.step(commands)
        if distance2(w.cogs[0].pos,goal)<140*140:break
      check distance2(w.cogs[0].pos,goal)<140*140
  test "body clearance rejects a visible but too narrow route":
    visionRulesVersion=22
    var w=newWorld(1)
    w.cover = @[Cover(x:3100,z:1900,w:200,h:0)]
    let a=point(2900,2130)
    let b=point(3500,2130)
    check w.lineClear(a,b)
    check not w.walkClear(a,b)
