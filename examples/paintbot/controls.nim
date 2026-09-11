## Human intents enter the same command stream as BASIC bots, as in GotA.
import sim

var pending: seq[Command]

proc queueWalkTo*(point: Point) =
  pending.add Command(walk: true, goal: point)

proc queueShootAt*(point: Point) =
  pending.add Command(shoot: true, aim: point)

proc flushPlayerCommands*(commands: var array[Seats, Command], slot: int) =
  if slot notin 0..<Seats:
    pending.setLen(0)
    return
  for command in pending:
    if command.walk:
      commands[slot].walk = true
      commands[slot].goal = command.goal
    if command.shoot:
      commands[slot].shoot = true
      commands[slot].aim = command.aim
  pending.setLen(0)
