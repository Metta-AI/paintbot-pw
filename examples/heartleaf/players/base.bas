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
' nothing that night. Be inside your own house by 21:00 or lose 3 points.
' Highest total after the last day wins.
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

' A small counter generator of our own, seeded by slot, so each villager
' wanders and pauses on their own rhythm. call rnd(n) leaves the next
' draw, 0..n-1, in rndOut.
if rngState = 0 then
  rngState = selfSlot * 7919 + 17
end if
sub rnd(n)
  rngState = (rngState * 75 + 74) mod 65537
  rndOut = rngState mod n
end sub

' Count outdoor company without treating hidden house occupants as a crowd.
sub company(x, y)
  neighbors = 0
  other = 0
  while other < villagerTotal
    if other <> selfSlot and villagerInHouse(other) < 0 then
      if distance(x, y, villagerX(other), villagerY(other)) <= 4 then
        neighbors = neighbors + 1
      end if
    end if
    other = other + 1
  wend
end sub

sub leisure()
  f = orderFailed()
  if orderKind = 0 then
    g = nearestStockedGarden()
    if g >= 0 then
      r = gather(g)
      wandering = 0
    else
      if wandering = 1 then
        wandering = 0
        call rnd(121)
        pauseUntil = worldTick + 120 + rndOut
        if f = 1 then
          pauseUntil = worldTick
        end if
      end if
      call company(myX, myY)
      if neighbors >= 2 then
        pauseUntil = worldTick
      end if
      if worldTick >= pauseUntil then
        ' Occasionally approach one quiet neighbor. Take a fixed destination
        ' beside them, so a departing neighbor does not start a chase.
        social = -1
        if worldTick >= socialAfter then
          call rnd(3)
          if rndOut = 0 then
            call rnd(villagerTotal)
            first = rndOut
            scan = 0
            while scan < villagerTotal and social < 0
              peer = (first + scan) mod villagerTotal
              if peer <> selfSlot and villagerInHouse(peer) < 0 then
                px = villagerX(peer)
                py = villagerY(peer)
                d = distTo(px, py)
                if d > 4 and d <= 16 then
                  call company(px, py)
                  if neighbors = 1 then
                    social = peer
                  end if
                end if
              end if
              scan = scan + 1
            wend
          end if
          call rnd(721)
          socialAfter = worldTick + 720 + rndOut
        end if

        call rnd(10)
        outing = rndOut
        ax = doorX(selfSlot)
        ay = doorY(selfSlot)
        if outing >= 4 and outing < 7 then
          call rnd(gardenTotal)
          ax = gardenX(rndOut)
          ay = gardenY(rndOut)
        end if
        if outing >= 7 and outing < 9 then
          call rnd(villagerTotal)
          ax = doorX(rndOut)
          ay = doorY(rndOut)
        end if
        if outing = 9 then
          ax = 64
          ay = 64
        end if
        if social >= 0 then
          ax = villagerX(social)
          ay = villagerY(social)
        end if
        tries = 0
        while tries < 6
          call rnd(9)
          dx = rndOut - 4
          call rnd(9)
          dy = rndOut - 4
          if social >= 0 then
            call rnd(5)
            dx = rndOut - 2
            call rnd(5)
            dy = rndOut - 2
          end if
          x = ax + dx
          y = ay + dy
          if dx * dx + dy * dy >= 4 and distTo(x, y) >= 4 then
            if tilePassable(x, y) = 1 then
              call company(x, y)
              if neighbors <= 1 then
                r = walkTo(x, y)
                if r = 1 then
                  wandering = 1
                  tries = 6
                end if
              end if
            end if
          end if
          tries = tries + 1
        wend
        if wandering = 0 then
          pauseUntil = worldTick + 24
        end if
      end if
    end if
  end if
end sub

' New-day reset.
if dayMark <> day then
  dayMark = day
  returningHome = 0
  wandering = 0
  pauseUntil = 0
  socialAfter = worldTick + 240 + selfSlot * 48
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
  ' Collect leftovers until it is time to get home for curfew.
  homeMinutes = distTo(doorX(selfSlot), doorY(selfSlot)) * 2 + 30
  if 1260 - minuteOfDay <= homeMinutes or minuteOfDay >= 1200 then
    returningHome = 1
  end if
  if returningHome = 1 then
    if inHouse >= 0 then
      if inHouse <> selfSlot then
        r = exitHouse()
      end if
    else
      if orderKind <> 3 or orderTarget <> selfSlot then
        r = enterHouse(selfSlot)
      end if
    end if
  else
    if inHouse >= 0 then
      r = exitHouse()
    else
      call leisure()
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

    call leisure()
  end if
end if
