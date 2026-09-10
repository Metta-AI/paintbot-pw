import std/unittest
import ../examples/paintbot/sim
suite "Heartwick outside-in barrage":
  test "five minute start, coastal targets, and deterministic elimination":
    visionRulesVersion = 20
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    w.tick = BarrageStartTick-1
    w.step(commands)
    check w.grenades.len == 0
    for tick in 0..<24: w.step(commands)
    check w.grenades.len > 0
    for shell in w.grenades:
      check shell.owner == -1
      check islandMargin(shell.target.x.int,shell.target.z.int) <= barrageDepth(w.tick)
    check barrageDepth(BarrageStartTick+BarrageRampTicks) > barrageDepth(BarrageStartTick)
    for slot in 0..<Seats:
      w.cogs[slot].shield = 0
      w.equipment[slot].armor = 0
      w.equipment[slot].lives = 1
      if team(slot) == 0: w.damage(slot,1,3)
    w.step(commands)
    check w.winner == 1
