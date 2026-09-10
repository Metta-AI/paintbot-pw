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

  test "bombardment cancels pending respawns and removes spare lives":
    visionRulesVersion = 21
    var w = newWorld(2026)
    var commands: array[Seats,Command]
    w.tick = BarrageStartTick
    w.cogs[0].hp = 0
    w.cogs[0].respawn = 1
    w.step(commands)
    check w.cogs[0].hp == 0
    check w.cogs[0].respawn == 0
    check w.equipment[0].lives == 0
    check w.equipment[1].lives == 1
    w.cogs[1].shield = 0
    w.equipment[1].armor = 0
    w.damage(1,2,3)
    for tick in 0..RespawnTicks: w.step(commands)
    check w.cogs[1].hp == 0
    check w.equipment[1].lives == 0

  test "a respawn immediately before bombardment still happens":
    visionRulesVersion = 21
    var w = newWorld(2026)
    var commands: array[Seats,Command]
    w.tick = BarrageStartTick-1
    w.cogs[0].hp = 0
    w.cogs[0].respawn = 1
    w.step(commands)
    check w.cogs[0].hp > 0
    check w.equipment[0].lives == 4
    w.step(commands)
    check w.equipment[0].lives == 1
