## Call to Adventure Silky HUD.

import
  std/[strformat, strutils],
  chroma, pixie, silky, vmath, windy,
  polyworld/[actioncam, chrome, gameuis, inputs, pathing, player, rtscameras,
    stackpanels],
  content, maps, sim, game, controls, layouts

const
  ## Icons draw at power-of-two sizes so the 128 and 256 px source art
  ## lands on exact mip levels and stays crisp.
  IconTiny = 16.0'f32
  IconSmall = 64.0'f32
  DividerColor = rgbx(94, 80, 56, 255)
  ActionKeys = [
    "Q", "W", "E", "R", "F", "G"
  ]
  HeroNames: array[HeroClass, string] = [
    "Brom", "Nyra", "Fenn", "Zyra"
  ]
  HeroTitles: array[HeroClass, string] = [
    "Fighter", "Wizard", "Rogue", "Cleric"
  ]
  HeroPortraitKeys*: array[HeroClass, string] = [
    "hero_fighter", "hero_wizard", "hero_rogue", "hero_cleric"
  ]
type
  HudChrome = object
    layout: GameUiLayout
    party: GameUiPanel
    chat: GameUiPanel
    minimap: GameUiPanel
    quest: GameUiPanel
    abilities: GameUiPanel
    inventory: GameUiPanel

proc placeChrome(layout: GameUiLayout): HudChrome =
  ## Places every textured HUD panel in one layout space.
  result.layout = layout
  result.party = layout.panel(GameUiRegion.TopLeft, PanelParty)
  result.chat = layout.panel(GameUiRegion.BottomLeft, PanelChat)
  result.minimap = layout.panel(GameUiRegion.TopRight, PanelMinimap)
  result.quest = layout.panel(GameUiRegion.TopCenter, PanelQuest)
  result.abilities = layout.panel(
    GameUiRegion.BottomCenter,
    PanelAbilities
  )
  result.inventory = layout.panel(
    GameUiRegion.BottomRight,
    PanelInventory
  )

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

proc minimapMap(panel: GameUiPanel): GameUiPanel =
  ## Returns the square that bounds the circular minimap well.
  panel

proc minimapInner(panel: GameUiPanel): GameUiPanel =
  ## Returns the map disk inside the circular rim.
  panel.minimapMap().inset(12)

proc insideMinimapCircle(area: GameUiPanel, point: Vec2): bool =
  ## Returns whether a point sits inside the circular map well.
  let
    radius = area.size.x * 0.5'f32
    delta = point - (area.origin + vec2(radius))
  delta.x * delta.x + delta.y * delta.y <= radius * radius

proc mouseOverUi*(window: Window, mouse: Vec2): bool =
  ## Returns whether camera input begins inside any visible HUD panel.
  if mouseOverDebugMenu(mouse):
    return true
  let chrome = currentChrome(window)
  if insideMinimapCircle(chrome.minimap.minimapInner(), mouse):
    return true
  mouseOverPanels(
    mouse,
    chrome.layout,
    [
      chrome.party,
      chrome.chat,
      chrome.quest,
      chrome.abilities,
      chrome.inventory
    ]
  )

proc heroColor(class: HeroClass): ColorRGBX =
  ## Returns the stable presentation color for one party role.
  case class
  of FighterClass: rgbx(194, 125, 62, 255)
  of WizardClass: rgbx(126, 89, 210, 255)
  of RogueClass: rgbx(57, 153, 181, 255)
  of ClericClass: rgbx(213, 177, 73, 255)

proc healthColor(actor: Actor): ColorRGBX =
  ## Returns a health color that moves from green through yellow to red.
  let ratio =
    if actor.maxHp <= 0:
      0'i32
    else:
      int32(actor.hp) * 100 div int32(actor.maxHp)
  if ratio > 60:
    rgbx(62, 190, 89, 255)
  elif ratio > 30:
    rgbx(229, 184, 54, 255)
  else:
    rgbx(216, 67, 62, 255)

proc abilityIconKey(ability: Ability): string =
  ## Returns the atlas name packed from one ability art file.
  "ability_" & AbilityIconFiles[ability]

proc progressExperience(game: Game): int32 =
  ## Derives presentation-only party experience from expedition progress.
  game.world.killed * 25 + game.world.collected * 10 +
    game.world.deepest * 100

proc heroLevel(game: Game): int32 =
  ## Returns the displayed party level without changing simulation state.
  1 + game.progressExperience div 250

proc selectedVisible*(tile: TileRef): bool =
  ## Returns whether any living party member sees a tile.
  for slot in 0 ..< min(PartySize, run.world.actors.len):
    if run.world.actors[slot].alive and
        run.world.visible(int32(slot), tile):
      return true

proc clockHour*(): float32 =
  ## The accelerated expedition clock in hours, 0 ..< 24 with a fraction:
  ## the party sets out at 10:00 and one real second is one game minute.
  let total = 10 * 60 + int(run.world.tick) div int(TickRate)
  float32(total mod (24 * 60)) / 60

proc smoothClockHour*(tick: float32): float32 =
  ## The same expedition clock from a fractional tick (whole ticks plus the
  ## frame's sub-tick blend), continuous instead of stepping once per whole
  ## game minute — the sun and its shadows glide with it.
  var minutes = 10.0'f32 * 60.0'f32 + tick / float32(TickRate)
  minutes = minutes - float32(24 * 60) * floor(minutes / float32(24 * 60))
  minutes / 60.0'f32

proc hudHour(): int =
  ## Returns the displayed hour of the accelerated expedition clock.
  int(clockHour())

proc addHudClock(s: var string) =
  ## Appends the accelerated expedition clock.
  let
    total = 10 * 60 + int(run.world.tick) div int(TickRate)
    minuteOfDay = total mod (24 * 60)
    hour = minuteOfDay div 60
    minute = minuteOfDay mod 60
    hour12 =
      if hour mod 12 == 0: 12
      else: hour mod 12
  s.addHudInt(hour12)
  s.add ':'
  s.addPad2(minute)
  s.add ' '
  if hour < 12:
    s.add "AM"
  else:
    s.add "PM"

proc isCombatLine(line: string): bool =
  ## Returns whether a log line belongs on the combat tab.
  let lower = line.toLowerAscii
  "stir" in lower or "lost" in lower or "kill" in lower or
    "hit" in lower or "wipe" in lower

var chatTab = 0

proc questTile(level: int32): TileRef =
  ## Returns the current floor's stair or vault objective marker.
  if run.world.phase == DescendingPhase:
    if level >= LevelCount - 1:
      return run.dungeon.vault
    for ramp in run.dungeon.ramps:
      if ramp.upper == level:
        return TileRef(
          level: int8(level),
          x: uint8(ramp.topX),
          z: uint8(ramp.topZ)
        )
  else:
    if level <= 0:
      return run.dungeon.entrance
    for ramp in run.dungeon.ramps:
      if ramp.lower == level:
        return TileRef(
          level: int8(level),
          x: uint8(ramp.bottomX),
          z: uint8(ramp.bottomZ)
        )
  TileRef(level: int8(level))

proc selectHeroSlot(
    primaryId: var int,
    selectedIds: var array[PartySize, bool],
    followSelection: var bool,
    slot: int,
    additive: bool
) =
  ## Selects one party slot from a HUD click.
  if slot < 0 or slot >= min(PartySize, run.world.actors.len):
    return
  var count = 0
  for selected in selectedIds:
    if selected:
      inc count
  if not additive:
    for i in 0 ..< PartySize:
      selectedIds[i] = false
  elif selectedIds[slot] and count > 1:
    selectedIds[slot] = false
    if slot == primaryId:
      for i in 0 ..< PartySize:
        if selectedIds[i]:
          primaryId = i
          break
    followSelection = false
    for i in 0 ..< min(PartySize, run.world.actors.len):
      if selectedIds[i] and run.world.actors[i].alive:
        followSelection = true
        break
    return
  selectedIds[slot] = true
  primaryId = slot
  followSelection = run.world.actors[slot].alive

proc minimapPoint(tile: TileRef, origin, size: Vec2): Vec2 =
  ## Converts one dungeon tile into a point on the current-floor minimap.
  origin + vec2(
    float32(tile.x) / float32(GridTiles) * size.x,
    float32(tile.z) / float32(GridTiles) * size.y
  )

proc drawPip(
    sk: Silky,
    tile: TileRef,
    level: int32,
    area: GameUiPanel,
    pipSize: float32,
    color: ColorRGBX
) =
  ## Draws a centered minimap pip when its tile is on the shown floor.
  if int32(tile.level) != level:
    return
  let point = minimapPoint(tile, area.origin, area.size)
  if not insideMinimapCircle(area, point):
    return
  sk.drawRect(
    point - vec2(pipSize * 0.5'f32),
    vec2(pipSize),
    color
  )

proc updateMinimapCamera*(
    window: Window,
    mouse: Vec2,
    cameraTarget: var Vec3,
    minimapPanning: var bool,
    followSelection: var bool,
    viewLevel: int
) =
  ## Moves the free camera while the primary button drags on the minimap.
  let
    chrome = currentChrome(window)
    area = chrome.minimap.minimapInner()
  if window.mousePressed(MouseLeft) and
      insideMinimapCircle(area, mouse):
    minimapPanning = true
    followSelection = false
  if not window.mouseDown(MouseLeft):
    minimapPanning = false
  if minimapPanning:
    let
      point = minimapWorldPoint(
        mouse,
        area.origin,
        area.size,
        HalfGrid
      )
      x = clamp(int(point.x + HalfGrid), 0, GridTiles - 1)
      z = clamp(int(point.y + HalfGrid), 0, GridTiles - 1)
      tile = tileCenter(viewLevel, x, z)
    cameraTarget = vec3(point.x, tile.y, point.y)

proc drawMinimapCamera(
    sk: Silky,
    window: Window,
    origin,
    size: Vec2,
    cameraTarget: Vec3,
    cameraDistance: float32
) =
  ## Draws the fixed RTS camera's visible ground footprint.
  let
    aspect = window.size.x.float32 / max(window.size.y.float32, 1)
    viewport = minimapViewport(
      cameraTarget,
      cameraDistance,
      aspect,
      origin,
      size,
      HalfGrid
    )
  sk.drawCameraFrame(viewport, rgbx(238, 221, 168, 255))

proc drawUi*(
    sk: Silky,
    window: Window,
    transport: var Player,
    cameraTarget: Vec3,
    cameraDistance: float32,
    primaryId: var int,
    selectedIds: var array[PartySize, bool],
    followSelection: var bool,
    actionCam: var ActionCam,
    focusPlayerHero: var bool
) =
  ## Draws every Silky HUD panel for the current frame.
  let
    chrome = currentChrome(window)
    chatPanel = sk.beginFrame(chrome.chat)
    questPanel = sk.beginFrame(chrome.quest)
    detailsPanel = sk.beginFrame(chrome.abilities)
    inventoryPanel = sk.beginFrame(chrome.inventory)
    selectedActor = run.world.actors[primaryId]
    selectedClass = selectedActor.heroClass
    shownLevel = run.viewLevel(selectedIds)
    experience = run.progressExperience
    experienceInLevel = experience mod 250
    nextExperience = 250
    party = chrome.party.partyPanels()
    chat = chatPanel.chatPanels()
    quest = questPanel.questPanels()
    abilities = detailsPanel.abilityPanels()
    inventory = inventoryPanel.inventoryPanels()
  for slot in 0 ..< PartySize:
    let
      actor = run.world.actors[slot]
      class = actor.heroClass
      card = party[slot].card
      portrait = party[slot].portrait
      nameBox = party[slot].name
      hpBar = party[slot].hp
      manaBar = party[slot].mana
    discard sk.beginFrame(card)
    sk.drawWellImage(
      portrait,
      HeroPortraitKeys[class],
      if actor.alive:
        rgbx(255, 255, 255, 255)
      else:
        rgbx(140, 140, 148, 255),
      selected = selectedIds[slot],
      iconSize = IconSmall
    )
    sk.drawLabel(
      HeroNames[class],
      nameBox.origin,
      nameBox.size,
      rgbx(255, 255, 255, 255),
      "Bold"
    )
    sk.drawBar(
      hpBar.origin,
      hpBar.size,
      max(actor.hp, 0'i16).float32,
      max(actor.maxHp, 1'i16).float32,
      healthColor(actor)
    )
    sk.drawSprite(
      "health",
      hpBar.origin + vec2(2, 2),
      vec2(IconTiny),
      healthColor(actor)
    )
    writeRatio(
      hudScratch,
      max(actor.hp, 0'i16).int,
      actor.maxHp.int
    )
    sk.drawLabel(
      hudScratch,
      hpBar.origin + vec2(70, 0),
      vec2(hpBar.size.x - 136, hpBar.size.y),
      rgbx(255, 255, 255, 255),
      "Small",
      CenterAlign
    )
    hudScratch.setLen(0)
    hudScratch.add "Lv "
    hudScratch.addHudInt(run.heroLevel)
    sk.drawLabel(
      hudScratch,
      hpBar.origin + vec2(hpBar.size.x - 60, 0),
      vec2(54, hpBar.size.y),
      rgbx(153, 163, 182, 255),
      "Small",
      RightAlign
    )
    if actor.maxMana > 0:
      sk.drawValueBar(
        manaBar.origin,
        manaBar.size,
        actor.mana.float32,
        actor.maxMana.float32,
        rgbx(58, 119, 220, 255),
        (writeRatio(hudScratch, actor.mana.int, actor.maxMana.int); hudScratch)
      )
    else:
      sk.drawBar(
        manaBar.origin,
        manaBar.size,
        0,
        1,
        rgbx(58, 119, 220, 255)
      )
    sk.drawSprite(
      "mana",
      manaBar.origin + vec2(2, 2),
      vec2(IconTiny),
      rgbx(186, 214, 255, 255)
    )
    if window.clicked(sk, card):
      actionCam.takeManual()
      selectHeroSlot(
        primaryId,
        selectedIds,
        followSelection,
        slot,
        window.buttonDown[KeyLeftShift] or
          window.buttonDown[KeyRightShift]
      )
      if options.playerSlot > 0 and
          not run.replayMode and
          slot == options.playerSlot - 1:
        focusPlayerHero = true
  let
    generalTab = chat.general
    combatTab = chat.combat
    chatBody = chat.body
  sk.drawLabel(
    "General",
    generalTab.origin,
    generalTab.size,
    if chatTab == 0: rgbx(235, 216, 154, 255)
    else: rgbx(150, 158, 172, 255),
    "Small",
    CenterAlign
  )
  sk.drawLabel(
    "Combat Log",
    combatTab.origin,
    combatTab.size,
    if chatTab == 1: rgbx(235, 216, 154, 255)
    else: rgbx(150, 158, 172, 255),
    "Small",
    CenterAlign
  )
  if window.clicked(sk, generalTab):
    chatTab = 0
  if window.clicked(sk, combatTab):
    chatTab = 1
  var shown: seq[string]
  if run.log.len == 0:
    shown.add "The party enters the Surface."
  else:
    for line in run.log:
      if chatTab == 0 or line.isCombatLine:
        shown.add line
  let firstLine = max(shown.len - 6, 0)
  var logRows = chatBody.stack(TopToBottom)
  for index in firstLine ..< shown.len:
    let row = logRows.takeRow(18)
    sk.drawLabel(
      shown[index],
      row.origin,
      row.size,
      if index == shown.high:
        rgbx(229, 215, 167, 255)
      else:
        rgbx(157, 169, 187, 255),
      "Small"
    )
  let
    mapArea = chrome.minimap.minimapMap()
    mapInner = chrome.minimap.minimapInner()
    mapCell = mapInner.size.x / float32(GridTiles)
  sk.drawSprite("minimap", mapArea.origin, mapArea.size)
  const MapSampleStride = 3
  for z in countup(0, GridTiles - 1, MapSampleStride):
    for x in countup(0, GridTiles - 1, MapSampleStride):
      let
        tile = TileRef(
          level: int8(shownLevel),
          x: uint8(x),
          z: uint8(z)
        )
        pos = minimapPoint(tile, mapInner.origin, mapInner.size)
        cell = vec2(max(mapCell * MapSampleStride.float32, 1.0'f32))
        mid = pos + cell * 0.5'f32
      if not insideMinimapCircle(mapInner, mid):
        continue
      let
        known = run.world.explored(tile)
        visible = selectedVisible(tile)
        passable = tile.walkable
        shade =
          if not passable:
            if known: rgbx(34, 38, 44, 255)
            else: rgbx(12, 14, 18, 255)
          elif visible:
            rgbx(81, 103, 69, 255)
          elif known:
            rgbx(43, 58, 45, 255)
          else:
            rgbx(18, 24, 23, 255)
      sk.drawRect(pos, cell, shade)
  let objective = questTile(shownLevel)
  sk.drawPip(
    objective,
    shownLevel,
    mapInner,
    11,
    rgbx(246, 202, 59, 255)
  )
  for slot in 0 ..< PartySize:
    let actor = run.world.actors[slot]
    if actor.alive:
      sk.drawPip(
        actor.home,
        shownLevel,
        mapInner,
        if selectedIds[slot]: 9 else: 6,
        heroColor(actor.heroClass)
      )
  for actor in run.world.actors:
    if actor.kind == MonsterActor and actor.alive and
        actor.home.level == int8(shownLevel) and
        selectedVisible(actor.home):
      sk.drawPip(
        actor.home,
        shownLevel,
        mapInner,
        4,
        rgbx(216, 76, 68, 255)
      )
  sk.drawMinimapCamera(
    window,
    mapInner.origin,
    mapInner.size,
    cameraTarget,
    cameraDistance
  )
  let
    themeName = quest.theme
    questTitleBox = quest.title
    clockRow = quest.clock
    enemyRow = quest.enemies
  sk.drawLabel(
    Themes[shownLevel].name,
    themeName.origin,
    themeName.size,
    rgbx(235, 216, 154, 255),
    "Small",
    CenterAlign
  )
  sk.drawLabel(
    "Quests",
    quest.heading.origin,
    quest.heading.size,
    rgbx(198, 158, 77, 255),
    "Small"
  )
  let questTitle =
    if run.world.phase == ReturningPhase:
      "Escape the Dungeon"
    elif shownLevel >= LevelCount - 1:
      "Clear the Vault"
    elif run.monstersOn(shownLevel) > 0:
      "Clear " & Themes[shownLevel].name
    else:
      "Descend to " & Themes[shownLevel + 1].name
  sk.drawLabel(
    questTitle,
    questTitleBox.origin,
    questTitleBox.size,
    rgbx(239, 225, 180, 255),
    "Small"
  )
  let clockHour = hudHour()
  sk.drawSprite(
    if clockHour < 6 or clockHour >= 18: "night" else: "day",
    clockRow.origin,
    vec2(18)
  )
  hudScratch.setLen(0)
  hudScratch.addHudClock()
  hudScratch.add "  Floor "
  hudScratch.addHudInt(shownLevel.int + 1)
  hudScratch.add '/'
  hudScratch.addHudInt(LevelCount)
  sk.drawLabel(
    hudScratch,
    clockRow.origin + vec2(22, 0),
    clockRow.size - vec2(22, 0),
    rgbx(160, 171, 188, 255),
    "Small"
  )
  hudScratch.setLen(0)
  hudScratch.add "Enemies "
  hudScratch.addHudInt(run.monstersOn(shownLevel))
  sk.drawLabel(
    hudScratch,
    enemyRow.origin,
    enemyRow.size,
    rgbx(160, 171, 188, 255),
    "Small"
  )
  sk.drawRect(
    abilities.divider.origin + vec2(0, 1),
    abilities.divider.size - vec2(0, 1),
    DividerColor
  )
  for index, slotPanel in abilities.slots:
    if index < 4:
      sk.drawWellImage(
        slotPanel,
        abilityIconKey(HeroAbilities[selectedClass][index]),
        iconSize = IconSmall
      )
    else:
      let
        bag = index - 4
        itemId = selectedActor.inventory[bag]
        itemIndex = run.world.itemIndex(itemId)
      var icon = ""
      if itemIndex >= 0:
        let ability = LootAbilities[run.world.items[itemIndex].kind]
        if ability != NoAbility:
          icon = abilityIconKey(ability)
      sk.drawWellImage(slotPanel, icon, iconSize = IconSmall)
      if options.playerSlot > 0 and
          not run.replayMode and
          primaryId == options.playerSlot - 1:
        if window.clicked(sk, slotPanel):
          queueUseItem(int32(primaryId), int32(bag))
        elif window.buttonReleased[MouseRight] and
            slotPanel.contains(sk.mousePos):
          queueDropItem(int32(primaryId), int32(bag))
    sk.drawKeyPip(slotPanel, ActionKeys[index])
  let xpBar = abilities.xp
  sk.drawValueBar(
    xpBar.origin,
    xpBar.size,
    experienceInLevel.float32,
    nextExperience.float32,
    rgbx(151, 82, 199, 255),
    (writeRatio(hudScratch, experienceInLevel.int, nextExperience); hudScratch)
  )
  sk.drawSprite(
    "essence",
    xpBar.origin + vec2(2, 2),
    vec2(IconTiny)
  )

  sk.drawLabel(
    "INVENTORY",
    inventory.title.origin,
    inventory.title.size,
    rgbx(200, 205, 216, 255),
    "Small"
  )
  for bag, well in inventory.slots:
    var icon = ""
    if bag < InventorySlots:
      let itemIndex = run.world.itemIndex(selectedActor.inventory[bag])
      if itemIndex >= 0:
        let ability = LootAbilities[run.world.items[itemIndex].kind]
        if ability != NoAbility:
          icon = abilityIconKey(ability)
    sk.drawWellImage(well, icon, iconSize = IconSmall)
    if bag < InventorySlots and
        options.playerSlot > 0 and
        not run.replayMode and
        primaryId == options.playerSlot - 1:
      if window.clicked(sk, well):
        queueUseItem(int32(primaryId), int32(bag))
      elif window.buttonReleased[MouseRight] and
          well.contains(sk.mousePos):
        queueDropItem(int32(primaryId), int32(bag))
  let counters = [
    ("gold", formatAmount(selectedActor.carriedValue.int),
      rgbx(232, 196, 86, 255)),
    ("crystal", $run.world.collected, rgbx(220, 120, 120, 255))
  ]
  for i, counter in counters:
    let box = inventory.counters[i]
    sk.drawSprite(counter[0], box.origin, vec2(20))
    sk.drawLabel(
      counter[1],
      box.origin + vec2(31, 0),
      vec2(box.size.x - 31, box.size.y),
      counter[2],
      "Hud",
      RightAlign
    )
  transport.drawTransport(
    sk,
    window,
    chrome.layout.transportPanel,
    actionCam,
    followSelection
  )
  if run.hashCheck.mismatches > 0:
    sk.drawError(
      chrome.layout.size,
      &"REPLAY DIVERGED - {run.hashCheck.mismatches} mismatches, " &
        &"first at tick {run.hashCheck.firstTick}"
    )
  sk.drawDebugMenu(window)
