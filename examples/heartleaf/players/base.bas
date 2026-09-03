' Heartleaf reference villager.
'
' You are one villager in a nine-house village. Every decision runs from the
' top of this file with a fresh instruction budget, once per game minute.
' Globals and arrays survive between decisions; registers do not.
'
' THE WEEK. Days run 9:00 to 21:00. Every morning each of the 27 gardens
' grows one vegetable. At exactly 18:00 every house holds its dinner tally:
' if the owner is inside with at least one visitor, the owner banks
' (items carried) x (visitor count), then the pantry feeds everyone present
' for three bite rounds - a vegetable you have never tasted is worth 3,
' a repeat 1. Hosting empties your bag. Anyone alone, or outside, scores
' nothing that night. Highest total after the last day wins.
'
' READ-ONLY VALUES
'   selfSlot worldTick day dayCount minuteOfDay dinnerDone
'   myX myY inHouse carried hosting acceptedHost orderKind orderTarget
'   score villagerTotal gardenTotal decisionPeriod
' minuteOfDay counts minutes since midnight: 540 is 9:00, 1080 is 18:00.
' inHouse is the house you are inside, or -1 outdoors.
' orderKind: 0 idle, 1 walking, 2 gathering, 3 heading into a house.
'
' QUERIES
'   invOf(v) eatenOf(v)                    your bag and your palate
'   gardenX(i) gardenY(i) gardenVeggie(i)  gardenVeggie is -1 when bare
'   nearestStockedGarden()                 garden id or -1
'   villagerX(s) villagerY(s) villagerInHouse(s) villagerHosting(s)
'   villagerCarried(s) villagerScore(s) inviteFrom(s)
'   doorX(h) doorY(h) occupants(h)
'   distTo(x, y) distance(x1, y1, x2, y2) tilePassable(x, y)
'
' COMMANDS, all return 1 when accepted and 0 when refused.
'   walkTo(x, y)   gather(gardenId)  invite(s)   accept(s)   decline(s)
'   enterHouse(h)  exitHouse()       cancel()    orderFailed()
' invite needs both of you outdoors within 3 tiles, and declares you a host.
' Entering a house hides you from the map until you exitHouse().
'
' THE PLAYBOOK. Gather all day; three villagers are due to host each night
' by rotation; guests walk to the nearest due host; never be alone at six.

dim invitedMark(8)
dim spotX(7)
dim spotY(7)

' Eight loitering spots around the well, five tiles out.
spotX(0) = 5
spotY(0) = 0
spotX(1) = 4
spotY(1) = 4
spotX(2) = 0
spotY(2) = 5
spotX(3) = -4
spotY(3) = 4
spotX(4) = -5
spotY(4) = 0
spotX(5) = -4
spotY(5) = -4
spotX(6) = 0
spotY(6) = -5
spotX(7) = 4
spotY(7) = -4

' New-day reset.
if dayMark <> day then
  dayMark = day
  s = 0
  while s < villagerTotal
    invitedMark(s) = 0
    s = s + 1
  wend
end if

' Am I due to host tonight? Rotation puts three hosts on every night.
hostTonight = 0
if (day + selfSlot) mod 3 = 0 then
  hostTonight = 1
end if

if dinnerDone = 1 then
  ' The party is over. Step outside and stroll for leftovers.
  if inHouse >= 0 then
    r = exitHouse()
  else
    if orderKind = 0 then
      g = nearestStockedGarden()
      if g >= 0 then
        r = gather(g)
      end if
    end if
  end if
else
  ' Accept the first standing invitation.
  if acceptedHost < 0 then
    s = 0
    while s < villagerTotal
      if inviteFrom(s) = 1 then
        r = accept(s)
        s = villagerTotal
      end if
      s = s + 1
    wend
  end if

  ' Where is dinner tonight? Hosts stay home. Guests follow an accepted
  ' invitation, or walk to the nearest villager whose rotation night it is.
  target = selfSlot
  if hostTonight = 0 then
    if acceptedHost >= 0 then
      target = acceptedHost
    else
      bestDist = 100000
      s = 0
      while s < villagerTotal
        if s <> selfSlot then
          if (day + s) mod 3 = 0 then
            d = distTo(doorX(s), doorY(s))
            if d < bestDist then
              bestDist = d
              target = s
            end if
          end if
        end if
        s = s + 1
      wend
    end if
  end if

  ' Leave in time. The walk costs about two game minutes per tile, plus a
  ' half-hour margin for door crowds; five o'clock is the hard deadline.
  minutesLeft = 1080 - minuteOfDay
  walkMinutes = distTo(doorX(target), doorY(target)) * 2
  going = 0
  if minutesLeft <= walkMinutes + 30 then
    going = 1
  end if
  if minuteOfDay >= 1020 then
    going = 1
  end if

  if going = 1 then
    if inHouse < 0 then
      alreadyHeading = 0
      if orderKind = 3 and orderTarget = target then
        alreadyHeading = 1
      end if
      if alreadyHeading = 0 then
        r = enterHouse(target)
      end if
    end if
  else
    ' Daytime. Hosts wave invitations at anyone passing close by.
    if hostTonight = 1 then
      s = 0
      while s < villagerTotal
        if s <> selfSlot then
          if invitedMark(s) = 0 then
            if villagerInHouse(s) < 0 then
              d = distTo(villagerX(s), villagerY(s))
              if d <= 3 then
                r = invite(s)
                if r = 1 then
                  invitedMark(s) = 1
                end if
              end if
            end if
          end if
        end if
        s = s + 1
      wend
    end if

    ' Gather whatever still grows; when the gardens are bare, loiter on
    ' the plaza, moving between spots around the well every so often so
    ' the village keeps bumping into itself without piling onto the well.
    f = orderFailed()
    if orderKind = 0 then
      g = nearestStockedGarden()
      if g >= 0 then
        r = gather(g)
      else
        spot = (selfSlot + worldTick / 480) mod 8
        tx = 64 + spotX(spot)
        ty = 64 + spotY(spot)
        if distTo(tx, ty) > 1 then
          r = walkTo(tx, ty)
        end if
      end if
    end if
  end if
end if
