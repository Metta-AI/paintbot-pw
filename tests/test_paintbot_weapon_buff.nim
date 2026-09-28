import std/[unittest]
import ../examples/paintbot/[sim, game]

proc clearField(w: var World) =
  w.pickups.setLen(0)
  for i in 0..<Seats:
    w.cogs[i].shield = 0
    w.equipment[i].armor = 0

proc openSpot(w: World, seat: int): Point =
  ## A dry, trench-free spot next to the seat's spawn.
  result = w.cogs[seat].pos
  doAssert w.trenchAt(result) < 0

proc blastAt(rules, distance: int): int32 =
  visionRulesVersion = rules
  var w = newWorld(2026)
  w.clearField()
  let victim = 1
  let p = w.openSpot(victim)
  w.explode(point(p.x.int+distance, p.z.int), 0)
  w.cogs[victim].hp

suite "Stronger grenades and spray (rules 40)":
  teardown:
    visionRulesVersion = 41
    replayRulesVersion = 41
  test "live rules are 41 (rules 40 weapons, plus generated maps)":
    check visionRulesVersion == 41
    check replayRulesVersion == 41
  test "an open-ground blast deals 3 from rules 40, 2 before":
    check blastAt(39, 100) == 1
    check blastAt(40, 100) == 0
  test "the blast reaches 360 (+ body radius) from rules 40, 270 before":
    check blastAt(39, 340) == 3
    check blastAt(40, 340) == 0
    check blastAt(40, 420) == 3
  test "spray recovery is 8 ticks from rules 40, 20 before":
    visionRulesVersion = 39
    check sprayRecoveryTicks() == 20
    check grenadeBlastRadius() == 270
    visionRulesVersion = 40
    check sprayRecoveryTicks() == 8
    check grenadeBlastRadius() == 360
  test "a spray burst sets the rules-40 cooldown":
    visionRulesVersion = 40
    var w = newWorld(2026)
    w.clearField()
    let seat = 0
    w.equipment[seat].sprayCan = true
    var commands: array[Seats, Command]
    commands[seat] = Command(shoot: true, aim: home(1))
    w.cogs[seat].aim = home(1)
    w.step(commands)
    check w.equipment[seat].burst > 0
    check w.equipment[seat].sprayCooldown in (SprayTicks+8-2)..(SprayTicks+8)
  test "the spray cone is wider from rules 40":
    visionRulesVersion = 39
    check sprayHalfWidth(500) == 300
    visionRulesVersion = 40
    check sprayHalfWidth(500) == 400
