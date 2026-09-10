' BASIC translation of the Paintbot baseline's objective and combat priorities.
' Persistent tracks supply short lead prediction; every enemy query is fog gated.
dim oldX(16)
dim oldY(16)
dim lastSeen(16)
best = -1
bestCost = 2147483647
thief = -1
i = 0
while i < 16
  if i mod 2 <> selfTeam and visible(i) then
    dx = playerX(i) - selfX
    dy = playerY(i) - selfY
    cost = dx * dx + dy * dy - (3 - playerHp(i)) * 160000
    if playerCarrying(i) then
      cost = cost - 2500000
      thief = i
    end if
    if cost < bestCost then
      best = i
      bestCost = cost
    end if
  end if
  i = i + 1
wend
' Carrying outranks every objective; recover our own heart when scoring is blocked.
if carrying then
  if ownHeartStolen and thief >= 0 then
    walkTo(playerX(thief), playerY(thief))
  else
    walkTo(homeX, homeY)
  end if
else
  if thief >= 0 then
    walkTo(playerX(thief), playerY(thief))
  else
    ' Two guards per side, six raiders. Guards reinforce nearby engagements.
    if selfId < 4 then
      if best >= 0 and bestCost < 3240000 then
        walkTo(playerX(best), playerY(best))
      else
        if selfTeam = 0 then
          walkTo(homeX + 600, homeY)
        else
          walkTo(homeX - 600, homeY)
        end if
      end if
    else
      walkTo(heartX, heartY)
    end if
  end if
end if
if best >= 0 then
  tx = playerX(best)
  ty = playerY(best)
  if lastSeen(best) = worldTick - 1 then
    tx = tx + (tx - oldX(best)) * 4
    ty = ty + (ty - oldY(best)) * 4
  end if
  shootAt(tx, ty)
end if
i = 0
while i < 16
  if visible(i) then
    oldX(i) = playerX(i)
    oldY(i) = playerY(i)
    lastSeen(i) = worldTick
  end if
  i = i + 1
wend
