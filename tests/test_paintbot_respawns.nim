import std/unittest
import ../examples/paintbot/sim
suite "Heartwick respawn budget":
  test "three respawns then permanent elimination":
    visionRulesVersion = 19
    var w = newWorld(2026)
    var commands: array[Seats, Command]
    check w.equipment[0].lives == 4
    for death in 1..4:
      w.cogs[0].shield = 0
      w.equipment[0].armor = 0
      w.damage(0, 1, 3)
      check w.cogs[0].hp == 0
      check w.equipment[0].lives == 4-death
      for tick in 0..RespawnTicks: w.step(commands)
      check (w.cogs[0].hp > 0) == (death < 4)
