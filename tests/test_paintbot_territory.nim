import std/[unittest, os, tempfiles, sets, deques]
import polyworld/cli
import ../examples/paintbot/[sim,bots]
suite "Heartwick territory control":
  setup:
    visionRulesVersion=13
  test "ten accessible hearts begin with one per team and eight neutral":
    let w=newWorld(2026)
    check w.controlHearts.len==10
    check w.captures==[1'i32,1'i32]
    for i,h in w.controlHearts:
      check h.owner==(if i<2:i.int32 else: -1'i32)
      check not w.blocked(h.pos)
  test "all ten hearts connect through walkable routes":
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
    for heart in w.controlHearts:
      check (heart.pos.x.int div 50,heart.pos.z.int div 50) in visited
  test "touch captures neutral and enemy hearts, contests preserve ownership":
    var w=newWorld(2026)
    for c in w.cogs.mitems:c.hp=0
    w.cogs[0].hp=3
    w.cogs[0].pos=w.controlHearts[2].pos
    w.updateTerritory()
    check w.controlHearts[2].owner==0
    w.cogs[1].hp=3
    w.cogs[1].pos=w.controlHearts[2].pos
    w.updateTerritory()
    check w.controlHearts[2].owner==0
    w.cogs[0].hp=0
    w.updateTerritory()
    check w.controlHearts[2].owner==1
  test "all ten wins and elimination does not":
    var w=newWorld(2026)
    for c in w.cogs.mitems:c.hp=0
    w.updateTerritory()
    check w.winner == -1
    for h in w.controlHearts.mitems:h.owner=0
    w.controlHearts[9].owner=1
    w.updateTerritory()
    check w.winner == -1
    w.cogs[0].hp=3
    w.cogs[0].pos=w.controlHearts[9].pos
    w.updateTerritory()
    check w.winner==0
    check w.captures==[10'i32,0'i32]
  test "deaths always respawn without consuming lives":
    var w=newWorld(2026)
    w.cogs[0].shield=0
    w.equipment[0].lives=1
    w.damage(0,1,99)
    var cmds:array[Seats,Command]
    for tick in 0..RespawnTicks:w.step(cmds)
    check w.cogs[0].hp>0
    check w.equipment[0].lives==StartingLives
  test "BASIC heart coordinate accessors and ownership remain distinct":
    let w=newWorld(2026)
    let (file,path)=createTempFile("territory-policy-", ".bas")
    file.write("walkTo(controlX(2),controlY(2))\nlookAt(controlOwner(2),heartCount())")
    file.close()
    defer:removeFile(path)
    let players=loadBots(@[BotGroup(path:path,count:Seats)])
    let commands=players.decide(w)
    check commands[0].goal==w.controlHearts[2].pos
    check commands[0].aim==point(-1,10)
