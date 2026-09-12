dim avoidUntil(10)
' Drop an unreachable assignment after three seconds without meaningful progress.
if worldTick mod 72 = 0 then
  dxProgress = selfX - progressX
  dyProgress = selfY - progressY
  if dxProgress * dxProgress + dyProgress * dyProgress < 40000 and objective >= 0 and objective < 10 then
    dxHeart = controlX(objective) - selfX
    dyHeart = controlY(objective) - selfY
    if dxHeart * dxHeart + dyHeart * dyHeart > 19600 then
      avoidUntil(objective) = worldTick + 360
    end if
  end if
  progressX = selfX
  progressY = selfY
end if
' BASIC translation of the Paintbot baseline's objective and combat priorities.
' Persistent tracks supply short lead prediction; every enemy query is fog gated.
dim pickupMemoryX(32)
dim pickupMemoryY(32)
dim pickupMemoryKind(32)
dim pickupMemoryTick(32)
dim oldX(16)
dim oldY(16)
dim lastSeen(16)
best = -1
bestCost = 2147483647
thief = -1
i = 0
while i < 16
  if playerTeam(i) <> selfTeam and visible(i) then
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
    if role < 2 and worldTick mod 720 < 480 then
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
if worldTick mod 360 = selfId * 21 then
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

' Remember seen supplies and deliberately equip before taking a fighting position.
i = 0
' Territory replaces flag errands: spread across neutral and enemy hearts.
if heartCount() > 0 then
  objective = -1
  objectiveCost = 2147483647
  j = 0
  while j < heartCount()
    if controlOwner(j) <> selfTeam and avoidUntil(j) <= worldTick then
      dx = controlX(j) - selfX
      dy = controlY(j) - selfY
      cost = dx * dx + dy * dy
      if j = 2 + (selfId / 2) mod 8 then
        cost = cost - 12000000
      end if
      if controlOwner(j) = -1 then
        cost = cost - 1000000
      end if
      if cost < objectiveCost then
        objective = j
        objectiveCost = cost
      end if
    end if
    j = j + 1
  wend
  if objective >= 0 then
    walkTo(controlX(objective),controlY(objective))
    if best < 0 then
      lookAt(controlX(objective),controlY(objective))
    end if
  end if
end if

i = 0
while i < pickupCount() and i < 32
  if pickupVisible(i) then
    pickupMemoryX(i) = pickupX(i)
    pickupMemoryY(i) = pickupY(i)
    pickupMemoryKind(i) = pickupKind(i)
    pickupMemoryTick(i) = worldTick + 1
  end if
  i = i + 1
wend
if not carrying and thief < 0 then
  nearest = -1
  nearestCost = 4840000
  j = 0
  while j < pickupCount() and j < 32
    if pickupMemoryTick(j) > 0 and worldTick - pickupMemoryTick(j) < 120 then
      kind = pickupMemoryKind(j)
      wanted = (kind = 0 and not hasGrenade) or (kind = 1 and not hasSpray and (selfId / 2) mod 2 = 0) or (kind = 2 and selfHp < 3) or (kind = 3 and armorHp < 3) or (kind = 4 and not hasUniform())
      if wanted then
        dx = pickupMemoryX(j) - selfX
        dy = pickupMemoryY(j) - selfY
        cost = dx * dx + dy * dy
        if cost < 10000 and not pickupVisible(j) then
          pickupMemoryTick(j) = 0
        else
          if cost < nearestCost then
            nearest = j
            nearestCost = cost
          end if
        end if
      end if
    end if
    j = j + 1
  wend
  if nearest >= 0 and (best < 0 or bestCost > 1440000 or selfHp = 1) then
    walkTo(pickupMemoryX(nearest), pickupMemoryY(nearest))
  end if
end if
' Match charge to distance rather than overshooting every close target.
if hasGrenade and best >= 0 then
  nx = playerX(best)
  ny = playerY(best)
  dx = nx - selfX
  dy = ny - selfY
  d2 = dx * dx + dy * dy
  safe = 1
  i = 0
  while i < 16
    if playerTeam(i) = selfTeam and visible(i) then
      fx = playerX(i) - nx
      fy = playerY(i) - ny
      if fx * fx + fy * fy < 122500 then
        safe = 0
      end if
    end if
    i = i + 1
  wend
  if safe and d2 > 160000 and d2 < 1638400 then
    lo = 0
    hi = 1280
    while hi - lo > 1
      mid = (hi + lo) / 2
      if mid * mid < d2 then
        lo = mid
      else
        hi = mid
      end if
    wend
    need = (hi - 150) * 24 / 1130
    if need < 1 then
      need = 1
    end if
    lookAt(nx, ny)
    chargeGrenade(grenadeCharge < need)
    if grenadeCharge >= need then
      shout(strNew("Grenade out!"))
    end if
  end if
end if

' Two quartermasters scout the back corners before joining the fight.
if heartCount() = 0 and not carrying and not hasGrenade and worldTick mod 960 < 240 then
  role = (selfId / 2) mod 8
  if role = 2 or role = 3 then
    sx = 300
    sy = 300
    if role = 3 then
      sy = 3700
    end if
    if selfTeam = 1 then
      sx = 6400 - sx
      sy = 4000 - sy
    end if
    walkTo(sx,sy)
    if best < 0 then
      lookAt(sx,sy)
    end if
  end if
end if

' The close-assault cog scouts the spray supply before approaching enemies.
if heartCount() = 0 and not carrying and not hasSpray and (selfId / 2) mod 8 = 0 and worldTick mod 960 < 240 then
  sx = 600
  sy = 1000
  if selfTeam = 1 then
    sx = 5800
    sy = 3000
  end if
  walkTo(sx,sy)
  lookAt(sx,sy)
end if

' Equipped assault cogs leave supply routes and close with the opposing team.
if heartCount() = 0 and not carrying and (hasSpray or hasGrenade) then
  if best >= 0 then
    walkTo(playerX(best), playerY(best))
  else
    walkTo(heartX,heartY)
    lookAt(heartX,heartY)
  end if
end if

' Alternate wilderness wings approach the heart from behind the village.
role = (selfId / 2) mod 8
if heartCount() = 0 and mapMinX() < 0 and (role = 4 or role = 5) and not carrying then
  if worldTick mod 1200 = 0 then
    flankStage = 0
  end if
  fy = mapMinY() + 200
  if role = 5 then
    fy = mapMaxY() - 200
  end if
  if flankStage = 0 then
    fx = mapMinX() + 400
    if selfTeam = 1 then
      fx = mapMaxX() - 400
    end if
  else
    fx = mapMaxX() - 400
    if selfTeam = 1 then
      fx = mapMinX() + 400
    end if
  end if
  dx = selfX - fx
  dy = selfY - fy
  if dx * dx + dy * dy < 90000 then
    flankStage = flankStage + 1
  end if
  if flankStage < 2 then
    walkTo(fx,fy)
    if best < 0 then
      lookAt(fx,fy)
    end if
  end if
end if

' React to approximate sound bearings only when no opponent is visible.
if best < 0 and soundCount() > 0 then
  soundBest = -1
  soundCost = 2147483647
  j = 0
  while j < soundCount()
    cost = soundAge(j)
    if soundKind(j) = 1 or soundKind(j) = 2 then
      cost = cost - 48
    end if
    if cost < soundCost then
      soundBest = j
      soundCost = cost
    end if
    j = j + 1
  wend
  bearing = soundDirection(soundBest)
  dxSound = 0
  dySound = 0
  if bearing = 0 or bearing = 1 or bearing = 7 then
    dxSound = 1000
  end if
  if bearing = 3 or bearing = 4 or bearing = 5 then
    dxSound = -1000
  end if
  if bearing = 1 or bearing = 2 or bearing = 3 then
    dySound = 1000
  end if
  if bearing = 5 or bearing = 6 or bearing = 7 then
    dySound = -1000
  end if
  lookAt(selfX + dxSound, selfY + dySound)
  if objective >= 0 and objective < heartCount() then
    dxSound = controlX(objective) - selfX
    dySound = controlY(objective) - selfY
    if dxSound * dxSound + dySound * dySound < 810000 then
      sneak(1)
    end if
  end if
end if
