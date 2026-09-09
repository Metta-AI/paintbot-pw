## Light vs Dark spectator viewer.
##
## Reads the simulation and never writes it. The renderer interpolates body
## poses between ticks and samples terrain height for the vertical. None of
## that can flow back into `World`.
##
## Fog is presentation too. All three view modes read the same world; only
## what gets drawn changes.

import
  std/[math, os, strformat, strutils, tables, times, unicode],
  chroma, opengl, pixie, vmath, windy, silky,
  polyworld/[
    actioncam, characters, chrome, clickmarks, common, fixed, inputs, particles,
    particleshaders,
    pathing, player, profiles, quadterrain, rtscameras, selectionoutlines,
    shapes,
    shadows, tapes, viewers, visions, worldbars
  ],
  content,
  sim,
  game,
  replays,
  ui,
  controls

const
  WindowTitle = "Light vs Dark"
  AtlasPath = TmpRoot & "/lvd.atlas.png"
  LogoPath = DataRoot & "/themes/lvd/lvd_logo.png"
  SeekCheckpointTicks = TickRate * 10
    ## One saved world every ten seconds, so a seek re-simulates at most
    ## that much.
  RebakeFrameGap = 30
    ## Terrain is re-emitted whole, so felling trees is batched rather than
    ## letting a busy lumber camp stutter the frame rate.
  SelectionDragPixels = 6.0'f32
    ## Pointer travel that turns a click into a box select.
  UnitModels = [
    [
      PeonUnit: DataRoot & "/characters/mini_legion/human/worker.glb",
      SoldierUnit: DataRoot & "/characters/mini_legion/human/footman.glb",
      ArcherUnit: DataRoot & "/characters/mini_legion/human/archer.glb",
      MageUnit: DataRoot & "/characters/mini_legion/human/mage.glb",
      KnightUnit: DataRoot & "/characters/mini_legion/human/horseman.glb",
      CatapultUnit: DataRoot &
        "/characters/mini_legion/human/siege_engine.glb",
      ClericUnit: DataRoot & "/characters/mini_legion/sentinel/druid.glb",
      SummonUnit: DataRoot &
        "/characters/mini_legion/sentinel/rock_golem.glb"
    ],
    [
      PeonUnit: DataRoot & "/characters/mini_legion/warband/minion.glb",
      SoldierUnit: DataRoot & "/characters/mini_legion/warband/grunt.glb",
      ArcherUnit: DataRoot &
        "/characters/mini_legion/warband/head_hunter.glb",
      MageUnit: DataRoot & "/characters/mini_legion/warband/warlock.glb",
      KnightUnit: DataRoot &
        "/characters/mini_legion/warband/hog_rider.glb",
      CatapultUnit: DataRoot &
        "/characters/mini_legion/undead/siege_engine.glb",
      ClericUnit: DataRoot & "/characters/mini_legion/undead/lich.glb",
      SummonUnit: DataRoot & "/characters/rpg_monsters/demon_king.glb"
    ]
  ]
  UnitHeights = [
    PeonUnit: 1.05'f32,
    SoldierUnit: 1.15'f32,
    ArcherUnit: 1.20'f32,
    MageUnit: 1.25'f32,
    KnightUnit: 1.55'f32,
    CatapultUnit: 1.40'f32,
    ClericUnit: 1.22'f32,
    SummonUnit: 1.90'f32
  ]
  LightPropPack = DataRoot & "/terrain/low_poly_village.glb"
  DarkPropPack = DataRoot & "/terrain/tower_defense_kit.glb"
  BuildingProps = [
    [
      TownHallBuilding: "house_lvl7",
      FarmBuilding: "farm_lvl4",
      BarracksBuilding: "farm_house_lvl5",
      LumberMillBuilding: "farm_house_lvl3",
      TowerBuilding: "tower_lvl5",
      StablesBuilding: "farm_house_lvl6",
      ChurchBuilding: "house_lvl4",
      BlacksmithBuilding: "farm_house_lvl2",
      GoldMineBuilding: ""
    ],
    [
      TownHallBuilding: "building1",
      FarmBuilding: "farm_lvl2",
      BarracksBuilding: "building3",
      LumberMillBuilding: "building2",
      TowerBuilding: "tower_square_tall1",
      StablesBuilding: "tower_tall1",
      ChurchBuilding: "tower_square_tall2",
      BlacksmithBuilding: "tower_square_small1",
      GoldMineBuilding: ""
    ]
  ]
  BuildingPropHeights = [
    TownHallBuilding: 3.0'f32,
    FarmBuilding: 1.6'f32,
    BarracksBuilding: 2.6'f32,
    LumberMillBuilding: 2.4'f32,
    TowerBuilding: 3.2'f32,
    StablesBuilding: 2.5'f32,
    ChurchBuilding: 2.8'f32,
    BlacksmithBuilding: 2.2'f32,
    GoldMineBuilding: 1.8'f32
  ]
  MineProps = ["mineral1", "mineral3", "rock2"]
  ConstructionProps = ["box1", "barel1", "wall1"]
  RubbleProps = ["rock1", "stump1"]

type
  GraphicsError = object of CatchableError
  SeekCheckpoint = object
    world: World
    actionIndex: int
    hashCheck: ReplayHashCheck
  SelectionTarget = object
    found: bool
    position: Vec3

var
  window*: Window
  sk*: Silky
  cameraDistance* = 190.0'f32
  cameraTarget* = vec3(0, 0, 0)
  cameraEye = vec3(0, 0, 0)
  panning = false
  minimapPanning* = false
  viewMode* =
    if options.playerSlot > 0: options.playerSlot
    else: options.viewMode
  primaryId* = NoEntity
  selectedIds*: seq[int32]
  followSelection* = false
  selectionPressPosition = vec2(0)
  selectionStarted = false
  selectionAdditive = false
  groupCameraScale = 1.0'f32
  seekCheckpoints: seq[SeekCheckpoint]
  transport* = initPlayer(
    live = not run.replayMode,
    durationTicks = run.maximumTicks,
    playing = not options.pauseOnStart,
    speed = options.speed
  )
  placedEditCount = 0
  placedBuildingKey = ""
  terrainDirty = false
  framesSinceRebake = 0
  frameAlpha = 0.0'f32
  previousUnitPositions: Table[int32, Vec3]
  previousUnitFacings: Table[int32, float32]
  terrainVisionTick = int32.low
  terrainVisionMode = int32.low

## Presentation helpers

proc unitPortraitPath(player: int32, kind: UnitKind): string =
  ## Returns the on-disk profile next to one unit model.
  UnitModels[player][kind].changeFileExt("profile.png")

proc buildingPack(player: int32, kind: BuildingKind): string =
  ## Returns the GLB pack that holds this building's prop.
  if kind == GoldMineBuilding:
    DarkPropPack
  elif player == LightPlayer or kind == FarmBuilding:
    LightPropPack
  else:
    DarkPropPack

proc buildingPortraitPath(player: int32, kind: BuildingKind): string =
  ## Returns the on-disk profile for one building prop.
  if kind == GoldMineBuilding:
    DarkPropPack.changeFileExt("mineral1.profile.png")
  else:
    buildingPack(player, kind).changeFileExt(
      BuildingProps[player][kind] & ".profile.png"
    )

proc clipIndex(model: CharacterModel, slot: AnimationSlot): int =
  ## Returns a clip for one pose. Locomotion prefers Run, Move, then Walk.
  const Names: array[AnimationSlot, seq[string]] = [
    RunAnimation: @["Run", "Move", "Walk", "RunForward", "WalkForward"],
    IdleAnimation: @["Idle", "IdleBattle", "IdleNormal"],
    DeathAnimation: @["Death", "Die", "Die01"],
    AttackAnimation: @[
      "Attack01", "Attack01Start", "WorkRoutine", "WorkStart", "Idle"
    ],
    AttackAlternateAnimation: @[
      "Attack02", "Attack02Start", "Attack01", "Attack01Start",
      "WorkRoutine", "Idle"
    ],
    VictoryAnimation: @["Victory", "Idle", "IdleBattle", "Taunting"]
  ]
  for name in Names[slot]:
    if name in model.clips:
      return model.clips[name]
  raise newException(GraphicsError, "missing clip for " & $slot)

proc addHudIcons(builder: AtlasBuilder) =
  ## Packs portraits and the theme logo.
  builder.addThemeLogo(LogoPath)
  for player in 0'i32 ..< PlayerCount:
    for kind in UnitKind:
      if not builder.addImage(
          unitPortraitKey(player, kind),
          readImage(unitPortraitPath(player, kind))
        ):
        raise newException(
          GraphicsError,
          "the UI atlas is too small for unit portraits"
        )
    for kind in BuildingKind:
      if kind == GoldMineBuilding and player != LightPlayer:
        continue
      if not builder.addImage(
          buildingPortraitKey(player, kind),
          readImage(buildingPortraitPath(player, kind))
        ):
        raise newException(
          GraphicsError,
          "the UI atlas is too small for building portraits"
        )

proc tileCentreXZ(tile: Tile2): Vec2 =
  ## Converts a tile coordinate to the world-space centre of that tile.
  vec2(float32(tile.x) - HalfGrid + 0.5'f32,
       float32(tile.y) - HalfGrid + 0.5'f32)

proc unitWorldPoint(unit: Unit): Vec3 =
  ## Converts a tile-space body into a render position.
  let
    x = toFloat32(unit.body.pos.x) - HalfGrid
    z = toFloat32(unit.body.pos.y) - HalfGrid
  vec3(x, surfaceHeight(x, z), z)

proc unitYaw(unit: Unit): float32 =
  ## Turns body facing into the renderer's yaw convention.
  let dir = direction(unit.body.facing)
  arctan2(toFloat32(dir.x), toFloat32(dir.y))

proc renderPoint(unit: Unit): Vec3 =
  ## Interpolates one unit between the latest simulation snapshots.
  let current = unitWorldPoint(unit)
  if not interpolateVisuals:
    return current
  mix(
    previousUnitPositions.getOrDefault(unit.id, current),
    current,
    frameAlpha
  )

proc renderFacing(unit: Unit): float32 =
  ## Interpolates yaw the short way so a +pi / -pi flip is not a spin.
  if not interpolateVisuals:
    return unitYaw(unit)
  let
    current = unitYaw(unit)
    previous = previousUnitFacings.getOrDefault(unit.id, current)
  previous + shortestTurn(previous, current) * frameAlpha

proc captureUnitPoses() =
  ## Remembers mobile poses before one authoritative tick.
  previousUnitPositions.clear()
  previousUnitFacings.clear()
  for unit in run.world.units:
    previousUnitPositions[unit.id] = unitWorldPoint(unit)
    previousUnitFacings[unit.id] = unitYaw(unit)

proc renderTime(ticks: int32): float32 =
  ## Converts animation ticks into seconds for the clip sampler.
  (float32(ticks) + frameAlpha) / float32(TickRate)

proc buildingCentre(structure: Building): Vec3 =
  ## Returns the world centre of a structure's footprint.
  let
    x = float32(structure.origin.x) + float32(structure.side) * 0.5'f32 -
      HalfGrid
    z = float32(structure.origin.y) + float32(structure.side) * 0.5'f32 -
      HalfGrid
  vec3(x, surfaceHeight(x, z), z)

proc isSelected*(id: int32): bool =
  ## Returns whether one entity belongs to the RTS selection set.
  for candidate in selectedIds:
    if candidate == id:
      return true

proc shownUnit*(unit: Unit): bool =
  ## Returns whether fog of war currently reveals this unit.
  if unit.state == UnitInMine:
    return false
  if viewMode == 0:
    return true
  run.world.unitVisible(viewMode - 1, unit)

proc shownBuilding*(structure: Building): bool =
  ## Returns whether fog of war currently reveals this structure.
  if viewMode == 0:
    return true
  run.world.buildingVisible(viewMode - 1, structure)

proc runGraphics*() =
  ## Runs the native or Emscripten spectator.
  startGameProfile()
  profileBlock "atlas":
    let builder = newHudAtlas(4096)
    addHudIcons(builder)
    builder.addDefaultFonts()
    builder.write(AtlasPath)
  profileBlock "window":
    (window, sk) = initGameWindow(
      WindowTitle,
      AtlasPath,
      gameWindowSize(options.windowWidth, options.windowHeight),
      options.vsync
    )
  if options.playerSlot > 0 and not run.replayMode:
    let player = options.playerSlot - 1
    for unit in run.world.units:
      if unit.owner == player and unit.state != UnitDying:
        selectedIds.add unit.id
        primaryId = unit.id
        followSelection = false
        break
  let splash = startSplash(sk, window)
  profileBlock "terrain":
    seed = run.mapSeed
    treeHeight = 6.0'f
    treeWidth = 0.0'f
    initTerrain(DenseTrees, GeneratedTerrain, PaintedRocks)
    scatterGrass(800, run.mapSeed)
    scatterRocks(80, run.mapSeed)

  ## Characters. Locomotion clips are Run, Move, or Walk.
  var
    unitModels: array[PlayerCount, array[UnitKind, CharacterModel]]
    unitClips: array[PlayerCount, array[UnitKind, array[AnimationSlot, int]]]
    loaded: Table[string, CharacterModel]
  profileBlock "models":
    for player in 0 ..< PlayerCount:
      for kind in UnitKind:
        let path = UnitModels[player][kind]
        if path notin loaded:
          loaded[path] = loadCharacterModel(path, UnitHeights[kind])
        let model = loaded[path]
        unitModels[player][kind] = model
        for slot in AnimationSlot:
          unitClips[player][kind][slot] = model.clipIndex(slot)
  drawSplash(sk, window, splash.name)

  let scene = newCharacterScene(window)
  scene.useToonShading()
  setEnvironmentPalette(scene.toon)
  var
    particles = initParticleSystem()
    clickMarks = initClickMarks()
    worldShapes = initShapeRenderer()
    worldBarRenderer = initWorldBarRenderer()
    damageTrails: DamageTrailTracker
    selectionOutline = initSelectionOutline()

  ## Structures are terrain props rather than per-frame draws.
  var
    villagePack: PropPack
    towerPack: PropPack
  profileBlock "props":
    villagePack = loadPropPack(LightPropPack)
    towerPack = loadPropPack(DarkPropPack)

  proc packFor(player: int32, name: string): PropPack =
    ## Chooses the pack that actually carries a prop, so Dark can borrow the
    ## village farm without a special case at every call site.
    if player == LightPlayer or not towerPack.hasProp(name): villagePack
    else: towerPack

  proc buildingKey(): string =
    ## A cheap fingerprint of everything that changes the prop layout, so the
    ## terrain is only re-emitted when the scene actually differs.
    result = $run.world.terrainEdits.len
    for structure in run.world.buildings:
      result.add &"|{structure.id}:{structure.state.ord}"

  proc placeSceneProps() =
    ## Rebuilds the whole prop list. `placeProp` has no removal, so the
    ## viewer owns the desired set and re-places all of it on any change.
    clearProps()
    for structure in run.world.buildings:
      let centre = buildingCentre(structure)
      if structure.kind == GoldMineBuilding:
        for index, name in MineProps:
          towerPack.placeProp(
            name,
            centre + vec3(float32(index) * 0.7'f32 - 0.7'f32, 0,
              float32(index mod 2) * 0.6'f32 - 0.3'f32),
            float32(index) * 1.1'f32,
            [1.8'f32, 1.4'f32, 1.2'f32][index]
          )
        continue
      if structure.state == BuildingDying:
        for index, name in RubbleProps:
          towerPack.placeProp(name,
            centre + vec3(float32(index) - 0.5'f32, 0, 0),
            float32(index), 0.8'f32)
        continue
      if structure.state == BuildingUnderConstruction:
        for index, name in ConstructionProps:
          towerPack.placeProp(name,
            centre + vec3(float32(index) - 1.0'f32, 0, float32(index mod 2)),
            float32(index) * 0.9'f32, 0.8'f32)
        continue
      let name = BuildingProps[structure.owner][structure.kind]
      packFor(structure.owner, name).placeProp(
        name, centre, 0.0'f32, BuildingPropHeights[structure.kind])

  proc applyTerrainEdits() =
    ## Mirrors felled trees into the render layer.
    for edit in run.world.terrainEdits:
      layers[0].tiles[edit.index].kind = GrassTile

  proc rebakeScene() =
    ## Refreshes terrain, props, and the displayed movement blockers.
    applyTerrainEdits()
    placeSceneProps()
    ## Walkability was computed once at map generation and structures live in
    ## the simulation's own grids, so the renderer must never recompute it.
    bakeTerrain(
      rebuildWalkability = false,
      blockers = [run.world.blocker]
    )
    placedEditCount = run.world.terrainEdits.len
    placedBuildingKey = buildingKey()
    terrainDirty = false
    framesSinceRebake = 0

  profileBlock "bake":
    rebakeScene()
  cameraTarget = vec3(0, 0, 0)
  var
    actionCam = initActionCam(
      minDistance = 40,
      maxDistance = 240,
      tight = 0.4,
      followRate = 1.0,
      zoomRate = 0.7,
      holdSeconds = 2.8,
      mapSpan = HalfGrid * 2,
      closeScale = 0.5
    )
    seenUnitId = 0'i32
    sawUnits = false

  ## Replay scaffolding

  seekCheckpoints.add SeekCheckpoint(
    world: run.world.clone(),
    actionIndex: 0,
    hashCheck: run.hashCheck
  )

  proc captureCheckpoint() =
    if run.world.tick div SeekCheckpointTicks < seekCheckpoints.len:
      return
    seekCheckpoints.add SeekCheckpoint(
      world: run.world.clone(),
      actionIndex: run.replayPlayer.actionIndex,
      hashCheck: run.hashCheck
    )

  proc restoreTo(target: int32) =
    ## Reloads the last checkpoint at or before a tick, then resimulates.
    let wanted = clamp(target, 0'i32, transport.timelineEnd)
    var slot = min(
      int(wanted) div SeekCheckpointTicks,
      seekCheckpoints.len - 1
    )
    while slot > 0 and seekCheckpoints[slot].world.tick > wanted:
      dec slot
    run.world.restore(seekCheckpoints[slot].world)
    if run.recorder != nil:
      run.replayPlayer.data = run.recorder.data
    run.replayPlayer.syncCursor(uint32(run.world.tick))
    run.hashCheck = seekCheckpoints[slot].hashCheck
    run.historyPlayback = true
    previousUnitPositions.clear()
    previousUnitFacings.clear()
    terrainDirty = true
    particles.clearParticles()
    while run.world.tick < wanted:
      advanceGame()
      captureCheckpoint()

  ## Camera and input

  proc selectionTarget(id: int32): SelectionTarget =
    ## Returns the current render position of a selectable entity.
    if id.isUnitId and run.world.hasUnit(id):
      let unit = run.world.units[run.world.unitIndex(id)]
      if unit.state notin {UnitDying, UnitInMine}:
        return SelectionTarget(found: true, position: renderPoint(unit))
    elif id.isBuildingId and run.world.hasBuilding(id):
      let structure = run.world.buildings[run.world.buildingIndex(id)]
      if structure.state != BuildingDying:
        return SelectionTarget(
          found: true,
          position: buildingCentre(structure)
        )

  proc selectedCount(): int =
    ## Returns the number of valid selected entities.
    for id in selectedIds:
      if selectionTarget(id).found:
        inc result

  proc playerMode(): bool =
    ## Returns whether this client issues orders for one side.
    options.playerSlot > 0 and not run.replayMode

  proc selectEntity(id: int32, additive = false) =
    ## Selects or toggles one entity. Spectator mode follows the selection.
    if not selectionTarget(id).found:
      return
    if not additive:
      selectedIds.setLen(0)
    elif isSelected(id) and selectedIds.len > 1:
      for i in 0 ..< selectedIds.len:
        if selectedIds[i] == id:
          selectedIds.delete(i)
          break
      primaryId = selectedIds[0]
      if not playerMode():
        followSelection = true
      actionCam.takeManual()
      return
    if not isSelected(id):
      selectedIds.add id
    primaryId = id
    if not playerMode():
      followSelection = true
    actionCam.takeManual()
    if selectedIds.len > 1:
      groupCameraScale = 1.0'f32

  proc clearSelection() =
    ## Clears the selection and leaves the camera free-floating.
    let hadSelection =
      selectedIds.len > 0 or
      primaryId != NoEntity or
      followSelection
    selectedIds.setLen(0)
    primaryId = NoEntity
    followSelection = false
    if hadSelection:
      actionCam.takeManual()

  proc selectAllUnits() =
    ## Selects all living mobile units for group following.
    selectedIds.setLen(0)
    let owner =
      if options.playerSlot > 0 and not run.replayMode:
        options.playerSlot - 1
      else:
        -1'i32
    for unit in run.world.units:
      if unit.state notin {UnitDying, UnitInMine}:
        if owner >= 0 and unit.owner != owner:
          continue
        selectedIds.add unit.id
    if selectedIds.len > 0:
      primaryId = selectedIds[0]
      if not playerMode():
        followSelection = true
      actionCam.takeManual()
      groupCameraScale = 1.0'f32

  proc pruneSelection() =
    ## Removes entities that have died or left the selectable world.
    var i = selectedIds.high
    while i >= 0:
      if not selectionTarget(selectedIds[i]).found:
        selectedIds.delete(i)
      dec i
    if selectedIds.len == 0:
      primaryId = NoEntity
      followSelection = false
    elif not isSelected(primaryId):
      primaryId = selectedIds[0]

  proc selectedCenter(): Vec3 =
    ## Returns the midpoint of all valid selected entities.
    var count = 0
    for id in selectedIds:
      let target = selectionTarget(id)
      if target.found:
        result += target.position
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
        x = target.position.x - center.x
        z = target.position.z - center.z
      result = max(result, sqrt(x * x + z * z))

  proc screenPosition(position: Vec3, viewProjection: Mat4): Vec2 =
    ## Projects one world position into window pixel coordinates.
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

  proc pickEntity(viewProjection: Mat4): int32 =
    ## Finds the nearest visible unit or structure under the pointer.
    var bestDistance = 28.0'f32
    template consider(id: int32, position: Vec3, height: float32) =
      block:
        let distance = (
          screenPosition(position + vec3(0, height, 0), viewProjection) -
          window.mousePos.vec2
        ).length
        if distance < bestDistance:
          bestDistance = distance
          result = id
    for unit in run.world.units:
      if unit.state in {UnitDying, UnitInMine} or
          (viewMode != 0 and not run.world.unitVisible(viewMode - 1, unit)):
        continue
      consider(unit.id, renderPoint(unit), UnitHeights[unit.kind] * 0.5'f32)
    for structure in run.world.buildings:
      if structure.state == BuildingDying or
          (viewMode != 0 and
            not run.world.buildingVisible(viewMode - 1, structure)):
        continue
      consider(structure.id, buildingCentre(structure), 1.4'f32)
      for y in 0'i32 ..< structure.side:
        for x in 0'i32 ..< structure.side:
          let
            tileX = int32(structure.origin.x) + x
            tileY = int32(structure.origin.y) + y
            world = tileCentreXZ(tile2(tileX, tileY))
          consider(
            structure.id,
            vec3(world.x, surfaceHeight(world.x, world.y), world.y),
            0.6'f32
          )

  proc structureAtTile(x, y: int32): int32 =
    ## Standing structure whose footprint contains this tile.
    result = NoEntity
    if not inGrid(x, y):
      return
    for structure in run.world.buildings:
      if structure.state == BuildingDying or
          not shownBuilding(structure):
        continue
      if covers(structure.origin, structure.side, x, y):
        return structure.id

  proc insideBox(point, origin, size: Vec2): bool =
    ## Returns whether a screen point lies inside a drag rectangle.
    point.x >= origin.x and
      point.y >= origin.y and
      point.x <= origin.x + size.x and
      point.y <= origin.y + size.y

  proc boxedUnits(viewProjection: Mat4): seq[int32] =
    ## Returns visible units whose screens fall inside the drag box.
    let
      press = selectionPressPosition
      current = window.mousePos.vec2
      origin = vec2(min(press.x, current.x), min(press.y, current.y))
      size = vec2(abs(current.x - press.x), abs(current.y - press.y))
      ownerFilter =
        if viewMode == 0: -1'i32
        else: viewMode - 1
    for unit in run.world.units:
      if unit.state in {UnitDying, UnitInMine}:
        continue
      if ownerFilter >= 0 and unit.owner != ownerFilter:
        continue
      if viewMode != 0 and
          not run.world.unitVisible(viewMode - 1, unit):
        continue
      let point = screenPosition(
        renderPoint(unit) +
          vec3(0, UnitHeights[unit.kind] * 0.5'f32, 0),
        viewProjection
      )
      if insideBox(point, origin, size):
        result.add unit.id

  proc selectBox(ids: seq[int32], additive: bool) =
    ## Replaces or extends the selection with boxed units.
    if ids.len == 0:
      if not additive:
        clearSelection()
      return
    if not additive:
      selectedIds.setLen(0)
    for id in ids:
      if not isSelected(id):
        selectedIds.add id
    primaryId = ids[0]
    if not playerMode():
      followSelection = true
    actionCam.takeManual()
    if selectedIds.len > 1:
      groupCameraScale = 1.0'f32

  proc feedLvdActions() =
    ## Notes builds, spawns, fights, wrecks, and upcoming tape commands.
    const LookAheadTicks = 48'i32
    let tick = run.world.tick
    actionCam.beginFrame(tick)
    proc renderOf(id: int32, point: var Vec3): bool =
      ## Finds a living unit or standing building in render space.
      if run.world.hasUnit(id):
        point = renderPoint(
          run.world.units[run.world.unitIndex(id)]
        )
        return true
      if run.world.hasBuilding(id):
        point = buildingCentre(
          run.world.buildings[run.world.buildingIndex(id)]
        )
        return true
      false
    proc noteUpcoming(actions: openArray[ReplayAction]) =
      ## Zooms toward recorded attacks and builds before they land.
      var i = actions.actionIndexAfter(uint32(tick))
      let limit = uint32(tick + LookAheadTicks)
      while i < actions.len and actions[i].tick <= limit:
        let action = actions[i]
        var pos: Vec3
        var score = 0.0'f32
        var id = action.entityId
        if action.kind == ActionAttack:
          if renderOf(action.entityId, pos):
            var target: Vec3
            if renderOf(action.first, target):
              pos = mix(pos, target, 0.5'f32)
            score = 72
        elif action.kind == ActionBuild:
          let tile = tile2(action.second, action.third)
          let xz = tileCentreXZ(tile)
          pos = vec3(xz.x, surfaceHeight(xz.x, xz.y), xz.y)
          score = 44
          id = 90_000_000 + action.entityId
        elif action.kind == ActionTrain:
          if renderOf(action.entityId, pos):
            score = 40
        if score > 0:
          actionCam.noteInterest(
            id,
            pos,
            score,
            6,
            tick,
            int32(action.tick) - tick + 24
          )
        inc i
    if run.replayPlayer != nil:
      noteUpcoming(run.replayPlayer.data.actions)
    elif run.recorder != nil:
      noteUpcoming(run.recorder.data.actions)
    for structure in run.world.buildings:
      let
        pos = buildingCentre(structure)
        radius = float32(structure.side) * 0.7'f32
      if structure.state == BuildingUnderConstruction:
        actionCam.noteInterest(
          structure.id,
          pos,
          32,
          radius,
          tick,
          48
        )
      elif structure.state == BuildingDying:
        actionCam.noteInterest(
          structure.id,
          pos,
          50.0'f32 + float32(structure.side) * 8.0'f32,
          radius,
          tick,
          24
        )
    var maxId = seenUnitId
    for unit in run.world.units:
      let pos = renderPoint(unit)
      if unit.state == UnitAttacking:
        actionCam.noteInterest(unit.id, pos, 55, 2.5, tick, 24)
      if sawUnits and unit.id > seenUnitId:
        actionCam.noteInterest(unit.id, pos, 38, 2, tick, 24)
      if unit.id > maxId:
        maxId = unit.id
    seenUnitId = maxId
    sawUnits = true

  proc updateCamera(dt: float32) =
    ## Applies fixed-north RTS pan, zoom, and selection following.
    pruneSelection()
    updateMinimapCamera(
      window,
      sk.mousePos,
      cameraTarget,
      minimapPanning,
      followSelection
    )
    if minimapPanning:
      actionCam.takeManual()
    let overUi = mouseOverUi(window, sk.mousePos)
    if window.buttonPressed[KeyA] and
        (window.buttonDown[KeyLeftControl] or
          window.buttonDown[KeyRightControl]):
      selectAllUnits()
    elif window.mousePressed(MouseLeft) and not overUi:
      selectionPressPosition = window.mousePos.vec2
      selectionStarted = true
      selectionAdditive =
        window.buttonDown[KeyLeftShift] or
        window.buttonDown[KeyRightShift]
    if window.mousePressed(MouseMiddle) and
        (not overUi or window.buttonPressed[MouseMiddleKey]):
      panning = true
    if not window.mouseDown(MouseMiddle):
      panning = false
    let delta = window.mouseDelta.vec2
    if panning:
      followSelection = false
      actionCam.takeManual()
      let
        speed = cameraDistance * 0.0015
      cameraTarget.x -= delta.x * speed
      cameraTarget.z -= delta.y * speed
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
      if followSelection and selectedCount() > 1:
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
          8.0'f32,
          400.0'f32
        )
    if actionCam.enabled:
      feedLvdActions()
      actionCam.chooseShot(dt, transport.speed)
      actionCam.follow(
        cameraTarget,
        cameraDistance,
        dt,
        transport.speed
      )
      return
    if not playerMode() and not selectionStarted:
      let count = selectedCount()
      if followSelection and count == 1:
        let focus = selectionTarget(selectedIds[0]).position
        cameraTarget = mix(
          cameraTarget,
          focus,
          damping(5.0'f32, dt)
        )
      elif followSelection and count > 1:
        let
          center = selectedCenter()
          distance = clamp(
            14.0'f32 + selectedRadius(center) * 2.8'f32,
            24.0'f32,
            400.0'f32
          ) * groupCameraScale
        cameraTarget = mix(
          cameraTarget,
          center,
          damping(4.0'f32, dt)
        )
        cameraDistance = mix(
          cameraDistance,
          distance,
          damping(2.0'f32, dt)
        )
      elif followSelection:
        clearSelection()

  proc updateWorldSelection(viewProjection: Mat4) =
    ## Applies click, shift-click, or box selection on left release.
    if not window.mouseReleased(MouseLeft):
      return
    if not selectionStarted:
      return
    let
      drag = (
        window.mousePos.vec2 - selectionPressPosition
      ).length
      overUi = mouseOverUi(window, sk.mousePos)
    if drag > SelectionDragPixels:
      selectBox(
        boxedUnits(viewProjection),
        selectionAdditive
      )
    elif not overUi:
      if not (playerMode() and pendingBuild >= 0):
        let picked = pickEntity(viewProjection)
        if picked != NoEntity:
          selectEntity(picked, selectionAdditive)
        elif not selectionAdditive:
          clearSelection()
    selectionStarted = false

  proc buildGhostOrigin(viewProjection: Mat4): (int32, int32) =
    ## Snaps the pending footprint so the cursor sits on its centre tile.
    let
      kind = BuildingKind(pendingBuild)
      side = BuildingTable[kind].footprint
      ground = pickGroundPoint(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection,
        cameraTarget.y
      )
      tile = groundTile(ground, HalfGrid, GridSide)
    (tile[0] - side div 2, tile[1] - side div 2)

  proc queuePendingBuild(x, y: int32) =
    ## Sends the first selected peon to raise the pending structure.
    let player = options.playerSlot - 1
    for id in selectedIds:
      if id.isUnitId and run.world.hasUnit(id):
        let unit = run.world.units[run.world.unitIndex(id)]
        if unit.owner == player and unit.kind == PeonUnit:
          queueBuild(player, id, pendingBuild, x, y)
          pendingBuild = -1
          return

  proc clickTilePoint(x, y: int32): Vec3 =
    ## Returns the render centre of one map tile.
    let xz = tileCentreXZ(tile2(x, y))
    vec3(xz.x, surfaceHeight(xz.x, xz.y), xz.y)

  proc issueSelectedMove(player, x, y: int32): bool =
    ## Moves every selected owned unit, or rallies a selected building.
    if not inGrid(x, y) or not run.world.terrainOpen(x, y):
      return false
    for id in selectedIds:
      if id.isUnitId and run.world.unitOwner(id) == player:
        if run.world.hasUnit(id):
          let unit = run.world.units[run.world.unitIndex(id)]
          if unit.state == UnitInMine:
            continue
        if attackMoveArmed:
          queueAttackMove(player, id, x, y)
        else:
          queueMove(player, id, x, y)
        result = true
    if not result:
      for id in selectedIds:
        if id.isBuildingId and run.world.buildingOwner(id) == player:
          queueSetRally(player, id, x, y)

  proc updatePlayerOrder(viewProjection: Mat4) =
    ## Turns a right-click into move, attack, harvest, or rally.
    if not playerMode():
      return
    if not window.mousePressed(MouseRight):
      return
    if mouseOverUi(window, sk.mousePos):
      return
    if pendingBuild >= 0:
      let origin = buildGhostOrigin(viewProjection)
      if run.world.canPlace(
          BuildingKind(pendingBuild),
          origin[0],
          origin[1]
      ):
        queuePendingBuild(origin[0], origin[1])
        clickMarks.emitClickMark(clickTilePoint(origin[0], origin[1]))
      return
    let
      player = options.playerSlot - 1
      picked = pickEntity(viewProjection)
      ground = pickGroundPoint(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection,
        cameraTarget.y
      )
      tile = groundTile(ground, HalfGrid, GridSide)
      tree = tileIndex(tile[0], tile[1])
      under = structureAtTile(tile[0], tile[1])
      target =
        if under != NoEntity:
          under
        else:
          picked
    if target != NoEntity:
      if run.world.hasBuilding(target):
        let structure = run.world.buildings[run.world.buildingIndex(target)]
        if structure.kind == GoldMineBuilding:
          var harvested = false
          for id in selectedIds:
            if id.isUnitId and run.world.hasUnit(id):
              let unit = run.world.units[run.world.unitIndex(id)]
              if unit.owner == player and unit.kind == PeonUnit:
                queueHarvest(player, id, target, 0)
                harvested = true
          if harvested:
            clickMarks.emitClickMark(buildingCentre(structure))
          attackMoveArmed = false
          return
        if structure.owner != player:
          for id in selectedIds:
            if id.isUnitId and run.world.unitOwner(id) == player:
              queueAttack(player, id, target)
          attackMoveArmed = false
          return
      elif run.world.hasUnit(target) and
          run.world.unitOwner(target) != player:
        for id in selectedIds:
          if id.isUnitId and run.world.unitOwner(id) == player:
            queueAttack(player, id, target)
        attackMoveArmed = false
        return
    if run.world.treeWood[tree] > 0:
      var harvested = false
      for id in selectedIds:
        if id.isUnitId and run.world.hasUnit(id):
          let unit = run.world.units[run.world.unitIndex(id)]
          if unit.owner == player and unit.kind == PeonUnit:
            queueHarvest(player, id, tree, 1)
            harvested = true
      if harvested:
        clickMarks.emitClickMark(clickTilePoint(tile[0], tile[1]))
        attackMoveArmed = false
        return
    if issueSelectedMove(player, tile[0], tile[1]):
      clickMarks.emitClickMark(clickTilePoint(tile[0], tile[1]))
    attackMoveArmed = false

  proc cameraView(): Mat4 =
    ## Returns the shared fixed-north RTS view matrix.
    cameraEye = rtsCameraEye(cameraTarget, cameraDistance)
    lookAt(cameraEye, cameraTarget, vec3(0, 1, 0))

  proc drawBuildingOutline(
      structure: Building,
      viewProjection: Mat4
  ) =
    ## Draws one structure's props into the current selection mask.
    let centre = buildingCentre(structure)
    if structure.kind == GoldMineBuilding:
      for index, name in MineProps:
        towerPack.drawProp(
          name,
          centre + vec3(float32(index) * 0.7'f32 - 0.7'f32, 0,
            float32(index mod 2) * 0.6'f32 - 0.3'f32),
          float32(index) * 1.1'f32,
          [1.8'f32, 1.4'f32, 1.2'f32][index],
          viewProjection
        )
      return
    if structure.state == BuildingUnderConstruction:
      for index, name in ConstructionProps:
        towerPack.drawProp(
          name,
          centre + vec3(float32(index) - 1.0'f32, 0, float32(index mod 2)),
          float32(index) * 0.9'f32,
          0.8'f32,
          viewProjection
        )
      return
    let name = BuildingProps[structure.owner][structure.kind]
    packFor(structure.owner, name).drawProp(
      name,
      centre,
      0.0'f32,
      BuildingPropHeights[structure.kind],
      viewProjection
    )

  proc drawSelectedOutline(
      view,
      projection,
      viewProjection: Mat4
  ) =
    ## Draws selected units and buildings into one yellow silhouette.
    var
      anyUnit = false
      anyBuilding = false
    for id in selectedIds:
      if id.isUnitId and run.world.hasUnit(id):
        let unit = run.world.units[run.world.unitIndex(id)]
        if shownUnit(unit) and unit.state != UnitDying:
          anyUnit = true
      elif id.isBuildingId and run.world.hasBuilding(id):
        let structure = run.world.buildings[run.world.buildingIndex(id)]
        if shownBuilding(structure) and
            structure.state != BuildingDying:
          anyBuilding = true
    if not anyUnit and not anyBuilding:
      return
    selectionOutline.beginMask(window.size)
    if anyUnit:
      beginCharacters(scene, window, view, projection, cameraEye)
      for id in selectedIds:
        if not id.isUnitId or not run.world.hasUnit(id):
          continue
        let unit = run.world.units[run.world.unitIndex(id)]
        if not shownUnit(unit) or unit.state == UnitDying:
          continue
        let
          model = unitModels[unit.owner][unit.kind]
          clip = unitClips[unit.owner][unit.kind][unit.animation]
        var animTime = renderTime(unit.animationTicks)
        if unit.animation == DeathAnimation or
            unit.animation == VictoryAnimation:
          animTime = min(animTime, clipDuration(model, clip))
        drawCharacter(
          scene,
          model,
          renderPoint(unit),
          renderFacing(unit),
          clip,
          animTime
        )
      finishCharacters(scene)
    if anyBuilding:
      for id in selectedIds:
        if not id.isBuildingId or not run.world.hasBuilding(id):
          continue
        let structure = run.world.buildings[run.world.buildingIndex(id)]
        if not shownBuilding(structure) or
            structure.state == BuildingDying:
          continue
        drawBuildingOutline(structure, viewProjection)
    selectionOutline.drawOutline()

  proc drawBuildGhost(viewProjection: Mat4) =
    ## Follows the pointer with a transparent building while placing.
    if not playerMode() or pendingBuild < 0:
      return
    let
      player = options.playerSlot - 1
      kind = BuildingKind(pendingBuild)
      side = BuildingTable[kind].footprint
      origin = buildGhostOrigin(viewProjection)
      valid = run.world.canPlace(kind, origin[0], origin[1])
      x = float32(origin[0]) + float32(side) * 0.5'f32 - HalfGrid
      z = float32(origin[1]) + float32(side) * 0.5'f32 - HalfGrid
      centre = vec3(x, surfaceHeight(x, z), z)
      name = BuildingProps[player][kind]
      tint =
        if valid:
          vec4(0.55, 0.95, 0.65, 0.42)
        else:
          vec4(0.95, 0.28, 0.22, 0.42)
    packFor(player, name).drawProp(
      name,
      centre,
      0.0'f32,
      BuildingPropHeights[kind],
      viewProjection,
      tint
    )

  proc updateTerrainVision() =
    ## Uploads the selected team's softened visible and explored terrain.
    if terrainVisionTick == run.world.tick and terrainVisionMode == viewMode:
      return
    terrainVisionTick = run.world.tick
    terrainVisionMode = viewMode
    var values = newSeq[uint8](GridSide * GridSide)
    if viewMode == 0:
      for value in values.mitems:
        value = 255
    else:
      let player = viewMode - 1
      for y in 0 ..< GridSide:
        for x in 0 ..< GridSide:
          let index = tileIndex(x, y)
          values[index] =
            if run.world.visible(player, x, y): 255
            elif run.world.explored(player, x, y): 48
            else: 0
    uploadTerrainVisibility(blurVisibility(values, GridSide, GridSide))

  proc drawWorldBars(
      viewProjection: Mat4,
      cameraRight,
      cameraUp: Vec3,
      dt: float32
  ) =
    ## Draws damage-gated health billboards above visible mobile units.
    damageTrails.beginFrame()
    worldBarRenderer.clear()
    for unit in run.world.units:
      if not shownUnit(unit) or unit.state == UnitDying or unit.hp <= 0:
        continue
      let
        maximum = max(UnitTable[unit.owner][unit.kind].hp, 1'i32).float32
        health = unit.hp.float32
        delayed = damageTrails.delayedValue(
          unit.id,
          health,
          maximum,
          dt
        )
      if unit.hp < UnitTable[unit.owner][unit.kind].hp:
        let
          anchor = renderPoint(unit) +
            vec3(0, UnitHeights[unit.kind] + 0.32'f32, 0)
          width = 0.82'f32 + UnitHeights[unit.kind] * 0.18'f32
          bars = [WorldResourceBar(
            value: health,
            maximum: maximum,
            delayedValue: delayed,
            height: 0.1'f32,
            color: healthColor(health, maximum),
            showDamageTrail: true
          )]
        worldBarRenderer.addResourceBars(anchor, width, bars)
    damageTrails.finishFrame()
    worldBarRenderer.draw(viewProjection, cameraRight, cameraUp)

  proc particleTargetPosition(id: int32): tuple[
      found: bool,
      position: Vec3
  ] =
    ## Returns the visible presentation center of one combat target.
    if id.isUnitId:
      let index = run.world.unitIndex(id)
      if index >= 0 and shownUnit(run.world.units[index]):
        let unit = run.world.units[index]
        return (
          true,
          renderPoint(unit) +
            vec3(0, UnitHeights[unit.kind] * 0.55'f32, 0)
        )
    elif id.isBuildingId:
      let index = run.world.buildingIndex(id)
      if index >= 0 and shownBuilding(run.world.buildings[index]):
        return (
          true,
          buildingCentre(run.world.buildings[index]) + vec3(0, 0.8'f32, 0)
        )

  proc expectedTowerTargets(): Table[int32, int32] =
    ## Predicts this tick's tower choices from the pre-tick simulation state.
    let nextTick = run.world.tick + 1
    for structure in run.world.buildings:
      let stats = BuildingTable[structure.kind]
      if stats.damage <= 0 or structure.state != BuildingComplete or
          structure.cooldown > 0 or
          (nextTick + structure.id) mod TowerStagger != 0:
        continue
      let enemy = 1 - structure.owner
      var
        target = NoEntity
        best = int32.high
      for unit in run.world.units:
        if unit.owner != enemy or unit.state == UnitDying or
            unit.state == UnitInMine:
          continue
        var distance = int32.high
        for y in int32(structure.origin.y) ..<
            int32(structure.origin.y) + structure.side:
          for x in int32(structure.origin.x) ..<
              int32(structure.origin.x) + structure.side:
            distance = min(
              distance,
              tileDistance(unit.tile, tile2(x, y))
            )
        if distance > stats.rangeTiles:
          continue
        if distance < best or
            (distance == best and unit.id < target):
          best = distance
          target = unit.id
      if target != NoEntity:
        result[structure.id] = target

  proc emitTickParticles(
      oldUnitCooldowns: Table[int32, int32],
      towerTargets: Table[int32, int32]
  ) =
    ## Emits each unit and tower attack exactly once after its simulation tick.
    for unit in run.world.units:
      if not shownUnit(unit) or unit.state != UnitAttacking:
        continue
      let stats = UnitTable[unit.owner][unit.kind]
      if unit.cooldown != stats.cooldownTicks or
          oldUnitCooldowns.getOrDefault(unit.id, -1) == unit.cooldown:
        continue
      let target = particleTargetPosition(unit.targetId)
      if not target.found:
        continue
      let origin = renderPoint(unit) +
        vec3(0, UnitHeights[unit.kind] * 0.62'f32, 0)
      case unit.kind
      of ArcherUnit:
        particles.emitParticleProjectile(
          ArrowWake,
          CombatSparks,
          origin,
          target.position,
          clamp(
            (target.position - origin).length / 17.0'f32,
            0.08'f32,
            0.42'f32
          )
        )
      of MageUnit, ClericUnit:
        particles.emitParticleProjectile(
          MagicBolt,
          MagicBurst,
          origin,
          target.position,
          clamp(
            (target.position - origin).length / 12.0'f32,
            0.12'f32,
            0.5'f32
          )
        )
      of CatapultUnit:
        particles.emitParticleProjectile(
          Fireball,
          FireBurst,
          origin,
          target.position,
          clamp(
            (target.position - origin).length / 13.0'f32,
            0.14'f32,
            0.52'f32
          )
        )
      of PeonUnit, SoldierUnit, KnightUnit, SummonUnit:
        particles.emitParticleBurst(CombatSparks, target.position)
    for structure in run.world.buildings:
      if not shownBuilding(structure) or structure.id notin towerTargets:
        continue
      let stats = BuildingTable[structure.kind]
      if structure.cooldown != stats.cooldownTicks:
        continue
      let target = particleTargetPosition(towerTargets[structure.id])
      if not target.found:
        continue
      let origin = buildingCentre(structure) +
        vec3(0, BuildingPropHeights[structure.kind] * 0.7'f32, 0)
      particles.emitParticleProjectile(
        Fireball,
        FireBurst,
        origin,
        target.position,
        clamp(
          (target.position - origin).length / 13.0'f32,
          0.14'f32,
          0.52'f32
        )
      )

  ## Frame

  var
    lastFrameTime = epochTime()
  const Step = 1.0'f32 / float32(TickRate)

  proc advanceRenderedMatch() =
    ## Advances one tick and converts its combat transitions into particles.
    var oldUnitCooldowns: Table[int32, int32]
    for unit in run.world.units:
      oldUnitCooldowns[unit.id] = unit.cooldown
    let towerTargets = expectedTowerTargets()
    captureUnitPoses()
    advanceGame()
    emitTickParticles(oldUnitCooldowns, towerTargets)
    captureCheckpoint()

  when defined(takeScreenshot):
    applyScreenshotCamera(cameraDistance)
    if existsEnv("CAM_X"):
      cameraTarget.x = getEnv("CAM_X").parseFloat.float32 - HalfGrid
    if existsEnv("CAM_Z"):
      cameraTarget.z = getEnv("CAM_Z").parseFloat.float32 - HalfGrid
    if existsEnv("VIEW_MODE"):
      viewMode = int32(getEnv("VIEW_MODE").parseInt)
    if existsEnv("SHOW_TILES"):
      showTiles = getEnv("SHOW_TILES").parseBool
    if existsEnv("SIM_SECONDS"):
      let wanted = int32(getEnv("SIM_SECONDS").parseFloat * TickRate.float64)
      while run.world.tick < wanted and
          run.world.tick < run.maximumTicks and not run.world.over:
        advanceGame()
      terrainDirty = true
    if primaryId == NoEntity:
      for structure in run.world.buildings:
        if structure.owner == LightPlayer and
            structure.kind == TownHallBuilding and
            structure.state != BuildingDying:
          primaryId = structure.id
          break
      selectedIds.setLen(0)
      if primaryId != NoEntity:
        selectedIds.add primaryId
      for unit in run.world.units:
        if selectedIds.len >= 10:
          break
        if unit.owner == LightPlayer and
            unit.state notin {UnitDying, UnitInMine}:
          selectedIds.add unit.id
    var screenshotFrame = 0

  holdSplash(sk, window, splash)
  window.onFrame = proc() =
    profileBlock "frame":
      let dt = frameDelta(lastFrameTime, Step)
      sk.uiScale = hudUiScale(window)
      sk.mousePos = window.mousePos.vec2 / sk.uiScale
      profileBlock "camera":
        updateCamera(dt)
      let recorded =
        if run.recorder != nil: int32(run.recorder.data.hashes.len)
        else: int32(run.replayPlayer.data.hashes.len)
      transport.sync(run.world.tick, recorded, run.world.over)
      let restoreTick = transport.takeRestore()
      if restoreTick >= 0:
        restoreTo(restoreTick)
        transport.sync(run.world.tick, recorded, run.world.over)
      transport.startFrame(dt, TickRate)
      let frameStart = epochTime()
      run.historyPlayback = transport.inHistory
      profileBlock "simulate":
        while transport.shouldTick(frameStart):
          if atLiveTickCap(run.world.tick, run.maximumTicks, transport.live):
            break
          run.historyPlayback = transport.inHistory
          advanceRenderedMatch()
          let recordedNow =
            if run.recorder != nil: int32(run.recorder.data.hashes.len)
            else: int32(run.replayPlayer.data.hashes.len)
          transport.sync(run.world.tick, recordedNow, run.world.over)
      let active = simulationActive(transport)
      frameAlpha =
        if active:
          clamp(transport.accumulator / Step, 0.0'f32, 1.0'f32)
        else:
          0.0'f32
      if active:
        particles.advanceParticles(dt)
        clickMarks.advanceClickMarks(dt)
      inc framesSinceRebake
      if run.world.terrainEdits.len != placedEditCount or
          buildingKey() != placedBuildingKey:
        terrainDirty = true
      if terrainDirty and
        (showTiles or framesSinceRebake >= RebakeFrameGap):
          profileBlock "rebake":
            rebakeScene()
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
          clockHour(float32(run.world.tick) + frameAlpha, TickRate))
        setEnvironmentPalette(scene.toon)

        # One loop for both passes: units render into the sun's depth map
        # first, then for the camera.
        proc drawWorldUnits() =
          for unit in run.world.units:
            if not shownUnit(unit):
              continue
            let
              model = unitModels[unit.owner][unit.kind]
              clip = unitClips[unit.owner][unit.kind][unit.animation]
            var animTime = renderTime(unit.animationTicks)
            ## One-shot clips must be clamped: the sampler wraps with `mod`,
            ## so a death would otherwise loop forever.
            if unit.animation == DeathAnimation or
                unit.animation == VictoryAnimation:
              animTime = min(animTime, clipDuration(model, clip))
            drawCharacter(scene, model, renderPoint(unit), renderFacing(unit),
              clip, animTime)

        sunDepthPasses(window.size):
          drawTerrainSunDepth()
          scene.sunDepthPass = true
          drawWorldUnits()
          scene.sunDepthPass = false
        glClearColor(0.05, 0.06, 0.09, 1.0)
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
        updateTerrainVision()
        drawTerrain(viewProjection, showTiles)
        beginCharacters(scene, window, view, projection, cameraEye)
        drawWorldUnits()
        finishCharacters(scene)
        drawSelectedOutline(view, projection, viewProjection)
        drawBuildGhost(viewProjection)
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
          for unit in run.world.units:
            if unit.id == 0 or unit.state == UnitDying:
              continue
            if unit.pathIndex >= int32(unit.path.len):
              continue
            let color =
              if unit.owner == LightPlayer:
                rgbx(80, 140, 230, 255)
              else:
                rgbx(210, 80, 85, 255)
            var points: seq[Vec3]
            let now = renderPoint(unit)
            points.add vec3(now.x, now.y + 0.2'f32, now.z)
            for i in int(unit.pathIndex) ..< unit.path.len:
              let tile = unit.path[i]
              let xz = tileCentreXZ(tile)
              points.add vec3(
                xz.x,
                surfaceHeight(xz.x, xz.y) + 0.2'f32,
                xz.y
              )
            if points.len >= 2:
              worldShapes.addPolyline(points, color)
          worldShapes.draw(viewProjection)
        drawWorldBars(
          viewProjection,
          barCameraRight,
          barCameraUp,
          dt
        )
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
          actionCam
        )
        drawSelectionBox(
          sk,
          window,
          selectionPressPosition,
          selectionStarted
        )
        sk.endUi()
      when defined(takeScreenshot):
        captureScreenshot(
          window,
          screenshotFrame,
          3,
          "light_vs_dark.png"
        )
      profileBlock "present":
        window.presentFrame(framePaceHz)
        reportReplayFrame(run.world.tick, int32(run.hashCheck.mismatches))
    if noteProfileFrame():
      when not defined(emscripten):
        window.closeRequested = true

  window.onButtonPress = proc(button: Button) =
    case button
    of KeySpace: transport.handleKey(button)
    of KeyC: actionCam.toggle(followSelection)
    of KeyT: scene.toggleShading()
    of KeyE: showTiles = not showTiles
    of KeyF1, KeyF2:
      discard handleChromeKey(button)
    of KeyV:
      if not playerMode():
        viewMode = (viewMode + 1) mod 3
    of KeyX:
      if playerMode():
        let player = options.playerSlot - 1
        for id in selectedIds:
          if run.world.unitOwner(id) == player or
              run.world.buildingOwner(id) == player:
            queueCancel(player, id)
        pendingBuild = -1
        attackMoveArmed = false
    of KeyEscape:
      if playerMode() and pendingBuild >= 0:
        pendingBuild = -1
      else:
        when not defined(emscripten):
          window.closeRequested = true
    else: discard

  while not window.closeRequested:
    pollEvents()
  saveRecording()
  particles.closeParticles()
  finishGameProfile()
