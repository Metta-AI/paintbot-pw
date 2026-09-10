import std/[unittest,sets,deques]
import ../examples/paintbot/sim
suite "Heartwick island":
  setup:visionRulesVersion=16
  test "shoreline excludes the corners while retaining woodland cover":
    let w=newWorld(2026)
    check (maxX()-minX())*(maxZ()-minZ())==8000*4800*2
    check forestLots().len>30
    check w.blocked(point(minX()+100,minZ()+100))
    check islandMargin(3200,2000)>0
    check landCoordinates(-1700,700)!=(-1700,700)
    check forestRouteDistance(-1700,700)>0
  test "every heart and supply connects through the woodland":
    let w=newWorld(2026)
    var visited:HashSet[(int,int)]
    var queue:Deque[(int,int)]
    queue.addLast((19,40));visited.incl((19,40))
    while queue.len>0:
      let p=queue.popFirst()
      for d in [(1,0),(-1,0),(0,1),(0,-1)]:
        let n=(p[0]+d[0],p[1]+d[1])
        if n in visited or w.blocked(point(n[0]*50,n[1]*50)):continue
        if not w.traversable(point(p[0]*50,p[1]*50),point(n[0]*50,n[1]*50)):continue
        visited.incl(n);queue.addLast(n)
    for h in w.controlHearts:
      check (h.pos.x.int div 50,h.pos.z.int div 50) in visited
    for p in w.pickups:
      check (p.pos.x.int div 50,p.pos.z.int div 50) in visited
