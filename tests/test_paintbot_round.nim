import std/unittest
import ../examples/paintbot/sim
suite "Rounded cover":
  test "corners outside the circle remain walkable and visible":
    var w: World
    w.cover = @[Cover(x:1000,z:1000,w:400,h:0)]
    check w.blocked(point(1200,1200),0)
    check not w.blocked(point(1005,1005),0)
    check w.lineClear(point(950,1005),point(1100,1005))
    check not w.lineClear(point(900,1200),point(1500,1200))
    check w.blocked(point(1410,1200),Radius)
  test "v7 keeps rectangles while v8 records round cover":
    visionRulesVersion=7
    check newWorld(2026).cover[0].h > 0
    visionRulesVersion=8
    let w = newWorld(2026)
    for c in w.cover: check c.h == 0
    for p in w.pickups: check not w.blocked(p.pos)
    for c in w.cogs: check not w.blocked(c.pos)
