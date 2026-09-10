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

  test "allies and opponents cannot walk through each other":
    for other in [1, 2]:
      var w = newWorld(1)
      w.cover = @[]
      w.cogs[0].pos = point(3000, 2000)
      w.cogs[other].pos = point(3400, 2000)
      w.cogs[0].goal = w.cogs[0].pos
      w.cogs[other].goal = w.cogs[other].pos
      var commands: array[Seats, Command]
      commands[0] = Command(walk: true, direct: true, goal: point(4000, 2000))
      commands[other] = Command(walk: true, direct: true, goal: point(2000, 2000))
      for tick in 0..<100:
        w.step(commands)
        check distance2(w.cogs[0].pos, w.cogs[other].pos) >= (2*Radius).int64*(2*Radius)
        check w.cogs[0].pos.x < w.cogs[other].pos.x

  test "respawn finds space around an occupied spawn":
    var w = newWorld(1)
    let spawnPoint = w.cogs[0].pos
    w.cogs[2].pos = spawnPoint
    w.cogs[2].goal = spawnPoint
    w.cogs[0].hp = 0
    w.cogs[0].respawn = 1
    w.step(default(array[Seats, Command]))
    check w.cogs[0].hp == 3
    check distance2(w.cogs[0].pos, w.cogs[2].pos) >= (2*Radius).int64*(2*Radius)

  test "sustained firing is limited to one shot per second":
    var w = newWorld(1)
    w.cover = @[]
    var commands: array[Seats, Command]
    commands[0] = Command(shoot: true, aim: point(3200, 1100))
    var shots = 0
    for tick in 0..<TickRate*3:
      w.step(commands)
      if w.cogs[0].cooldown == FireCooldownTicks: inc shots
    check shots == 3

  test "vision is a forward cone for allies and enemies":
    var w = newWorld(1)
    w.cover = @[]
    w.cogs[0].pos = point(3000, 2000)
    w.cogs[0].aim = point(4000, 2000)
    for other in [1, 2]:
      w.cogs[other].pos = point(3500, 2000)
      check w.visible(0, other)
      w.cogs[other].pos = point(2500, 2000)
      check not w.visible(0, other)
      w.cogs[other].pos = point(3000, 2500)
      check not w.visible(0, other)
      w.cogs[other].pos = point(3500, 2800)
      check w.visible(0, other)
      w.cogs[other].pos = point(3500, 2900)
      check not w.visible(0, other)
    check w.visible(0, 0)

  test "turning without shooting changes vision":
    var w = newWorld(1)
    w.cover = @[]
    w.cogs[0].pos = point(3000, 2000)
    w.cogs[0].goal = w.cogs[0].pos
    w.cogs[0].aim = point(4000, 2000)
    w.cogs[1].pos = point(2500, 2000)
    w.cogs[1].goal = w.cogs[1].pos
    check not w.visible(0, 1)
    var commands: array[Seats, Command]
    commands[0].aim = point(2000, 2000)
    w.step(commands)
    check w.visible(0, 1)
    check w.balls.len == 0
