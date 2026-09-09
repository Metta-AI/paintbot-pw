' Call to Adventure reference hero controller.
'
' Each hero runs an isolated copy of this program every decision tick.
' Movement and combat are high-level commands; Nim owns pathfinding and
' records only accepted actions in the replay.
'
' Only stop after a command that actually started. A failed attack or
' pickup used to halt the hero in place. On the vault, walkTo now heads
' for remaining monsters the party has not seen yet, then the stairs home.

if hp * 2 <= maxHp then
  if useItem(0) <> 0 then
    stop
  end if
  if useItem(1) <> 0 then
    stop
  end if
end if

friend = woundedAlly()
if friend <> 0 then
  if healTarget(friend) <> 0 then
    stop
  end if
end if

enemy = nearestEnemy()
if enemy <> 0 then
  if attackTarget(enemy) <> 0 then
    stop
  end if
end if

treasure = nearestLoot()
if treasure <> 0 then
  if pickupTarget(treasure) <> 0 then
    stop
  end if
end if

discardResult = walkTo(objectiveLevel, objectiveX, objectiveY)
