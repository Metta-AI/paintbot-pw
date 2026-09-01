## Watching an expedition. The camera follows the party down, and the world
## is drawn as a cutaway: the uppermost selected hero's floor, plus everything
## below it, so you can see the levels they have yet to reach through the
## shafts while the ceilings above them are simply not drawn.
##
## Nothing in this file is authoritative. It reads the simulation and turns
## body poses into smooth float positions; no value computed here is ever
## written back.

import
  std/[math, tables, times],
  chroma, opengl, pixie, silky, vmath, windy,
  polyworld/[actioncam, characters, common, fixed, particles, particleshaders,
    pathing, player, profiles, quadterrain, rtscameras, selectionoutlines,
    shadows, shapes, tapes, viewers, visions, worldbars],
  content, maps, sim, game, replays, ui

when defined(takeScreenshot):
  import std/[os, strutils]

const
  AtlasPath = DataRoot & "/themes/cta.atlas.png"
  LogoPath = DataRoot & "/themes/cta/cta_logo.png"
  SimulationStep = 1.0'f32 / TickRate.float32
  SeekCheckpointTicks = TickRate * 10
  PathLift = 0.2'f32
  PathHalfWidth = 0.12'f32
  FacingHeight = 0.85'f32
  FacingOffset = 0.4'f32
  FacingLength = 0.45'f32
  FacingHalfWidth = 0.18'f32
  # Rendered by tools/profile_glb.nim from the same presets the heroes wear.
  HeroPortraitPaths: array[HeroClass, string] = [
    DataRoot & "/characters/modular_chars/character.preset_5.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_18.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_11.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_9.profile.png"
  ]

type
  HeroVisual = object
    ## Holds client-only animation smoothing for one actor slot.
    angle: float32
    animTime: float32
    clip: int

  SeekCheckpoint = object
    ## Captures all authoritative state needed for an exact replay seek.
    tick: int32
    world: World
    log: seq[string]
    actionIndex: int
    hashCheck: ReplayHashCheck

var sk: Silky

proc registerTileColors() =
  ## Gives every dungeon kind a texture, tint, and blend priority.
  setTileMaterial(
    int(FloorTile), StoneMaterial, DirtMaterial,
    vec3(0.72, 0.70, 0.66), vec3(0.48, 0.46, 0.43), 10
  )
  setTileMaterial(
    int(RubbleTile), CliffMaterial, DirtMaterial,
    vec3(0.58, 0.52, 0.46), vec3(0.42, 0.38, 0.34), 11
  )
  setTileMaterial(
    int(LavaTile), VolcanicMaterial, VolcanicMaterial,
    vec3(1.0, 0.48, 0.20), vec3(0.68, 0.20, 0.08), 16
  )
  setTileMaterial(
    int(ObsidianTile), VolcanicMaterial, CliffMaterial,
    vec3(0.28, 0.24, 0.32), vec3(0.18, 0.16, 0.22), 15
  )
  setTileMaterial(
    int(GoldTile), SandMaterial, StoneMaterial,
    vec3(1.0, 0.86, 0.40), vec3(0.72, 0.58, 0.24), 17
  )
  setTileMaterial(
    int(MossTile), MarshMaterial, DirtMaterial,
    vec3(0.54, 0.72, 0.48), vec3(0.36, 0.48, 0.32), 12
  )
  setTileMaterial(
    int(RampTile), StoneMaterial, CliffMaterial,
    vec3(0.82, 0.76, 0.62), vec3(0.56, 0.50, 0.40), 13
  )

proc renderPosition(actor: Actor): Vec3 =
  ## Converts a tile-space body into a render position on the actor's floor.
  let
    base = tileCenter(
      int(actor.home.level), int(actor.home.x), int(actor.home.z))
    x = toFloat32(actor.body.pos.x) - HalfGrid
    z = toFloat32(actor.body.pos.y) - HalfGrid
  vec3(x, base.y, z)

proc actorYaw(actor: Actor): float32 =
  ## Renderer yaw from body facing: `arctan2(dx, dz)`. East is +pi/2,
  ## south is 0, west is -pi/2, north is pi.
  let dir = direction(actor.body.facing)
  arctan2(toFloat32(dir.x), toFloat32(dir.y))

proc travelYaw(fromPos, toPos: Vec3, fallback: float32): float32 =
  ## Renderer yaw of a world-space step, or fallback when the step is tiny.
  let
    dx = toPos.x - fromPos.x
    dz = toPos.z - fromPos.z
  if dx * dx + dz * dz < 1e-8'f32:
    fallback
  else:
    arctan2(dx, dz)

proc actorPathColor(actor: Actor): ColorRGBX =
  ## Returns a stable debug color for one actor's followed path.
  if actor.kind == HeroActor:
    case actor.heroClass
    of FighterClass: rgbx(194, 125, 62, 255)
    of WizardClass: rgbx(126, 89, 210, 255)
    of RogueClass: rgbx(57, 153, 181, 255)
    of ClericClass: rgbx(213, 177, 73, 255)
  else:
    rgbx(235, 72, 56, 255)

proc liftedPathPoint(position: Vec3): Vec3 =
  ## Raises a path point so the line sits above the floor.
  vec3(position.x, position.y + PathLift, position.z)

proc addFacingTriangle(
    renderer: var ShapeRenderer,
    actor: Actor,
    color: ColorRGBX
) =
  ## Draws the heading the simulation currently stores on this body.
  let
    dir = direction(actor.body.facing)
    fx = toFloat32(dir.x)
    fz = toFloat32(dir.y)
  if fx * fx + fz * fz < 1e-8'f32:
    return
  let
    forward = normalize(vec3(fx, 0, fz))
    right = vec3(-forward.z, 0, forward.x)
    origin =
      renderPosition(actor) +
      forward * FacingOffset +
      vec3(0, FacingHeight, 0)
    tip = origin + forward * FacingLength
    left = origin + right * FacingHalfWidth
    rightPt = origin - right * FacingHalfWidth
  renderer.addTriangle(tip, left, rightPt, color)

proc addActorPaths(
    renderer: var ShapeRenderer,
    world: World,
    visibleFrom: int
) =
  ## Adds remaining path ribbons and a facing triangle for each living actor.
  for actor in world.actors:
    if actor.id == 0 or not actor.alive:
      continue
    if int(actor.home.level) < visibleFrom:
      continue
    if actor.kind == MonsterActor and not selectedVisible(actor.home):
      continue
    let color = actorPathColor(actor)
    renderer.addFacingTriangle(actor, color)
    if actor.path.len == 0 or actor.pathIndex >= int32(actor.path.len):
      continue
    var points: seq[Vec3]
    points.add liftedPathPoint(renderPosition(actor))
    for i in int(actor.pathIndex) ..< actor.path.len:
      let tile = actor.path[i].tile
      if int(tile.level) < visibleFrom:
        if points.len >= 2:
          renderer.addPolyline(points, color, PathHalfWidth)
        points.setLen(0)
        continue
      points.add liftedPathPoint(
        tileCenter(int(tile.level), int(tile.x), int(tile.z))
      )
    if points.len >= 2:
      renderer.addPolyline(points, color, PathHalfWidth)

proc makeCircleIcon(size: int, fill: ColorRGBA): Image =
  ## Builds a filled circle sprite for compact HUD chrome.
  result = newImage(size, size)
  let ctx = newContext(result)
  ctx.fillStyle = fill
  ctx.fillCircle(
    circle(vec2(size.float32 * 0.5'f32), size.float32 * 0.46'f32)
  )

proc addHudIcons(builder: AtlasBuilder) =
  ## Packs textured HUD plates into the atlas.
  const PanelDir = DataRoot & "/themes/cta/"
  builder.addThemeLogo(LogoPath)
  if not builder.addImage(
      "cta_badge",
      makeCircleIcon(22, rgba(18, 20, 28, 255))
    ) or
      not builder.addImage(
        "cta_leftTop",
        readImage(PanelDir & "leftTop.png")
      ) or
      not builder.addImage(
        "cta_leftRight",
        readImage(PanelDir & "leftRight.png")
      ) or
      not builder.addImage(
        "cta_bottomLeft",
        readImage(PanelDir & "bottomLeft.png")
      ) or
      not builder.addImage(
        "cta_bottomCenter",
        readImage(PanelDir & "bottomCenter.png")
      ) or
      not builder.addImage(
        "cta_bottomRight",
        readImage(PanelDir & "bottomRight.png")
      ):
    raise newException(
      ValueError,
      "the UI atlas is too small for HUD panels"
    )

proc addAbilityIcons(builder: AtlasBuilder) =
  ## Packs every ability art file used by the action bar.
  const AbilityDir = DataRoot & "/abilities/"
  for _, name in AbilityIconFiles:
    if name.len == 0:
      continue
    let icon = readImage(AbilityDir & name & ".png").resize(128, 128)
    if not builder.addImage("ability_" & name, icon):
      raise newException(
        ValueError,
        "the UI atlas is too small for ability icons"
      )

proc runGraphics*() =
  ## Runs the native or Emscripten graphical expedition viewer.
  startProfileTrace()
  registerTileColors()
  profileBlock "atlas":
    let builder = newHudAtlas(4096)
    for class in HeroClass:
      let portrait = readImage(HeroPortraitPaths[class])
      if not builder.addImage(HeroPortraitKeys[class], portrait):
        raise newException(
          ValueError,
          "Failed to allocate hero portrait: " & HeroPortraitPaths[class]
        )
    addHudIcons(builder)
    addAbilityIcons(builder)
    builder.addDefaultFonts()
    builder.write(AtlasPath)
  var window: Window
  profileBlock "window":
    (window, sk) = initGameWindow(
      "Call to Adventure",
      AtlasPath,
      gameWindowSize(options.windowWidth, options.windowHeight)
    )
  let splash = startSplash(sk, window)
  # The stack spans about 45 tiles top to bottom; the shading uses amplitude
  # as its height scale, so a value near the whole span keeps every level
  # readable instead of clipping the deep ones to black.
  profileBlock "terrain":
    amplitude = 48.0
    initTerrain()
    bakeTerrain(rebuildWalkability = false)

  let scene = newCharacterScene(window)
  scene.useToonShading()
  var
    particles = initParticleSystem()
    worldBarRenderer = initWorldBarRenderer()
    worldShapes = initShapeRenderer()
    damageTrails: DamageTrailTracker
    selectionOutline = initSelectionOutline()
  var heroModels: array[HeroClass, CharacterModel]
  var monsterModels: array[Species, CharacterModel]
  profileBlock "models":
    for class in HeroClass:
      heroModels[class] = loadModularCharacterModel(
        HeroModelPath, HeroManifestPath, ClassPresets[class], 1.7)
    for species in Species:
      monsterModels[species] = loadCharacterModel(SpeciesModels[species], 1.6)
  drawSplash(sk, window, splash.name)

  proc clipFor(model: CharacterModel, names: varargs[string]): int =
    ## Clip names differ across the model packs, so ask for the first one
    ## this model actually has and fall back to whatever exists.
    for name in names:
      if model.clips.hasKey(name):
        return model.clipIndex(name)
    0

  var
    heroIdle, heroRun, heroAttack: array[HeroClass, int]
    monsterIdle, monsterRun, monsterAttack: array[Species, int]
  for class in HeroClass:
    let model = heroModels[class]
    heroIdle[class] = clipFor(model, "Idle", "Idle_Battle", "Idle01")
    heroRun[class] = clipFor(
      model, "Run", "RunForwardBattle", "BattleRunForward",
      "MoveFWD_Battle", "Walk")
    heroAttack[class] = clipFor(model, "Attack01", "NormalAttack01")
  for species in Species:
    let model = monsterModels[species]
    monsterIdle[species] = clipFor(model, "Idle", "Idle_Battle")
    monsterRun[species] = clipFor(model, "Run", "Walk")
    monsterAttack[species] = clipFor(model, "Attack01")

  var
    visuals: seq[HeroVisual]
    previousActorPositions: Table[int32, Vec3]
    previousActorFacings: Table[int32, float32]
    renderAlpha = 1.0'f32

  proc captureActorPositions() =
    ## Remembers the visual pose before one authoritative tick.
    var
      nextPositions: Table[int32, Vec3]
      nextFacings: Table[int32, float32]
    for actor in run.world.actors:
      if actor.id == 0:
        continue
      let pos = renderPosition(actor)
      nextPositions[actor.id] = pos
      nextFacings[actor.id] = travelYaw(
        previousActorPositions.getOrDefault(actor.id, pos),
        pos,
        actorYaw(actor)
      )
    previousActorPositions = nextPositions
    previousActorFacings = nextFacings

  proc actorRenderPosition(actor: Actor): Vec3 =
    ## Interpolates one actor between the two latest simulation snapshots.
    let current = renderPosition(actor)
    if not interpolateVisuals:
      return current
    mix(
      previousActorPositions.getOrDefault(actor.id, current),
      current,
      renderAlpha
    )

  proc actorRenderFacing(actor: Actor): float32 =
    ## Interpolates the last walked heading the short way. Travel yaw is
    ## taken from the tick's displacement so a ±pi wrap in body facing
    ## cannot spin the model.
    if not interpolateVisuals:
      return actorYaw(actor)
    let
      currentPos = renderPosition(actor)
      current = travelYaw(
        previousActorPositions.getOrDefault(actor.id, currentPos),
        currentPos,
        actorYaw(actor)
      )
      previous = previousActorFacings.getOrDefault(actor.id, current)
    previous + shortestTurn(previous, current) * renderAlpha

  type
    ActorParticleState = object
      id: int32
      kind: ActorKind
      class: uint8
      hp: int16
      action: Ability
      actionTicks: int16
      origin: Vec3
      targetFound: bool
      targetPosition: Vec3
  proc captureParticleActors(): seq[ActorParticleState] =
    ## Captures flat pre-tick combat data without retaining simulation refs.
    for actor in run.world.actors:
      if not actor.alive:
        continue
      var state = ActorParticleState(
        id: actor.id,
        kind: actor.kind,
        class: actor.class,
        hp: actor.hp,
        action: actor.action,
        actionTicks: actor.actionTicks,
        origin: renderPosition(actor) + vec3(0, 0.82'f32, 0)
      )
      let targetSlot = run.world.actorSlot(actor.target)
      if targetSlot >= 0 and run.world.actors[targetSlot].alive:
        state.targetFound = true
        state.targetPosition = renderPosition(
          run.world.actors[targetSlot]
        ) + vec3(0, 0.72'f32, 0)
      result.add state

  proc emitActorAttack(state: ActorParticleState) =
    ## Converts one CTA ability impact into its matching game effect.
    if not state.targetFound:
      return
    let travel = clamp(
      (state.targetPosition - state.origin).length / 13.0'f32,
      0.1'f32,
      0.5'f32
    )
    if state.kind == MonsterActor:
      if Species(state.class) == LichSpecies:
        particles.emitParticleProjectile(
          MagicBolt,
          MagicBurst,
          state.origin,
          state.targetPosition,
          travel
        )
      else:
        particles.emitParticleBurst(
          CombatSparks,
          state.targetPosition
        )
      return
    case state.action
    of MeteorStrike:
      particles.emitParticleProjectile(
        Fireball,
        FireBurst,
        state.origin,
        state.targetPosition,
        travel
      )
    of FrostLance, SunOrb:
      particles.emitParticleProjectile(
        MagicBolt,
        MagicBurst,
        state.origin,
        state.targetPosition,
        travel
      )
    of VerdantArrow:
      particles.emitParticleProjectile(
        ArrowWake,
        CombatSparks,
        state.origin,
        state.targetPosition,
        travel
      )
    of FirebrandSword, MoltenFist, VenomDagger, SolarHammer,
        IronFlail, BlazingBlade, VoidBlade, GaleSlash:
      particles.emitParticleBurst(
        CombatSparks,
        state.targetPosition
      )
    of LightningStorm, ArcaneMeteor, ShadowComet, CosmicFlare:
      particles.emitParticleProjectile(
        MagicBolt,
        MagicBurst,
        state.origin,
        state.targetPosition,
        travel
      )
    of FirePhoenix:
      particles.emitParticleProjectile(
        Fireball,
        FireBurst,
        state.origin,
        state.targetPosition,
        travel
      )
    else:
      discard

  proc emitTickParticles(oldActors: seq[ActorParticleState]) =
    ## Emits action impacts and all actual hit-point restoration once.
    for old in oldActors:
      let slot = run.world.actorSlot(old.id)
      if slot >= 0 and
          run.world.actors[slot].hp > old.hp:
        particles.emitParticleBurst(
          HealingAura,
          renderPosition(run.world.actors[slot])
        )
      if old.action == NoAbility:
        continue
      let spec = Abilities[old.action]
      if old.actionTicks + 1 != spec.windupTicks or
          spec.damage <= 0:
        continue
      emitActorAttack(old)

  var
    cameraDistance = 26.0'f32
    cameraTarget = vec3(0, 0, 0)
    panning = false
    minimapPanning = false
    lastMouse = ivec2(0, 0)
    lastFrameTime = epochTime()
    followSelection = false
    actionCam = initActionCam(
      minDistance = 12,
      maxDistance = 36,
      tight = 0.35,
      followRate = 3.5,
      zoomRate = 2.5,
      holdSeconds = 0.7,
      mapSpan = 28
    )
    primaryId = 0
    selectedIds: array[PartySize, bool]
    selectionPressPosition = vec2(0)
    selectionStarted = false
    selectionAdditive = false
    groupCameraScale = 1.0'f32
    terrainVisionTick = int32.low
    terrainVisionLevel = int32.low
    replayCheckpoints: seq[SeekCheckpoint]
    transport = initPlayer(
      live = not run.replayMode,
      durationTicks = options.maximumTicks,
      playing = not options.pauseOnStart,
      speed = options.speed
    )

  proc copyLog(): seq[string] =
    ## Copies the presentation log into an independent checkpoint value.
    for line in run.log:
      result.add line

  proc captureCheckpoint(): SeekCheckpoint =
    ## Captures the exact simulation and replay cursor at the current tick.
    SeekCheckpoint(
      tick: run.world.tick,
      world: run.world.clone(),
      log: copyLog(),
      actionIndex: run.replayPlayer.actionIndex,
      hashCheck: run.hashCheck
    )

  proc restoreCheckpoint(checkpoint: SeekCheckpoint) =
    ## Restores one simulation checkpoint without rebinding the game object.
    run.world.restore(checkpoint.world)
    run.log = checkpoint.log
    if run.recorder != nil:
      run.replayPlayer.data = run.recorder.data
    run.replayPlayer.syncCursor(uint32(run.world.tick))
    run.hashCheck = checkpoint.hashCheck

  proc cacheSeekCheckpoint() =
    ## Extends the seek cache as playback reaches new territory.
    let finalTick = transport.timelineEnd
    if run.world.tick mod SeekCheckpointTicks != 0 and
        run.world.tick != finalTick:
      return
    if replayCheckpoints.len == 0 or
        replayCheckpoints[^1].tick < run.world.tick:
      replayCheckpoints.add captureCheckpoint()

  proc restoreTo(target: int32) =
    ## Reloads the last checkpoint at or before a tick, then resimulates.
    var checkpointIndex = 0
    for i, checkpoint in replayCheckpoints:
      if checkpoint.tick > target:
        break
      checkpointIndex = i
    restoreCheckpoint(replayCheckpoints[checkpointIndex])
    run.historyPlayback = true
    transport.accumulator = 0
    previousActorPositions.clear()
    previousActorFacings.clear()
    particles.clearParticles()
    renderAlpha = 1
    while run.world.tick < target:
      advanceGame()
      cacheSeekCheckpoint()

  replayCheckpoints = @[captureCheckpoint()]

  proc partyCenter(): Vec3 =
    ## Returns the average interpolated position of the living party.
    var
      total = vec3(0, 0, 0)
      count = 0
    for slot in 0 ..< PartySize:
      if run.world.actors[slot].alive:
        total = total + actorRenderPosition(run.world.actors[slot])
        inc count
    if count == 0: cameraTarget else: total / count.float32

  cameraTarget = partyCenter()

  proc selectedAlive(): bool =
    ## Returns whether the selected party slot contains a living hero.
    primaryId >= 0 and
      primaryId < min(PartySize, run.world.actors.len) and
      run.world.actors[primaryId].alive

  proc selectedCount(): int =
    ## Returns the number of selected party slots.
    for selected in selectedIds:
      if selected:
        inc result

  proc selectedLivingCount(): int =
    ## Returns the number of selected heroes currently alive.
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      if selectedIds[slot] and run.world.actors[slot].alive:
        inc result

  proc selectedLivingHero(): int =
    ## Returns the first selected living hero slot, or minus one.
    result = -1
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      if selectedIds[slot] and run.world.actors[slot].alive:
        return slot

  proc selectedViewLevel(): int =
    ## Returns the uppermost floor a selected living hero stands on.
    int(run.viewLevel(selectedIds))

  proc updateSelectionCamera() =
    ## Activates the camera mode appropriate for the current selection.
    let livingCount = selectedLivingCount()
    followSelection = livingCount > 0
    if livingCount > 1:
      groupCameraScale = 1.0'f32

  proc selectEntity(slot: int, additive = false) =
    ## Selects one party slot and updates the shared camera selection.
    if slot < 0 or slot >= min(PartySize, run.world.actors.len):
      return
    if not additive:
      for i in 0 ..< PartySize:
        selectedIds[i] = false
    elif selectedIds[slot] and selectedCount() > 1:
      selectedIds[slot] = false
      if slot == primaryId:
        for i in 0 ..< PartySize:
          if selectedIds[i]:
            primaryId = i
            break
      updateSelectionCamera()
      actionCam.takeManual()
      return
    selectedIds[slot] = true
    primaryId = slot
    actionCam.takeManual()
    updateSelectionCamera()

  proc selectAllHeroes() =
    ## Selects every party hero and activates the group camera.
    for slot in 0 ..< PartySize:
      selectedIds[slot] = true
    if not selectedAlive():
      for slot in 0 ..< min(PartySize, run.world.actors.len):
        if run.world.actors[slot].alive:
          primaryId = slot
          break
    actionCam.takeManual()
    updateSelectionCamera()

  selectAllHeroes()
  actionCam.enabled = true
  followSelection = false

  proc selectedCenter(): Vec3 =
    ## Returns the midpoint of all selected living heroes.
    var count = 0
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if selectedIds[slot] and actor.alive:
        result = result + actorRenderPosition(actor)
        inc count
    if count > 0:
      result = result / count.float32

  proc selectedRadius(center: Vec3): float32 =
    ## Returns the largest planar distance from the selection midpoint.
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if not selectedIds[slot] or not actor.alive:
        continue
      let
        position = actorRenderPosition(actor)
        dx = position.x - center.x
        dz = position.z - center.z
      result = max(result, sqrt(dx * dx + dz * dz))

  proc partyActionLevel(): int8 =
    ## Returns the floor most living heroes currently stand on.
    var counts: array[LevelCount, int]
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      if run.world.actors[slot].alive:
        inc counts[int(run.world.actors[slot].home.level)]
    result = 0
    for level, count in counts:
      if count > counts[int(result)]:
        result = int8(level)

  proc feedCtaActions() =
    ## Notes the living party first, then nearby fights on that floor.
    const
      LookAheadTicks = 48'i32
      PartyShotId = 90_000_000'i32
    let
      tick = run.world.tick
      level = partyActionLevel()
    actionCam.beginFrame(tick)
    proc leadPosition(actor: Actor): Vec3 =
      ## Nudges one step along the current path, not a room ahead.
      result = actorRenderPosition(actor)
      if actor.path.len == 0:
        return
      let i = min(int(actor.pathIndex), actor.path.len - 1)
      if i < 0:
        return
      let tile = actor.path[i].tile
      if tile.level != actor.home.level:
        return
      result = mix(
        result,
        tileCenter(int(tile.level), int(tile.x), int(tile.z)),
        0.25'f32
      )
    var
      partyTotal = vec3(0, 0, 0)
      partyCount = 0
      partyRadius = 2.4'f32
      partyFighting = false
    for actor in run.world.actors:
      if actor.kind != HeroActor or
          not actor.alive or
          actor.home.level != level:
        continue
      partyTotal = partyTotal + leadPosition(actor)
      inc partyCount
      if actor.state == FightingState or actor.busy:
        partyFighting = true
    if partyCount > 0:
      let center = partyTotal / partyCount.float32
      for actor in run.world.actors:
        if actor.kind != HeroActor or
            not actor.alive or
            actor.home.level != level:
          continue
        let
          pos = actorRenderPosition(actor)
          dx = pos.x - center.x
          dz = pos.z - center.z
        partyRadius = max(
          partyRadius,
          sqrt(dx * dx + dz * dz) + 1.6'f32
        )
      actionCam.noteInterest(
        PartyShotId,
        center + vec3(0, 0.45'f32, 0),
        if partyFighting: 120.0'f32 else: 100.0'f32,
        partyRadius,
        tick,
        12
      )
    proc noteUpcoming(actions: openArray[ReplayAction]) =
      ## Widens the party shot toward a recorded swing still in the room.
      var i = actions.actionIndexAfter(uint32(tick))
      let limit = uint32(tick + LookAheadTicks)
      while i < actions.len and actions[i].tick <= limit:
        let action = actions[i]
        if action.kind == ActionAttackTarget or
            action.kind == ActionHealTarget:
          let heroSlot = run.world.actorSlot(action.heroId)
          if heroSlot >= 0:
            let hero = run.world.actors[heroSlot]
            if hero.home.level == level:
              var pos = actorRenderPosition(hero)
              let targetSlot = run.world.actorSlot(action.first)
              if targetSlot >= 0:
                let target = run.world.actors[targetSlot]
                if target.home.level == level:
                  pos = mix(
                    pos,
                    actorRenderPosition(target),
                    0.4'f32
                  )
              actionCam.noteInterest(
                action.heroId,
                pos,
                70,
                2.2,
                tick,
                int32(action.tick) - tick + 12
              )
        inc i
    if run.replayPlayer != nil:
      noteUpcoming(run.replayPlayer.data.actions)
    elif run.recorder != nil:
      noteUpcoming(run.recorder.data.actions)
    for actor in run.world.actors:
      if actor.id == 0 or actor.home.level != level:
        continue
      if actor.kind == HeroActor and actor.alive:
        if actor.state == FightingState or actor.busy:
          var pos = actorRenderPosition(actor)
          let targetSlot = run.world.actorSlot(actor.target)
          if targetSlot >= 0:
            let target = run.world.actors[targetSlot]
            if target.home.level == level:
              pos = mix(pos, actorRenderPosition(target), 0.35'f32)
          actionCam.noteInterest(actor.id, pos, 80, 2.2, tick, 16)
      elif actor.kind == MonsterActor and actor.alive:
        let pos = actorRenderPosition(actor)
        if actor.state == FightingState:
          actionCam.noteInterest(actor.id, pos, 68, 1.8, tick, 16)
        elif actor.maxHp > 0 and actor.hp * 3 <= actor.maxHp:
          actionCam.noteInterest(actor.id, pos, 55, 2.0, tick, 12)

  proc updateTerrainVision(level: int32) =
    ## Uploads softened party vision and explored memory for one floor.
    if terrainVisionTick == run.world.tick and
        terrainVisionLevel == level:
      return
    terrainVisionTick = run.world.tick
    terrainVisionLevel = level
    var values = newSeq[uint8](TilesPerLevel)
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        let
          tile = TileRef(level: int8(level), x: uint8(x), z: uint8(z))
          index = z * GridTiles + x
        values[index] =
          if selectedVisible(tile): 255
          elif run.world.explored(tile): 48
          else: 0
    uploadTerrainVisibility(blurVisibility(values, GridTiles, GridTiles))

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

  proc pickEntity(viewProjection: Mat4): int =
    ## Finds the nearest visible living hero under the pointer.
    result = -1
    var bestDistance = 32.0'f32
    let visibleFrom = selectedViewLevel()
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if not actor.alive or int(actor.home.level) < visibleFrom:
        continue
      let
        point = screenPosition(
          actorRenderPosition(actor) + vec3(0, 0.9'f32, 0),
          viewProjection
        )
        delta = point - window.mousePos.vec2
        distance = sqrt(delta.x * delta.x + delta.y * delta.y)
      if distance < bestDistance:
        bestDistance = distance
        result = slot

  proc updateWorldSelection(viewProjection: Mat4) =
    ## Selects a clicked hero without treating camera drags as clicks.
    if not window.buttonReleased[MouseLeft]:
      return
    let
      delta = window.mousePos.vec2 - selectionPressPosition
      dragDistance = sqrt(delta.x * delta.x + delta.y * delta.y)
    if selectionStarted and dragDistance <= 6.0'f32 and
        not mouseOverUi(window, sk.mousePos):
      let picked = pickEntity(viewProjection)
      if picked >= 0:
        selectEntity(picked, selectionAdditive)
      elif not selectionAdditive:
        for slot in 0 ..< PartySize:
          selectedIds[slot] = false
        followSelection = false
        actionCam.takeManual()
    selectionStarted = false

  proc drawWorldBars(
      viewProjection: Mat4,
      cameraRight,
      cameraUp: Vec3,
      visibleFrom: int,
      dt: float32
  ) =
    ## Draws hero resources and damage-gated monster health in the world.
    damageTrails.beginFrame()
    worldBarRenderer.clear()
    for actor in run.world.actors:
      if actor.id == 0 or not actor.alive or
          int(actor.home.level) < visibleFrom:
        continue
      let
        health = max(actor.hp, 0'i16).float32
        maximumHealth = max(actor.maxHp, 1'i16).float32
        delayedHealth = damageTrails.delayedValue(
          actor.id,
          health,
          maximumHealth,
          dt
        )
      if actor.kind == HeroActor:
        var bars = @[WorldResourceBar(
          value: health,
          maximum: maximumHealth,
          delayedValue: delayedHealth,
          height: 0.15'f32,
          color: healthColor(health, maximumHealth),
          showDamageTrail: true
        )]
        if actor.maxMana > 0:
          bars.add WorldResourceBar(
            value: max(actor.mana, 0'i16).float32,
            maximum: actor.maxMana.float32,
            delayedValue: max(actor.mana, 0'i16).float32,
            height: 0.09'f32,
            color: rgbx(60, 125, 231, 255)
          )
        let anchor = actorRenderPosition(actor) + vec3(0, 2.02'f32, 0)
        worldBarRenderer.addResourceBars(anchor, 1.55'f32, bars)
      elif actor.hp < actor.maxHp:
        let
          anchor = actorRenderPosition(actor) + vec3(0, 1.82'f32, 0)
          bars = [WorldResourceBar(
            value: health,
            maximum: maximumHealth,
            delayedValue: delayedHealth,
            height: 0.1'f32,
            color: healthColor(health, maximumHealth),
            showDamageTrail: true
          )]
        worldBarRenderer.addResourceBars(anchor, 1.0'f32, bars)
    damageTrails.finishFrame()
    worldBarRenderer.draw(viewProjection, cameraRight, cameraUp)

  proc drawSelectedOutline(
      view,
      projection: Mat4,
      cameraEye: Vec3,
      visibleFrom: int
  ) =
    ## Draws selected animated heroes and composites their exact outlines.
    if selectedLivingCount() == 0:
      return
    selectionOutline.beginMask(window.size)
    beginCharacters(scene, window, view, projection, cameraEye)
    for slot in 0 ..< min(PartySize, run.world.actors.len):
      let actor = run.world.actors[slot]
      if not selectedIds[slot] or not actor.alive or
          slot >= visuals.len or int(actor.home.level) < visibleFrom:
        continue
      drawCharacter(
        scene,
        heroModels[actor.heroClass],
        actorRenderPosition(actor),
        visuals[slot].angle,
        visuals[slot].clip,
        visuals[slot].animTime,
        color(1, 1, 1, 1)
      )
    finishCharacters(scene)
    selectionOutline.drawOutline()

  window.onButtonPress = proc(button: Button) =
    sk.uiScale = hudUiScale(window)
    sk.mousePos = window.mousePos.vec2 / sk.uiScale
    case button
    of MouseLeft:
      if not mouseOverUi(window, sk.mousePos):
        selectionPressPosition = window.mousePos.vec2
        selectionStarted = true
        selectionAdditive =
          window.buttonDown[KeyLeftShift] or
          window.buttonDown[KeyRightShift]
    of MouseRight:
      if not mouseOverUi(window, sk.mousePos):
        panning = true
        lastMouse = window.mousePos
    of KeySpace:
      transport.handleKey(button)
    of KeyC:
      actionCam.toggle(followSelection)
    of KeyT:
      scene.toggleShading()
    of KeyF:
      if selectedLivingCount() > 0:
        followSelection = not followSelection
        if followSelection:
          actionCam.takeManual()
    of KeyF1:
      debugMenuOpen = not debugMenuOpen
    of KeyA:
      if window.buttonDown[KeyLeftControl] or
          window.buttonDown[KeyRightControl]:
        selectAllHeroes()
    of KeyEscape:
      when not defined(emscripten):
        window.closeRequested = true
    else:
      discard

  window.onButtonRelease = proc(button: Button) =
    case button
    of MouseRight: panning = false
    else: discard

  window.onScroll = proc() =
    sk.uiScale = hudUiScale(window)
    sk.mousePos = window.mousePos.vec2 / sk.uiScale
    if not mouseOverUi(window, sk.mousePos):
      actionCam.takeManual()
      if followSelection and selectedLivingCount() > 1:
        groupCameraScale = clamp(
          groupCameraScale *
            (1.0'f32 - window.scrollDelta.y * 0.1'f32 / 3.0'f32),
          0.75,
          3.0
        )
      else:
        cameraDistance = clamp(
          cameraDistance *
            (1.0'f32 - window.scrollDelta.y * 0.1'f32 / 3.0'f32),
          8,
          160
        )

  when defined(takeScreenshot):
    var screenshotFrame = 0
    applyScreenshotCamera(cameraDistance)
    if existsEnv("PBR"):
      scene.shading = PbrCharacters
    if existsEnv("SIM_TICKS"):
      for _ in 0 ..< getEnv("SIM_TICKS").parseInt:
        if run.world.phase in {EscapedPhase, WipedPhase}:
          break
        advanceGame()
      # Snap rather than ease: a capture renders a handful of frames, which
      # is nowhere near enough for a smoothed camera to travel from the
      # entrance to wherever the party actually got to.
      cameraTarget = partyCenter()
    if run.replayMode and existsEnv("REPLAY_TICK"):
      transport.seekTo(int32(getEnv("REPLAY_TICK").parseInt))
      cameraTarget = partyCenter()
    if existsEnv("SELECT_ALL"):
      selectAllHeroes()

  holdSplash(sk, window, splash)
  window.onFrame = proc() =
    profileBlock "frame":
      let dt = frameDelta(lastFrameTime, SimulationStep)
      sk.uiScale = hudUiScale(window)
      sk.mousePos = window.mousePos.vec2 / sk.uiScale
      let recorded =
        if run.recorder != nil: int32(run.recorder.data.hashes.len)
        elif run.replayMode: int32(run.replayPlayer.data.hashes.len)
        else: run.world.tick
      transport.sync(
        run.world.tick,
        recorded,
        run.world.phase in {EscapedPhase, WipedPhase}
      )
      let restoreTick = transport.takeRestore()
      if restoreTick >= 0:
        restoreTo(restoreTick)
        transport.sync(
          run.world.tick,
          recorded,
          run.world.phase in {EscapedPhase, WipedPhase}
        )
      transport.startFrame(dt, TickRate)
      let
        frameStart = epochTime()
        active = simulationActive(transport)
      run.historyPlayback = transport.inHistory
      profileBlock "simulate":
        while transport.shouldTick(frameStart):
          if atLiveTickCap(run.world.tick, options.maximumTicks, transport.live):
            break
          captureActorPositions()
          let oldActors = captureParticleActors()
          run.historyPlayback = transport.inHistory
          advanceGame()
          emitTickParticles(oldActors)
          cacheSeekCheckpoint()
          let recordedNow =
            if run.recorder != nil: int32(run.recorder.data.hashes.len)
            elif run.replayMode: int32(run.replayPlayer.data.hashes.len)
            else: run.world.tick
          transport.sync(
            run.world.tick,
            recordedNow,
            run.world.phase in {EscapedPhase, WipedPhase}
          )
      renderAlpha =
        if active:
          clamp(transport.accumulator / SimulationStep, 0.0'f32, 1.0'f32)
        else:
          1.0'f32
      if active:
        particles.advanceParticles(dt * transport.speed.float32)

      # Camera
      profileBlock "camera":
        updateMinimapCamera(
          window,
          sk.mousePos,
          cameraTarget,
          minimapPanning,
          followSelection,
          selectedViewLevel()
        )
        if minimapPanning:
          actionCam.takeManual()
        if panning:
          let delta = window.mousePos - lastMouse
          lastMouse = window.mousePos
          followSelection = false
          actionCam.takeManual()
          cameraTarget.x -= delta.x.float32 * 0.05'f32
          cameraTarget.z -= delta.y.float32 * 0.05'f32
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
        if actionCam.enabled:
          feedCtaActions()
          actionCam.chooseShot(dt, transport.speed)
          actionCam.follow(
            cameraTarget,
            cameraDistance,
            dt,
            transport.speed
          )
        else:
          let livingSelection = selectedLivingCount()
          if followSelection and livingSelection == 1:
            let
              cameraHero = selectedLivingHero()
              actor = run.world.actors[cameraHero]
              targetPosition =
                actorRenderPosition(actor) + vec3(0, 0.85'f32, 0)
            cameraTarget = mix(
              cameraTarget,
              targetPosition,
              damping(5.0'f32, dt)
            )
          elif followSelection and livingSelection > 1:
            let
              groupCenter = selectedCenter()
              groupDistance = clamp(
                10.0'f32 + selectedRadius(groupCenter) * 2.8'f32,
                16.0'f32,
                80.0'f32
              ) * groupCameraScale
            cameraTarget = mix(
              cameraTarget,
              groupCenter + vec3(0, 0.45'f32, 0),
              damping(4.0'f32, dt)
            )
            cameraDistance = mix(
              cameraDistance,
              groupDistance,
              damping(2.0'f32, dt)
            )
          elif followSelection:
            followSelection = false

      let
        eye = rtsCameraEye(cameraTarget, cameraDistance)
        view = lookAt(eye, cameraTarget, vec3(0, 1, 0))
        projection = perspective(
          45.0'f32,
          window.size.x.float32 / window.size.y.float32,
          0.1,
          400.0
        )
        viewProjection = projection * view
        cameraForward = normalize(cameraTarget - eye)
        barCameraRight = normalize(cross(cameraForward, vec3(0, 1, 0)))
        barCameraUp = normalize(cross(barCameraRight, cameraForward))

      updateWorldSelection(viewProjection)

      profileBlock "drawWorld":
        # One clock for the whole frame: the palette, the sun's position,
        # and its shadow map all follow the expedition hour. The fractional
        # tick keeps the sun gliding between simulation steps instead of
        # visibly stepping shadow positions once a second.
        scene.setToonHour(
          smoothClockHour(float32(run.world.tick) + renderAlpha))
        setEnvironmentPalette(scene.toon)

        # The cutaway. Levels are baked in order from the surface down, so
        # "this floor and everything under it" is one contiguous vertex range and
        # costs a single draw call with an offset. The sun depth pass draws
        # the same range, so hidden floors above never cast down into view.
        let visibleFrom = selectedViewLevel()

        # One loop for both passes: actors and floor treasure render into
        # the sun's depth map first, then for the camera. The turn smoothing
        # and clip time advance exactly once per frame, in whichever pass
        # runs first.
        proc drawWorldActors(advanceVisuals: bool) =
          if visuals.len < run.world.actors.len:
            visuals.setLen(run.world.actors.len)
          for slot in 0 ..< run.world.actors.len:
            let actor = run.world.actors[slot]
            if actor.id == 0 or not actor.alive:
              continue
            if int(actor.home.level) < visibleFrom:
              continue     # above the cut, so not drawn
            if actor.kind == MonsterActor and not selectedVisible(actor.home):
              continue
            let
              position = actorRenderPosition(actor)
              hero = actor.kind == HeroActor
              model =
                if hero: heroModels[actor.heroClass]
                else: monsterModels[actor.species]
            if advanceVisuals:
              visuals[slot].angle = actorRenderFacing(actor)
              let wantedClip =
                if actor.busy:
                  if hero: heroAttack[actor.heroClass]
                  else: monsterAttack[actor.species]
                elif actor.moving:
                  if hero: heroRun[actor.heroClass]
                  else: monsterRun[actor.species]
                else:
                  if hero: heroIdle[actor.heroClass]
                  else: monsterIdle[actor.species]
              if visuals[slot].clip != wantedClip:
                visuals[slot].clip = wantedClip
                visuals[slot].animTime = 0
              if active:
                visuals[slot].animTime += dt * transport.speed.float32
            drawCharacter(
              scene, model, position, visuals[slot].angle,
              visuals[slot].clip, visuals[slot].animTime,
              sizeFactor = if hero: 1.0 else: 0.95)

          # Treasure still on the floor, drawn as a small spinning marker so
          # you can see what the party is walking toward.
          for item in run.world.items:
            if item.carrier != 0:
              continue
            if int(item.tile.level) < visibleFrom:
              continue
            if not selectedVisible(item.tile):
              continue
            let position = tileCenter(
              int(item.tile.level), int(item.tile.x), int(item.tile.z))
            drawCharacter(
              scene, monsterModels[SkeletonSpecies],
              position + vec3(0, 0.1, 0),
              run.world.tick.float32 * 0.02,
              monsterIdle[SkeletonSpecies], 0, color(1.0, 0.85, 0.25, 1), 0.35)

        let shadowPassRan =
          sunShadowsActive() and layerVertexRanges.len > visibleFrom
        if shadowPassRan:
          sunDepthPasses(window.size):
            drawTerrainSunDepth(
              layerVertexRanges[visibleFrom].a,
              layerVertexRanges[^1].b - layerVertexRanges[visibleFrom].a + 1
            )
            scene.sunDepthPass = true
            # The turn smoothing and clip times advance in the first pass
            # only, so both maps and the camera see the same frame.
            drawWorldActors(advanceVisuals = sunPassIndex == 0)
            scene.sunDepthPass = false

        glViewport(0, 0, window.size.x.GLsizei, window.size.y.GLsizei)
        glClearColor(0.04, 0.04, 0.06, 1)
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

        if layerVertexRanges.len > visibleFrom:
          let
            first = layerVertexRanges[visibleFrom].a
            last = layerVertexRanges[^1].b
          updateTerrainVision(int32(visibleFrom))
          drawTerrainRange(
            viewProjection,
            first,
            last - first + 1,
            showTiles
          )

        beginCharacters(scene, window, view, projection, eye)
        drawWorldActors(advanceVisuals = not shadowPassRan)
        finishCharacters(scene)
        particles.drawParticles(
          viewProjection,
          barCameraRight,
          barCameraUp,
          cameraForward
        )
        if showPaths:
          worldShapes.clear()
          worldShapes.addActorPaths(run.world, visibleFrom)
          worldShapes.draw(viewProjection)
        drawWorldBars(
          viewProjection,
          barCameraRight,
          barCameraUp,
          visibleFrom,
          dt
        )
        drawSelectedOutline(
          view,
          projection,
          eye,
          visibleFrom
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
          primaryId,
          selectedIds,
          followSelection,
          actionCam
        )
        sk.endUi()
      when defined(takeScreenshot):
        captureScreenshot(
          window,
          screenshotFrame,
          8,
          "examples/call_to_adventure/shot.png"
        )
      profileBlock "present":
        window.swapBuffers()
    if noteProfileFrame():
      when not defined(emscripten):
        window.closeRequested = true

  while not window.closeRequested:
    pollEvents()

  if not run.replayMode:
    saveRecording()
  particles.closeParticles()
  finishProfileTrace()
  echo "run ended: ", run.world.phase, " with ", run.world.banked, " gold banked"
