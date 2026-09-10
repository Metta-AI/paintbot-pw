import std/unittest
import ../examples/paintbot/sim
proc arena(): World =
  visionRulesVersion = 6
  result = newWorld(42)
  result.cover = @[]
  result.trenches = @[]
  result.pickups = @[]
  for i in 0..<Seats:
    result.cogs[i].shield = 0
    result.cogs[i].pos = point(100+i*150, 200)
    result.cogs[i].goal = result.cogs[i].pos
suite "Original Paintbot equipment":
  test "grenades charge then release and land on a fixed timer":
    var w = arena()
    w.equipment[0].grenade = true
    w.cogs[0].aim = point(6000, 200)
    var c: array[Seats, Command]
    c[0].chargeGrenade = true
    for tick in 0..<24: w.step(c)
    check w.grenades.len == 0
    c[0].chargeGrenade = false
    w.step(c)
    check w.grenades.len == 1
    check not w.equipment[0].grenade
    let target = w.grenades[0].target
    for tick in 0..<10: w.step(c)
    check w.grenades.len == 0
    check w.blasts[^1].pos == target
  test "blast damages friends and differentiates trenches":
    var w = arena()
    w.trenches = @[Cover(x: 2800, z: 1800, w: 280, h: 280), Cover(x: 3100,
        z: 1800, w: 280, h: 280)]
    w.cogs[0].pos = point(2900, 1900)
    w.equipment[0].armor = 3
    w.cogs[2].pos = point(3101, 1900)
    w.cogs[1].pos = point(2900, 1700)
    w.explode(point(2900, 1900), 4)
    check w.cogs[0].hp == 0
    check w.cogs[2].hp == 2
    check w.cogs[1].hp == 1
  test "spray locks direction and damages each body once":
    var w = arena()
    w.cogs[0].pos = point(3000, 2000); w.cogs[0].goal = w.cogs[0].pos
    w.cogs[1].pos = point(3400, 2000); w.cogs[1].goal = w.cogs[1].pos
    w.equipment[0].sprayCan = true; w.equipment[1].armor = 3
    var c: array[Seats, Command]
    c[0] = Command(shoot: true, aim: point(4000, 2000))
    w.step(c)
    check w.cogs[1].hp == 3
    check w.equipment[1].armor == 0
    c[0].aim = point(2000, 2000)
    for tick in 0..<4: w.step(c)
    check w.cogs[1].hp == 3
    check w.equipment[0].sprayAim.x > 0
    check w.balls.len == 0
  test "cover blocks spray but not grenades":
    var w = arena()
    w.cogs[0].pos = point(3000, 2000); w.cogs[1].pos = point(3400, 2000)
    w.equipment[0].sprayAim = point(850, 0)
    w.cover = @[Cover(x: 3200, z: 1800, w: 100, h: 400)]
    check not w.sprayTouches(0, 1)
    w.explode(point(3400, 2000), 0)
    check w.cogs[1].hp == 1
  test "trench escape is slow but entering is full speed":
    var w = arena()
    w.trenches = @[Cover(x: 2800, z: 1800, w: 280, h: 280)]
    w.cogs[0].pos = point(2940, 1940); w.cogs[0].goal = w.cogs[0].pos
    var c: array[Seats, Command]
    c[0] = Command(walk: true, direct: true, goal: point(4000, 1940))
    w.step(c)
    check w.cogs[0].pos.x == 2945
    w.cogs[0].pos = point(2775, 1940)
    w.step(c)
    check w.cogs[0].pos.x == 2803
  test "death exhausts lives, loses equipment and returns heart":
    var w = arena()
    w.equipment[0].lives = 1; w.equipment[0].grenade = true
    w.cogs[0].carrying = true; w.hearts[1].carrier = 0
    w.damage(0, 1, 3)
    check w.equipment[0].lives == 0
    check not w.equipment[0].grenade
    check w.hearts[1].pos == home(1)
    for tick in 0..<100: w.step(default(array[Seats, Command]))
    check w.cogs[0].hp == 0
  test "one capture wins even if own heart is stolen":
    var w = arena()
    w.cogs[0].pos = home(0); w.cogs[0].goal = home(0); w.cogs[0].carrying = true
    w.hearts[1].carrier = 0; w.hearts[0].carrier = 1
    w.step(default(array[Seats, Command]))
    check w.winner == 0
  test "shield refills armor without healing and medkit heals":
    var w = arena()
    w.cogs[0].hp = 1
    w.pickups = @[Pickup(pos: w.cogs[0].pos, kind: armorPickup)]
    w.step(default(array[Seats, Command]))
    check w.cogs[0].hp == 1
    check w.equipment[0].armor == 3
    check w.pickups[0].readyAt == 720
    w.pickups.add Pickup(pos: w.cogs[0].pos, kind: medkitPickup)
    w.step(default(array[Seats, Command]))
    check w.cogs[0].hp == 3

  test "windup locks aim and simultaneous friendly fire can kill both":
    var w=arena()
    w.cogs[0].pos=point(3000,2000);w.cogs[0].goal=w.cogs[0].pos;w.cogs[0].hp=1
    w.cogs[2].pos=point(3400,2000);w.cogs[2].goal=w.cogs[2].pos;w.cogs[2].hp=1
    var c:array[Seats,Command]
    c[0]=Command(shoot:true,aim:w.cogs[2].pos)
    c[2]=Command(shoot:true,aim:w.cogs[0].pos)
    w.step(c)
    check w.cogs[0].hp==1
    check w.cogs[2].hp==1
    c[0].aim=point(3000,3000)
    c[2].aim=point(3400,3000)
    for tick in 0..<GunWindupTicks:w.step(c)
    check w.cogs[0].hp==0
    check w.cogs[2].hp==0
  test "paint impacts include armor and nonlethal damage but exclude spawn shields":
    var w=arena()
    var impacts=0
    observeHit=proc(tick:int32,victim,attacker:int,pos:Point)=
      inc impacts
      check victim==0
      check attacker==1
    defer:observeHit=nil
    w.equipment[0].armor=2
    w.damage(0,1,1)
    check impacts==1
    check w.cogs[0].hp==3
    w.equipment[0].armor=0
    w.damage(0,1,1)
    check impacts==2
    check w.cogs[0].hp==2
    w.cogs[0].shield=10
    w.damage(0,1,1)
    check impacts==2

  test "wide spray hits off-axis enemies for three HP":
    var w = arena()
    visionRulesVersion = 17
    w.cogs[0].pos = point(3000,2000)
    w.cogs[0].goal = w.cogs[0].pos
    w.cogs[1].pos = point(3500,2250)
    w.cogs[1].goal = w.cogs[1].pos
    w.equipment[0].sprayAim = point(850,0)
    check w.sprayTouches(0,1)
    visionRulesVersion = 16
    check not w.sprayTouches(0,1)
    visionRulesVersion = 17
    w.cogs[2].pos = point(3500,2450)
    check not w.sprayTouches(0,2)
    w.equipment[0].sprayCan = true
    var commands: array[Seats,Command]
    commands[0] = Command(shoot:true,aim:point(4000,2000))
    w.step(commands)
    check w.cogs[1].hp == 0

  test "spray hits when respawn protection expires during a burst":
    var w = arena()
    visionRulesVersion = 18
    w.cogs[0].pos = point(3000,2000)
    w.cogs[0].goal = w.cogs[0].pos
    w.cogs[1].pos = point(3400,2000)
    w.cogs[1].goal = w.cogs[1].pos
    w.cogs[1].shield = 2
    w.equipment[0].sprayCan = true
    var commands: array[Seats,Command]
    commands[0] = Command(shoot:true,aim:point(4000,2000))
    w.step(commands)
    check w.cogs[1].hp == 3
    check (w.equipment[0].sprayHits and 2'u32) == 0
    commands[0].shoot = false
    w.step(commands)
    check w.cogs[1].shield == 0
    check w.cogs[1].hp == 0
    check (w.equipment[0].sprayHits and 2'u32) != 0
