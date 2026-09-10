import std/unittest
import ../examples/paintbot/sim
suite "Heartwick wilderness":
  setup:
    visionRulesVersion=12
  test "playable area grows by exactly half and connects all four sides":
    let w=newWorld(2026)
    check (maxX()-minX())*(maxZ()-minZ())==Width*Height*3 div 2
    let loop=[point(-400,-200),point(6800,-200),point(6800,4200),point(-400,4200)]
    for i,p in loop:
      let q=loop[(i+1) mod 4]
      check w.traversable(p,q)
      for n in 0..100:
        let step=point(p.x.int+(q.x-p.x).int*n div 100,p.z.int+(q.z-p.z).int*n div 100)
        check not w.blocked(step)
    check terrainHeight(-500,900)>0
  test "cog traverses upper wilderness route":
    var w=newWorld(2026)
    w.cogs[0].pos=point(-400,-200)
    let goal=point(6800,-200)
    var commands:array[Seats,Command]
    commands[0]=Command(walk:true,goal:goal,aim:goal)
    for tick in 0..<400:w.step(commands)
    check distance2(w.cogs[0].pos,goal)<10000
  test "old replay arena stays bounded to the village":
    visionRulesVersion=11
    let w=newWorld(2026)
    check minX()==0
    check w.blocked(point(-400,2000))
    check terrainHeight(-500,900)==0
