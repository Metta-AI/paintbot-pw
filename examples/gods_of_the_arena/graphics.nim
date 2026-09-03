## Window, terrain rendering, characters, camera, and HUD for the arena.

import
  std/[math, strutils, tables, times],
  bumpy, chroma, opengl, pixie, silky, vmath,
  content, sim, game, maps, replays, ui, controls,
  polyworld/actioncam, polyworld/characters, polyworld/clickmarks,
  polyworld/common, polyworld/pathing,
  polyworld/tapes,
  polyworld/particles, polyworld/particleshaders, polyworld/player,
  polyworld/profiles,
  polyworld/quadterrain,
  polyworld/shadows,
  polyworld/[chrome, inputs, rtscameras, selectionoutlines, shapes, viewers,
    visions, worldbars]

when defined(takeScreenshot):
  import std/os

const
  AtlasPath = TmpRoot & "/gota.atlas.png"
  LogoPath = DataRoot & "/themes/gota/gota_logo.png"

type
  GraphicsError = object of CatchableError

proc renderPoint(position: WorldPoint): Vec3 =
  ## Converts authoritative integer coordinates at the rendering boundary.
  vec3(
    position.x.float32 / WorldScale.float32,
    position.y.float32 / WorldScale.float32,
    position.z.float32 / WorldScale.float32
  )

proc renderFacing(value: Heading): float32 =
  ## Converts an integer heading to the renderer's angular convention.
  arctan2(value.x.float32, value.z.float32)

proc addAbilityIcons(builder: AtlasBuilder) =
  ## Packs every hero ability art file used by the action bar.
  const AbilityDir = DataRoot & "/abilities/"
  var packed: set[Ability]
  for class in HeroClass:
    for slot in HeroAbilitySlot:
      let ability = heroAbility(class, slot)
      if ability in packed:
        continue
      packed.incl ability
      let icon = readImage(
        AbilityDir & ability.abilitySpec.icon & ".png"
      ).resize(128, 128)
      if not builder.addImage(abilityIconKey(ability), icon):
        raise newException(
          GraphicsError,
          "the UI atlas is too small for ability icons"
        )

proc addItemIcons(builder: AtlasBuilder) =
  ## Packs every shop item art file used by the inventory.
  const ItemDir = DataRoot & "/items/"
  for item in Item:
    if item == NoItem:
      continue
    let icon = readImage(
      ItemDir & item.itemSpec.icon & ".png"
    ).resize(128, 128)
    if not builder.addImage(itemIconKey(item), icon):
      raise newException(
        GraphicsError,
        "the UI atlas is too small for item icons"
      )

proc addHudIcons(builder: AtlasBuilder) =
  ## Packs the theme logo into the atlas.
  builder.addThemeLogo(LogoPath)

proc laneRenderPath(lane: int): seq[Vec3] =
  ## Converts one integer lane polyline into render-space points.
  for point in lanePathPoints[lane]:
    result.add vec3(
      point.x.float32 / PathUnitsPerTile.float32,
      point.y.float32 / PathUnitsPerTile.float32,
      point.z.float32 / PathUnitsPerTile.float32
    )

# Lane footmen and the gods per team: humans for red, undead for blue, so
# the teams read from their models with no tinting. Heroes are outfits of
# the same modular pack Call to Adventure uses. Blue wears the upper tank,
# ranged, mage, support, and fighter looks. Red wears the lower ones.
# Ranger, Crossbowman, and Arcanist drop or swap gear from their numbered
# preset. Everyone else wears the preset as published.
const
  FootmanModels: array[Team, string] = [
    DataRoot & "/characters/mini_legion/human/footman.glb",
    DataRoot & "/characters/mini_legion/undead/skeleton_warrior.glb"
  ]
  HeroModelPath = DataRoot & "/characters/modular_chars/character.glb"
  HeroTargetHeight = 1.7'f32
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
  HeroPortraitPaths: array[HeroClass, string] = [
    DataRoot & "/characters/modular_chars/character.preset_1.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_13.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_16.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_17.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_2.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_3.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_11.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_12.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_6.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_14.profile.png"
  ]
  HeroLooks: array[HeroClass, seq[string]] = [
    @[
      "Back_1", "Body_White_1", "Body_White_Head_1", "Chest_1",
      "Eye_Black_1", "Foot_1", "Hand_1", "Head_1", "Leg_1",
      "Wield_Gear_Left_1", "Wield_Gear_Right_1"
    ],
    @[
      "Body_Yellow_1", "Body_Yellow_Head_1", "Brow_Brown_3", "Chest_13",
      "Eye_Brown_7", "Foot_13", "Hand_13", "Head_13", "Leg_13",
      "Mouth_Yellow_3", "Wield_Gear_Right_13"
    ],
    @[
      "Back_16", "Body_White_1", "Body_White_Head_2", "Chest_16",
      "Earring_4", "Eye_BlueB_1", "Foot_16", "Hand_16", "Head_16",
      "Leg_16", "Mouth_White_3", "Wield_Gear_Right_12"
    ],
    @[
      "Back_17", "Body_Yellow_1", "Body_Yellow_Head_3", "Chest_17",
      "Eye_Brown_4", "Foot_17", "Hand_17", "Head_17", "Leg_17",
      "Wield_Gear_Left_17"
    ],
    @[
      "Back_2", "Body_White_1", "Body_White_Head_1", "Brow_Blue_8",
      "Chest_2", "Eye_BlueB_4", "Foot_2", "Hand_2", "Head_2", "Leg_2",
      "Mouth_White_2", "Wield_Gear_Right_2"
    ],
    @[
      "Back_3", "Body_White_1", "Body_White_Head_3", "Brow_Blue_8",
      "Chest_3", "Eye_BlueB_1", "Foot_3", "Hand_3", "Head_3", "Leg_3",
      "Mouth_Brown_2", "Wield_Gear_Right_3"
    ],
    @[
      "Body_White_1", "Body_White_Head_2", "Chest_11", "Eye_Brown_11",
      "Foot_11", "Hand_11", "Head_11", "Leg_11", "Mouth_Brown_4",
      "Wield_Gear_Right_11"
    ],
    @[
      "Back_12", "Body_Yellow_1", "Body_Yellow_Head_2", "Brow_Brown_3",
      "Chest_12", "Eye_Brown_4", "Foot_12", "Hand_12", "Head_12",
      "Leg_12", "Mouth_Brown_10", "Wield_Gear_Right_12"
    ],
    @[
      "Back_6", "Body_Yellow_1", "Body_Yellow_Head_3", "Chest_6",
      "Eye_Purple_1", "Foot_6", "Hand_6", "Head_6", "Leg_6",
      "Mouth_Purple_9", "Wield_Gear_Left_6"
    ],
    @[
      "Back_14", "Body_Yellow_1", "Body_Yellow_Head_3", "Chest_14",
      "Eye_BlueB_1", "Foot_14", "Hand_14", "Head_14", "Leg_14",
      "Mouth_Yellow_2", "Wield_Gear_Left_14", "Wield_Gear_Right_7"
    ]
  ]

var
  window: Window
  sk: Silky

proc runGraphics*() =
  ## Runs the native or Emscripten graphical spectator.
  startProfileTrace()
  profileBlock "atlas":
    let builder = newHudAtlas(4096)
    for class in HeroClass:
      if not builder.addImage(
          HeroPortraitKeys[class], readImage(HeroPortraitPaths[class])):
        raise newException(
          GraphicsError,
          "the UI atlas is too small for hero portraits"
        )
    addHudIcons(builder)
    addAbilityIcons(builder)
    addItemIcons(builder)
    builder.addDefaultFonts()
    builder.write(AtlasPath)
  profileBlock "window":
    (window, sk) = initGameWindow(
      "Gods of the Arena",
      AtlasPath,
      gameWindowSize(options.windowWidth, options.windowHeight),
      options.vsync
    )
  let splash = startSplash(sk, window)
  profileBlock "terrain":
    amplitude = 1.4'f32
    seed = run.map.seed
    initTerrain()
    scatterGrass(800, run.map.seed)
    scatterRocks(80, run.map.seed)

  let scene = newCharacterScene(window)
  scene.useToonShading()
  var
    # Footmen and gods are the lane grunts of each faction: humans for red,
    # undead for blue, so the teams read from their models alone.
    footmanModels: array[Team, CharacterModel]
    footmanRenderClips: array[Team, array[6, int]]
    heroModels: array[HeroClass, CharacterModel]
    heroRenderClips: array[5, int]
  profileBlock "models":
    for team in Team:
      let model = loadCharacterModel(FootmanModels[team], 1.15)
      footmanModels[team] = model
      footmanRenderClips[team] = [
        model.clipIndex("Run"),
        model.clipIndex("Idle"),
        model.clipIndex("Death"),
        model.clipIndex("Victory"),
        model.clipIndex("Attack01"),
        model.clipIndex("Attack02")
      ]
    for class in HeroClass:
      heroModels[class] = loadModularCharacterModel(
        HeroModelPath,
        HeroLooks[class],
        HeroTargetHeight
      )
    let heroModel = heroModels[VanguardKnight]
    heroRenderClips = [
      heroModel.clipIndex("Run"),
      heroModel.clipIndex("Idle"),
      heroModel.clipIndex("Death"),
      heroModel.clipIndex("Attack01"),
      heroModel.clipIndex("Attack02")
    ]
  var
    particles = initParticleSystem()
    clickMarks = initClickMarks()
    worldShapes = initShapeRenderer()
    selectionOutline = initSelectionOutline()
    worldBarRenderer = initWorldBarRenderer()
    damageTrails: DamageTrailTracker

  const
    SmallTowerScale = 3.5'f32
    TallTowerScale = 4.5'f32
    GateTowerScale = 6.0'f32
    BarracksScale = 2.25'f32
    FountainScale = BarracksScale * 1.5'f32
    RedBarracksOffsets = [4.0'f32, -4.0'f32, 4.0'f32]
    BlueBarracksOffsets = [-4.0'f32, 4.0'f32, -4.0'f32]

  proc towerPropName(tier: TowerTier): string =
    ## Returns the terrain-kit model name for one tower tier.
    case tier
    of OuterTower:
      "tower_square_small1"
    of InnerTower:
      "tower_square_tall1"
    of GateTower:
      "tower_square_tall2"

  proc towerScale(tier: TowerTier): float32 =
    ## Returns the world scale for one tower tier.
    case tier
    of OuterTower:
      SmallTowerScale
    of InnerTower:
      TallTowerScale
    of GateTower:
      GateTowerScale

  proc lanePlacement(
      path: seq[Vec3],
      ratio,
      offset: float32
  ): tuple[position: Vec3, facing: float32] =
    ## Finds a presentation prop position beside a sampled lane point.
    let
      index = clamp(
        int(round((path.len - 1).float32 * ratio)),
        0,
        path.len - 1
      )
      nextIndex = min(index + 1, path.len - 1)
      previousIndex = max(index - 1, 0)
      direction = normalize(vec3(
        path[nextIndex].x - path[previousIndex].x,
        0,
        path[nextIndex].z - path[previousIndex].z
      ))
      side = vec3(-direction.z, 0, direction.x)
      facing = arctan2(direction.x, direction.z)
    for amount in [offset, -offset, offset * 0.5, offset * -0.5]:
      var position = path[index] + side * amount
      let (tileX, tileZ) = worldToTile(position.x, position.z)
      if isWalkable(0, tileX, tileZ):
        position.y = groundHeight(position.x, position.z)
        return (position, facing)
    (path[index], facing)

  proc placeStaticStructures(pack: PropPack) =
    ## Places one permanent barracks at each end of every lane.
    for lane in 0 .. 2:
      let path = laneRenderPath(lane)
      let
        redBarracks = lanePlacement(path, 0.0, RedBarracksOffsets[lane])
        blueBarracks = lanePlacement(path, 1.0, BlueBarracksOffsets[lane])
      pack.placeProp(
        "building2",
        redBarracks.position,
        redBarracks.facing,
        BarracksScale
      )
      pack.placeProp(
        "building2",
        blueBarracks.position,
        blueBarracks.facing + PI.float32,
        BarracksScale
      )
  var towerPack: PropPack
  profileBlock "props":
    towerPack = loadPropPack(DataRoot & "/terrain/tower_defense_kit.glb")
    for name in [
      "tower_square_small1",
      "tower_square_tall1",
      "tower_square_tall2",
      "building2",
      "magiccrystal1"
    ]:
      doAssert towerPack.hasProp(name), "missing tower kit prop: " & name
    towerPack.placeStaticStructures()
    towerPack.placeProp(
      "magiccrystal1",
      tileCenter(RedFortLayer, FortOuterRadius, FortOuterRadius),
      scale = FountainScale
    )
    towerPack.placeProp(
      "magiccrystal1",
      tileCenter(BlueFortLayer, FortOuterRadius, FortOuterRadius),
      rotation = PI.float32,
      scale = FountainScale
    )
  profileBlock "bake":
    bakeTerrain(rebuildWalkability = false)
  drawSplash(sk, window, splash.name)

  type God = object
    team: Team
    position: Vec3
    facing: float32
    animTime: float32

  var gods = [
    God(team: RedTeam, facing: arctan2(1.0'f32, 1.0'f32)),
    God(team: BlueTeam, facing: arctan2(-1.0'f32, -1.0'f32)),
  ]
  for i, god in gods.mpairs:
    let offset =
      if god.team == RedTeam:
        vec3(-3.5, 0, -3.5)
      else:
        vec3(3.5, 0, 3.5)
    god.position = renderPoint(run.world.forts[i].center) + offset
    god.position.y = surfaceHeightNear(
      god.position.x,
      god.position.z,
      renderPoint(run.world.forts[i].center).y
    )

  proc godClip(god: God): int =
    ## Selects the god animation for the current game state.
    if not run.world.gameOver:
      idleClip
    elif god.team == run.world.winner:
      victoryClip
    else:
      deathClip

  proc heroSizeFactor(hero: Hero): float32 =
    ## Returns the small visual scale increase earned through hero levels.
    1.0'f32 + min(hero.level - 1, 10).float32 * 0.025'f32

  const
    SeekCheckpointTicks = TickRate * 10
    HeroWorldBarWidth = 1.75'f32
    TowerWorldBarWidth = 2.4'f32
    FootmanWorldBarWidth = 0.95'f32

  type
    SeekCheckpoint = object
      tick: int
      world: World
      replayActionIndex: int
      hashCheck: ReplayHashCheck

    SelectionTarget = object
      found: bool
      position: Vec3
      focusHeight: float32

  var
    replayCheckpoints: seq[SeekCheckpoint]
    previousUnitPositions: Table[int32, Vec3]
    previousUnitFacings: Table[int32, float32]
    renderAlpha = 1.0'f32
    animationAlpha = 0.0'f32
    viewMode =
      if options.playerSlot > 0:
        int32(run.world.heroes[options.playerSlot - 1].team.ord) + 1
      else:
        0'i32
    terrainVisionTick = int32.low
    terrainVisionMode = int32.low

  proc captureUnitPositions() =
    ## Remembers all mobile poses before one authoritative tick.
    previousUnitPositions.clear()
    previousUnitFacings.clear()
    for hero in run.world.heroes:
      previousUnitPositions[hero.id] = renderPoint(hero.position)
      previousUnitFacings[hero.id] = renderFacing(hero.facing)
    for footman in run.world.footmen:
      previousUnitPositions[footman.id] = renderPoint(footman.position)
      previousUnitFacings[footman.id] = renderFacing(footman.facing)

  proc unitRenderPoint(id: int32, position: WorldPoint): Vec3 =
    ## Interpolates one mobile unit between the latest simulation snapshots.
    let current = renderPoint(position)
    if not interpolateVisuals:
      return current
    mix(
      previousUnitPositions.getOrDefault(id, current),
      current,
      renderAlpha
    )

  proc unitRenderFacing(id: int32, facing: Heading): float32 =
    ## Interpolates yaw the short way so a +pi / -pi flip is not a spin.
    if not interpolateVisuals:
      return renderFacing(facing)
    let
      current = renderFacing(facing)
      previous = previousUnitFacings.getOrDefault(id, current)
    previous + shortestTurn(previous, current) * renderAlpha

  proc unitRenderTime(ticks: int32): float32 =
    ## Samples authoritative animation state continuously between ticks.
    (ticks.float32 + animationAlpha) / TickRate.float32

  proc holdClipTime(
      model: CharacterModel, clip: int, ticks: int32, hold: bool
  ): float32 =
    ## Samples animation time. One-shot clips hold the last pose; the
    ## sampler wraps with `mod`, so a death would otherwise loop. Held
    ## poses ignore the interpolant, or a corpse wiggles between ticks.
    if hold:
      min(
        ticks.float32 / TickRate.float32,
        clipDuration(model, clip)
      )
    else:
      unitRenderTime(ticks)

  proc visibleInView(team: Team, position: WorldPoint): bool =
    ## Applies the current omniscient or team visibility spectator mode.
    if viewMode == 0:
      return true
    let viewingTeam = Team(viewMode - 1)
    team == viewingTeam or visible(run.world, viewingTeam, position)

  proc updateTerrainVision() =
    ## Uploads softened terrain vision for the selected spectator team.
    if terrainVisionTick == run.world.tick and terrainVisionMode == viewMode:
      return
    terrainVisionTick = run.world.tick
    terrainVisionMode = viewMode
    var values = newSeq[uint8](GridTiles * GridTiles)
    if viewMode == 0:
      for value in values.mitems:
        value = 255
    else:
      let team = int(viewMode - 1)
      for i in 0 ..< values.len:
        values[i] =
          if run.world.teamVisible[team][i] != 0: 255
          elif run.world.teamExplored[team][i] != 0: 48
          else: 0
    uploadTerrainVisibility(blurVisibility(values, GridTiles, GridTiles))

  proc screenPosition(position: Vec3, viewProjection: Mat4): Vec2 =
    ## Projects a world position into window pixel coordinates.
    let clip = viewProjection * vec4(
      position.x,
      position.y,
      position.z,
      1
    )
    if clip.w <= 0:
      return vec2(-10000)
    let normalized = vec2(clip.x / clip.w, clip.y / clip.w)
    vec2(
      (normalized.x * 0.5'f32 + 0.5'f32) * window.size.x.float32,
      (0.5'f32 - normalized.y * 0.5'f32) * window.size.y.float32
    )

  proc drawWorldUnitBars(
      renderer: var WorldBarRenderer,
      viewProjection: Mat4,
      cameraRight,
      cameraUp: Vec3,
      dt: float32
  ) =
    ## Builds and draws attached hero, tower, and footman resource bars.
    damageTrails.beginFrame()
    renderer.clear()
    for hero in run.world.heroes:
      if hero.state == Dying or hero.hp <= 0 or
          not visibleInView(hero.team, hero.position):
        continue
      let
        health = max(hero.hp, 0'i32).float32
        maximumHealth = max(hero.maxHp, 1'i32).float32
        delayedHealth = damageTrails.delayedValue(
          hero.id,
          health,
          maximumHealth,
          dt
        )
        anchor = unitRenderPoint(hero.id, hero.position) +
          vec3(0, 2.2'f32, 0)
        bars = [
          WorldResourceBar(
            value: health,
            maximum: maximumHealth,
            delayedValue: delayedHealth,
            height: 0.16'f32,
            color: healthColor(health, maximumHealth),
            showDamageTrail: true
          ),
          WorldResourceBar(
            value: max(hero.mana, 0'i32).float32,
            maximum: max(hero.maxMana, 1'i32).float32,
            delayedValue: max(hero.mana, 0'i32).float32,
            height: 0.1'f32,
            color: rgbx(60, 125, 231, 255)
          )
        ]
      renderer.addResourceBars(anchor, HeroWorldBarWidth, bars)
    for tower in run.world.towers:
      if tower.hp <= 0 or not visibleInView(tower.team, tower.position):
        continue
      let
        health = tower.hp.float32
        maximumHealth = tower.maxHp.float32
        delayedHealth = damageTrails.delayedValue(
          tower.id,
          health,
          maximumHealth,
          dt
        )
        anchor = renderPoint(tower.position) +
          vec3(0, towerScale(tower.tier) + 0.45'f32, 0)
        bars = [WorldResourceBar(
          value: health,
          maximum: maximumHealth,
          delayedValue: delayedHealth,
          height: 0.14'f32,
          color: healthColor(health, maximumHealth),
          showDamageTrail: true
        )]
      renderer.addResourceBars(anchor, TowerWorldBarWidth, bars)
    for footman in run.world.footmen:
      if footman.state == Dying or footman.hp <= 0 or
          not visibleInView(footman.team, footman.position):
        continue
      let
        health = footman.hp.float32
        maximumHealth = FootmanHp.float32
        delayedHealth = damageTrails.delayedValue(
          footman.id,
          health,
          maximumHealth,
          dt
        )
      if footman.hp < FootmanHp:
        let
          anchor = unitRenderPoint(footman.id, footman.position) +
            vec3(0, 1.38'f32, 0)
          bars = [WorldResourceBar(
            value: health,
            maximum: maximumHealth,
            delayedValue: delayedHealth,
            height: 0.1'f32,
            color: healthColor(health, maximumHealth),
            showDamageTrail: true
          )]
        renderer.addResourceBars(anchor, FootmanWorldBarWidth, bars)
    damageTrails.finishFrame()
    renderer.draw(viewProjection, cameraRight, cameraUp)

  proc pickEntity(viewProjection: Mat4): int32 =
    ## Finds the closest visible mesh under the pointer by triangle hit.
    let
      (origin, dir) = mouseRay(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection
      )
    var bestDistance = -1.0'f32
    template consider(candidateId: int32, distance: float32) =
      if distance > 0 and (bestDistance < 0 or distance < bestDistance):
        bestDistance = distance
        result = candidateId
    for hero in run.world.heroes:
      if hero.state == Dying or not visibleInView(hero.team, hero.position):
        continue
      let
        model = heroModels[hero.class]
        clip = heroRenderClips[hero.animClip]
      consider(
        hero.id,
        pickCharacter(
          model,
          origin,
          dir,
          unitRenderPoint(hero.id, hero.position),
          unitRenderFacing(hero.id, hero.facing),
          clip,
          holdClipTime(
            model, clip, hero.animTicks, hero.state == Dying
          ),
          hero.heroSizeFactor()
        )
      )
    for footman in run.world.footmen:
      if footman.state == Dying or
          not visibleInView(footman.team, footman.position):
        continue
      let
        model = footmanModels[footman.team]
        clip = footmanRenderClips[footman.team][footman.animClip]
      consider(
        footman.id,
        pickCharacter(
          model,
          origin,
          dir,
          unitRenderPoint(footman.id, footman.position),
          unitRenderFacing(footman.id, footman.facing),
          clip,
          holdClipTime(
            model, clip, footman.animTicks, footman.state == Dying
          )
        )
      )
    for tower in run.world.towers:
      if tower.hp <= 0 or not visibleInView(tower.team, tower.position):
        continue
      consider(
        tower.id,
        pickProp(
          towerPack,
          towerPropName(tower.tier),
          origin,
          dir,
          renderPoint(tower.position),
          renderFacing(tower.facing),
          towerScale(tower.tier)
        )
      )
    for i, god in gods:
      if not visibleInView(god.team, run.world.forts[i].center):
        continue
      let
        model = footmanModels[god.team]
        clip = footmanRenderClips[god.team][god.godClip]
      var animTime = god.animTime
      if run.world.gameOver and god.team != run.world.winner:
        animTime = min(animTime, clipDuration(model, clip))
      consider(
        run.world.forts[i].id,
        pickCharacter(
          model,
          origin,
          dir,
          god.position,
          god.facing,
          clip,
          animTime,
          2.6
        )
      )

  proc captureCheckpoint(): SeekCheckpoint =
    ## Captures simulation state for an exact seek restore.
    SeekCheckpoint(
      tick: int(run.world.tick),
      world: run.world.clone(),
      replayActionIndex:
        if run.replayPlayer != nil: run.replayPlayer.actionIndex else: 0,
      hashCheck: run.hashCheck
    )

  var
    cameraDistance = 170.0'f32
    cameraTarget = vec3(0, 0, 0)
    panning = false
    minimapPanning = false
    cameraEye = vec3(0, 0, 0)
    primaryId = 0'i32
    selectedIds: seq[int32]
    selectionPressPosition = vec2(0)
    rightPressPosition = vec2(0)
    selectionStarted = false
    selectionAdditive = false
    attackMoveArmed = false
    followSelection = false
    cameraEase: CameraEase
    focusPlayerHero = false
    groupCameraScale = 1.0'f32
    actionCam = initActionCam(
      minDistance = 22,
      maxDistance = 150,
      tight = 0.72,
      followRate = 1.0,
      zoomRate = 0.7,
      holdSeconds = 2.8,
      mapSpan = HalfGrid * 2
    )
    prevTowerHp: seq[int32]
    prevFortHp: array[2, int32]
    sawTowerHp = false
    transport = initPlayer(
      live = not run.replayMode,
      durationTicks =
        if run.replayMode:
          int32(run.replayData.header.setup.maximumTicks)
        else:
          options.maximumTicks,
      playing = not options.pauseOnStart,
      speed = options.speed
    )

  window.onButtonPress = proc(button: Button) =
    if button == KeySpace:
      transport.handleKey(button)
    elif button == KeyC:
      actionCam.toggle(followSelection)
    elif button == KeyT:
      scene.toggleShading()
    elif button == KeyF1:
      debugMenuOpen = not debugMenuOpen

  proc objectTeam(id: int32): int32 =
    ## Returns 1 for red, 2 for blue, or 0 when the id is unknown.
    let hero = heroById(run.world, id)
    if hero.id != 0:
      return int32(hero.team.ord + 1)
    let footman = footmanById(run.world, id)
    if footman.id != 0:
      return int32(footman.team.ord + 1)
    for tower in run.world.towers:
      if tower.id == id:
        return int32(tower.team.ord + 1)
    for fort in run.world.forts:
      if fort.id == id:
        return int32(fort.team.ord + 1)
    0

  proc playerMode(): bool =
    ## Returns whether this client issues orders for one hero.
    options.playerSlot > 0 and not run.replayMode

  proc playerHeroId(): int32 =
    ## Returns the human hero identifier.
    run.world.heroes[options.playerSlot - 1].id

  if playerMode():
    primaryId = playerHeroId()
    selectedIds.add primaryId
    followSelection = false

  proc syncViewMode() =
    ## Shows one team's fog when the selection is one-sided.
    if playerMode():
      viewMode =
        int32(run.world.heroes[options.playerSlot - 1].team.ord) + 1
      return
    var mode = 0'i32
    for id in selectedIds:
      let team = objectTeam(id)
      if team == 0:
        continue
      if mode == 0:
        mode = team
      elif mode != team:
        viewMode = 0
        return
    viewMode = mode

  proc isSelected(id: int32): bool =
    ## Returns whether an object belongs to the current selection set.
    for selectedId in selectedIds:
      if selectedId == id:
        return true

  proc selectionTarget(id: int32): SelectionTarget =
    ## Returns current rendering and camera data for one selectable object.
    let hero = heroById(run.world, id)
    if hero.id != 0 and visibleInView(hero.team, hero.position):
      return SelectionTarget(
        found: true,
        position: unitRenderPoint(hero.id, hero.position),
        focusHeight: 0.9'f32
      )
    let footman = footmanById(run.world, id)
    if footman.id != 0 and visibleInView(footman.team, footman.position):
      return SelectionTarget(
        found: true,
        position: unitRenderPoint(footman.id, footman.position),
        focusHeight: 0.6'f32
      )
    for tower in run.world.towers:
      if tower.id == id and tower.hp > 0 and
          visibleInView(tower.team, tower.position):
        return SelectionTarget(
          found: true,
          position: renderPoint(tower.position),
          focusHeight: 2.5'f32
        )
    for i, god in gods:
      if run.world.forts[i].id == id and
          visibleInView(god.team, run.world.forts[i].center):
        return SelectionTarget(
          found: true,
          position: god.position,
          focusHeight: 1.3'f32
        )

  proc selectedTargetCount(): int =
    ## Returns the number of selected objects still present in the run.world.
    for id in selectedIds:
      if selectionTarget(id).found:
        inc result

  proc selectEntity(id: int32, additive = false) =
    ## Selects or toggles one object and activates selection following.
    if not selectionTarget(id).found:
      return
    if not additive:
      selectedIds.setLen(0)
    elif isSelected(id) and selectedIds.len > 1:
      for i in 0 ..< selectedIds.len:
        if selectedIds[i] == id:
          selectedIds.delete(i)
          break
      if primaryId == id:
        primaryId = selectedIds[0]
      followSelection = selectedTargetCount() > 0
      actionCam.takeManual()
      return
    if not isSelected(id):
      selectedIds.add id
    primaryId = id
    followSelection = true
    actionCam.takeManual()
    if selectedIds.len > 1:
      groupCameraScale = 1.0'f32

  proc selectAllHeroes() =
    ## Selects every hero and activates the group-follow camera.
    selectedIds.setLen(0)
    for hero in run.world.heroes:
      selectedIds.add hero.id
    if selectedIds.len > 0:
      if not isSelected(primaryId):
        primaryId = selectedIds[0]
      followSelection = true
      actionCam.takeManual()
      groupCameraScale = 1.0'f32

  proc pruneSelection() =
    ## Removes objects which no longer exist without changing valid choices.
    var i = selectedIds.high
    while i >= 0:
      if not selectionTarget(selectedIds[i]).found:
        selectedIds.delete(i)
      dec i
    if selectedIds.len == 0:
      followSelection = false
      primaryId = 0
    if selectedIds.len > 0 and not isSelected(primaryId):
      primaryId = selectedIds[0]

  proc clearSelection() =
    ## Clears the selection and leaves the camera free-floating.
    selectedIds.setLen(0)
    primaryId = 0
    followSelection = false
    actionCam.takeManual()

  proc selectedCenter(): Vec3 =
    ## Returns the midpoint of all currently selected world objects.
    var count = 0
    for id in selectedIds:
      let target = selectionTarget(id)
      if target.found:
        result += target.position + vec3(0, target.focusHeight, 0)
        inc count
    if count > 0:
      result = result / count.float32

  proc selectedRadius(center: Vec3): float32 =
    ## Returns the largest planar distance from the selection midpoint.
    for id in selectedIds:
      let target = selectionTarget(id)
      if not target.found:
        continue
      let
        dx = target.position.x - center.x
        dz = target.position.z - center.z
      result = max(result, sqrt(dx * dx + dz * dz))

  when defined(takeScreenshot):
    if existsEnv("SELECT_ID"):
      selectEntity(getEnv("SELECT_ID").parseInt.int32)
    if existsEnv("SELECT_ALL"):
      selectAllHeroes()

  proc drawOutlinedObject(
      id: int32,
      view,
      projection,
      viewProjection: Mat4
  ) =
    ## Draws one object's silhouette into the current outline mask.
    for hero in run.world.heroes:
      if hero.id != id:
        continue
      beginCharacters(scene, window, view, projection, cameraEye)
      drawCharacter(
        scene,
        heroModels[hero.class],
        unitRenderPoint(hero.id, hero.position),
        unitRenderFacing(hero.id, hero.facing),
        heroRenderClips[hero.animClip],
        holdClipTime(
          heroModels[hero.class],
          heroRenderClips[hero.animClip],
          hero.animTicks,
          hero.state == Dying
        ),
        sizeFactor = hero.heroSizeFactor()
      )
      finishCharacters(scene)
      return
    for footman in run.world.footmen:
      if footman.id != id:
        continue
      beginCharacters(scene, window, view, projection, cameraEye)
      drawCharacter(
        scene,
        footmanModels[footman.team],
        unitRenderPoint(footman.id, footman.position),
        unitRenderFacing(footman.id, footman.facing),
        footmanRenderClips[footman.team][footman.animClip],
        holdClipTime(
          footmanModels[footman.team],
          footmanRenderClips[footman.team][footman.animClip],
          footman.animTicks,
          footman.state == Dying
        )
      )
      finishCharacters(scene)
      return
    for i, god in gods:
      if run.world.forts[i].id != id:
        continue
      beginCharacters(scene, window, view, projection, cameraEye)
      drawCharacter(
        scene,
        footmanModels[god.team],
        god.position,
        god.facing,
        footmanRenderClips[god.team][god.godClip],
        god.animTime,
        sizeFactor = 2.6
      )
      finishCharacters(scene)
      return
    for tower in run.world.towers:
      if tower.hp <= 0 or tower.id != id:
        continue
      towerPack.drawProp(
        towerPropName(tower.tier),
        renderPoint(tower.position),
        renderFacing(tower.facing),
        towerScale(tower.tier),
        viewProjection
      )
      return

  proc drawIdOutlines(
      ids: openArray[int32],
      color: Vec3,
      view,
      projection,
      viewProjection: Mat4
  ) =
    ## Composites one outline color around every id that still exists.
    var any = false
    for id in ids:
      if selectionTarget(id).found:
        any = true
        break
    if not any:
      return
    selectionOutline.beginMask(window.size)
    for id in ids:
      if selectionTarget(id).found:
        drawOutlinedObject(id, view, projection, viewProjection)
    selectionOutline.drawOutline(color)

  proc drawSelectedOutline(
      view,
      projection,
      viewProjection: Mat4
  ) =
    ## Draws the yellow selection outline and the red attack-target outline.
    if selectedIds.len > 0:
      drawIdOutlines(
        selectedIds,
        SelectionOutlineColor,
        view,
        projection,
        viewProjection
      )
    if playerMode():
      let targetId = heroById(run.world, playerHeroId()).attackObjectId
      if targetId != 0:
        drawIdOutlines(
          [targetId],
          AttackOutlineColor,
          view,
          projection,
          viewProjection
        )

  proc feedGotaActions() =
    ## Notes fights, tower shots, creeping, approaches, and upcoming tape.
    const
      LookAheadTicks = 48'i32
      ApproachHero = 14.0'f32
      ApproachTower = 10.0'f32
      ApproachFort = 16.0'f32
      CreepBase = 70_000_000'i32
      PairBase = 80_000_000'i32
    let tick = int32(run.world.tick)
    actionCam.beginFrame(tick)
    proc planarDist(a, b: Vec3): float32 =
      ## Returns ground distance between two render points.
      let
        dx = a.x - b.x
        dz = a.z - b.z
      sqrt(dx * dx + dz * dz)
    proc renderOf(id: int32, point: var Vec3): bool =
      ## Finds a living object's current render position.
      let hero = heroById(run.world, id)
      if hero != nil and hero.id != 0:
        point = renderPoint(hero.position)
        return true
      let tower = towerById(run.world, id)
      if tower.id != 0:
        point = renderPoint(tower.position)
        return true
      let footman = footmanById(run.world, id)
      if footman.id != 0:
        point = renderPoint(footman.position)
        return true
      for fort in run.world.forts:
        if fort.id == id:
          point = renderPoint(fort.center)
          return true
      false
    proc noteUpcoming(actions: openArray[ReplayAction]) =
      ## Zooms toward recorded attacks before they execute.
      var i = actions.actionIndexAfter(uint32(tick))
      let limit = uint32(tick + LookAheadTicks)
      while i < actions.len and actions[i].tick <= limit:
        let action = actions[i]
        if action.kind == ActionAttackTarget or
            action.kind == ActionUseItem:
          var pos: Vec3
          if renderOf(action.heroId, pos):
            var score = 78.0'f32
            if action.kind == ActionAttackTarget:
              var target: Vec3
              if renderOf(action.first, target):
                pos = mix(pos, target, 0.5'f32)
              score = 82
            else:
              score = 86
            actionCam.noteInterest(
              action.heroId,
              pos,
              score,
              8,
              tick,
              int32(action.tick) - tick + 24
            )
        inc i
    if run.replayPlayer != nil:
      noteUpcoming(run.replayPlayer.data.actions)
    elif run.recorder != nil:
      noteUpcoming(run.recorder.data.actions)
    if prevTowerHp.len != run.world.towers.len:
      prevTowerHp.setLen(run.world.towers.len)
    for i, tower in run.world.towers:
      let pos = renderPoint(tower.position)
      if tower.hp > 0:
        if tower.attackTicks != 0:
          actionCam.noteInterest(tower.id, pos, 58, 10, tick, 36)
        elif tower.hp < tower.maxHp:
          actionCam.noteInterest(tower.id, pos, 48, 10, tick, 36)
      elif sawTowerHp and prevTowerHp[i] > 0:
        actionCam.noteInterest(tower.id, pos, 96, 12, tick, 48)
      prevTowerHp[i] = tower.hp
    for i, fort in run.world.forts:
      let
        godPos = gods[i].position
        wounded = fort.hp > 0 and fort.hp < FortHp
        dying = sawTowerHp and prevFortHp[i] > 0 and fort.hp <= 0
      if dying:
        actionCam.noteInterest(fort.id, godPos, 150, 6, tick, 72)
      elif fort.hp > 0:
        var score = 0.0'f32
        if wounded:
          let hurt = 1.0'f32 - fort.hp.float32 / FortHp.float32
          score = 90.0'f32 + 50.0'f32 * hurt
        for hero in run.world.heroes:
          if hero.team == fort.team or
              hero.state == Dying or
              hero.hp <= 0:
            continue
          let
            pos = renderPoint(hero.position)
            dist = planarDist(pos, godPos)
          if hero.attackingFort or dist < ApproachFort:
            let t = 1.0'f32 - clamp(dist / ApproachFort, 0, 1)
            score = max(
              score,
              if hero.attackingFort: 130.0'f32 + 15.0'f32 * t
              else: 100.0'f32 + 25.0'f32 * t
            )
        for footman in run.world.footmen:
          if footman.team == fort.team or
              footman.state == Dying or
              footman.hp <= 0:
            continue
          let
            pos = renderPoint(footman.position)
            dist = planarDist(pos, godPos)
          if footman.attackingFort or dist < ApproachFort * 0.7'f32:
            score = max(score, 88.0'f32)
        if score > 0:
          actionCam.noteInterest(
            fort.id,
            godPos,
            score,
            6,
            tick,
            36
          )
      prevFortHp[i] = fort.hp
    sawTowerHp = true
    for hero in run.world.heroes:
      let pos = renderPoint(hero.position)
      if hero.state == Fighting:
        actionCam.noteInterest(hero.id, pos, 80, 6, tick, 36)
      elif hero.state == Dying and
          hero.deathTicks < TickRate:
        actionCam.noteInterest(hero.id, pos, 92, 6, tick, 24)
    for i, hero in run.world.heroes:
      if hero.state == Dying or hero.hp <= 0:
        continue
      let fromPos = renderPoint(hero.position)
      for other in run.world.heroes:
        if other.team == hero.team or
            other.state == Dying or
            other.hp <= 0 or
            other.id <= hero.id:
          continue
        let
          toPos = renderPoint(other.position)
          dist = planarDist(fromPos, toPos)
        if dist < ApproachHero:
          let
            t = 1.0'f32 - dist / ApproachHero
            pos = mix(fromPos, toPos, 0.5'f32)
            id = PairBase + hero.id * 256 + other.id
          actionCam.noteInterest(
            id,
            pos,
            55 + 20 * t,
            8,
            tick,
            24
          )
      for tower in run.world.towers:
        if tower.team == hero.team or tower.hp <= 0:
          continue
        let
          toPos = renderPoint(tower.position)
          dist = planarDist(fromPos, toPos)
        if dist < ApproachTower:
          let t = 1.0'f32 - dist / ApproachTower
          actionCam.noteInterest(
            PairBase + hero.id * 1000 + tower.id,
            mix(fromPos, toPos, 0.4'f32),
            52 + 18 * t,
            10,
            tick,
            24
          )
    var
      laneScore: array[3, float32]
      laneX: array[3, float32]
      laneY: array[3, float32]
      laneZ: array[3, float32]
      laneN: array[3, int]
    for footman in run.world.footmen:
      if footman.lane < 0 or footman.lane > 2:
        continue
      let fighting = footman.state == Fighting
      let dying =
        footman.state == Dying and
        footman.deathTicks < TickRate
      if not fighting and not dying:
        continue
      let
        pos = renderPoint(footman.position)
        w = if fighting: 1.0'f32 else: 0.6'f32
        lane = footman.lane
      laneScore[lane] += w
      laneX[lane] += pos.x * w
      laneY[lane] += pos.y * w
      laneZ[lane] += pos.z * w
      inc laneN[lane]
    for lane in 0 .. 2:
      if laneN[lane] == 0:
        continue
      let total = laneScore[lane]
      actionCam.noteInterest(
        CreepBase + int32(lane),
        vec3(
          laneX[lane] / total,
          laneY[lane] / total,
          laneZ[lane] / total
        ),
        min(18.0'f32 + float32(laneN[lane]) * 2.0'f32, 32.0'f32),
        10,
        tick,
        36
      )

  proc playerHeroFrame(): Vec3 =
    ## Returns the look-at that frames the human hero over the HUD.
    let hero = heroById(run.world, playerHeroId())
    if hero.id == 0:
      return cameraTarget
    rtsFollowFrame(
      unitRenderPoint(hero.id, hero.position) + vec3(0, 0.9'f32, 0),
      cameraDistance,
      RtsGotaFollowLift
    )

  if playerMode():
    cameraTarget = playerHeroFrame()

  proc updateCamera(dt: float32) =
    ## Applies fixed-north RTS pan, zoom, and selection following.
    pruneSelection()
    syncViewMode()
    if focusPlayerHero:
      focusPlayerHero = false
      startCameraEase(cameraEase, cameraTarget)
    updateMinimapCamera(
      window,
      sk.mousePos,
      cameraTarget,
      minimapPanning,
      followSelection
    )
    if minimapPanning:
      actionCam.takeManual()
      cancelCameraEase(cameraEase)
    let overUi = mouseOverUi(window, sk.mousePos, primaryId)
    if window.buttonPressed[KeyA] and
        (window.buttonDown[KeyLeftControl] or
          window.buttonDown[KeyRightControl]):
      selectAllHeroes()
    elif window.buttonPressed[KeyA] and playerMode():
      attackMoveArmed = true
    if window.mousePressed(MouseLeft) and not overUi:
      selectionPressPosition = window.mousePos.vec2
      selectionStarted = true
      selectionAdditive =
        window.buttonDown[KeyLeftShift] or
        window.buttonDown[KeyRightShift]
    if window.mousePressed(MouseRight) and not overUi:
      rightPressPosition = window.mousePos.vec2
    if window.mousePressed(MouseMiddle) and
        (not overUi or window.buttonPressed[MouseMiddleKey]):
      if not playerMode():
        followSelection = false
        actionCam.takeManual()
      cancelCameraEase(cameraEase)
    panning =
      window.mouseDown(MouseMiddle) and
        (not overUi or window.buttonDown[MouseMiddleKey]) or
      (not playerMode() and not overUi and window.mouseDown(MouseRight))

    let delta = window.mouseDelta.vec2
    if playerMode():
      if not overUi and window.scrollDelta.y != 0:
        cancelCameraEase(cameraEase)
        cameraDistance = clamp(
          cameraDistance * pow(
            0.92'f32,
            window.scrollDelta.y / 3.0'f32
          ),
          5.0'f32,
          400.0'f32
        )
      if panning:
        cancelCameraEase(cameraEase)
        let panSpeed = cameraDistance * 0.0015
        cameraTarget.x -= delta.x * panSpeed
        cameraTarget.z -= delta.y * panSpeed
        cameraTarget.x = clamp(cameraTarget.x, -HalfGrid, HalfGrid)
        cameraTarget.z = clamp(cameraTarget.z, -HalfGrid, HalfGrid)
      elif applyRtsPan(
          cameraTarget,
          rtsPanDir(window),
          dt,
          cameraDistance,
          HalfGrid
        ):
        cancelCameraEase(cameraEase)
      else:
        discard advanceCameraEase(
          cameraEase,
          cameraTarget,
          playerHeroFrame(),
          dt
        )
      return
    if panning:
      followSelection = false
      actionCam.takeManual()
      let
        panSpeed = cameraDistance * 0.0015
      cameraTarget.x -= delta.x * panSpeed
      cameraTarget.z -= delta.y * panSpeed
      cameraTarget.x = clamp(cameraTarget.x, -HalfGrid, HalfGrid)
      cameraTarget.z = clamp(cameraTarget.z, -HalfGrid, HalfGrid)
    if not minimapPanning and
        applyRtsPan(
          cameraTarget,
          rtsPanDir(window),
          dt,
          cameraDistance,
          HalfGrid
        ):
      followSelection = false
      actionCam.takeManual()
    if not overUi and window.scrollDelta.y != 0:
      actionCam.takeManual()
      if followSelection and selectedTargetCount() > 1:
        groupCameraScale = clamp(
          groupCameraScale * pow(
            0.92'f32,
            window.scrollDelta.y / 3.0'f32
          ),
          0.75'f32,
          3.0'f32
        )
      else:
        cameraDistance = clamp(
          cameraDistance * pow(
            0.92'f32,
            window.scrollDelta.y / 3.0'f32
          ),
          5.0'f32,
          400.0'f32
        )

    if actionCam.enabled:
      feedGotaActions()
      actionCam.chooseShot(dt, transport.speed)
      actionCam.follow(
        cameraTarget,
        cameraDistance,
        dt,
        transport.speed
      )
      return
    let targetCount = selectedTargetCount()
    if followSelection and targetCount == 1:
      let target = selectionTarget(selectedIds[0])
      cameraTarget = mix(
        cameraTarget,
        target.position + vec3(0, target.focusHeight, 0),
        damping(5.0'f32, dt)
      )
    elif followSelection and targetCount > 1:
      let
        groupCenter = selectedCenter()
        groupDistance = clamp(
          12.0'f32 + selectedRadius(groupCenter) * 2.8'f32,
          20.0'f32,
          400.0'f32
        ) * groupCameraScale
      cameraTarget = mix(
        cameraTarget,
        groupCenter,
        damping(4.0'f32, dt)
      )
      cameraDistance = mix(
        cameraDistance,
        groupDistance,
        damping(2.0'f32, dt)
      )
    elif followSelection:
      followSelection = false

  proc issueGroundOrder(viewProjection: Mat4, attackMove: bool) =
    ## Walks or attack-moves the human hero onto the tile under the pointer.
    let heroId = playerHeroId()
    let hero = heroById(run.world, heroId)
    if hero.id == 0 or hero.state == Dying:
      return
    let
      (origin, dir) = mouseRay(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection
      )
      walk = pickWalkableTile(origin, dir)
    if not walk.hit:
      return
    let
      mapX = int32(layers[walk.layer].originX + walk.x)
      mapY = int32(layers[walk.layer].originZ + walk.z)
    if attackMove:
      queueAttackMove(heroId, mapX, mapY)
    else:
      queueWalkTo(heroId, mapX, mapY)
    selectEntity(heroId)
    clickMarks.emitClickMark(tileCenter(walk.layer, walk.x, walk.z))

  proc updateWorldSelection(viewProjection: Mat4) =
    ## Selects a clicked world unit, or attacks it in player mode.
    if not window.mouseReleased(MouseLeft):
      return
    if selectionStarted and
        (window.mousePos.vec2 - selectionPressPosition).length <=
          6.0'f32 and
        not mouseOverUi(window, sk.mousePos, primaryId):
      let picked = pickEntity(viewProjection)
      if playerMode() and attackMoveArmed:
        let heroId = playerHeroId()
        if picked != 0 and objectTeam(picked) != objectTeam(heroId):
          queueAttackTarget(heroId, picked)
        else:
          issueGroundOrder(viewProjection, true)
        attackMoveArmed = false
      elif picked != 0:
        selectEntity(picked, selectionAdditive)
        if playerMode() and objectTeam(picked) != objectTeam(playerHeroId()):
          queueAttackTarget(playerHeroId(), picked)
      elif not selectionAdditive:
        clearSelection()
    selectionStarted = false

  proc updatePlayerOrder(viewProjection: Mat4) =
    ## Turns a right-click into a walk, attack-move, or chase attack.
    if not playerMode():
      return
    if not window.mouseReleased(MouseRight):
      return
    if mouseOverUi(window, sk.mousePos, primaryId):
      return
    if (window.mousePos.vec2 - rightPressPosition).length > 6.0'f32:
      return
    let
      heroId = playerHeroId()
      picked = pickEntity(viewProjection)
    if picked != 0 and objectTeam(picked) != objectTeam(heroId):
      queueAttackTarget(heroId, picked)
      attackMoveArmed = false
      return
    issueGroundOrder(viewProjection, attackMoveArmed)
    attackMoveArmed = false

  proc cameraView(): Mat4 =
    ## Updates the camera eye and returns its view matrix.
    cameraEye = rtsCameraEye(cameraTarget, cameraDistance)
    lookAt(cameraEye, cameraTarget, vec3(0, 1, 0))

  ## Frame

  const SimulationStep = 1.0'f32 / TickRate.float32

  var lastFrameTime = epochTime()

  proc particleTargetPosition(id: int32): tuple[
      found: bool,
      position: Vec3
  ] =
    ## Returns the presentation-space center of one combat target.
    let hero = heroById(run.world, id)
    if hero.id != 0:
      return (
        true,
        renderPoint(hero.position) + vec3(0, 0.85'f32, 0)
      )
    let footman = footmanById(run.world, id)
    if footman.id != 0:
      return (
        true,
        renderPoint(footman.position) + vec3(0, 0.65'f32, 0)
      )
    let tower = towerById(run.world, id)
    if tower.id != 0:
      return (
        true,
        renderPoint(tower.position) +
          vec3(0, towerScale(tower.tier) * 0.55'f32, 0)
      )
    for i, fort in run.world.forts:
      if fort.id == id:
        return (true, gods[i].position + vec3(0, 1.0'f32, 0))

  proc emitAttackParticles(
      style: HeroAttackStyle,
      origin,
      target: Vec3
  ) =
    ## Converts one landed hero attack into its presentation effect.
    case style
    of MeleeAttack:
      particles.emitParticleBurst(CombatSparks, target)
    of RangedAttack:
      particles.emitParticleProjectile(
        ArrowWake,
        CombatSparks,
        origin,
        target,
        clamp(
          (target - origin).length / 18.0'f32,
          0.08'f32,
          0.38'f32
        )
      )
    of MagicAttack:
      particles.emitParticleProjectile(
        MagicBolt,
        MagicBurst,
        origin,
        target,
        clamp(
          (target - origin).length / 13.0'f32,
          0.12'f32,
          0.48'f32
        )
      )

  proc emitTickParticles(
      oldHeroLanded: seq[bool],
      oldFootmanLanded: Table[int32, bool],
      oldTowerTicks: seq[int32]
  ) =
    ## Emits each authoritative attack transition exactly once.
    for i, hero in run.world.heroes:
      if i >= oldHeroLanded.len or oldHeroLanded[i] or
          not hero.damageLanded:
        continue
      let target = particleTargetPosition(hero.attackObjectId)
      if not target.found:
        continue
      let origin = renderPoint(hero.position) + vec3(0, 0.9'f32, 0)
      emitAttackParticles(
        hero.class.heroSpec.attackStyle,
        origin,
        target.position
      )
    for footman in run.world.footmen:
      if oldFootmanLanded.getOrDefault(footman.id, false) or
          not footman.damageLanded:
        continue
      let targetId =
        if footman.targetId != 0:
          footman.targetId
        elif footman.targetHeroId != 0:
          footman.targetHeroId
        elif footman.targetTowerId != 0:
          footman.targetTowerId
        elif footman.team == RedTeam:
          run.world.forts[1].id
        else:
          run.world.forts[0].id
      let target = particleTargetPosition(targetId)
      if target.found:
        particles.emitParticleBurst(
          CombatSparks,
          target.position
        )
    for i, tower in run.world.towers:
      if i >= oldTowerTicks.len or tower.targetId == 0 or
          oldTowerTicks[i] != TowerAttackTicks - 1 or
          tower.attackTicks != 0:
        continue
      let target = particleTargetPosition(tower.targetId)
      if not target.found:
        continue
      let origin = renderPoint(tower.position) +
        vec3(0, towerScale(tower.tier) * 0.72'f32, 0)
      particles.emitParticleProjectile(
        Fireball,
        FireBurst,
        origin,
        target.position,
        clamp(
          (target.position - origin).length / 14.0'f32,
          0.14'f32,
          0.5'f32
        )
      )

  proc advanceRenderedSimulation() =
    ## Advances one simulation tick and starts any new god animation.
    let wasGameOver = run.world.gameOver
    var
      oldHeroLanded = newSeq[bool](run.world.heroes.len)
      oldFootmanLanded: Table[int32, bool]
      oldTowerTicks = newSeq[int32](run.world.towers.len)
    for i, hero in run.world.heroes:
      oldHeroLanded[i] = hero.damageLanded
    for footman in run.world.footmen:
      oldFootmanLanded[footman.id] = footman.damageLanded
    for i, tower in run.world.towers:
      oldTowerTicks[i] = tower.attackTicks
    captureUnitPositions()
    advanceGame()
    emitTickParticles(
      oldHeroLanded,
      oldFootmanLanded,
      oldTowerTicks
    )
    if int(run.world.tick) mod SeekCheckpointTicks == 0 or
        int32(run.world.tick) == transport.timelineEnd:
      if replayCheckpoints.len == 0 or
          replayCheckpoints[^1].tick < int(run.world.tick):
        replayCheckpoints.add captureCheckpoint()
    if run.world.gameOver and not wasGameOver:
      for god in gods.mitems:
        god.animTime = 0

  proc restoreTo(targetTick: int32) =
    ## Reloads the last checkpoint at or before a tick, then resimulates.
    var checkpointIndex = 0
    for i, checkpoint in replayCheckpoints:
      if checkpoint.tick > targetTick:
        break
      checkpointIndex = i
    let checkpoint = replayCheckpoints[checkpointIndex]
    run.world.restore(checkpoint.world)
    if run.recorder != nil and run.replayPlayer != nil:
      run.replayPlayer.data = run.recorder.data
    run.replayPlayer.syncCursor(uint32(run.world.tick))
    run.hashCheck = checkpoint.hashCheck
    run.historyPlayback = true
    previousUnitPositions.clear()
    previousUnitFacings.clear()
    particles.clearParticles()
    renderAlpha = 1
    animationAlpha = 0
    for god in gods.mitems:
      god.animTime = 0
    while int32(run.world.tick) < targetTick:
      advanceGame()
      if int(run.world.tick) mod SeekCheckpointTicks == 0 or
          int32(run.world.tick) == transport.timelineEnd:
        if replayCheckpoints.len == 0 or
            replayCheckpoints[^1].tick < int(run.world.tick):
          replayCheckpoints.add captureCheckpoint()

  if not run.replayMode:
    startReplayRecording(uint32(transport.durationTicks))
  replayCheckpoints = @[captureCheckpoint()]

  when defined(takeScreenshot):
    var screenshotFrame = 0
    applyScreenshotCamera(cameraDistance)
    if existsEnv("CAM_X"): cameraTarget.x = getEnv("CAM_X").parseFloat.float32
    if existsEnv("CAM_Z"): cameraTarget.z = getEnv("CAM_Z").parseFloat.float32
    if existsEnv("SHOW_EDGES"): showTiles = getEnv("SHOW_EDGES") != "0"
    if run.replayMode and existsEnv("REPLAY_TICK"):
      transport.seekTo(int32(getEnv("REPLAY_TICK").parseInt))
    if existsEnv("SIM_SECONDS"):
      # Fast-forward the battle deterministically before the first frame.
      let simSeconds = getEnv("SIM_SECONDS").parseFloat
      for i in 0 ..< int(simSeconds * TickRate.float64):
        advanceGame()
    if existsEnv("PARTICLE_DEMO"):
      let
        origin = cameraTarget + vec3(-2.5'f32, 4.0'f32, 0)
        target = cameraTarget + vec3(2.5'f32, 4.0'f32, 0)
      particles.emitParticleProjectile(
        Fireball,
        FireBurst,
        origin,
        target,
        0.42'f32
      )
      particles.emitParticleBurst(
        HealingAura,
        cameraTarget + vec3(0, 3.5'f32, 0)
      )
    if not playerMode():
      for hero in run.world.heroes:
        if hero.class == Arcanist and hero.state != Dying:
          primaryId = hero.id
          selectedIds = @[hero.id]
          followSelection = true
          break
      if primaryId == 0:
        for hero in run.world.heroes:
          if hero.state != Dying:
            primaryId = hero.id
            selectedIds = @[hero.id]
            followSelection = true
            break
    else:
      primaryId = playerHeroId()
      selectedIds = @[primaryId]
      followSelection = false
      cameraTarget = playerHeroFrame()

  holdSplash(sk, window, splash)
  window.onFrame = proc() =
    profileBlock "frame":
      let dt = frameDelta(lastFrameTime)
      sk.uiScale = hudUiScale(window)
      sk.mousePos = window.mousePos.vec2 / sk.uiScale
      profileBlock "camera":
        updateCamera(dt)
      let recorded =
        if run.recorder != nil: int32(run.recorder.data.hashes.len)
        else: int32(run.replayPlayer.data.hashes.len)
      transport.sync(int32(run.world.tick), recorded, run.world.gameOver)
      let restoreTick = transport.takeRestore()
      if restoreTick >= 0:
        restoreTo(restoreTick)
        transport.sync(int32(run.world.tick), recorded, run.world.gameOver)
      transport.startFrame(dt, TickRate)
      let frameStart = epochTime()
      run.historyPlayback = transport.inHistory
      profileBlock "simulate":
        while transport.shouldTick(frameStart):
          if atLiveTickCap(
              int32(run.world.tick),
              transport.durationTicks,
              transport.live
          ):
            break
          run.historyPlayback = transport.inHistory
          advanceRenderedSimulation()
          let recordedNow =
            if run.recorder != nil: int32(run.recorder.data.hashes.len)
            else: int32(run.replayPlayer.data.hashes.len)
          transport.sync(int32(run.world.tick), recordedNow, run.world.gameOver)
      let active = simulationActive(transport)
      if active:
        renderAlpha = clamp(
          transport.accumulator / SimulationStep,
          0.0'f32,
          1.0'f32
        )
        animationAlpha = renderAlpha
      else:
        renderAlpha = 1
        animationAlpha = 0
      if active:
        particles.advanceParticles(dt)
        clickMarks.advanceClickMarks(dt)
        for god in gods.mitems:
          god.animTime += dt
          if run.world.gameOver and god.team != run.world.winner:
            god.animTime = min(
              god.animTime,
              clipDuration(
                footmanModels[god.team], footmanRenderClips[god.team][deathClip])
            )

      let
        aspect = window.size.x.float32 / max(window.size.y.float32, 1)
        view = cameraView()
        projection = perspective(45.0'f32, aspect, 0.1'f32, 1000.0'f32)
        viewProjection = projection * view
        cameraForward = normalize(cameraTarget - cameraEye)
        barCameraRight = normalize(cross(cameraForward, vec3(0, 1, 0)))
        barCameraUp = normalize(cross(barCameraRight, cameraForward))

      updateWorldSelection(viewProjection)
      updatePlayerOrder(viewProjection)

      profileBlock "drawWorld":
        # One clock for the whole frame: the palette, the sun's position,
        # and its shadow map all follow the in-game hour. The fractional
        # tick keeps the sun gliding between simulation steps instead of
        # visibly stepping shadow positions a few times a second.
        scene.setToonHour(
          clockHour(float32(run.world.tick) + renderAlpha, TickRate))
        setEnvironmentPalette(scene.toon)

        # One loop for both passes: footmen, heroes, and gods render into
        # the sun's depth map first, then for the camera.
        proc drawWorldCharacters() =
          for footman in run.world.footmen:
            if not visibleInView(footman.team, footman.position):
              continue
            let
              model = footmanModels[footman.team]
              clip = footmanRenderClips[footman.team][footman.animClip]
            drawCharacter(
              scene, model, unitRenderPoint(footman.id, footman.position),
              unitRenderFacing(footman.id, footman.facing),
              clip,
              holdClipTime(
                model, clip, footman.animTicks, footman.state == Dying))
          for hero in run.world.heroes:
            if not visibleInView(hero.team, hero.position):
              continue
            let clip = heroRenderClips[hero.animClip]
            drawCharacter(
              scene,
              heroModels[hero.class],
              unitRenderPoint(hero.id, hero.position),
              unitRenderFacing(hero.id, hero.facing),
              clip,
              holdClipTime(
                heroModels[hero.class],
                clip,
                hero.animTicks,
                hero.state == Dying
              ),
              sizeFactor = hero.heroSizeFactor()
            )
          for god in gods:
            if not visibleInView(
                god.team, run.world.forts[god.team.ord].center):
              continue
            let
              model = footmanModels[god.team]
              clip = footmanRenderClips[god.team][god.godClip]
            var animTime = god.animTime
            if run.world.gameOver and god.team != run.world.winner:
              animTime = min(animTime, clipDuration(model, clip))
            drawCharacter(
              scene, model, god.position, god.facing,
              clip, animTime, sizeFactor = 2.6)

        sunDepthPasses(window.size):
          drawTerrainSunDepth()
          for tower in run.world.towers:
            if tower.hp <= 0:
              continue
            towerPack.drawPropSunDepth(
              towerPropName(tower.tier),
              renderPoint(tower.position),
              renderFacing(tower.facing),
              towerScale(tower.tier)
            )
          scene.sunDepthPass = true
          drawWorldCharacters()
          scene.sunDepthPass = false
        glClearColor(0.05, 0.06, 0.09, 1.0)
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
        updateTerrainVision()
        drawTerrain(viewProjection, showTiles)
        for tower in run.world.towers:
          if tower.hp <= 0 or not visibleInView(tower.team, tower.position):
            continue
          towerPack.drawProp(
            towerPropName(tower.tier),
            renderPoint(tower.position),
            renderFacing(tower.facing),
            towerScale(tower.tier),
            viewProjection
          )

        beginCharacters(scene, window, view, projection, cameraEye)
        drawWorldCharacters()
        finishCharacters(scene)

        drawWater(viewProjection, cameraEye)
        particles.drawParticles(
          viewProjection,
          barCameraRight,
          barCameraUp,
          cameraForward
        )
        clickMarks.drawClickMarks(viewProjection)
        if showPaths:
          worldShapes.clear()
          for hero in run.world.heroes:
            if hero.state == Dying or hero.hp <= 0:
              continue
            if hero.movePathIndex >= hero.movePath.len:
              continue
            let color =
              if hero.team == RedTeam:
                rgbx(210, 72, 64, 255)
              else:
                rgbx(64, 120, 220, 255)
            var points: seq[Vec3]
            let now = unitRenderPoint(hero.id, hero.position)
            points.add vec3(now.x, now.y + 0.2'f32, now.z)
            for i in hero.movePathIndex ..< hero.movePath.len:
              let p = renderPoint(hero.movePath[i])
              points.add vec3(p.x, p.y + 0.2'f32, p.z)
            if points.len >= 2:
              worldShapes.addPolyline(points, color)
          worldShapes.draw(viewProjection)
        drawWorldUnitBars(
          worldBarRenderer,
          viewProjection,
          barCameraRight,
          barCameraUp,
          dt
        )
        drawSelectedOutline(view, projection, viewProjection)

      profileBlock "ui":
        glDisable(GL_DEPTH_TEST)
        glDisable(GL_CULL_FACE)
        glDisable(GL_BLEND)
        when not defined(emscripten):
          glDisable(GL_MULTISAMPLE)
        glActiveTexture(GL_TEXTURE0)
        glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
        sk.beginUi(window, window.size)
        drawUi(
          sk,
          window,
          transport,
          cameraTarget,
          cameraDistance,
          viewMode,
          primaryId,
          selectedIds,
          followSelection,
          actionCam,
          focusPlayerHero
        )
        sk.endUi()
      when defined(takeScreenshot):
        captureScreenshot(
          window,
          screenshotFrame,
          30,
          "examples/gods_of_the_arena/gota_shot.png"
        )
      profileBlock "present":
        window.presentFrame(framePaceHz)
    if noteProfileFrame():
      when not defined(emscripten):
        window.closeRequested = true

  while not window.closeRequested:
    pollEvents()

  if not run.replayMode:
    saveRecording()
  particles.closeParticles()
  finishProfileTrace()
