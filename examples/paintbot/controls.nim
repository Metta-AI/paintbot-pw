## Human intents enter the same command stream as BASIC bots, as in GotA.
import sim

var pending: seq[Command]
var charging = false
var sneaking = false
var destructing = false

proc queueSelfDestruct*() =
  ## Rules 49: blow up on the next command flush.
  destructing = true

proc setSneaking*(held: bool) =
  sneaking = held

proc setGrenadeCharge*(held: bool) =
  charging = held

proc queueWalkTo*(point: Point) =
  pending.add Command(walk: true, goal: point)

proc queueShootAt*(point: Point) =
  pending.add Command(shoot: true, aim: point)

proc flushPlayerCommands*(commands: var openArray[Command], slot: int) =
  if slot notin 0..<Seats:
    pending.setLen(0)
    return
  commands[slot].chargeGrenade = charging
  commands[slot].sneak = sneaking
  if destructing:
    commands[slot].selfDestruct = true
    destructing = false
  for command in pending:
    if command.walk:
      commands[slot].walk = true
      commands[slot].goal = command.goal
    if command.shoot:
      commands[slot].shoot = true
      commands[slot].aim = command.aim
  pending.setLen(0)
