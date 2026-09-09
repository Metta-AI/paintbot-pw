## Light vs Dark Silky HUD.

import
  std/strformat,
  chroma, pixie, silky, vmath, windy,
  polyworld/[actioncam, chrome, gameuis, inputs, pathing, player, rtscameras,
    stackpanels],
  content, sim, game, controls, layouts

const
  ResourceColors = [
    rgbx(232, 196, 86, 255),
    rgbx(196, 168, 120, 255),
    rgbx(160, 200, 160, 255)
  ]
  ## Icons draw at power-of-two sizes so the 128 and 256 px source art
  ## lands on exact mip levels and stays crisp.
  IconTiny = 16.0'f32
  IconSmall = 64.0'f32
  IconLarge = 128.0'f32
  WellPad = 4.0'f32
  IconTint = rgbx(245, 230, 190, 255)
  ScoreIcons = ["tower", "kills", "deaths"]
  CommandTabs = ["BUILD", "UNITS", "UPGRADES"]
  ViewLabels = ["A", "L", "D"]
  ResourceIcons = ["gold", "wood", "food"]
  CommandTabIcons = ["build", "units", "research"]
  ViewButtonSize = 32.0'f32
  SelectionIcon = 48.0'f32
  GridBarH = 12.0'f32
  HealthColor = rgbx(70, 190, 95, 255)
  CostFill = rgbx(12, 14, 20, 200)
  CommandTabH = 28.0'f32
  CommandTabLift = 4.0'f32

var commandTab = 0

type
  HudChrome = object
    layout: GameUiLayout
    score: GameUiPanel
    resources: GameUiPanel
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

proc drawPortrait(
    sk: Silky,
    well: GameUiPanel,
    key: string,
    iconSize: float32,
    color = rgbx(255, 255, 255, 255)
) =
  ## Draws a profile sprite at a fixed size centered in a well.
  sk.drawWellImage(well, key, color, iconSize = iconSize)

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
  result.resources = layout.panel(GameUiRegion.TopCenter, PanelResources)
  result.minimap = layout.panel(GameUiRegion.TopRight, PanelMinimap)
  result.selection = layout.panel(
    GameUiRegion.BottomLeft,
    PanelSelection
  )
  result.build = layout.panel(GameUiRegion.BottomRight, PanelBuild)

proc currentLayout*(window: Window): GameUiLayout =
  ## Returns the nine-region HUD layout in Silky layout space.
  initGameUiLayout(
    vec2(window.size.x.float32, window.size.y.float32) /
      gameUiScale(window),
    TransportHeight
  )

proc currentChrome(window: Window): HudChrome =
  ## Places every textured HUD panel for the current window.
  placeChrome(currentLayout(window))

proc mouseOverUi*(window: Window, mouse: Vec2): bool =
  ## Returns whether the pointer is over an anchored game UI panel.
  if mouseOverDebugMenu(mouse):
    return true
  let chrome = currentChrome(window)
  mouseOverPanels(
    mouse,
    chrome.layout,
    [
      chrome.score,
      chrome.resources,
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

proc minimapMap(panel: GameUiPanel): GameUiPanel =
  ## Returns the same stacked map rectangle used for rendering and input.
  panel.minimapPanels().map

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
    panels: ScorePanels,
    player: int32,
    row: int
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
  sk.drawSprite(
    if player == LightPlayer: "alliance" else: "hostile",
    panels.sides[row].origin,
    vec2(IconTiny),
    color
  )
  for i, cell in panels.values[row]:
    writeInt(hudScratch, values[i])
    sk.drawLabel(
      hudScratch,
      cell.origin,
      cell.size,
      color,
      "Default",
      CenterAlign
    )

proc drawSlotCosts(
    sk: Silky,
    slot: GameUiPanel,
    gold,
    wood: int32
) =
  ## Draws gold and lumber costs over one hovered command portrait.
  if not sk.hovered(slot):
    return
  let inner = slot.inset(WellPad)
  sk.drawRect(inner.origin, inner.size, CostFill)
  var costs = slot.stack(BottomToTop, vec2(7, 6))
  for i, value in [wood, gold]:
    let
      row = costs.takeRow(18, 3)
      resource = 1 - i
    sk.drawSprite(
      ResourceIcons[resource],
      row.origin + vec2(0, 1),
      vec2(IconTiny)
    )
    writeInt(hudScratch, value.int)
    sk.drawLabel(
      hudScratch,
      row.origin + vec2(16, 0),
      vec2(row.size.x - 16, row.size.y),
      ResourceColors[resource],
      "Small",
      RightAlign
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
    scorePanel = sk.beginFrame(chrome.score)
    scoreSlots = scorePanel.scorePanels()
    resourcePanel = sk.beginFrame(chrome.resources)
    minimapPanel = sk.beginFrame(chrome.minimap)
    selectionPanel = sk.beginFrame(chrome.selection)
    buildPanel = sk.beginFrame(chrome.build)
    light = run.world.players[LightPlayer]
    resources = resourcePanel.resourcePanels()
    minimap = minimapPanel.minimapPanels()
    selection = selectionPanel.selectionPanels()
    build = buildPanel.buildPanels()

  for i, label in ["TOWERS", "KILLS", "DEATHS"]:
    let pos = scoreSlots.headers[i].origin
    sk.drawSprite(
      ScoreIcons[i], pos + vec2(0, 1), vec2(IconTiny), IconTint
    )
    sk.drawLabel(
      label,
      pos + vec2(IconTiny + 4, 0),
      vec2(68, 20),
      rgbx(166, 174, 190, 255),
      "Hud"
    )
  sk.drawScoreRow(scoreSlots, LightPlayer, 0)
  sk.drawScoreRow(scoreSlots, DarkPlayer, 1)

  let resourceRows = [
    ("GOLD", light.gold),
    ("WOOD", light.wood),
    ("FOOD", light.foodUsed)
  ]
  for i, row in resourceRows:
    let
      cell = resources[i]
    var contents = cell.stack(LeftToRight, vec2(5, 2))
    contents.gap(2)
    let
      icon = contents.take(vec2(16, 24), 9)
      caption = contents.take(vec2(33, 24))
      amount = contents.takeRest()
    sk.drawFaintFrame(cell)
    sk.drawSprite(
      ResourceIcons[i],
      icon.origin + vec2(0, 4),
      vec2(IconTiny)
    )
    sk.drawLabel(
      row[0],
      caption.origin + vec2(0, 3),
      vec2(caption.size.x, 20),
      rgbx(166, 174, 190, 255),
      "Small"
    )
    if i == 2:
      writeRatio(hudScratch, row[1].int, light.foodCap.int)
    else:
      writeAmount(hudScratch, row[1].int)
    sk.drawLabel(
      hudScratch,
      amount.origin,
      amount.size,
      ResourceColors[i],
      "Hud",
      RightAlign
    )

  let hudTime = currentHudTime()
  sk.drawSprite(
    if hudTime.hour < 6 or hudTime.hour >= 18: "night" else: "day",
    minimap.sun.origin + vec2(0, 2),
    vec2(ViewButtonSize)
  )
  writeClock(hudScratch, hudTime.hour, hudTime.minute)
  sk.drawLabel(
    hudScratch,
    minimap.clock.origin + vec2(0, 6),
    vec2(80, 24),
    rgbx(247, 221, 143, 255),
    "Small"
  )
  let area = minimapPanel.minimapMap()
  const MapSampleStride = 2'i32
  let cell = area.size.x / float32(GridSide)
  sk.drawFrame(area)
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
  for index, button in minimap.views:
    let
      hot = viewMode == int32(index)
    sk.drawSlot(button, selected = hot)
    sk.drawLabel(
      ViewLabels[index],
      button.origin,
      button.size,
      rgbx(226, 230, 239, 255),
      "Small",
      CenterAlign
    )
    if window.clicked(sk, button):
      if options.playerSlot == 0:
        viewMode = int32(index)

  if primaryId == NoEntity or
      (not run.world.hasUnit(primaryId) and
        not run.world.hasBuilding(primaryId)):
    primaryId = NoEntity
  # The first selection fills the main portrait; the rest fill the grid.
  var
    portraitKey = ""
    portraitHp = 0'i32
    portraitMax = 1'i32
    portraitId = primaryId
    portraitName = "NO SELECTION"
  if portraitId == NoEntity:
    for id in selectedIds:
      if (id.isUnitId and run.world.hasUnit(id)) or
          (id.isBuildingId and run.world.hasBuilding(id)):
        portraitId = id
        break
  if portraitId.isUnitId and run.world.hasUnit(portraitId):
    let unit = run.world.units[run.world.unitIndex(portraitId)]
    portraitKey = unitPortraitKey(unit.owner, unit.kind)
    portraitHp = unit.hp
    portraitMax = UnitTable[unit.owner][unit.kind].hp
    portraitName = unit.kind.unitName(unit.owner)
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
  let
    selectPortrait = selection.portrait
    selectBar = selection.hp
    selectName = selection.name
  sk.drawPortrait(selectPortrait, portraitKey, IconLarge)
  writeRatio(hudScratch, portraitHp.int, portraitMax.int)
  sk.drawValueBar(
    selectBar.origin,
    selectBar.size,
    portraitHp.float32,
    portraitMax.float32,
    HealthColor,
    hudScratch
  )
  sk.drawLabel(
    portraitName,
    selectName.origin,
    selectName.size,
    rgbx(226, 230, 239, 255),
    "Small"
  )
  var
    shown = 0
    clickedId = NoEntity
  for id in selectedIds:
    if shown >= selection.units.len:
      break
    if id == portraitId or not id.isUnitId or not run.world.hasUnit(id):
      continue
    let
      unit = run.world.units[run.world.unitIndex(id)]
      slot = selection.units[shown]
    sk.drawPortrait(
      slot,
      unitPortraitKey(unit.owner, unit.kind),
      SelectionIcon
    )
    sk.drawBar(
      slot.origin + vec2(WellPad, slot.size.y - GridBarH),
      vec2(SelectionIcon, GridBarH),
      unit.hp.float32,
      UnitTable[unit.owner][unit.kind].hp.float32,
      HealthColor
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
    for slot in 0 ..< min(QueueSlots, selection.units.len):
      let
        well = selection.units[slot]
        filled = slot < structure.queueLength
      if filled:
        let kind = UnitKind(structure.queue[slot] - 1)
        sk.drawPortrait(
          well,
          unitPortraitKey(max(structure.owner, 0), kind),
          SelectionIcon
        )
      if filled and slot == 0:
        sk.drawRect(
          well.origin,
          vec2(well.size.x, 3),
          rgbx(238, 216, 120, 255)
        )

  for i, label in CommandTabs:
    let
      selected = commandTab == i
      lift = if selected: CommandTabLift else: 0.0'f
      tab = GameUiPanel(
        origin: build.tabs[i].origin - vec2(0, lift),
        size: build.tabs[i].size + vec2(0, lift)
      )
      over = sk.hovered(tab)
      tint =
        if selected: rgbx(235, 216, 154, 255)
        elif over: rgbx(210, 214, 224, 255)
        else: rgbx(150, 158, 172, 255)
    sk.drawTab(tab, selected, over)
    sk.drawSprite(
      CommandTabIcons[i],
      tab.origin + vec2(5, tab.size.y - CommandTabH + 6),
      vec2(IconTiny),
      tint
    )
    sk.drawLabel(
      label,
      tab.origin + vec2(22, 0),
      tab.size - vec2(24, 0),
      tint,
      "Hud",
      CenterAlign
    )
    if window.clicked(sk, tab):
      commandTab = i
  if commandTab == 0:
    for index in 0 ..< build.slots.len:
      let slot = build.slots[index]
      if index <= BuildableHigh.ord:
        let
          kind = BuildingKind(index)
          stats = BuildingTable[kind]
          player = commandPlayer(viewMode)
        sk.drawPortrait(
          slot,
          buildingPortraitKey(LightPlayer, kind),
          IconSmall,
          commandPortraitColor(run.world.canBuild(player, kind))
        )
        sk.drawSlotCosts(slot, stats.gold, stats.wood)
        if options.playerSlot > 0 and
            not run.replayMode and
            window.clicked(sk, slot):
          pendingBuild = int32(kind.ord)
  elif commandTab == 1:
    for kind in UnitKind:
      let
        slot = build.slots[kind.ord]
        stats = UnitTable[LightPlayer][kind]
        player = commandPlayer(viewMode)
      sk.drawPortrait(
        slot,
        unitPortraitKey(LightPlayer, kind),
        IconSmall,
        commandPortraitColor(
          canShowTrain(player, primaryId, kind)
        )
      )
      sk.drawSlotCosts(slot, stats.gold, stats.wood)
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
      build.contents.origin,
      vec2(build.contents.size.x, 28),
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
  sk.drawDebugMenu(window)
