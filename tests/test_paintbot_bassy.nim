import
  std/os,
  bassy,
  polyworld/cli,
  ../examples/paintbot/[bots, sim]

const Source = """
TYPE Memory
  ticks AS INTEGER
  previous AS INTEGER
END TYPE
DIM memory AS Memory
memory.ticks = memory.ticks + 1
previous = memory.previous
memory.previous = me.x
x = me.x
hp = me.hp
legacyX = selfX
legacyTick = worldTick
sub accumulate()
  legacySum = legacySum + selfHp
end sub
accumulate()
visibleValue = agents(1).visible
agentX = agents(1).x
agentY = agents(1).y
agentHp = agents(1).hp
agentTeam = agents(1).team
agentCarrying = agents(1).carrying
fraction = 3 / 2
quotient = 3 \ 2
walkTo(me.x + quotient, me.y)
"""

echo "Testing Bassy records, numeric semantics, and fog-gated field refresh"
block:
  visionRulesVersion = 48
  var world = newWorld(2026)
  let bot = loadScriptBot(Source, 0)
  var players = newSeq[Bot](Seats)
  players[0] = bot
  if jitSupported():
    doAssert bot.runtime.compileNative() > 0
  for i in 0 ..< 3:
    let commands = players.decide(world)
    doAssert not bot.failed, bot.error
    let view = seatView(0)
    doAssert bot.runtime.getGlobal("x") == view.selfX
    doAssert bot.runtime.getGlobal("hp") == view.selfHp
    doAssert bot.runtime.getGlobal("legacyX") == view.selfX
    doAssert bot.runtime.getGlobal("legacyTick") == view.worldTick
    doAssert bot.runtime.getGlobal("legacySum") == view.selfHp * int32(i + 1)
    doAssert bot.runtime.getGlobal("visibleValue") == view.visible(1)
    doAssert bot.runtime.getGlobal("agentX") == view.playerX(1)
    doAssert bot.runtime.getGlobal("agentY") == view.playerY(1)
    doAssert bot.runtime.getGlobal("agentHp") == view.playerHp(1)
    doAssert bot.runtime.getGlobal("agentTeam") == view.playerTeam(1)
    doAssert bot.runtime.getGlobal("agentCarrying") == view.playerCarrying(1)
    doAssert bot.runtime.getGlobal("memory.ticks") == int32(i + 1)
    doAssert bot.runtime.getGlobal("quotient") == 1
    doAssert bot.runtime.getGlobalValue("fraction").asFixed == 1.5'fx
    doAssert commands[0].goal.x == view.selfX + 1
    world.cogs[0].pos.x += 10
    inc world.tick

  let other = loadScriptBot("answer = agents(0).hp", 1)
  doAssert other.runtime.getGlobal("answer") == 0
  doAssert bot.runtime.getGlobal("memory.ticks") == 3

echo "Testing baseline records compile and stay within seat budgets"
block:
  let source = readFile(
    currentSourcePath().parentDir.parentDir /
      "examples/paintbot/players/base.bas"
  )
  var world = newWorld(7)
  let players = loadBots(@[BotGroup(
    path: currentSourcePath().parentDir.parentDir /
      "examples/paintbot/players/base.bas",
    count: Seats
  )])
  doAssert source == readFile(
    currentSourcePath().parentDir.parentDir /
      "coworld/paintbot/players/base.bas"
  )
  for i in 0 ..< 240:
    let commands = players.decide(world)
    world.step(commands)
  for bot in players:
    doAssert not bot.failed, bot.error
  for slot in 0 ..< Seats:
    doAssert peakInstructions[slot] <= limits().maxInstructions
    doAssert peakWork[slot] <= limits().maxWorkUnits
  echo "Baseline state hash: ", world.stateHash()

echo "Paintbot Bassy integration passed"
