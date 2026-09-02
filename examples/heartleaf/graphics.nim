## Heartleaf spectator viewer.
##
## Reads the simulation and never writes it. The renderer interpolates body
## poses between ticks and samples terrain height for the vertical. None of
## that can flow back into `World`.

import
  std/[json, math, os, strutils, times],
  chroma, opengl, pixie, vmath, windy, silky,
  polyworld/[
    actioncam, characters, chrome, clickmarks, common, fixed, inputs,
    pathing, player, profiles, quadterrain, rtscameras, shadows, tapes,
    viewers
  ],
  content,
  maps as mapgen,
  sim,
  game,
  replays,
  ui,
  controls

const
  WindowTitle = "Heartleaf"
  AtlasPath = DataRoot & "/themes/heartleaf.atlas.png"
  LogoPath = DataRoot & "/themes/heartleaf/heartleaf_logo.png"
  SeekCheckpointTicks = TickRate * 10
    ## One saved world every ten seconds, so a seek re-simulates at most
    ## that much.
  VillagerHeight = 1.7'f32
  VillagePropPack = DataRoot & "/terrain/low_poly_village.glb"
  ModularCharacterPath = DataRoot & "/characters/modular_chars/character.glb"
  ModularManifestPath = DataRoot & "/characters/modular_chars/manifest.json"
  VillagerPresetNumbers: array[VillagerCount, int] = [
    1, 2, 3, 5, 6, 9, 11, 12, 13]
    ## The modular presets that ship pre-rendered profile portraits.
  HousePropScale = 5.2'f32
  GardenPropScale = 1.1'f32
  CropProps = ["carrot1", "carrot2", "tomato1", "tomato2"]
    ## A stocked garden shows one of these; an empty plot is bare dirt.

type
  GraphicsError = object of CatchableError
  SeekCheckpoint = object
    world: World
    hashCheck: ReplayHashCheck

var
  window*: Window
  sk*: Silky
  cameraDistance* = 64.0'f32
  cameraTarget* = vec3(0, 0, 0)
  cameraEye = vec3(0, 0, 0)
  panning = false
  minimapPanning* = false
  showEdges = false
  followSlot* = -1'i32
  rightPressPosition = vec2(0)
  seekCheckpoints: seq[SeekCheckpoint]
  transport* = initPlayer(
    live = not run.replayMode,
    durationTicks = run.maximumTicks,
    playing = not options.pauseOnStart,
    speed = options.speed
  )
  frameAlpha = 0.0'f32
  previousPositions: array[VillagerCount, Vec3]
  previousFacings: array[VillagerCount, float32]
  havePoses = false

## Presentation helpers

proc villagerPresetName(slot: int): string =
  "Preset " & $VillagerPresetNumbers[slot]

proc villagerParts(slot: int): seq[string] =
  ## One preset's part list with the adventuring gear left at home:
  ## villagers carry vegetables, not backpacks and weapons.
  let
    manifest = parseFile(ModularManifestPath)
    wanted = villagerPresetName(slot)
  var found = false
  for preset in manifest["presets"]:
    if preset["name"].getStr != wanted:
      continue
    found = true
    for part in preset["parts"]:
      let name = part.getStr
      if name.startsWith("Back_") or name.startsWith("Wield_Gear_"):
        continue
      result.add name
  doAssert found, ModularManifestPath & ": no preset " & wanted

proc villagerPortraitPath(slot: int): string =
  DataRoot & "/characters/modular_chars/character.preset_" &
    $VillagerPresetNumbers[slot] & ".profile.png"

proc clipIndex(model: CharacterModel, slot: AnimationSlot): int =
  ## Returns a clip for one pose from the modular pack.
  const Names: array[AnimationSlot, seq[string]] = [
    IdleAnimation: @["Idle", "IdleBattle"],
    WalkAnimation: @["Walk", "Run"],
    GatherAnimation: @["Attack01", "Victory", "Idle"],
    WaveAnimation: @["Victory", "LevelUp", "Idle"]
  ]
  for name in Names[slot]:
    if name in model.clips:
      return model.clips[name]
  raise newException(GraphicsError, "missing clip for " & $slot)

proc addHudIcons(builder: AtlasBuilder) =
  ## Packs the villager portraits and the theme logo.
  builder.addThemeLogo(LogoPath)
  for slot in 0 ..< VillagerCount:
    if not builder.addImage(
        villagerPortraitKey(int32(slot)),
        readImage(villagerPortraitPath(slot))
      ):
      raise newException(
        GraphicsError,
        "the UI atlas is too small for villager portraits"
      )

proc tileCentreXZ(tile: Tile2): Vec2 =
  ## Converts a tile coordinate to the world-space centre of that tile.
  vec2(float32(tile.x) - HalfGrid + 0.5'f32,
       float32(tile.y) - HalfGrid + 0.5'f32)

proc tileWorldPoint(tile: Tile2): Vec3 =
  ## Returns the render centre of one map tile.
  let xz = tileCentreXZ(tile)
  vec3(xz.x, surfaceHeight(xz.x, xz.y), xz.y)

proc villagerWorldPoint(v: Villager): Vec3 =
  ## Converts a tile-space body into a render position.
  let
    x = toFloat32(v.body.pos.x) - HalfGrid
    z = toFloat32(v.body.pos.y) - HalfGrid
  vec3(x, surfaceHeight(x, z), z)

proc villagerYaw(v: Villager): float32 =
  ## Turns body facing into the renderer's yaw convention.
  let dir = direction(v.body.facing)
  arctan2(toFloat32(dir.x), toFloat32(dir.y))

proc renderPoint(v: Villager): Vec3 =
  ## Interpolates one villager between the latest simulation snapshots.
  let current = villagerWorldPoint(v)
  if not havePoses:
    return current
  mix(previousPositions[v.slot], current, frameAlpha)

proc renderFacing(v: Villager): float32 =
  ## Interpolates yaw the short way so a +pi / -pi flip is not a spin.
  let current = villagerYaw(v)
  if not havePoses:
    return current
  let previous = previousFacings[v.slot]
  previous + shortestTurn(previous, current) * frameAlpha

proc captureVillagerPoses() =
  ## Remembers poses before one authoritative tick.
  for slot in 0 ..< VillagerCount:
    let v = run.world.villagers[slot]
    previousPositions[slot] = villagerWorldPoint(v)
    previousFacings[slot] = villagerYaw(v)
  havePoses = true

proc renderTime(ticks: int32): float32 =
  ## Converts animation ticks into seconds for the clip sampler.
  (float32(ticks) + frameAlpha) / float32(TickRate)

proc housePropYaw(house: House): float32 =
  ## Faces a house model toward its own door.
  arctan2(float32(house.facingX), float32(house.facingY))

proc runGraphics*() =
  ## Runs the native or Emscripten spectator.
  startProfileTrace()
  profileBlock "atlas":
    let builder = newHudAtlas(4096)
    addHudIcons(builder)
    builder.addDefaultFonts()
    builder.write(AtlasPath)
  profileBlock "window":
    (window, sk) = initGameWindow(
      WindowTitle,
      AtlasPath,
      gameWindowSize(options.windowWidth, options.windowHeight)
    )
  let splash = startSplash(sk, window)

  profileBlock "terrain":
    quadterrain.seed = run.mapSeed
    ## Tilled plots read as dirt; house pads read as stone.
    setTileMaterial(
      int(GardenTileKind),
      DirtMaterial, DirtMaterial,
      vec3(0.85, 0.72, 0.55), vec3(0.8, 0.7, 0.55),
      7
    )
    setTileMaterial(
      int(HouseTileKind),
      StoneMaterial, StoneMaterial,
      vec3(0.95), vec3(0.9),
      8
    )
    initTerrain()
    scatterGrass(800, run.mapSeed)

  var villagePack: PropPack
  profileBlock "props":
    villagePack = loadPropPack(VillagePropPack)
    for slot in 0 ..< VillagerCount:
      let house = run.world.map.houses[slot]
      villagePack.placeProp(
        "house_lvl" & $(int(house.propKind) + 1),
        tileWorldPoint(house.center),
        housePropYaw(house),
        HousePropScale
      )
    for garden in 0 ..< GardenCount:
      let tile = run.world.map.gardenTiles[garden]
      villagePack.placeProp(
        "farm_lvl2",
        tileWorldPoint(tile),
        float32(garden) * 1.3'f32,
        GardenPropScale
      )
    villagePack.placeProp(
      "stone_ring1",
      tileWorldPoint(tile2(GridSide div 2, GridSide div 2)),
      0.0'f32,
      2.0'f32
    )
    ## The village map never changes, so the terrain bakes exactly once.
    bakeTerrain(rebuildWalkability = false)

  ## Everything is always visible; there is no fog in a village.
  block:
    var values = newSeq[uint8](GridTiles * GridTiles)
    for value in values.mitems:
      value = 255
    uploadTerrainVisibility(values)

  var
    villagerModels: array[VillagerCount, CharacterModel]
    villagerClips: array[VillagerCount, array[AnimationSlot, int]]
  profileBlock "models":
    for slot in 0 ..< VillagerCount:
      villagerModels[slot] = loadModularCharacterModel(
        ModularCharacterPath,
        villagerParts(slot),
        VillagerHeight
      )
      for animation in AnimationSlot:
        villagerClips[slot][animation] =
          villagerModels[slot].clipIndex(animation)
  drawSplash(sk, window, splash.name)

  let scene = newCharacterScene(window)
  scene.useToonShading()
  setEnvironmentPalette(scene.toon)
  var clickMarks = initClickMarks()

  cameraTarget = vec3(0, surfaceHeight(0, 0), 0)
  var actionCam = initActionCam(
    minDistance = 16,
    maxDistance = 120,
    tight = 0.4,
    followRate = 1.0,
    zoomRate = 0.7,
    holdSeconds = 2.8,
    mapSpan = HalfGrid * 2,
    closeScale = 0.5
  )

  ## Replay scaffolding

  seekCheckpoints.add SeekCheckpoint(
    world: run.world.clone(),
    hashCheck: run.hashCheck
  )

  proc captureCheckpoint() =
    if run.world.tick div SeekCheckpointTicks < seekCheckpoints.len:
      return
    seekCheckpoints.add SeekCheckpoint(
      world: run.world.clone(),
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
    havePoses = false
    while run.world.tick < wanted:
      advanceGame()
      captureCheckpoint()

  ## Camera and input

  proc playerMode(): bool =
    ## Returns whether this client issues orders for one villager.
    options.playerSlot > 0 and not run.replayMode

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

  proc pickVillager(viewProjection: Mat4): int32 =
    ## Finds the nearest outdoor villager under the pointer, or -1.
    result = -1
    var bestDistance = 28.0'f32
    for slot in 0 ..< VillagerCount:
      let v = run.world.villagers[slot]
      if v.inHouse >= 0:
        continue
      let distance = (
        screenPosition(
          renderPoint(v) + vec3(0, VillagerHeight * 0.5'f32, 0),
          viewProjection
        ) - window.mousePos.vec2
      ).length
      if distance < bestDistance:
        bestDistance = distance
        result = int32(slot)

  proc houseAtTile(x, y: int32): int32 =
    ## The house whose footprint or doorstep contains this tile, or -1.
    result = -1
    for slot in 0 ..< VillagerCount:
      let house = run.world.map.houses[slot]
      if chebyshev(tile2(x, y), house.center) <= 1 or
          chebyshev(tile2(x, y), house.door) <= 1:
        return int32(slot)

  proc gardenAtTile(x, y: int32): int32 =
    ## The garden plot on this tile, or -1.
    result = -1
    for garden in 0 ..< GardenCount:
      if run.world.map.gardenTiles[garden] == tile2(x, y):
        return int32(garden)

  proc feedActionCam() =
    ## Points the director camera at gathering, waving, the dinner rush,
    ## and the parties themselves.
    let tick = run.world.tick
    actionCam.beginFrame(tick)
    for slot in 0 ..< VillagerCount:
      let v = run.world.villagers[slot]
      if v.inHouse >= 0:
        continue
      let pos = renderPoint(v)
      if v.animation == GatherAnimation:
        actionCam.noteInterest(int32(slot) + 1, pos, 40, 2, tick, 24)
      elif v.animation == WaveAnimation:
        actionCam.noteInterest(int32(slot) + 1, pos, 55, 2.5, tick, 24)
      elif v.order == EnterOrder and
          run.world.minuteOfDay >= 17 * 60:
        actionCam.noteInterest(int32(slot) + 1, pos, 45, 2, tick, 24)
    if run.world.phase == EveningPhase:
      for house in 0 ..< VillagerCount:
        if run.world.lastTally[house].valid:
          actionCam.noteInterest(
            100'i32 + int32(house),
            tileWorldPoint(run.world.map.houses[house].center),
            70,
            3,
            tick,
            48
          )

  proc updateCamera(dt: float32) =
    ## Applies fixed-north RTS pan, zoom, and villager following.
    updateMinimapCamera(
      window,
      sk.mousePos,
      cameraTarget,
      minimapPanning
    )
    if minimapPanning:
      followSlot = -1
      actionCam.takeManual()
    let overUi = mouseOverUi(window, sk.mousePos)
    if window.mousePressed(MouseRight) and not overUi:
      rightPressPosition = window.mousePos.vec2
      panning = true
    if not window.mouseDown(MouseRight):
      panning = false
    let delta = window.mouseDelta.vec2
    if panning and delta.length > 0:
      followSlot = -1
      actionCam.takeManual()
      let speed = cameraDistance * 0.0015
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
      followSlot = -1
      actionCam.takeManual()
    if not overUi and window.scrollDelta.y != 0:
      actionCam.takeManual()
      cameraDistance = clamp(
        cameraDistance * pow(0.92'f32, window.scrollDelta.y / 3.0'f32),
        6.0'f32,
        220.0'f32
      )
    if actionCam.enabled:
      feedActionCam()
      actionCam.chooseShot(dt, transport.speed)
      actionCam.follow(
        cameraTarget,
        cameraDistance,
        dt,
        transport.speed
      )
      return
    if followSlot >= 0:
      let v = run.world.villagers[followSlot]
      let focus =
        if v.inHouse >= 0:
          tileWorldPoint(run.world.map.houses[v.inHouse].center)
        else:
          renderPoint(v)
      cameraTarget = mix(cameraTarget, focus, damping(5.0'f32, dt))

  proc updateSelection(viewProjection: Mat4) =
    ## A left click on a villager follows them; empty ground lets go.
    if not window.mouseReleased(MouseLeft):
      return
    if mouseOverUi(window, sk.mousePos) or minimapPanning:
      return
    let picked = pickVillager(viewProjection)
    if picked >= 0:
      followSlot = picked
      actionCam.takeManual()
    else:
      followSlot = -1

  proc updatePlayerOrder(viewProjection: Mat4) =
    ## Turns a right-click into an invite, gather, enter, or walk.
    if not playerMode():
      return
    if not window.mouseReleased(MouseRight):
      return
    if mouseOverUi(window, sk.mousePos):
      return
    if (window.mousePos.vec2 - rightPressPosition).length > 6.0'f32:
      return
    let
      player = options.playerSlot - 1
      picked = pickVillager(viewProjection)
    if picked >= 0 and picked != player:
      queueInvite(player, picked)
      clickMarks.emitClickMark(
        renderPoint(run.world.villagers[picked]))
      return
    let
      ground = pickGroundPoint(
        window.mousePos.vec2,
        window.size.vec2,
        viewProjection,
        cameraTarget.y
      )
      tile = groundTile(ground, HalfGrid, GridSide)
      garden = gardenAtTile(tile[0], tile[1])
      house = houseAtTile(tile[0], tile[1])
    if garden >= 0 and run.world.gardens[garden] >= 0:
      queueGather(player, garden)
    elif house >= 0:
      queueEnterHouse(player, house)
    else:
      queueMove(player, tile[0], tile[1])
    clickMarks.emitClickMark(tileWorldPoint(tile2(tile[0], tile[1])))

  proc cameraView(): Mat4 =
    ## Returns the shared fixed-north RTS view matrix.
    cameraEye = rtsCameraEye(cameraTarget, cameraDistance)
    lookAt(cameraEye, cameraTarget, vec3(0, 1, 0))

  ## Frame

  var lastFrameTime = epochTime()
  const Step = 1.0'f32 / float32(TickRate)

  proc advanceRenderedGame() =
    ## Advances one tick, remembering poses for interpolation.
    captureVillagerPoses()
    advanceGame()
    captureCheckpoint()

  when defined(takeScreenshot):
    applyScreenshotCamera(cameraDistance)
    if existsEnv("CAM_X"):
      cameraTarget.x = getEnv("CAM_X").parseFloat.float32 - HalfGrid
    if existsEnv("CAM_Z"):
      cameraTarget.z = getEnv("CAM_Z").parseFloat.float32 - HalfGrid
    if existsEnv("SIM_SECONDS"):
      let wanted = int32(getEnv("SIM_SECONDS").parseFloat * TickRate.float64)
      while run.world.tick < wanted and
          run.world.tick < run.maximumTicks and not run.world.over:
        advanceGame()
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
          advanceRenderedGame()
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
        clickMarks.advanceClickMarks(dt)
      let
        aspect = window.size.x.float32 / max(window.size.y.float32, 1)
        view = cameraView()
        projection = perspective(45.0'f32, aspect, 0.1'f32, 1000.0'f32)
        viewProjection = projection * view
      updateSelection(viewProjection)
      updatePlayerOrder(viewProjection)
      profileBlock "drawWorld":
        ## One clock for the whole frame: the palette, the sun's position,
        ## and its shadow map all follow the village hour, so the dinner
        ## bell rings at golden hour and the walk home is dusk.
        scene.setToonHour(simClockHour(frameAlpha))
        setEnvironmentPalette(scene.toon)

        proc drawCrops(matrix: Mat4) =
          ## Stocked gardens show their vegetable; bare plots show dirt.
          for garden in 0 ..< GardenCount:
            let veggie = run.world.gardens[garden]
            if veggie < 0:
              continue
            villagePack.drawProp(
              CropProps[int(veggie) mod CropProps.len],
              tileWorldPoint(run.world.map.gardenTiles[garden]),
              float32(garden) * 0.7'f32,
              0.3'f32,
              matrix
            )

        proc drawWorldVillagers() =
          for slot in 0 ..< VillagerCount:
            let v = run.world.villagers[slot]
            if v.inHouse >= 0:
              continue
            let
              model = villagerModels[slot]
              clip = villagerClips[slot][v.animation]
            var animTime = renderTime(v.animationTicks)
            ## Gesture clips must be clamped: the sampler wraps with `mod`,
            ## so a wave would otherwise loop forever.
            if v.animation in {GatherAnimation, WaveAnimation}:
              animTime = min(animTime, clipDuration(model, clip))
            drawCharacter(
              scene, model, renderPoint(v), renderFacing(v), clip, animTime)

        sunDepthPasses(window.size):
          drawTerrainSunDepth()
          scene.sunDepthPass = true
          drawWorldVillagers()
          scene.sunDepthPass = false
        glClearColor(0.05, 0.06, 0.09, 1.0)
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
        drawTerrain(viewProjection, showEdges)
        drawCrops(viewProjection)
        beginCharacters(scene, window, view, projection, cameraEye)
        drawWorldVillagers()
        finishCharacters(scene)
        clickMarks.drawClickMarks(viewProjection)
      profileBlock "ui":
        glDisable(GL_DEPTH_TEST)
        glDisable(GL_CULL_FACE)
        glDisable(GL_BLEND)
        when not defined(emscripten):
          glDisable(GL_MULTISAMPLE)
        glActiveTexture(GL_TEXTURE0)
        glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
        sk.beginUi(window, window.size)

        ## World overlays drawn in HUD space: occupant portraits float over
        ## each occupied house, and gesture icons over busy villagers.
        for house in 0 ..< VillagerCount:
          var inside: seq[int32]
          for slot in 0 ..< VillagerCount:
            if run.world.villagers[slot].inHouse == int32(house):
              inside.add int32(slot)
          if inside.len == 0:
            continue
          let anchor = screenPosition(
            tileWorldPoint(run.world.map.houses[house].center) +
              vec3(0, 3.4'f32, 0),
            viewProjection
          ) / sk.uiScale
          let width = float32(inside.len) * 22 - 2
          sk.drawRoundedRect(
            anchor - vec2(width * 0.5'f32 + 4, 12),
            vec2(width + 8, 26),
            rgbx(18, 22, 20, 190),
            6
          )
          for index, slot in inside:
            sk.drawSprite(
              villagerPortraitKey(slot),
              anchor + vec2(
                float32(index) * 22 - width * 0.5'f32, -9),
              vec2(20)
            )
        for slot in 0 ..< VillagerCount:
          let v = run.world.villagers[slot]
          if v.inHouse >= 0:
            continue
          if v.animation notin {GatherAnimation, WaveAnimation}:
            continue
          let anchor = screenPosition(
            renderPoint(v) + vec3(0, VillagerHeight + 0.6'f32, 0),
            viewProjection
          ) / sk.uiScale
          sk.drawSprite(
            if v.animation == GatherAnimation: "gather" else: "wave",
            anchor - vec2(10, 10),
            vec2(20)
          )

        drawUi(
          sk,
          window,
          transport,
          cameraTarget,
          cameraDistance,
          viewProjection,
          followSlot,
          actionCam
        )
        sk.endUi()
      when defined(takeScreenshot):
        captureScreenshot(
          window,
          screenshotFrame,
          3,
          "heartleaf.png"
        )
      profileBlock "present":
        window.swapBuffers()
    if noteProfileFrame():
      when not defined(emscripten):
        window.closeRequested = true

  window.onButtonPress = proc(button: Button) =
    case button
    of KeySpace: transport.handleKey(button)
    of KeyC:
      var following = followSlot >= 0
      actionCam.toggle(following)
      if not following:
        followSlot = -1
    of KeyT: scene.toggleShading()
    of KeyE:
      if playerMode():
        queueExitHouse(options.playerSlot - 1)
    of KeyQ:
      ## Accept the first standing invitation.
      if playerMode():
        let me = run.world.villagers[options.playerSlot - 1]
        for host in 0 ..< VillagerCount:
          if me.inviteFrom[host]:
            queueAccept(options.playerSlot - 1, int32(host))
            break
    of KeyEscape:
      when not defined(emscripten):
        window.closeRequested = true
    else: discard

  while not window.closeRequested:
    pollEvents()
  finishProfileTrace()
