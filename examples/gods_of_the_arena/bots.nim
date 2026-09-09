## Gods of the Arena hero scripting: the BASIC surface one hero has
## on the simulation.

import
  polyworld/[basic, cli, controllers, profiles, tapes],
  content,
  sim,
  replays

when defined(coworld):
  import polyworld/coworld

type
  HeroDataSlot = enum
    DataSelfId,
    DataSelfTeam,
    DataSelfClass,
    DataSelfX,
    DataSelfY,
    DataSelfHp,
    DataSelfMaxHp,
    DataSelfMana,
    DataSelfMaxMana,
    DataSelfGold,
    DataSelfLevel,
    DataWorldTick

const
  HeroDataNames: array[HeroDataSlot, string] = [
    "selfId",
    "selfTeam",
    "selfClass",
    "selfX",
    "selfY",
    "selfHp",
    "selfMaxHp",
    "selfMana",
    "selfMaxMana",
    "selfGold",
    "selfLevel",
    "worldTick"
  ]

var
  activeGame: Game
  heroDataIds: array[HeroDataSlot, int32]

proc bindHeroData(program: Program) =
  ## Resolves host data slots once so think ticks do not allocate names.
  for slot, name in HeroDataNames:
    heroDataIds[slot] = program.hostDataIndex(name)
    doAssert heroDataIds[slot] >= 0, "missing host data " & name

proc heroVmLimits(): Limits =
  ## Returns independent structural and per-decision limits for a hero VM.
  result = defaultLimits()
  result.maxSourceBytes = 64 * 1024
  result.maxCodeInstructions = 20_000
  result.maxArrays = 32
  result.maxArrayElements = 4096
  result.maxGlobals = 256
  result.maxHostData = 32
  result.maxHostFunctions = 32
  result.maxRoutines = 64
  result.maxParameters = 16
  result.maxRegisters = 256
  result.maxSyntaxDepth = 32
  result.maxCallDepth = 16
  result.maxMemoryBytes = 2 * 1024 * 1024
  result.maxInstructions = 20_000
  result.maxWorkUnits = 50_000
  result.maxPrintBytes = 1024
  result.maxPrintEvents = 128

proc initHeroHost(heroId: int32): Host =
  ## Builds the bounded world-query and action interface for one hero.
  result = initHost()
  for name in HeroDataNames:
    discard result.addData(name)

  let objectCountProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    int32(worldObjectCount(activeGame.world, heroId))
  let objectIdProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      value.id
    else:
      0
  let objectKindProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      value.kind
    else:
      0
  let objectTeamProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      int32(value.team.ord)
    else:
      0
  let objectClassProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      value.class
    else:
      -1
  let objectXProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      mapCoordinate(value.position.x)
    else:
      0
  let objectYProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      mapCoordinate(value.position.z)
    else:
      0
  let objectHpProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(activeGame.world, heroId, int(arguments[0]), value):
      max(value.hp, 0'i32)
    else:
      0
  let objectAliveProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    int32(
      worldObjectAt(activeGame.world, heroId, int(arguments[0]), value) and
        value.alive
    )
  let walkToProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    try:
      if activeGame.recorder != nil:
        activeGame.recorder.recordWalkTo(
          uint32(activeGame.world.tick),
          heroId,
          arguments[0],
          arguments[1]
        )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(
        BasicError,
        "replay recording failed: " & error.msg
      )
    int32(applyWalkTo(activeGame.world, heroId, arguments[0], arguments[1]))
  let attackTargetProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    try:
      if activeGame.recorder != nil:
        activeGame.recorder.recordAttackTarget(
          uint32(activeGame.world.tick),
          heroId,
          arguments[0]
        )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(
        BasicError,
        "replay recording failed: " & error.msg
      )
    int32(applyAttackTarget(activeGame.world, heroId, arguments[0]))
  let itemIdProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    let index = heroIndex(activeGame.world, heroId)
    let slot = int(arguments[0])
    if index < 0 or slot < 0 or slot >= InventorySlots:
      return 0
    int32(activeGame.world.heroes[index].inventory[slot].ord)
  let itemCountProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    let index = heroIndex(activeGame.world, heroId)
    let slot = int(arguments[0])
    if index < 0 or slot < 0 or slot >= InventorySlots:
      return 0
    activeGame.world.heroes[index].itemCounts[slot]
  let buyItemProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    try:
      if activeGame.recorder != nil:
        activeGame.recorder.recordBuyItem(
          uint32(activeGame.world.tick),
          heroId,
          arguments[0]
        )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(
        BasicError,
        "replay recording failed: " & error.msg
      )
    int32(applyBuyItem(activeGame.world, heroId, arguments[0]))
  let useItemProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    try:
      if activeGame.recorder != nil:
        activeGame.recorder.recordUseItem(
          uint32(activeGame.world.tick),
          heroId,
          arguments[0]
        )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(
        BasicError,
        "replay recording failed: " & error.msg
      )
    int32(applyUseItem(activeGame.world, heroId, arguments[0]))

  discard result.addFunction("objectCount", 0, objectCountProc, 2)
  discard result.addFunction("objectId", 1, objectIdProc, 4)
  discard result.addFunction("objectKind", 1, objectKindProc, 4)
  discard result.addFunction("objectTeam", 1, objectTeamProc, 4)
  discard result.addFunction("objectClass", 1, objectClassProc, 4)
  discard result.addFunction("objectX", 1, objectXProc, 4)
  discard result.addFunction("objectY", 1, objectYProc, 4)
  discard result.addFunction("objectHp", 1, objectHpProc, 4)
  discard result.addFunction("objectAlive", 1, objectAliveProc, 4)
  discard result.addFunction("walkTo", 2, walkToProc, 800)
  discard result.addFunction("attackTarget", 1, attackTargetProc, 20)
  discard result.addFunction("itemId", 1, itemIdProc, 4)
  discard result.addFunction("itemCount", 1, itemCountProc, 4)
  discard result.addFunction("buyItem", 1, buyItemProc, 20)
  discard result.addFunction("useItem", 1, useItemProc, 20)

proc loadBots*(
    game: Game,
    groups: openArray[BotGroup],
    playerSlot = 0'i32
) =
  ## Loads bot files into every hero slot except the optional human slot.
  activeGame = game
  let
    limits = heroVmLimits()
    schema = initHeroHost(0)
    kinds = controllerKinds(game.world.heroes.len, playerSlot)
    sources = groups.expandBotSources(kinds)
  game.heroVms.setLen(game.world.heroes.len)
  var bound = false
  for i in 0 ..< game.world.heroes.len:
    if kinds[i] == PlayerController:
      continue
    let program =
      when defined(coworld):
        compilePlayer(sources[i], schema, limits, int(i))
      else:
        compile(sources[i], schema, limits)
    if not bound:
      bindHeroData(program)
      bound = true
    game.heroVms[i] = HeroVm(
      runtime: initRuntime(
        program,
        initHeroHost(game.world.heroes[i].id),
        limits
      ),
      limits: limits,
      ready: true
    )
    when defined(coworld):
      game.heroVms[i].output = playerPrinter(int(i))

proc runHeroScript(game: Game, index: int) =
  ## Runs one bounded persistent BASIC decision for a living hero.
  if index < 0 or index >= game.heroVms.len:
    return
  let
    hero = game.world.heroes[index]
    vm = game.heroVms[index]
  if vm == nil or vm.failed or hero.state == Dying:
    return
  vm.runtime.restart()
  try:
    vm.runtime.setData(heroDataIds[DataSelfId], hero.id)
    vm.runtime.setData(heroDataIds[DataSelfTeam], int32(hero.team.ord))
    vm.runtime.setData(heroDataIds[DataSelfClass], int32(hero.class.ord))
    vm.runtime.setData(
      heroDataIds[DataSelfX],
      mapCoordinate(hero.position.x)
    )
    vm.runtime.setData(
      heroDataIds[DataSelfY],
      mapCoordinate(hero.position.z)
    )
    vm.runtime.setData(heroDataIds[DataSelfHp], max(hero.hp, 0'i32))
    vm.runtime.setData(heroDataIds[DataSelfMaxHp], hero.maxHp)
    vm.runtime.setData(heroDataIds[DataSelfMana], hero.mana)
    vm.runtime.setData(heroDataIds[DataSelfMaxMana], hero.maxMana)
    vm.runtime.setData(heroDataIds[DataSelfGold], int32(hero.gold))
    vm.runtime.setData(heroDataIds[DataSelfLevel], int32(hero.level))
    vm.runtime.setData(heroDataIds[DataWorldTick], game.world.tick)
    discard vm.runtime.run(vm.output)
    inc vm.decisions
  except BasicError as error:
    vm.failed = true
    vm.lastError = error.msg
    when defined(coworld):
      playerError(index, error.msg)
    else:
      echo "hero ", hero.id, " BASIC error: ", error.msg
  vm.lastWork = vm.runtime.workUsed
  vm.lastInstructions = vm.runtime.instructionsUsed

proc runBotDecisions*(game: Game) {.measure.} =
  ## Runs every VM in seeded cyclic order and advances the first slot.
  activeGame = game
  for offset in 0 ..< game.world.heroes.len:
    let index = (game.world.heroTurnStart + offset) mod game.world.heroes.len
    runHeroScript(game, index)
  game.world.heroTurnStart =
    (game.world.heroTurnStart + 1) mod game.world.heroes.len
