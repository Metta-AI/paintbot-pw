## Gods of the Arena Silky HUD.

import
  std/[strformat, strutils],
  chroma, pixie, silky, vmath, windy,
  polyworld/[actioncam, chrome, gameuis, inputs, pathing, player, rtscameras],
  content, sim, game, controls

const
  ## Plate sizes and inner offsets are laid out for a 1920 wide layout at
  ## UI scale 1.
  PanelScore = vec2(298, 104)
  PanelHeroes = vec2(1051, 145)
  PanelClock = vec2(128, 86)
  PanelMinimap = vec2(256, 256)
  PanelDetails = vec2(859, 242)
  PanelInventory = vec2(252, 243)
  HudClearance = 48.0'f32
  ## Icons draw at power-of-two sizes so the 128 and 256 px source art
  ## lands on exact mip levels and stays crisp.
  IconTiny = 16.0'f32
  IconSmall = 64.0'f32
  IconLarge = 128.0'f32
  ShopIcon = 32.0'f32
  WellPad = 4.0'f32
  WellSmall = IconSmall + WellPad * 2
  ShopWell = ShopIcon + WellPad * 2
  BadgeSmall = 18.0'f32
  BadgeLarge = 64.0'f32
  ScoreHeaderXs = [14.0'f32, 115, 205]
  ScoreHeaderY = 11.0'f32
  ScoreValueXs = [43.0'f32, 133, 223]
  ScoreValueW = 40.0'f32
  ScoreRowYs = [31.0'f32, 61]
  ScoreRowH = 25.0'f32
  ScoreIconLift = 4.0'f32
  AbilityKeys = ["Q", "W", "E", "R", "F", "G"]
  ScoreIcons = ["tower", "kills", "deaths"]
  CooldownFill = rgbx(8, 10, 16, 180)
  IconTint = rgbx(245, 230, 190, 255)
  HeroPortraitKeys: array[HeroClass, string] = [
    "gota_vanguard_knight",
    "gota_ranger",
    "gota_arcanist",
    "gota_druid_warden",
    "gota_demon_hunter",
    "gota_death_knight",
    "gota_crossbowman",
    "gota_lich",
    "gota_warlock",
    "gota_berserker"
  ]
  HeroSlotXs = [21.0'f32, 116, 212, 307, 401]
  HeroSlotXsBlue = [570.0'f32, 665, 760, 856, 951]
  HeroSlotY = 10.0'f32
  HeroSlotSize = vec2(78, 80)
  HeroBarInset = (HeroSlotSize.x - IconSmall) * 0.5'f32
  HeroBarYs = [99.0'f32, 120]
  HeroBarSize = vec2(IconSmall, 12)
  AbilitySlotXs = [
    296.0'f32, 386, 476, 566, 668, 758
  ]
  AbilitySlotY = 150.0'f32
  DetailsPortrait = vec2(32, 32)
  DetailsPortraitSize = vec2(150, 150)
  DetailsBadge = vec2(14, 123)
  DetailsNameX = 194.0'f32
  DetailsNameW = 96.0'f32
  DetailsNameY = 36.0'f32
  DetailsClassY = 64.0'f32
  DetailsStatY = 86.0'f32
  DetailsBarX = 300.0'f32
  DetailsBarW = 526.0'f32
  DetailsBarYs = [36.0'f32, 74, 112]
  DetailsBarH = 28.0'f32
  InventoryTitleY = 10.0'f32
  InventoryInset = 14.0'f32
  InventorySlotsPos = [
    vec2(14, 50), vec2(90, 50), vec2(166, 50),
    vec2(14, 127), vec2(90, 127), vec2(166, 127)
  ]
  InventorySlotSize = vec2(WellSmall, WellSmall)
  InventoryGoldY = 200.0'f32
  ShopColumns = 5
  ShopOrigin = vec2(14, 48)
  ShopPitch = vec2(44, 37)

var shopOpen = false

type
  HudChrome = object
    layout: GameUiLayout
    score: GameUiPanel
    heroes: GameUiPanel
    clock: GameUiPanel
    minimap: GameUiPanel
    details: GameUiPanel
    inventory: GameUiPanel
  SelectedKind = enum
    SelectedHero,
    SelectedTower,
    SelectedMob,
    SelectedGod

  SelectedUnit = ref object
    id: int32
    kind: SelectedKind
    team: Team
    portraitKey: string
    callsign: string
    classLabel: string
    status: string
    hp: float32
    maxHp: float32
    mana: float32
    maxMana: float32
    xp: int
    nextXp: int
    gold: int
    level: int
    damage: int32
    moveSpeed: float32
    attackSpeed: float32
    attackRange: float32
    inventory: array[InventorySlots, Item]
    itemCounts: array[InventorySlots, int32]
    abilities: array[HeroAbilitySlot, Ability]
    cooldowns: array[HeroAbilitySlot, int32]

proc placeChrome(layout: GameUiLayout): HudChrome =
  ## Places every textured HUD panel in one layout space.
  result.layout = layout
  result.score = layout.panel(GameUiRegion.TopLeft, PanelScore)
  result.heroes = layout.panel(GameUiRegion.TopCenter, PanelHeroes)
  result.clock = layout.panel(GameUiRegion.TopRight, PanelClock)
  result.minimap = layout.panel(GameUiRegion.BottomLeft, PanelMinimap)
  result.details = layout.panel(GameUiRegion.BottomCenter, PanelDetails)
  result.inventory = layout.panel(
    GameUiRegion.BottomRight,
    PanelInventory
  )

proc hudLayoutFits(layoutSize: Vec2): bool =
  ## Returns whether native HUD plates fit this layout without overlap.
  let
    layout = initGameUiLayout(layoutSize, TransportHeight)
    chrome = placeChrome(layout)
  layoutFits(
    layout,
    [
      chrome.score,
      chrome.heroes,
      chrome.clock,
      chrome.minimap,
      chrome.details,
      chrome.inventory
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

proc mouseOverUi*(
    window: Window,
    mouse: Vec2,
    primaryId = 0'i32
): bool =
  ## Returns whether the pointer is over a visible game UI panel.
  if mouseOverDebugMenu(mouse):
    return true
  let chrome = currentChrome(window)
  if primaryId == 0:
    result = mouseOverPanels(
      mouse,
      chrome.layout,
      [
        chrome.score,
        chrome.heroes,
        chrome.clock,
        chrome.minimap,
        chrome.inventory
      ]
    )
  else:
    result = mouseOverPanels(
      mouse,
      chrome.layout,
      [
        chrome.score,
        chrome.heroes,
        chrome.clock,
        chrome.minimap,
        chrome.details,
        chrome.inventory
      ]
    )

proc renderPoint(position: WorldPoint): Vec3 =
  ## Converts authoritative integer coordinates at the HUD boundary.
  vec3(
    position.x.float32 / WorldScale.float32,
    position.y.float32 / WorldScale.float32,
    position.z.float32 / WorldScale.float32
  )

proc teamHudColor(team: Team): ColorRGBX =
  ## Returns a readable HUD color for one team.
  if team == RedTeam:
    rgbx(224, 80, 83, 255)
  else:
    rgbx(76, 128, 232, 255)

proc classLabel(style: HeroAttackStyle): string =
  ## Returns the compact class word shown under a hero name.
  case style
  of MeleeAttack:
    "MELEE"
  of RangedAttack:
    "RANGER"
  of MagicAttack:
    "MAGE"

proc callsign(name: string): string =
  ## Returns the first name word in HUD capitals.
  var word = name
  let space = name.find(' ')
  if space >= 0:
    word = name[0 ..< space]
  toUpperAscii(word)

proc remainingTowers(team: Team): int =
  ## Counts the towers still standing for one team.
  for tower in run.world.towers:
    if tower.team == team and tower.hp > 0:
      inc result

proc clockHour*(): float32 =
  ## The accelerated spectator clock in hours, 0 ..< 24 with a fraction:
  ## the match starts at 8:00 and a day is five minutes long.
  clockHour(run.world.tick, TickRate)

proc currentHudTime(): tuple[day, hour, minute: int] =
  ## Converts simulation ticks into the accelerated spectator clock.
  hudClock(run.world.tick, TickRate)

proc visibleInView(
    viewMode: int32,
    team: Team,
    position: WorldPoint
): bool =
  ## Applies the current omniscient or team visibility spectator mode.
  if viewMode == 0:
    return true
  let viewingTeam = Team(viewMode - 1)
  team == viewingTeam or visible(run.world, viewingTeam, position)

proc isPicked(id: int32, selectedIds: openArray[int32]): bool =
  ## Returns whether an object belongs to the current selection set.
  for selectedId in selectedIds:
    if selectedId == id:
      return true

proc selectedUnit(id: int32, viewMode: int32): SelectedUnit =
  ## Builds the current flat view of one selectable world object.
  for hero in run.world.heroes:
    if hero.id == id:
      if not visibleInView(viewMode, hero.team, hero.position):
        return nil
      let
        spec = hero.class.heroSpec
        moveSpeed = hero.heroMoveSpeed.float32 *
          TickRate.float32 / WorldScale.float32
        attackRange = heroAttackRange(hero.class).float32 /
          WorldScale.float32
        attackTicks = heroAttackTicks(hero.class).float32
      return SelectedUnit(
        id: hero.id,
        kind: SelectedHero,
        team: hero.team,
        portraitKey: HeroPortraitKeys[hero.class],
        callsign: callsign(spec.name),
        classLabel: classLabel(spec.attackStyle),
        status: if hero.state == Dying: "Respawning" else: "Ready",
        hp: max(hero.hp, 0'i32).float32,
        maxHp: hero.maxHp.float32,
        mana: hero.mana.float32,
        maxMana: hero.maxMana.float32,
        xp: hero.xp,
        nextXp:
          if hero.level < HeroMaxLevel:
            xpForNextLevel(hero.level)
          else:
            hero.xp,
        gold: hero.gold,
        level: hero.level,
        damage: hero.heroAttackDamage,
        moveSpeed: moveSpeed,
        attackSpeed: TickRate.float32 / max(attackTicks, 1),
        attackRange: attackRange,
        inventory: hero.inventory,
        itemCounts: hero.itemCounts,
        abilities: spec.abilities,
        cooldowns: hero.cooldowns
      )
  for footman in run.world.footmen:
    if footman.id == id:
      if not visibleInView(viewMode, footman.team, footman.position):
        return nil
      let
        moveSpeed = FootmanMovePerTick.float32 *
          TickRate.float32 / WorldScale.float32
        meleeRange = FootmanMeleeRange.float32 / WorldScale.float32
      return SelectedUnit(
        id: footman.id,
        kind: SelectedMob,
        team: footman.team,
        callsign: "FOOTMAN",
        classLabel: "MINION",
        status: if footman.state == Dying: "Dying" else: "Marching",
        hp: max(footman.hp, 0'i32).float32,
        maxHp: FootmanHp.float32,
        level: 1,
        damage: FootmanDamage,
        moveSpeed: moveSpeed,
        attackSpeed: 1.0'f32,
        attackRange: meleeRange
      )
  for tower in run.world.towers:
    if tower.id == id:
      if not visibleInView(viewMode, tower.team, tower.position):
        return nil
      let
        role =
          case tower.tier
          of OuterTower:
            "OUTER"
          of InnerTower:
            "INNER"
          of GateTower:
            "GATE"
        attackRange = TowerAttackRanges[tower.tier].float32 /
          WorldScale.float32
      return SelectedUnit(
        id: tower.id,
        kind: SelectedTower,
        team: tower.team,
        callsign: role,
        classLabel: "TOWER",
        status:
          if tower.hp <= 0:
            "Destroyed"
          elif towerExposed(run.world, tower):
            "Exposed"
          else:
            "Protected",
        hp: max(tower.hp, 0'i32).float32,
        maxHp: tower.maxHp.float32,
        level: tower.tier.ord + 1,
        damage: TowerDamages[tower.tier],
        attackRange: attackRange
      )
  for fort in run.world.forts:
    if fort.id == id:
      if not visibleInView(viewMode, fort.team, fort.center):
        return nil
      return SelectedUnit(
        id: fort.id,
        kind: SelectedGod,
        team: fort.team,
        callsign: "GOD",
        classLabel: "FORT",
        status: if fort.hp > 0: "Defending" else: "Fallen",
        hp: max(fort.hp, 0'i32).float32,
        maxHp: FortHp.float32,
        level: 1
      )

proc selectHeroCard(
    primaryId: var int32,
    selectedIds: var seq[int32],
    followSelection: var bool,
    id: int32,
    additive: bool
) =
  ## Selects or toggles one hero from a HUD portrait click.
  var found = false
  for hero in run.world.heroes:
    if hero.id == id:
      found = true
      break
  if not found:
    return
  if not additive:
    selectedIds.setLen(0)
  elif isPicked(id, selectedIds) and selectedIds.len > 1:
    for i in 0 ..< selectedIds.len:
      if selectedIds[i] == id:
        selectedIds.delete(i)
        break
    if primaryId == id:
      primaryId = selectedIds[0]
    followSelection = selectedIds.len > 0
    return
  if not isPicked(id, selectedIds):
    selectedIds.add id
  primaryId = id
  followSelection = true

proc minimapMap(panel: GameUiPanel): GameUiPanel =
  ## Returns the map rectangle inside the minimap plate's frame.
  panel.inset(8)

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

proc minimapPosition(position: Vec3, panel: GameUiPanel): Vec2 =
  ## Projects a world position into the minimap's inner rectangle.
  let area = panel.minimapMap()
  let
    x = clamp(
      (position.x + HalfGrid) / (HalfGrid * 2),
      0.0'f32,
      1.0'f32
    )
    y = clamp(
      (position.z + HalfGrid) / (HalfGrid * 2),
      0.0'f32,
      1.0'f32
    )
  area.origin + vec2(x * area.size.x, y * area.size.y)

proc drawMinimapCamera(
    sk: Silky,
    window: Window,
    panel: GameUiPanel,
    cameraTarget: Vec3,
    cameraDistance: float32
) =
  ## Draws the fixed RTS camera's visible ground footprint.
  let
    area = panel.minimapMap()
    aspect = window.size.x.float32 / max(window.size.y.float32, 1)
  sk.drawCameraFrame(
    minimapViewport(
      cameraTarget,
      cameraDistance,
      aspect,
      area.origin,
      area.size,
      HalfGrid
    ),
    rgbx(255, 242, 187, 255)
  )

proc drawScoreRow(
    sk: Silky,
    origin: Vec2,
    team: Team,
    y: float32
) =
  ## Draws one team's towers, kills, and deaths on a single row.
  let
    color = teamHudColor(team)
    values = [
      remainingTowers(team),
      run.world.teamHeroKills[team.ord],
      run.world.teamHeroDeaths[team.ord]
    ]
  sk.drawSprite(
    if team == RedTeam: "hostile" else: "alliance",
    origin + vec2(ScoreHeaderXs[0], y + ScoreIconLift),
    vec2(IconTiny),
    color
  )
  for i, x in ScoreValueXs:
    writeInt(hudScratch, values[i])
    sk.drawLabel(
      hudScratch,
      origin + vec2(x, y),
      vec2(ScoreValueW, ScoreRowH),
      color,
      "Default",
      CenterAlign
    )

proc heroCardX(hero: Hero): float32 =
  ## Returns the plate-local x of one top-bar hero card.
  let slot = max(min(hero.slot, 4), 0)
  if hero.team == RedTeam:
    HeroSlotXs[slot]
  else:
    HeroSlotXsBlue[slot]

proc drawHeroPortrait(
    sk: Silky,
    window: Window,
    panel: GameUiPanel,
    hero: Hero,
    primaryId: var int32,
    selectedIds: var seq[int32],
    followSelection: var bool,
    actionCam: var ActionCam,
    focusPlayerHero: var bool
) =
  ## Draws one top-bar portrait on the hero plate.
  let
    x = heroCardX(hero)
    portrait = panel.imageSlot(
      x, HeroSlotY, HeroSlotSize.x, HeroSlotSize.y
    )
    picked = isPicked(hero.id, selectedIds)
  sk.drawWellImage(
    portrait,
    HeroPortraitKeys[hero.class],
    if hero.state == Dying or hero.hp <= 0:
      rgbx(140, 140, 148, 255)
    else:
      rgbx(255, 255, 255, 255),
    selected = picked,
    iconSize = IconSmall
  )
  if window.clicked(sk, portrait):
    actionCam.takeManual()
    selectHeroCard(
      primaryId,
      selectedIds,
      followSelection,
      hero.id,
      window.buttonDown[KeyLeftShift] or
        window.buttonDown[KeyRightShift]
    )
    if options.playerSlot > 0 and
        not run.replayMode and
        hero.id == run.world.heroes[options.playerSlot - 1].id:
      focusPlayerHero = true

proc drawHeroMeters(
    sk: Silky,
    panel: GameUiPanel,
    hero: Hero
) =
  ## Draws one hero's bars and level on the hero plate.
  let
    x = heroCardX(hero)
    portrait = panel.imageSlot(
      x, HeroSlotY, HeroSlotSize.x, HeroSlotSize.y
    )
    hpBar = panel.imageSlot(
      x + HeroBarInset, HeroBarYs[0], HeroBarSize.x, HeroBarSize.y
    )
    manaBar = panel.imageSlot(
      x + HeroBarInset, HeroBarYs[1], HeroBarSize.x, HeroBarSize.y
    )
  sk.drawBar(
    hpBar.origin,
    hpBar.size,
    hero.hp.float32,
    hero.maxHp.float32,
    rgbx(70, 190, 95, 255)
  )
  sk.drawBar(
    manaBar.origin,
    manaBar.size,
    hero.mana.float32,
    hero.maxMana.float32,
    rgbx(65, 126, 224, 255)
  )
  sk.drawBadge(
    portrait.origin + vec2(-2, portrait.size.y - BadgeSmall),
    vec2(BadgeSmall),
    $hero.level
  )

proc drawStat(
    sk: Silky,
    origin: Vec2,
    y: float32,
    icon: string,
    value: string
) =
  ## Draws one compact stat icon and its numeric value.
  sk.drawSprite(
    icon,
    origin + vec2(0, y + 1),
    vec2(16),
    IconTint
  )
  sk.drawLabel(
    value,
    origin + vec2(20, y),
    vec2(56, 18),
    rgbx(236, 238, 244, 255),
    "Small"
  )

proc drawAbilityIcon(
    sk: Silky,
    slot: GameUiPanel,
    icon: string,
    tint = rgbx(255, 255, 255, 255)
) =
  ## Draws one ability glyph inside a framed art slot.
  sk.drawWellImage(slot, icon, tint, iconSize = IconSmall)

proc drawCooldownSweep(
    sk: Silky,
    slot: GameUiPanel,
    remaining, duration: int32
) =
  ## Covers the unreadied portion of one ability well from the top.
  if remaining <= 0 or duration <= 0:
    return
  let height = slot.size.y * remaining.float32 / duration.float32
  sk.drawRect(slot.origin, vec2(slot.size.x, height), CooldownFill)

proc cooldownSeconds(remaining: int32): int32 =
  ## Rounds remaining ticks up to whole seconds for the HUD.
  (remaining + TickRate - 1) div TickRate

proc drawAbilityKey(
    sk: Silky,
    slot: GameUiPanel,
    key: string
) =
  ## Draws one hotkey along the bottom of a framed art slot.
  sk.drawLabel(
    key,
    slot.origin + vec2(0, slot.size.y - 18),
    vec2(slot.size.x, 16),
    rgbx(226, 230, 239, 255),
    "Small",
    CenterAlign
  )

proc drawUi*(
    sk: Silky,
    window: Window,
    transport: var Player,
    cameraTarget: Vec3,
    cameraDistance: float32,
    viewMode: int32,
    primaryId: var int32,
    selectedIds: var seq[int32],
    followSelection: var bool,
    actionCam: var ActionCam,
    focusPlayerHero: var bool
) =
  ## Draws every Silky HUD panel for the current frame.
  let
    chrome = currentChrome(window)
    scorePanel = sk.beginFrame(chrome.score)
    heroesPanel = sk.beginFrame(chrome.heroes)
    clockPanel = sk.beginFrame(chrome.clock)
    minimapPanel = sk.beginFrame(chrome.minimap)
    inventoryPanel = sk.beginFrame(chrome.inventory)
    hudTime = currentHudTime()
  var selection = selectedUnit(primaryId, viewMode)
  let detailsPanel =
    if selection != nil:
      sk.beginFrame(chrome.details)
    else:
      chrome.details

  for i, label in ["TOWERS", "KILLS", "DEATHS"]:
    let pos = scorePanel.origin + vec2(ScoreHeaderXs[i], ScoreHeaderY)
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
  sk.drawScoreRow(scorePanel.origin, RedTeam, ScoreRowYs[0])
  sk.drawScoreRow(scorePanel.origin, BlueTeam, ScoreRowYs[1])

  for hero in run.world.heroes:
    sk.drawHeroPortrait(
      window,
      heroesPanel,
      hero,
      primaryId,
      selectedIds,
      followSelection,
      actionCam,
      focusPlayerHero
    )
  for hero in run.world.heroes:
    sk.drawHeroMeters(heroesPanel, hero)

  sk.drawSprite(
    if hudTime.hour < 6 or hudTime.hour >= 18: "night" else: "day",
    clockPanel.origin + vec2(16, 14),
    vec2(22)
  )
  sk.drawLabel(
    "TIME OF DAY",
    clockPanel.origin + vec2(42, 12),
    vec2(clockPanel.size.x - 56, 20),
    rgbx(193, 198, 210, 255),
    "Small"
  )
  writeClock(hudScratch, hudTime.hour, hudTime.minute)
  sk.drawLabel(
    hudScratch,
    clockPanel.origin + vec2(4, 39),
    vec2(clockPanel.size.x - 8, 40),
    rgbx(247, 221, 143, 255),
    "H1",
    CenterAlign
  )

  let mapArea = minimapPanel.minimapMap()
  sk.drawFrame(
    GameUiPanel(origin: mapArea.origin, size: mapArea.size)
  )
  sk.drawRect(
    mapArea.origin + mapArea.size * 0.5'f32 - vec2(2),
    vec2(4),
    rgbx(91, 119, 128, 255)
  )
  template drawMinimapPip(
      objectId: int32,
      worldPosition: Vec3,
      pipSize: float32,
      pipColor: ColorRGBX
  ) =
    block:
      let point = minimapPosition(worldPosition, minimapPanel)
      if isPicked(objectId, selectedIds):
        sk.drawRect(
          point - vec2(pipSize * 0.5'f32 + 2),
          vec2(pipSize + 4),
          rgbx(255, 242, 187, 255)
        )
      sk.drawRect(
        point - vec2(pipSize * 0.5'f32),
        vec2(pipSize),
        pipColor
      )
  for tower in run.world.towers:
    if tower.hp > 0 and
        visibleInView(viewMode, tower.team, tower.position):
      drawMinimapPip(
        tower.id,
        renderPoint(tower.position),
        5.0'f32,
        teamHudColor(tower.team)
      )
  for fort in run.world.forts:
    if visibleInView(viewMode, fort.team, fort.center):
      drawMinimapPip(
        fort.id,
        renderPoint(fort.center),
        10.0'f32,
        teamHudColor(fort.team)
      )
  for footman in run.world.footmen:
    if footman.state != Dying and footman.hp > 0 and
        visibleInView(viewMode, footman.team, footman.position):
      drawMinimapPip(
        footman.id,
        renderPoint(footman.position),
        3.0'f32,
        teamHudColor(footman.team)
      )
  for hero in run.world.heroes:
    if visibleInView(viewMode, hero.team, hero.position):
      drawMinimapPip(
        hero.id,
        renderPoint(hero.position),
        7.0'f32,
        teamHudColor(hero.team)
      )
  sk.drawMinimapCamera(
    window,
    minimapPanel,
    cameraTarget,
    cameraDistance
  )

  if selection != nil:
    let
      teamColor = teamHudColor(selection.team)
      portrait = detailsPanel.imageSlot(
        DetailsPortrait.x,
        DetailsPortrait.y,
        DetailsPortraitSize.x,
        DetailsPortraitSize.y
      )
    if selection.kind == SelectedHero:
      sk.drawWellImage(
        portrait, selection.portraitKey, iconSize = IconLarge
      )
    else:
      let glyph =
        case selection.kind
        of SelectedTower:
          "tower"
        of SelectedMob:
          "minion"
        of SelectedGod:
          "fort"
        of SelectedHero:
          "champion"
      sk.drawWellImage(portrait, glyph, teamColor, iconSize = IconLarge)
    if window.clicked(sk, portrait) and
        selection.kind == SelectedHero and
        options.playerSlot > 0 and
        not run.replayMode and
        selection.id == run.world.heroes[options.playerSlot - 1].id:
      actionCam.takeManual()
      focusPlayerHero = true
    if selection.kind == SelectedHero:
      for slot in HeroAbilitySlot:
        let
          i = slot.ord
          well = detailsPanel.imageSlot(
            AbilitySlotXs[i], AbilitySlotY, WellSmall, WellSmall
          )
          spec = selection.abilities[slot].abilitySpec
          remaining = selection.cooldowns[slot]
        sk.drawAbilityIcon(
          well,
          abilityIconKey(selection.abilities[slot]),
          if remaining > 0:
            rgbx(150, 150, 158, 255)
          else:
            rgbx(255, 255, 255, 255)
        )
        sk.drawCooldownSweep(well, remaining, spec.cooldownTicks)
      for i in 0 .. 1:
        let
          well = detailsPanel.imageSlot(
            AbilitySlotXs[4 + i], AbilitySlotY, WellSmall, WellSmall
          )
          item = selection.inventory[i]
        if item != NoItem:
          sk.drawAbilityIcon(well, itemIconKey(item))
        else:
          sk.drawWellImage(well, "")
  let playerHero =
    options.playerSlot > 0 and not run.replayMode
  let playerHeroId =
    if playerHero:
      run.world.heroes[options.playerSlot - 1].id
    else:
      0'i32
  if playerHero:
    let title = GameUiPanel(
      origin: inventoryPanel.origin + vec2(InventoryInset, InventoryTitleY),
      size: vec2(inventoryPanel.size.x - InventoryInset * 2, 28)
    )
    if window.clicked(sk, title):
      shopOpen = not shopOpen
  if playerHero and shopOpen:
    var index = 0
    for item in Item:
      if item == NoItem:
        continue
      let
        col = index mod ShopColumns
        row = index div ShopColumns
        slotPanel = inventoryPanel.imageSlot(
          ShopOrigin.x + col.float32 * ShopPitch.x,
          ShopOrigin.y + row.float32 * ShopPitch.y,
          ShopWell,
          ShopWell
        )
      sk.drawWellImage(slotPanel, itemIconKey(item), iconSize = ShopIcon)
      if window.clicked(sk, slotPanel):
        queueBuyItem(playerHeroId, int32(item.ord))
      inc index
  else:
    for slot in 0 ..< InventorySlots:
      let
        slotPanel = inventoryPanel.imageSlot(
          InventorySlotsPos[slot].x,
          InventorySlotsPos[slot].y,
          InventorySlotSize.x,
          InventorySlotSize.y
        )
        item =
          if selection == nil: NoItem else: selection.inventory[slot]
      if item != NoItem:
        sk.drawWellImage(slotPanel, itemIconKey(item), iconSize = IconSmall)
      else:
        sk.drawSlot(slotPanel)
      if playerHero and window.clicked(sk, slotPanel):
        queueUseItem(playerHeroId, int32(slot))

  if selection != nil:
    let
      teamColor = teamHudColor(selection.team)
      badge = detailsPanel.imageSlot(
        DetailsBadge.x, DetailsBadge.y, BadgeLarge, BadgeLarge
      )
      namePos = detailsPanel.origin + vec2(DetailsNameX, DetailsNameY)
      classPos = detailsPanel.origin + vec2(DetailsNameX, DetailsClassY)
      statPos = detailsPanel.origin + vec2(DetailsNameX, DetailsStatY)
      hpBar = detailsPanel.imageSlot(
        DetailsBarX, DetailsBarYs[0], DetailsBarW, DetailsBarH
      )
      manaBar = detailsPanel.imageSlot(
        DetailsBarX, DetailsBarYs[1], DetailsBarW, DetailsBarH
      )
      xpBar = detailsPanel.imageSlot(
        DetailsBarX, DetailsBarYs[2], DetailsBarW, DetailsBarH
      )
    sk.drawBadge(badge.origin, badge.size, $selection.level, font = "Bold")
    sk.drawLabel(
      selection.callsign,
      namePos,
      vec2(DetailsNameW, 28),
      rgbx(255, 255, 255, 255),
      "Default"
    )
    sk.drawLabel(
      selection.classLabel,
      classPos,
      vec2(DetailsNameW, 20),
      teamColor,
      "Small"
    )
    sk.drawStat(statPos, 0, "damage", $selection.damage)
    sk.drawStat(statPos, 18, "health", $selection.maxHp.int)
    sk.drawStat(
      statPos,
      36,
      "movement",
      $(selection.moveSpeed * 100).int
    )
    writeRatio(hudScratch, selection.hp.int, selection.maxHp.int)
    sk.drawValueBar(
      hpBar.origin,
      hpBar.size,
      selection.hp,
      selection.maxHp,
      rgbx(66, 188, 91, 255),
      hudScratch
    )
    sk.drawSprite(
      "health",
      hpBar.origin + vec2(4, 4),
      vec2(20),
      rgbx(66, 188, 91, 255)
    )
    if selection.maxMana > 0:
      sk.drawValueBar(
        manaBar.origin,
        manaBar.size,
        selection.mana,
        selection.maxMana,
        rgbx(61, 124, 225, 255),
        (writeRatio(hudScratch, selection.mana.int, selection.maxMana.int); hudScratch)
      )
      sk.drawSprite(
        "mana",
        manaBar.origin + vec2(4, 4),
        vec2(20),
        rgbx(186, 214, 255, 255)
      )
    if selection.nextXp > 0:
      sk.drawValueBar(
        xpBar.origin,
        xpBar.size,
        selection.xp.float32,
        selection.nextXp.float32,
        rgbx(152, 86, 196, 255),
        (writeRatio(hudScratch, selection.xp, selection.nextXp); hudScratch)
      )
      sk.drawSprite(
        "experience",
        xpBar.origin + vec2(4, 4),
        vec2(20)
      )
    for i in 0 .. 5:
      let well = detailsPanel.imageSlot(
        AbilitySlotXs[i], AbilitySlotY, WellSmall, WellSmall
      )
      if i < 4 and selection.kind == SelectedHero:
        let remaining = selection.cooldowns[HeroAbilitySlot(i)]
        if remaining > 0:
          sk.drawLabel(
            $cooldownSeconds(remaining),
            well.origin,
            well.size,
            rgbx(247, 221, 143, 255),
            "Hud",
            CenterAlign
          )
      if i >= 4 and selection.kind == SelectedHero:
        let count = selection.itemCounts[i - 4]
        if count > 1:
          sk.drawLabel(
            $count,
            well.origin,
            well.size,
            rgbx(247, 221, 143, 255),
            "Hud",
            CenterAlign
          )
      sk.drawAbilityKey(well, AbilityKeys[i])

  if selection != nil:
    for slot in 0 ..< InventorySlots:
      if selection.itemCounts[slot] > 1:
        let slotPanel = inventoryPanel.imageSlot(
          InventorySlotsPos[slot].x,
          InventorySlotsPos[slot].y,
          InventorySlotSize.x,
          InventorySlotSize.y
        )
        sk.drawLabel(
          $selection.itemCounts[slot],
          slotPanel.origin,
          slotPanel.size,
          rgbx(247, 221, 143, 255),
          "Hud",
          CenterAlign
        )
  sk.drawLabel(
    if playerHero and shopOpen: "SHOP" else: "INVENTORY",
    inventoryPanel.origin + vec2(InventoryInset, InventoryTitleY),
    vec2(inventoryPanel.size.x - InventoryInset * 2, 28),
    rgbx(200, 205, 216, 255),
    "Small"
  )
  let gold = inventoryPanel.imageSlot(
    InventoryInset,
    InventoryGoldY,
    inventoryPanel.size.x - InventoryInset * 2,
    31
  )
  sk.drawSprite(
    "gold",
    gold.origin + vec2(0, 6),
    vec2(20)
  )
  sk.drawLabel(
    formatAmount(if selection == nil: 0 else: selection.gold),
    gold.origin + vec2(31, 0),
    vec2(gold.size.x - 31, gold.size.y),
    rgbx(232, 196, 86, 255)
  )

  if run.replayMode and run.hashCheck.error.len > 0:
    sk.drawError(
      chrome.layout.size,
      &"REPLAY DIVERGED - continuing simulation " &
        &"({run.hashCheck.mismatches} mismatches)",
      run.hashCheck.error
    )

  transport.drawTransport(
    sk,
    window,
    chrome.layout.transportPanel,
    actionCam,
    followSelection
  )
  sk.drawDebugMenu(window)
