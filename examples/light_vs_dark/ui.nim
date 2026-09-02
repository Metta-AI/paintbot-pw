## Light vs Dark Silky HUD.

import
  std/strformat,
  chroma, pixie, silky, vmath, windy,
  polyworld/[actioncam, chrome, gameuis, inputs, pathing, player, rtscameras],
  content, sim, game, controls

const
  PanelScore = vec2(353, 461)
  PanelMinimap = vec2(788, 432)
  PanelSelection = vec2(488, 250)
  PanelBuild = vec2(642, 283)
  HudClearance = 48.0'f32
  CommandTabs = ["BUILD", "UNITS", "UPGRADES"]
  ViewLabels = ["A", "L", "D", "*"]
  ResourceIcons = ["gold", "wood", "food"]
  CommandTabIcons = ["build", "units", "research"]
  SelectionGrid = [
    vec2(214, 34), vec2(280, 34), vec2(345, 34), vec2(410, 34),
    vec2(214, 101), vec2(280, 101), vec2(345, 101), vec2(410, 101),
    vec2(214, 167), vec2(280, 167), vec2(345, 167), vec2(410, 167)
  ]
  SelectionSlotSize = vec2(56, 56)
  BuildGrid = [
    vec2(25, 66), vec2(133, 66), vec2(240, 66), vec2(349, 66),
    vec2(457, 66),
    vec2(25, 172), vec2(133, 172), vec2(240, 172), vec2(349, 172),
    vec2(457, 172)
  ]
  BuildSlotSize = vec2(91, 91)
  CommandTabXs = [28.0'f32, 164, 357]
  CommandTabWs = [133.0'f32, 191, 227]

var commandTab = 0

type
  HudChrome = object
    layout: GameUiLayout
    score: GameUiPanel
    minimap: GameUiPanel
    selection: GameUiPanel
    build: GameUiPanel

var
  unitPortraitKeys: array[PlayerCount, array[UnitKind, string]]
  buildingPortraitKeys: array[PlayerCount, array[BuildingKind, string]]

for player in 0 ..< PlayerCount:
  for kind in UnitKind:
    unitPortraitKeys[player][kind] = "lvd_u" & $player & "_" & $kind.ord
  for kind in BuildingKind:
    if kind == GoldMineBuilding:
      buildingPortraitKeys[player][kind] = "lvd_b_mine"
    else:
      buildingPortraitKeys[player][kind] =
        "lvd_b" & $player & "_" & $kind.ord

proc unitPortraitKey*(player: int32, kind: UnitKind): string =
  ## Returns the atlas name packed from one unit's profile PNG.
  unitPortraitKeys[player][kind]

proc buildingPortraitKey*(player: int32, kind: BuildingKind): string =
  ## Returns the atlas name packed from one building's profile PNG.
  buildingPortraitKeys[max(player, 0)][kind]

proc coverSquare(well: GameUiPanel, pad = 4.0'f32): GameUiPanel =
  ## Returns a centered square inset inside a portrait well.
  let side = min(well.size.x, well.size.y) - pad * 2
  result.size = vec2(max(side, 1))
  result.origin = well.origin + (well.size - result.size) * 0.5'f32

proc drawPortrait(
    sk: Silky,
    well: GameUiPanel,
    key: string,
    color = rgbx(255, 255, 255, 255)
) =
  ## Draws a profile sprite inside a well after the plate.
  if key.len == 0:
    return
  sk.drawWellImage(well, key, color)

proc commandPlayer(viewMode: int32): int32 =
  ## Returns the side whose build and train locks the HUD should show.
  if options.playerSlot > 0 and not run.replayMode:
    options.playerSlot - 1
  elif viewMode > 0:
    viewMode - 1
  else:
    LightPlayer

proc canShowTrain(
    player: int32,
    buildingId: int32,
    kind: UnitKind
): bool =
  ## Returns whether this side could start training the unit right now.
  if buildingId.isBuildingId and
      run.world.buildingOwner(buildingId) == player:
    return run.world.canTrain(buildingId, kind)
  for structure in run.world.buildings:
    if structure.owner == player and
        run.world.canTrain(structure.id, kind):
      return true
  false

proc commandPortraitColor(ready: bool): ColorRGBX =
  ## Fades portraits that cannot be built or trained yet.
  if ready:
    rgbx(255, 255, 255, 255)
  else:
    rgbx(255, 255, 255, 128)

proc placeChrome(layout: GameUiLayout): HudChrome =
  ## Places every textured HUD panel in one layout space.
  result.layout = layout
  result.score = layout.panel(GameUiRegion.TopLeft, PanelScore)
  result.minimap = layout.panel(GameUiRegion.TopRight, PanelMinimap)
  result.selection = layout.panel(
    GameUiRegion.BottomLeft,
    PanelSelection
  )
  result.build = layout.panel(GameUiRegion.BottomRight, PanelBuild)

proc hudLayoutFits(layoutSize: Vec2): bool =
  ## Returns whether native HUD plates fit this layout without overlap.
  let
    layout = initGameUiLayout(layoutSize, TransportHeight)
    chrome = placeChrome(layout)
  layoutFits(
    layout,
    [
      chrome.score,
      chrome.minimap,
      chrome.selection,
      chrome.build
    ],
    HudClearance
  )

proc hudUiScale*(windowSize: Vec2): float32 =
  ## Returns the stepped Silky scale that keeps HUD plates from overlapping.
  fitUiScale(windowSize, hudLayoutFits, UiCrispSteps)

proc hudUiScale*(window: Window): float32 =
  ## Returns the stepped Silky scale that fits the native HUD on this window.
  hudUiScale(vec2(window.size.x.float32, window.size.y.float32))

proc currentLayout*(window: Window): GameUiLayout =
  ## Returns the nine-region HUD layout in Silky layout space.
  initGameUiLayout(
    vec2(window.size.x.float32, window.size.y.float32) /
      hudUiScale(window),
    TransportHeight
  )

proc currentChrome(window: Window): HudChrome =
  ## Places every textured HUD panel for the current window.
  placeChrome(currentLayout(window))

proc mouseOverUi*(window: Window, mouse: Vec2): bool =
  ## Returns whether the pointer is over an anchored game UI panel.
  let chrome = currentChrome(window)
  mouseOverPanels(
    mouse,
    chrome.layout,
    [
      chrome.score,
      chrome.minimap,
      chrome.selection,
      chrome.build
    ]
  )

proc playerColor(player: int32): ColorRGBX =
  ## Returns a readable HUD color for one player.
  if player == LightPlayer:
    rgbx(80, 140, 230, 255)
  else:
    rgbx(210, 80, 85, 255)

const
  UnitStateNames: array[UnitState, string] = [
    "UnitIdle", "UnitMoving", "UnitChasing", "UnitAttacking",
    "UnitToMine", "UnitInMine", "UnitToDropGold", "UnitDepositGold",
    "UnitToTree", "UnitChopping", "UnitToDropWood", "UnitDepositWood",
    "UnitToBuild", "UnitBuilding", "UnitDying"
  ]
  BuildingStateNames: array[BuildingState, string] = [
    "BuildingUnderConstruction", "BuildingComplete", "BuildingDying"
  ]

proc gatherRate(gathered: int64): int32 =
  ## Estimates one resource's gather rate in units per game minute.
  let ticks = max(run.world.tick, TickRate)
  int32(gathered * 60'i64 * int64(TickRate) div int64(ticks))

proc clockHour*(): float32 =
  ## The accelerated spectator clock in hours, 0 ..< 24 with a fraction:
  ## the match starts at 8:00 and a day is five minutes long.
  clockHour(run.world.tick, TickRate)

proc currentHudTime(): tuple[day, hour, minute: int] =
  ## Converts simulation ticks into the accelerated spectator clock.
  hudClock(run.world.tick, TickRate)

proc towerCount(player: int32): int =
  ## Counts standing towers for one player.
  for structure in run.world.buildings:
    if structure.owner == player and
        structure.kind == TowerBuilding and
        structure.state != BuildingDying:
      inc result

proc buildingName(kind: BuildingKind, owner = -1'i32): string =
  ## Returns a spectator-facing name for one structure.
  case kind
  of TownHallBuilding: "TOWN HALL"
  of FarmBuilding: "FARM"
  of BarracksBuilding: "BARRACKS"
  of LumberMillBuilding: "LUMBER MILL"
  of TowerBuilding: "TOWER"
  of StablesBuilding:
    if owner == DarkPlayer: "KENNELS" else: "STABLES"
  of ChurchBuilding:
    if owner == DarkPlayer: "TEMPLE" else: "CHURCH"
  of BlacksmithBuilding: "BLACKSMITH"
  of GoldMineBuilding: "GOLD MINE"

proc unitName(kind: UnitKind, owner: int32): string =
  ## Returns a spectator-facing name for one unit.
  if owner == DarkPlayer:
    case kind
    of PeonUnit: "PEON"
    of SoldierUnit: "GRUNT"
    of ArcherUnit: "SPEARMAN"
    of MageUnit: "WARLOCK"
    of KnightUnit: "RAIDER"
    of CatapultUnit: "CATAPULT"
    of ClericUnit: "NECROLYTE"
    of SummonUnit: "DAEMON"
  else:
    case kind
    of PeonUnit: "PEASANT"
    of SoldierUnit: "FOOTMAN"
    of ArcherUnit: "ARCHER"
    of MageUnit: "CONJURER"
    of KnightUnit: "KNIGHT"
    of CatapultUnit: "CATAPULT"
    of ClericUnit: "CLERIC"
    of SummonUnit: "ELEMENTAL"

proc isPicked(id: int32, selectedIds: openArray[int32]): bool =
  ## Returns whether one entity belongs to the HUD selection set.
  for candidate in selectedIds:
    if candidate == id:
      return true

proc shiftHeld(window: Window): bool =
  ## Returns whether either shift key is currently down.
  window.buttonDown[KeyLeftShift] or
    window.buttonDown[KeyRightShift]

proc dropSelected(
    selectedIds: var seq[int32],
    primaryId: var int32,
    id: int32
) =
  ## Removes one entity from a multi-unit selection.
  if selectedIds.len <= 1:
    return
  for i in 0 ..< selectedIds.len:
    if selectedIds[i] == id:
      selectedIds.delete(i)
      break
  if primaryId == id:
    primaryId = selectedIds[0]

proc drawSelectionBox*(
    sk: Silky,
    window: Window,
    press: Vec2,
    active: bool
) =
  ## Draws the live box-select rectangle in layout space.
  if not active:
    return
  let current = window.mousePos.vec2
  if (current - press).length <= 6.0'f32:
    return
  let
    scale = max(sk.uiScale, 0.001'f32)
    origin = vec2(
      min(press.x, current.x),
      min(press.y, current.y)
    ) / scale
    size = vec2(
      abs(current.x - press.x),
      abs(current.y - press.y)
    ) / scale
    line = 2.0'f32
    edge = rgbx(180, 220, 255, 230)
  sk.drawRect(origin, size, rgbx(80, 160, 255, 45))
  sk.drawRect(origin, vec2(size.x, line), edge)
  sk.drawRect(
    origin + vec2(0, size.y - line),
    vec2(size.x, line),
    edge
  )
  sk.drawRect(origin, vec2(line, size.y), edge)
  sk.drawRect(
    origin + vec2(size.x - line, 0),
    vec2(line, size.y),
    edge
  )

proc shownUnit(unit: Unit, viewMode: int32): bool =
  ## Returns whether fog of war currently reveals this unit.
  if unit.state == UnitInMine:
    return false
  if viewMode == 0:
    return true
  run.world.unitVisible(viewMode - 1, unit)

proc shownBuilding(structure: Building, viewMode: int32): bool =
  ## Returns whether fog of war currently reveals this structure.
  if viewMode == 0:
    return true
  run.world.buildingVisible(viewMode - 1, structure)

proc minimapWell(panel: GameUiPanel): GameUiPanel =
  ## Returns the chrome well that holds the minimap.
  panel.imageSlot(522, 78, 256, 282)

proc minimapMap(panel: GameUiPanel): GameUiPanel =
  ## Returns the square map centered in the minimap well.
  coverSquare(panel.minimapWell(), 0)

proc minimapPoint(tile: Tile2, area: GameUiPanel): Vec2 =
  ## Converts one map tile into a point on the minimap.
  area.origin + vec2(
    float32(tile.x) / float32(GridSide) * area.size.x,
    float32(tile.y) / float32(GridSide) * area.size.y
  )

proc minimapCell(
    x, y, stride: int32, area: GameUiPanel
): (Vec2, Vec2) =
  ## Returns origin and size of one sampled terrain cell, spanning to the
  ## next sample so cells tessellate with no gap or overlap.
  let
    x1 = min(x + stride, GridSide)
    y1 = min(y + stride, GridSide)
    origin = minimapPoint(tile2(x, y), area)
    far = minimapPoint(tile2(x1, y1), area)
  (origin, far - origin)

proc updateMinimapCamera*(
    window: Window,
    mouse: Vec2,
    cameraTarget: var Vec3,
    minimapPanning: var bool,
    followSelection: var bool
) =
  ## Moves the free camera while the primary button drags on the minimap.
  let
    chrome = currentChrome(window)
    area = chrome.minimap.minimapMap()
  if window.mousePressed(MouseLeft) and area.contains(mouse):
    minimapPanning = true
    followSelection = false
  if not window.mouseDown(MouseLeft):
    minimapPanning = false
  if minimapPanning:
    let point = minimapWorldPoint(
      mouse,
      area.origin,
      area.size,
      HalfGrid
    )
    cameraTarget.x = point.x
    cameraTarget.z = point.y
    cameraTarget.y = surfaceHeight(point.x, point.y)

proc drawMinimapCamera(
    sk: Silky,
    window: Window,
    area: GameUiPanel,
    cameraTarget: Vec3,
    cameraDistance: float32
) =
  ## Draws the fixed RTS camera's visible ground footprint.
  let aspect = window.size.x.float32 / max(window.size.y.float32, 1)
  sk.drawCameraFrame(
    minimapViewport(
      cameraTarget,
      cameraDistance,
      aspect,
      area.origin,
      area.size,
      HalfGrid
    )
  )

proc drawScoreRow(
    sk: Silky,
    origin: Vec2,
    player: int32,
    y: float32
) =
  ## Draws one side's towers, kills, and deaths.
  let
    color = playerColor(player)
    enemy = 1'i32 - player
    values = [
      towerCount(player),
      int(run.world.players[enemy].unitsLost),
      int(run.world.players[player].unitsLost)
    ]
  sk.drawRect(origin + vec2(0, y + 4), vec2(12, 12), color)
  var x = 18.0'f32
  for i, label in ["TOWERS", "KILLS", "DEATHS"]:
    sk.drawLabel(
      label,
      origin + vec2(x, y),
      vec2(48, 20),
      rgbx(166, 174, 190, 255),
      "Small"
    )
    writeInt(hudScratch, values[i])
    sk.drawLabel(
      hudScratch,
      origin + vec2(x + 48, y),
      vec2(22, 20),
      color
    )
    x += 72

proc drawSlotCosts(
    sk: Silky,
    origin,
    size: Vec2,
    gold,
    wood: int32
) =
  ## Draws gold and lumber costs on one command portrait.
  sk.drawRect(
    origin + vec2(0, size.y - 36),
    vec2(size.x, 36),
    rgbx(12, 14, 20, 200)
  )
  sk.drawSprite("gold", origin + vec2(6, size.y - 34), vec2(14))
  writeInt(hudScratch, gold.int)
  sk.drawLabel(
    hudScratch,
    origin + vec2(22, size.y - 36),
    vec2(size.x - 28, 18),
    rgbx(232, 196, 86, 255),
    "Small"
  )
  sk.drawSprite("wood", origin + vec2(6, size.y - 18), vec2(14))
  writeInt(hudScratch, wood.int)
  sk.drawLabel(
    hudScratch,
    origin + vec2(22, size.y - 18),
    vec2(size.x - 28, 18),
    rgbx(196, 168, 120, 255),
    "Small"
  )

proc drawUi*(
    sk: Silky,
    window: Window,
    transport: var player.Player,
    cameraTarget: Vec3,
    cameraDistance: float32,
    viewMode: var int32,
    primaryId: var int32,
    selectedIds: var seq[int32],
    followSelection: var bool,
    actionCam: var ActionCam
) =
  ## Draws every Silky HUD panel for the current frame.
  let
    chrome = currentChrome(window)
    scorePanel = sk.beginImagePanel(chrome.score, "lvd_leftTop")
    minimapPanel = sk.beginImagePanel(chrome.minimap, "lvd_leftRight")
    selectionPanel = sk.beginImagePanel(
      chrome.selection,
      "lvd_bottomLeft"
    )
    buildPanel = sk.beginImagePanel(chrome.build, "lvd_bottomRight")
    light = run.world.players[LightPlayer]
    resourceBox = scorePanel.imageSlot(16, 188, 240, 252)

  sk.drawLabel(
    "WHO IS WINNING NOW?",
    scorePanel.origin + vec2(16, 8),
    vec2(320, 28),
    rgbx(224, 80, 83, 255),
    "Small"
  )
  sk.drawScoreRow(scorePanel.origin + vec2(16, 0), LightPlayer, 48)
  sk.drawScoreRow(scorePanel.origin + vec2(16, 0), DarkPlayer, 96)

  sk.drawLabel(
    "RESOURCES",
    resourceBox.origin,
    vec2(resourceBox.size.x, 20),
    rgbx(200, 205, 216, 255),
    "Small"
  )
  let resourceRows = [
    ("GOLD", light.gold, gatherRate(light.goldGathered)),
    ("WOOD", light.wood, gatherRate(light.woodGathered)),
    ("FOOD", light.foodUsed, 0'i32)
  ]
  for i, row in resourceRows:
    let y = 28.0'f32 + i.float32 * 48
    sk.drawSprite(
      ResourceIcons[i],
      resourceBox.origin + vec2(0, y + 8),
      vec2(16)
    )
    if i == 2:
      writeRatio(hudScratch, row[1].int, light.foodCap.int)
    else:
      writeAmount(hudScratch, row[1].int)
    sk.drawLabel(
      row[0],
      resourceBox.origin + vec2(22, y),
      vec2(52, 20),
      rgbx(166, 174, 190, 255),
      "Small"
    )
    sk.drawLabel(
      hudScratch,
      resourceBox.origin + vec2(76, y),
      vec2(80, 20)
    )
    hudScratch.setLen(0)
    hudScratch.add '+'
    hudScratch.addHudInt(row[2].int)
    hudScratch.add " /m"
    sk.drawLabel(
      hudScratch,
      resourceBox.origin + vec2(156, y),
      vec2(72, 20),
      rgbx(120, 196, 90, 255),
      "Small"
    )

  let strip = minimapPanel.imageSlot(12, 10, 700, 50)
  sk.drawSprite("gold", strip.origin + vec2(8, 16), vec2(16))
  sk.drawLabel(
    formatAmount(light.gold.int),
    strip.origin + vec2(28, 12),
    vec2(80, 28),
    rgbx(232, 196, 86, 255)
  )
  sk.drawSprite(
    "wood",
    strip.origin + vec2(180, 16),
    vec2(16)
  )
  sk.drawLabel(
    formatAmount(light.wood.int),
    strip.origin + vec2(200, 12),
    vec2(80, 28),
    rgbx(196, 168, 120, 255)
  )
  sk.drawSprite(
    "food",
    strip.origin + vec2(350, 16),
    vec2(16)
  )
  hudScratch.setLen(0)
  hudScratch.addHudInt(light.foodUsed.int)
  hudScratch.add '/'
  hudScratch.addHudInt(light.foodCap.int)
  sk.drawLabel(
    hudScratch,
    strip.origin + vec2(370, 12),
    vec2(80, 28),
    rgbx(160, 200, 160, 255)
  )
  let hudTime = currentHudTime()
  sk.drawSprite(
    if hudTime.hour < 6 or hudTime.hour >= 18: "night" else: "day",
    strip.origin + vec2(500, 16),
    vec2(16)
  )
  writeClock(hudScratch, hudTime.hour, hudTime.minute)
  sk.drawLabel(
    hudScratch,
    strip.origin + vec2(522, 12),
    vec2(160, 28),
    rgbx(247, 221, 143, 255)
  )
  let
    well = minimapPanel.minimapWell()
    area = minimapPanel.minimapMap()
  const MapSampleStride = 2'i32
  let cell = area.size.x / float32(GridSide)
  sk.drawRoundedRect(
    well.origin,
    well.size,
    rgbx(16, 18, 22, 255),
    wellRadius(well.size)
  )
  sk.drawRoundedRect(
    area.origin,
    area.size,
    rgbx(24, 30, 24, 255),
    wellRadius(area.size)
  )
  for y in countup(0'i32, GridSide - 1, MapSampleStride):
    for x in countup(0'i32, GridSide - 1, MapSampleStride):
      let index = tileIndex(x, y)
      var shade =
        if run.world.map.passable[index] == 0: rgbx(42, 68, 112, 255)
        else:
          case run.world.map.kinds[index]
          of 5'u8: rgbx(32, 62, 38, 255)
          of 1'u8: rgbx(146, 128, 88, 255)
          of 3'u8: rgbx(84, 92, 66, 255)
          else: rgbx(66, 96, 58, 255)
      if viewMode != 0:
        if not run.world.explored(viewMode - 1, x, y):
          shade = rgbx(9, 11, 15, 255)
        elif not run.world.visible(viewMode - 1, x, y):
          shade = rgbx(shade.r div 2, shade.g div 2, shade.b div 2, 255)
      let (pos, size) = minimapCell(x, y, MapSampleStride, area)
      sk.drawRect(pos, size, shade)
  for structure in run.world.buildings:
    if structure.owner < 0 or not shownBuilding(structure, viewMode):
      continue
    let point = minimapPoint(structure.origin, area)
    if isPicked(structure.id, selectedIds):
      sk.drawRect(point - vec2(2), vec2(cell * 3 + 4), rgbx(238, 235, 205, 255))
    sk.drawRect(
      point,
      vec2(cell * 3, cell * 3),
      playerColor(structure.owner)
    )
  for unit in run.world.units:
    if unit.state == UnitDying or not shownUnit(unit, viewMode):
      continue
    let point = minimapPoint(unit.tile, area)
    if isPicked(unit.id, selectedIds):
      sk.drawRect(point - vec2(2), vec2(cell * 1.5 + 4), rgbx(238, 235, 205, 255))
    sk.drawRect(
      point,
      vec2(cell * 1.5, cell * 1.5),
      playerColor(unit.owner)
    )
  sk.drawMinimapCamera(window, area, cameraTarget, cameraDistance)
  for index in 0 .. 3:
    let
      button = minimapPanel.imageSlot(
        530 + index.float32 * 62,
        374,
        58,
        52
      )
      hot = viewMode == int32(index)
    if hot:
      sk.drawRect(
        button.origin + vec2(4),
        button.size - vec2(8),
        rgbx(64, 84, 122, 180)
      )
    sk.drawLabel(
      ViewLabels[index],
      button.origin,
      button.size,
      rgbx(226, 230, 239, 255),
      "Small",
      CenterAlign
    )
    if index < 3 and window.clicked(sk, button):
      if options.playerSlot == 0:
        viewMode = int32(index)

  if primaryId == NoEntity or
      (not run.world.hasUnit(primaryId) and
        not run.world.hasBuilding(primaryId)):
    primaryId = NoEntity
  var
    portraitKey = ""
    portraitHp = 0'i32
    portraitMax = 1'i32
    portraitId = primaryId
    portraitName = "NO SELECTION"
    portraitStatus = ""
  for id in selectedIds:
    if id.isUnitId and run.world.hasUnit(id):
      portraitId = id
      break
  if portraitId.isUnitId and run.world.hasUnit(portraitId):
    let unit = run.world.units[run.world.unitIndex(portraitId)]
    portraitKey = unitPortraitKey(unit.owner, unit.kind)
    portraitHp = unit.hp
    portraitMax = UnitTable[unit.owner][unit.kind].hp
    portraitName = unit.kind.unitName(unit.owner)
    hudScratch.setLen(0)
    hudScratch.add UnitStateNames[unit.state]
    hudScratch.add "  "
    hudScratch.addAmount(unit.carryGold.int)
    hudScratch.add "g "
    hudScratch.addAmount(unit.carryWood.int)
    hudScratch.add 'w'
    portraitStatus = hudScratch
  elif portraitId != NoEntity and run.world.hasBuilding(portraitId):
    let structure = run.world.buildings[
      run.world.buildingIndex(portraitId)
    ]
    portraitKey = buildingPortraitKey(
      max(structure.owner, 0),
      structure.kind
    )
    portraitHp = structure.hp
    portraitMax = max(structure.maxHp, 1)
    portraitName = structure.kind.buildingName(structure.owner)
    if structure.kind == GoldMineBuilding:
      hudScratch.setLen(0)
      hudScratch.add "Gold left "
      hudScratch.addAmount(structure.goldLeft.int)
      portraitStatus = hudScratch
    elif structure.state == BuildingUnderConstruction:
      portraitStatus = "Building"
    elif structure.queueLength > 0:
      portraitStatus = "Training"
    else:
      portraitStatus = BuildingStateNames[structure.state]
  let
    selectPortrait = selectionPanel.imageSlot(18, 15, 169, 136)
    selectBar = selectionPanel.imageSlot(18, 160, 169, 23)
    selectName = selectionPanel.imageSlot(18, 186, 169, 22)
    selectStatus = selectionPanel.imageSlot(18, 208, 169, 32)
  sk.drawPortrait(selectPortrait, portraitKey)
  writeRatio(hudScratch, portraitHp.int, portraitMax.int)
  sk.drawValueBar(
    selectBar.origin,
    selectBar.size,
    portraitHp.float32,
    portraitMax.float32,
    rgbx(70, 190, 95, 255),
    hudScratch
  )
  sk.drawLabel(
    portraitName,
    selectName.origin,
    selectName.size,
    rgbx(226, 230, 239, 255),
    "Small"
  )
  if portraitStatus.len > 0:
    sk.drawLabel(
      portraitStatus,
      selectStatus.origin,
      selectStatus.size,
      rgbx(166, 174, 190, 255),
      "Small"
    )
  var
    shown = 0
    clickedId = NoEntity
  for id in selectedIds:
    if shown >= 10:
      break
    if not id.isUnitId or not run.world.hasUnit(id):
      continue
    let
      unit = run.world.units[run.world.unitIndex(id)]
      slot = selectionPanel.imageSlot(
        SelectionGrid[shown].x,
        SelectionGrid[shown].y,
        SelectionSlotSize.x,
        SelectionSlotSize.y
      )
    sk.drawPortrait(
      slot,
      unitPortraitKey(unit.owner, unit.kind)
    )
    if id == primaryId:
      sk.drawRect(
        slot.origin,
        vec2(slot.size.x, 3),
        rgbx(238, 216, 120, 255)
      )
    if window.clicked(sk, slot):
      clickedId = id
    inc shown
  if clickedId != NoEntity:
    actionCam.takeManual()
    if shiftHeld(window):
      dropSelected(selectedIds, primaryId, clickedId)
    else:
      selectedIds.setLen(0)
      selectedIds.add clickedId
      primaryId = clickedId
  if shown == 0 and
      primaryId.isBuildingId and
      run.world.hasBuilding(primaryId):
    let structure = run.world.buildings[
      run.world.buildingIndex(primaryId)
    ]
    for slot in 0 ..< min(QueueSlots, 10):
      let
        well = selectionPanel.imageSlot(
          SelectionGrid[slot].x,
          SelectionGrid[slot].y,
          SelectionSlotSize.x,
          SelectionSlotSize.y
        )
        filled = slot < structure.queueLength
      if filled:
        let kind = UnitKind(structure.queue[slot] - 1)
        sk.drawPortrait(
          well,
          unitPortraitKey(max(structure.owner, 0), kind)
        )
      if filled and slot == 0:
        sk.drawRect(
          well.origin,
          vec2(well.size.x, 3),
          rgbx(238, 216, 120, 255)
        )

  for i, label in CommandTabs:
    let
      tab = buildPanel.imageSlot(
        CommandTabXs[i],
        18,
        CommandTabWs[i],
        36
      )
      tint =
        if commandTab == i: rgbx(235, 216, 154, 255)
        else: rgbx(150, 158, 172, 255)
    sk.drawSprite(
      CommandTabIcons[i],
      tab.origin + vec2(8, 6),
      vec2(24),
      tint
    )
    sk.drawLabel(
      label,
      tab.origin + vec2(34, 0),
      tab.size - vec2(40, 0),
      tint,
      "Small",
      CenterAlign
    )
    if window.clicked(sk, tab):
      commandTab = i
  if commandTab == 0:
    for index in 0 .. 9:
      let slot = buildPanel.imageSlot(
        BuildGrid[index].x,
        BuildGrid[index].y,
        BuildSlotSize.x,
        BuildSlotSize.y
      )
      if index <= BuildableHigh.ord:
        let
          kind = BuildingKind(index)
          stats = BuildingTable[kind]
          player = commandPlayer(viewMode)
        sk.drawPortrait(
          slot,
          buildingPortraitKey(LightPlayer, kind),
          commandPortraitColor(run.world.canBuild(player, kind))
        )
        sk.drawSlotCosts(
          slot.origin,
          slot.size,
          stats.gold,
          stats.wood
        )
        if options.playerSlot > 0 and
            not run.replayMode and
            window.clicked(sk, slot):
          pendingBuild = int32(kind.ord)
  elif commandTab == 1:
    for kind in UnitKind:
      let
        slot = buildPanel.imageSlot(
          BuildGrid[kind.ord].x,
          BuildGrid[kind.ord].y,
          BuildSlotSize.x,
          BuildSlotSize.y
        )
        stats = UnitTable[LightPlayer][kind]
        player = commandPlayer(viewMode)
      sk.drawPortrait(
        slot,
        unitPortraitKey(LightPlayer, kind),
        commandPortraitColor(
          canShowTrain(player, primaryId, kind)
        )
      )
      sk.drawSlotCosts(
        slot.origin,
        slot.size,
        stats.gold,
        stats.wood
      )
      if options.playerSlot > 0 and
          not run.replayMode and
          window.clicked(sk, slot):
        let player = options.playerSlot - 1
        if primaryId.isBuildingId and
            run.world.buildingOwner(primaryId) == player:
          queueTrain(player, primaryId, int32(kind.ord))
  else:
    sk.drawLabel(
      "No upgrades",
      buildPanel.origin + vec2(25, 66),
      vec2(523, 28),
      rgbx(150, 160, 178, 255),
      "Small",
      CenterAlign
    )

  transport.drawTransport(
    sk,
    window,
    chrome.layout.transportPanel,
    actionCam,
    followSelection
  )

  if run.world.over:
    sk.drawLabel(
      describeResult(),
      vec2(0, chrome.layout.gameAreaSize.y * 0.5'f32 - 40),
      vec2(chrome.layout.size.x, 40),
      rgbx(240, 226, 180, 255),
      "H1",
      CenterAlign
    )

  if run.hashCheck.mismatches > 0:
    sk.drawError(
      chrome.layout.size,
      &"REPLAY DIVERGED - {run.hashCheck.mismatches} mismatches, " &
        &"first at tick {run.hashCheck.firstTick}"
    )
