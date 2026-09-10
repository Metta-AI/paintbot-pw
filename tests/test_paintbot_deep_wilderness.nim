import std/[unittest,sets,deques]
import ../examples/paintbot/sim
suite "Expanded Heartwick woodland":
  setup:visionRulesVersion=14
  test "area doubles with hills and substantial physical cover":
    let w=newWorld(2026)
    check (maxX()-minX())*(maxZ()-minZ())==8000*4800*2
    check forestLots().len>60
    check terrainHeight(-2100,700)>200
    check terrainHeight(-1700,700)<terrainHeight(-2100,700)
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
  test "a cog walks the outer trail and navigation supports the larger grid":
    var w=newWorld(2026)
    w.cogs[0].pos=point(-1700,700)
    let goal=point(-1700,3300)
    var commands:array[Seats,Command]
    commands[0]=Command(walk:true,goal:goal,aim:goal)
    for i in 0..<240:w.step(commands)
    check distance2(w.cogs[0].pos,goal)<20000
