' Light vs Dark reference overlord.
'
' You command one player, not one unit. Every decision runs from the top of
' this file with a fresh instruction budget, five times a second. Globals and
' arrays survive between decisions; registers do not.
'
' BUDGET. You get 300000 instructions and 400000 work units per decision.
' That sounds like a lot and it is not: a loop over every unit nested inside
' a loop over every unit will blow through it, the script will be marked
' failed, and your player will stand still for the rest of the match. Scan
' the observation list ONCE and use the nearest* host calls, which do their
' searching inside the host where it is cheap.
'
' READ-ONLY VALUES
'   selfPlayer enemyPlayer worldTick gold wood foodUsed foodCap
'   obsCount ownUnits ownBuildings homeX homeY mapSize decisionPeriod
'
' OBSERVATIONS, index 0 to obsCount - 1. The list is ordered: your buildings
' first, then your units, then whatever of the enemy's you can currently see,
' then gold mines, then the nearest tree tiles. Fog of war is real; anything
' you cannot see is simply absent.
'   obsId(i) obsKind(i) obsOwner(i) obsSub(i) obsX(i) obsY(i)
'   obsHp(i) obsMaxHp(i) obsState(i) obsResource(i) obsIndexOf(id)
'   obsIdle(i) obsUnderConstruction(i) obsFailed(i) obsDropOff(i)
'   obsCarrying(i)
' obsKind: 1 building, 2 unit, 3 gold mine, 4 tree.
' obsSub for units: 0 peon, 1 soldier, 2 archer, 3 mage,
'   4 knight, 5 catapult, 6 cleric, 7 summon.
' obsSub for buildings: 0 hall, 1 farm, 2 barracks, 3 lumber mill,
'   4 tower, 5 stables, 6 church, 7 blacksmith.
' obsIdle is true for a unit taking no orders or a finished building.
' For a tree, obsId is a tile index and obsResource is the wood left.
'
' WATCH OUT. `and`, `or` and `not` here are LOGICAL, not bitwise: 16 and 1
' is 1, not 0. There is no way to test a bit, which is why every condition
' above is its own call instead of a packed flags word.
'
' QUERIES
'   distance(x1, y1, x2, y2)   nearestEnemy(unitId)
'   nearestOwnIdle(kind, x, y) nearestMine(x, y)   nearestTree(x, y)
'   nearestDropOff(x, y, wantWood)                 canPlace(kind, x, y)
'   tilePassable(x, y) tileVisible(x, y) tileExplored(x, y)
'   unitCostGold(k) unitCostWood(k) unitFood(k) unitTrainTicks(k)
'   unitRange(k) unitHp(k)
'   buildCostGold(k) buildCostWood(k) buildTicks(k) buildFootprint(k)
'   buildFood(k) canBuild(k) canTrain(buildingId, unitKind)
'
' COMMANDS, all return 1 when accepted and 0 when refused.
'   moveUnit(id, x, y)          attackMove(id, x, y)
'   attackUnit(id, targetId)
'   harvest(id, target, isTree) build(peonId, kind, x, y)
'   train(buildingId, kind)     setRally(buildingId, x, y)
'   cancel(id)                  orderFailed(id)
' harvest wants a mine id with isTree 0, or a tile index with isTree 1.
' attackMove marches to a tile but stops to fight whoever it sees.
' moveUnit ignores everyone and walks through.

decisions = decisions + 1

PeonKind = 0
SoldierKind = 1
ArcherKind = 2
MageKind = 3
KnightKind = 4
CatapultKind = 5
ClericKind = 6
SummonKind = 7
HallKind = 0
FarmKind = 1
BarracksKind = 2
MillKind = 3
TowerKind = 4
StablesKind = 5
ChurchKind = 6
BlacksmithKind = 7

' One pass over the observation list. Everything below reads these.
myHall = 0
myBarracks = 0
myMill = 0
myTower = 0
myStables = 0
myChurch = 0
myBlacksmith = 0
farmCount = 0
busySites = 0
peonsIdle = 0
soldierCount = 0
combatCount = 0
enemyTarget = 0
builderPeon = 0

index = 0
while index < obsCount
  kind = obsKind(index)
  owner = obsOwner(index)
  flags = obsIdle(index)
  underConstruction = obsUnderConstruction(index)

  if kind = 1 and owner = selfPlayer then
    what = obsSub(index)
    if what = HallKind and flags = 1 then
      myHall = obsId(index)
    end if
    if what = BarracksKind and flags = 1 then
      myBarracks = obsId(index)
    end if
    if what = MillKind and flags = 1 then
      myMill = obsId(index)
    end if
    if what = TowerKind and flags = 1 then
      myTower = obsId(index)
    end if
    if what = StablesKind and flags = 1 then
      myStables = obsId(index)
    end if
    if what = ChurchKind and flags = 1 then
      myChurch = obsId(index)
    end if
    if what = BlacksmithKind and flags = 1 then
      myBlacksmith = obsId(index)
    end if
    if what = FarmKind then
      farmCount = farmCount + 1
    end if
    if underConstruction = 1 then
      busySites = busySites + 1
    end if
  end if

  if kind = 2 and owner = selfPlayer then
    what = obsSub(index)
    if what = SoldierKind then
      soldierCount = soldierCount + 1
    end if
    if what <> PeonKind then
      combatCount = combatCount + 1
    end if
    if what = PeonKind and flags = 1 then
      peonsIdle = peonsIdle + 1
      if builderPeon = 0 then
        builderPeon = obsId(index)
      end if
    end if
  end if

  if kind = 2 and owner = enemyPlayer then
    if enemyTarget = 0 then
      enemyTarget = obsId(index)
    end if
  end if

  index = index + 1
wend

' Keep every idle peon working. Alternate gold and wood so both stockpiles
' grow; wood is the tighter constraint early because farms and barracks want
' a lot of it.
index = 0
while index < obsCount
  if obsKind(index) = 2 and obsOwner(index) = selfPlayer then
    if obsSub(index) = PeonKind and obsIdle(index) = 1 then
      ' Every idle peon works, the builder included. A build order issued
      ' further down overrides whatever this assigns, and a peon holding a
      ' load delivers it before taking the new job, so nothing is wasted.
      id = obsId(index)
      harvestTurn = harvestTurn + 1
      if harvestTurn mod 3 = 0 then
        tree = nearestTree(obsX(index), obsY(index))
        if tree >= 0 then
          discardResult = harvest(id, tree, 1)
        end if
      else
        mine = nearestMine(obsX(index), obsY(index))
        if mine <> 0 then
          discardResult = harvest(id, mine, 0)
        end if
      end if
    end if
  end if
  index = index + 1
wend

' Build out the base. One site at a time, so a rejected placement does not
' spend the whole treasury guessing. First match wins.
if builderPeon <> 0 and busySites = 0 then
  wanted = 0 - 1
  if foodCap - foodUsed <= 2 and canBuild(FarmKind) <> 0 then
    wanted = FarmKind
  end if
  if wanted < 0 then
    if myBarracks = 0 and farmCount >= 1 and canBuild(BarracksKind) <> 0 then
      wanted = BarracksKind
    end if
  end if
  if wanted < 0 then
    if myBarracks <> 0 and myMill = 0 and canBuild(MillKind) <> 0 then
      wanted = MillKind
    end if
  end if
  if wanted < 0 then
    if myMill <> 0 and myStables = 0 and canBuild(StablesKind) <> 0 then
      wanted = StablesKind
    end if
  end if
  if wanted < 0 then
    if myMill <> 0 and myTower = 0 and canBuild(TowerKind) <> 0 then
      wanted = TowerKind
    end if
  end if
  if wanted < 0 then
    if myStables <> 0 and myBlacksmith = 0 then
      if canBuild(BlacksmithKind) <> 0 then
        wanted = BlacksmithKind
      end if
    end if
  end if
  if wanted < 0 then
    if myMill <> 0 and myChurch = 0 and canBuild(ChurchKind) <> 0 then
      wanted = ChurchKind
    end if
  end if

  if wanted >= 0 then
    ' Spiral outward from the hall looking for somewhere the footprint fits.
    radius = 4
    placed = 0
    while radius < 14 and placed = 0
      offset = 0 - radius
      while offset <= radius and placed = 0
        if canPlace(wanted, homeX + offset, homeY - radius) <> 0 then
          placed = build(builderPeon, wanted, homeX + offset, homeY - radius)
        end if
        if placed = 0 then
          if canPlace(wanted, homeX + offset, homeY + radius) <> 0 then
            placed = build(builderPeon, wanted, homeX + offset, homeY + radius)
          end if
        end if
        if placed = 0 then
          if canPlace(wanted, homeX - radius, homeY + offset) <> 0 then
            placed = build(builderPeon, wanted, homeX - radius, homeY + offset)
          end if
        end if
        if placed = 0 then
          if canPlace(wanted, homeX + radius, homeY + offset) <> 0 then
            placed = build(builderPeon, wanted, homeX + radius, homeY + offset)
          end if
        end if
        offset = offset + 2
      wend
      radius = radius + 2
    wend
  end if
end if

' Keep production running.
if myHall <> 0 then
  if canTrain(myHall, PeonKind) <> 0 and ownUnits < 18 then
    discardResult = train(myHall, PeonKind)
  end if
end if
if myBarracks <> 0 then
  trained = 0
  if soldierCount < 6 and canTrain(myBarracks, SoldierKind) <> 0 then
    discardResult = train(myBarracks, SoldierKind)
    trained = 1
  end if
  if trained = 0 and canTrain(myBarracks, KnightKind) <> 0 then
    discardResult = train(myBarracks, KnightKind)
    trained = 1
  end if
  if trained = 0 and canTrain(myBarracks, CatapultKind) <> 0 then
    discardResult = train(myBarracks, CatapultKind)
    trained = 1
  end if
  if trained = 0 and canTrain(myBarracks, ArcherKind) <> 0 then
    discardResult = train(myBarracks, ArcherKind)
    trained = 1
  end if
  if trained = 0 and canTrain(myBarracks, SoldierKind) <> 0 then
    discardResult = train(myBarracks, SoldierKind)
  end if
end if
if myChurch <> 0 then
  if canTrain(myChurch, ClericKind) <> 0 then
    discardResult = train(myChurch, ClericKind)
  end if
end if
if myTower <> 0 then
  if canTrain(myTower, MageKind) <> 0 then
    discardResult = train(myTower, MageKind)
  else
    if canTrain(myTower, SummonKind) <> 0 then
      discardResult = train(myTower, SummonKind)
    end if
  end if
end if

' Fight. Combat units defend themselves when idle. The march is an
' attack-move, so they stop and shoot whoever they see on the way.
attacking = 0
if combatCount >= 8 then
  attacking = 1
end if

index = 0
while index < obsCount
  if obsKind(index) = 2 and obsOwner(index) = selfPlayer then
    if obsSub(index) <> PeonKind and obsIdle(index) = 1 then
      id = obsId(index)
      foe = nearestEnemy(id)
      if foe <> 0 then
        discardResult = attackUnit(id, foe)
      else
        if attacking = 1 then
          discardResult = attackMove(id, mapSize - 1 - homeX, mapSize - 1 - homeY)
        end if
      end if
    end if
  end if
  index = index + 1
wend
