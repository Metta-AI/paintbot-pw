## Heartleaf content: the fingerprint and the clock arithmetic.

import
  ../examples/heartleaf/content

echo "Testing the content fingerprint"
block fingerprintIsStable:
  doAssert contentHash() != 0, "the content fingerprint is empty"
  doAssert contentHash() == contentHash(),
    "the content fingerprint is not deterministic"

echo "Testing clock arithmetic"
block clockMath:
  doAssert minuteOfDayAt(0) == DayStartMinute
  doAssert minuteOfDayAt(TicksPerGameMinute) == DayStartMinute + 1
  doAssert minuteOfDayAt(DayTicks) == DayEndMinute
  ## Dinner lands exactly on a tick boundary.
  let dinnerTick = (DinnerMinute - DayStartMinute) * TicksPerGameMinute
  doAssert minuteOfDayAt(dinnerTick) == DinnerMinute
  doAssert minuteOfDayAt(dinnerTick - 1) == DinnerMinute - 1
  ## Dinner also lands on a decision boundary, so a bot heading home can
  ## still act on the final minute before the tally.
  doAssert dinnerTick mod DecisionTicks == 0

block gameLength:
  doAssert gameLengthTicks(1) == DayTicks + ScoreScreenTicks
  doAssert gameLengthTicks(DefaultDayCount) ==
    DefaultDayCount * (DayTicks + ScoreScreenTicks)

echo "Testing the tile helpers"
block tiles:
  doAssert inGrid(0, 0) and inGrid(GridSide - 1, GridSide - 1)
  doAssert not inGrid(-1, 0) and not inGrid(0, GridSide)
  doAssert tileIndex(0, 1) == GridSide
  doAssert chebyshev(tile2(2, 3), tile2(5, 1)) == 3

echo "Testing the name tables"
block names:
  doAssert VillagerNames.len == VillagerCount
  doAssert VeggieNames.len == VeggieKinds
  for name in VillagerNames:
    doAssert name.len > 0
  for name in VeggieNames:
    doAssert name.len > 0

echo "test_hlf_content: all checks passed"
