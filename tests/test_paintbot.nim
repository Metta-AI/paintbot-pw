import std/unittest
import ../examples/paintbot/sim
suite "Paintbot rules":
  test "seeded arena is deterministic":
    var a=newWorld(42);var b=newWorld(42)
    for i in 0..<100:
      a.step(default(array[Seats,Command]));b.step(default(array[Seats,Command]))
    check a.stateHash()==b.stateHash()
  test "cover blocks fire":
    let w=newWorld(42);let c=w.cover[0]
    check not w.lineClear(point(c.x.int-20,c.z.int+50),point(c.x.int+c.w.int+20,c.z.int+50))
  test "three tags drop the heart and respawn":
    var w=newWorld(1);w.cogs[0].shield=0
    w.cogs[0].carrying=true;w.hearts[1].carrier=0
    for i in 0..<3:w.hit(0,1)
    check w.cogs[0].hp==0
    check w.hearts[1].carrier== -1
    for i in 0..<RespawnTicks:w.step(default(array[Seats,Command]))
    check w.cogs[0].hp==3
    check w.cogs[0].shield>0
  test "capture requires own heart and three captures win":
    var w=newWorld(1)
    for n in 0..<3:
      w.cogs[0].pos=home(0);w.cogs[0].goal=home(0)
      w.cogs[0].carrying=true;w.hearts[1].carrier=0
      w.step(default(array[Seats,Command]))
    check w.winner==0
    check w.scores()[0]==1
    check w.scores()[1]==0
  test "hidden enemies are not visible":
    let w=newWorld(2)
    check not w.visible(0,1)
    check w.visible(0,2)

  test "a stolen home heart prevents scoring":
    var w = newWorld(1)
    w.cogs[0].pos = home(0)
    w.cogs[0].goal = home(0)
    w.cogs[0].carrying = true
    w.hearts[1].carrier = 0
    w.cogs[1].carrying = true
    w.hearts[0].carrier = 1
    w.step(default(array[Seats, Command]))
    check w.captures[0] == 0
    check w.cogs[0].carrying
  test "dropped heart automatically returns":
    var w = newWorld(1)
    w.hearts[0].pos = point(3200, 200)
    w.hearts[0].returnAt = 2
    for i in 0..<3: w.step(default(array[Seats, Command]))
    check w.hearts[0].pos == home(0)
