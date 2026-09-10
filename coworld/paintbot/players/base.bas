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
    if cost < bestCost and dx * dx + dy * dy <= 27562500 then
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
    role = (selfId / 2) mod 8
    gx = heartX
    gy = heartY
    if role < 2 then
      gx = 1950 + role * 200
      gy = 1000
      if selfTeam = 1 then
        gx = 6400 - gx
        gy = 4000 - gy
      end if
    else
      if role < 6 then
        if selfX < 3800 and selfTeam = 0 or selfX > 2600 and selfTeam = 1 then
          gx = 3200
          gy = 500 + (role - 2) * 1000
        end if
      end if
    end if
    if best >= 0 and bestCost < 9000000 and bestCost > 640000 and hasSpray = 0 and (role >= 2 or terrainHeight(selfX,selfY) > 200) then
      gx = selfX
      gy = selfY
    end if
    if hasSpray and best >= 0 then
      gx = playerX(best)
      gy = playerY(best)
    end if
    walkTo(gx, gy)
  end if
end if
if best < 0 then
  scan = (worldTick / 24 + selfId) mod 4
  if scan = 0 then
    lookAt(selfX + 2000, selfY)
  end if
  if scan = 1 then
    lookAt(selfX, selfY + 2000)
  end if
  if scan = 2 then
    lookAt(selfX - 2000, selfY)
  end if
  if scan = 3 then
    lookAt(selfX, selfY - 2000)
  end if
  if heardCount() > 0 then
    lookAt(heardX(0), heardY(0))
  end if
end if
if worldTick mod 120 = selfId * 7 then
  if best >= 0 then
    shout(strNew("Contact! Cover this lane."))
  else
    if terrainHeight(selfX,selfY) > 100 then
      shout(strNew("Holding high ground."))
    else
      shout(strNew("Moving on the flank."))
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
  if hasSpray = 0 or bestCost < 640000 then
    shootAt(tx, ty)
  else
    lookAt(tx, ty)
  end if
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
' Collect nearby equipment and use charged grenades within throwing distance.
if not carrying then
  nearest = -1
  nearestCost = 490000
  j = 0
  while j < pickupCount()
    if pickupVisible(j) then
      kind = pickupKind(j)
      wanted = (kind = 0 and not hasGrenade) or (kind = 1 and not hasSpray) or (kind = 2 and selfHp < 3) or (kind = 3 and armorHp < 3)
      if wanted then
        dx = pickupX(j) - selfX
        dy = pickupY(j) - selfY
        cost = dx * dx + dy * dy
        if cost < nearestCost then
          nearest = j
          nearestCost = cost
        end if
      end if
    end if
    j = j + 1
  wend
  if nearest >= 0 then
    walkTo(pickupX(nearest), pickupY(nearest))
  end if
end if
if hasGrenade and best >= 0 and bestCost < 1638400 then
  chargeGrenade(grenadeCharge < 24)
end if
