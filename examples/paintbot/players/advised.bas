' Paintbot PW example: a BASIC cog that asks the advisor oracle for a judgment.
' Every 48 ticks (2 s) the cog sends one coarse state and two typed questions; the answer
' lands on a later tick and steers it between capturing the nearest unowned heart and
' standing guard on the nearest owned one. Without an oracle (oracleAvailable() = 0) it
' captures, exactly like a plain script. See coworld/paintbot/guide.md, "BASIC seats".
owned = 0
free = 0
nearestFree = -1
nearestFreeD = 2000000000
nearestOwned = -1
nearestOwnedD = 2000000000
i = 0
while i < heartCount()
  dx = controlX(i) - selfX
  dy = controlY(i) - selfY
  d = dx * dx + dy * dy
  if controlOwner(i) = selfTeam then
    owned = owned + 1
    if d < nearestOwnedD then
      nearestOwnedD = d
      nearestOwned = i
    end if
  else
    free = free + 1
    if d < nearestFreeD then
      nearestFreeD = d
      nearestFree = i
    end if
  end if
  i = i + 1
wend

' Ask: one request in flight per cog, at most one every 48 ticks.
if request = 0 and worldTick - lastAsk >= 48 then
  oracleState(strNew("tick"), worldTick)
  oracleState(strNew("hp"), selfHp)
  oracleState(strNew("lives_left"), livesLeft)
  oracleState(strNew("hearts_owned_by_us"), owned)
  oracleState(strNew("hearts_not_ours"), free)
  oracleState(strNew("armor"), armorHp)
  oracleNote(strNew("Owned hearts score every second with nobody on them; a team with no lives left loses."))
  oracleQuestion(strNew("guard"), 0, strNew("Should this cog stand guard on one of our hearts instead of capturing another?"))
  oracleCriterion(strNew("guard"), strNew("true"), strNew("We hold most hearts, or this cog is hurt or on its last life."))
  oracleCriterion(strNew("guard"), strNew("false"), strNew("Unowned hearts remain and this cog is fit to take one."))
  oracleQuestion(strNew("caution"), 1, strNew("How careful should this cog be about fights right now?"))
  oracleCriterion(strNew("caution"), strNew(""), strNew("Take every fight."))
  oracleCriterion(strNew("caution"), strNew(""), strNew("Balanced."))
  oracleCriterion(strNew("caution"), strNew(""), strNew("Refuse fights; slip away from enemy groups."))
  request = oracleAsk()
  if request > 0 then
    lastAsk = worldTick
  end if
end if

' Collect: keep acting on the last answer while a request is pending.
if request > 0 then
  status = oraclePoll(request)
  if status > 0 then
    guard = oracleAnswer(request, strNew("guard"))
    caution = oracleAnswer(request, strNew("caution"))
    shout(strCat(strCat(strNew("guard "), strFromInt(guard)), strCat(strNew(" caution "), strFromInt(caution))))
    print "tick "; worldTick; " guard "; guard; " caution "; caution
    request = 0
  else
    if status < 0 then
      request = 0
    end if
  end if
end if

' Act: guard when the oracle is at least 50% for it and we own a heart; otherwise capture.
if guard >= 500 and nearestOwned >= 0 then
  walkTo(controlX(nearestOwned), controlY(nearestOwned))
else
  if nearestFree >= 0 then
    walkTo(controlX(nearestFree), controlY(nearestFree))
  end if
end if
if caution >= 1500 then
  sneak(1)
end if
