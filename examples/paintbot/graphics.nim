## Painted Polyworld arena with hash-verified spectator analysis.
import std/[math, times, tables]
import windy, opengl, vmath, chroma, jsony
import polyworld/[shapes, characters, common, toon, shadows, quadterrain, pathing]
import game, sim, analysis
when defined(emscripten): {.emit: "#include <emscripten.h>\n#include <emscripten/html5.h>".}
else: {.emit: "#define EMSCRIPTEN_KEEPALIVE".}
type
  ViewerIndex = object
    events: seq[Moment]
    momentum: seq[Sample]
    names: array[Seats, string]
    communications: seq[Communication]
    seed: int32
  ViewerState = object
    world: World
    total: int
    paused: bool
    screen: array[Seats, array[2, float32]]
    visible: array[Seats, bool]
    footprint: array[4, array[2, float32]]
var
  paused = false
  speed = 1
  seek = -1
  selected = -1
  lens = -1
  follow = false
  firstPerson = false
  insetSize = 0.25'f32
  bars = true
  trails = false
  camX = 0'f32
  camZ = 0'f32
  distance = 60'f32
  yaw = 0'f32
  tilt = 0.92'f32
proc setPlaying(value: cint) {.exportc: "pw_play", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} = paused = value == 0
proc setSpeed(value: cint) {.exportc: "pw_speed", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} = speed = clamp(value.int, 1, 32)
proc setTick(value: cint) {.exportc: "pw_seek", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} = seek = max(0, value.int)
proc selectSeat(value: cint) {.exportc: "pw_select", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} = selected = clamp(value.int,
    -1, Seats-1)
proc setView(value: cint) {.exportc: "pw_lens", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} = lens = clamp(value.int, -1, Seats+1)
proc setCamera(x, z, d, angle, pitch: cfloat) {.exportc: "pw_camera", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  camX = clamp(x, -40, 40); camZ = clamp(z, -28, 28); distance = clamp(d, 6,
      100); yaw = angle; tilt = clamp(pitch, 0.2, 1.56)
proc setInset(value: cfloat) {.exportc: "pw_inset", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} = insetSize = clamp(value, 0.18, 0.5)
proc setOptions(f, p, b, t: cint) {.exportc: "pw_options", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  follow = f != 0; firstPerson = p != 0; bars = b != 0; trails = t != 0
const teamColors = [rgbx(255, 103, 81, 255), rgbx(74, 192, 255, 255)]
proc position(p: Point, y = 0'f32): Vec3 = vec3(p.x.float32/100-32, y,
    p.z.float32/100-20)
proc seen(i: int): bool =
  if lens < 0: return true
  if lens < Seats: return world.visible(lens, i)
  for s in 0..<Seats:
    if team(s) == lens-Seats and world.cogs[s].hp > 0 and world.visible(s,
        i): return true
proc box(r: var ShapeRenderer, x, y, z, dx, dy, dz: float32, c: ColorRGBX) =
  let light = rgbx(uint8(c.r.float*0.78), uint8(c.g.float*0.78), uint8(
      c.b.float*0.78), c.a)
  let dark = rgbx(uint8(c.r.float*0.55), uint8(c.g.float*0.55), uint8(
      c.b.float*0.55), c.a)
  let a = vec3(x-dx, y, z-dz); let b = vec3(x+dx, y, z-dz)
  let d = vec3(x-dx, y, z+dz); let e = vec3(x+dx, y, z+dz)
  let up = vec3(0, dy, 0)
  r.addQuad(a, b, e, d, c)
  r.addQuad(a+up, d+up, e+up, b+up, c)
  r.addQuad(a, a+up, b+up, b, light)
  r.addQuad(b, b+up, e+up, e, dark)
  r.addQuad(e, e+up, d+up, d, light)
  r.addQuad(d, d+up, a+up, a, dark)
proc gem(r: var ShapeRenderer, p: Vec3, s: float32, c: ColorRGBX) =
  let top = p+vec3(0, s, 0); let bottom = p-vec3(0, s, 0)
  let ring = [p+vec3(s, 0, 0), p+vec3(0, 0, s), p+vec3(-s, 0, 0), p+vec3(0, 0, -s)]
  for i in 0..3:
    r.addTriangle(top, ring[i], ring[(i+1) mod 4], c)
    r.addTriangle(bottom, ring[(i+1) mod 4], ring[i], c)

proc runGraphics*() =
  setup()
  let index = if replayMode: indexReplay() else: ReplayIndex()
  let window = newWindow("Paintbot · The Painted Grove", ivec2(1440, 900))
  makeContextCurrent(window)
  loadExtensions()
  # The playable surface stays perfectly flat. Scenic elevation is outside it.
  let ground = QuadLayer(originX: 24, originZ: 36, width: 80, depth: 56,
      tiles: newSeq[Tile](80*56))
  for z in 0..<56:
    for x in 0..<80:
      let gx = x-8; let gz = z-8
      var tile = Tile(flags: TileExists or TileConnectedEast or
          TileConnectedSouth, kind: GrassTile)
      if gx < 0 or gz < 0 or gx >= 64 or gz >= 40:
        let height = (sin(x.float*0.43)*cos(z.float*0.39)*0.8+0.3).float32
        tile.tops = pack([height, height, height, height])
        if (x*17+z*31) mod 13 == 0: tile.kind = TreeTile
      elif abs(gz-20) < 3 or (gx < 12 or gx > 52) and abs(gz-20) <
          6: tile.kind = RoadTile
      ground.tiles[z*80+x] = tile
  layers = @[ground]
  amplitude = 1.2
  treeHeight = 5.5
  initTerrain(DenseTrees, GeneratedTerrain, PaintedRocks)
  computeWalkable()
  scatterGrass(1500, recording.seed, matchTerrain = true)
  bakeTerrain(rebuildWalkability = false)
  let coverPack = loadPropPack(when defined(
      emscripten): "/paintbot-cover.glb" else: "tmp/paintbot-cover.glb",
      unitHeight = false, textured = true, repeatTexture = true)
  for c in world.cover:
    coverPack.placeProp("cover", vec3((c.x+c.w div 2).float32/100-32, 0, (
        c.z+c.h div 2).float32/100-20))
  bakeTerrain(rebuildWalkability = false)
  let scene = newCharacterScene(window)
  scene.useToonShading()
  scene.setToonHour(15.4)
  setEnvironmentPalette(scene.toon)
  let model = loadModularCharacterModel(DataRoot &
      "/characters/modular_chars/character.glb", ["Body_Yellow_1",
      "Body_Yellow_Head_3", "Chest_14", "Foot_14", "Hand_14", "Head_14",
      "Leg_14", "Eye_BlueB_1", "Mouth_Yellow_2"], 2.0)
  let runClip = model.clipIndex("Run")
  let idleClip = model.clipIndex("Idle")
  var shapes = initShapeRenderer()
  var last = epochTime()
  var accumulator = 0.0
  var previous = world.cogs
  var announced = false
  var lastHud = -1
  var visibilityTick = -1
  var visibilityLens = -2
  window.onFrame = proc() =
    let now = epochTime(); let dt = min(now-last, 0.1); last = now
    if replayMode and seek >= 0:
      index.restore(seek); seek = -1; accumulator = 0; previous = world.cogs
      if world.tick == recording.frames.len: paused = true
    if not paused:
      accumulator+=dt*TickRate.float*speed.float
      var steps = 0
      while accumulator >= 1 and steps < 96:
        if (replayMode and world.tick >= recording.frames.len) or
            (not replayMode and (world.tick >= options.maximumTicks or world.winner >= 0)): paused = true; accumulator = 0; break
        previous = world.cogs
        advance(); accumulator-=1; inc steps
    let alpha = if paused: 1'f32 else: clamp(accumulator.float32, 0, 1)
    var poses: array[Seats, Vec3]
    for i, c in world.cogs:
      poses[i] = if previous[i].hp > 0 and c.hp > 0: mix(position(previous[
          i].pos), position(c.pos), alpha) else: position(c.pos)
    if follow and selected >= 0:
      camX = poses[selected].x; camZ = poses[selected].z
    let target = vec3(camX, 0, camZ)
    let fittedDistance = distance*max(1'f32, 1.6'f32/(window.size.x.float32/max(
        1, window.size.y).float32))
    let eye = target+vec3(sin(yaw)*cos(tilt), sin(tilt), cos(yaw)*cos(
        tilt))*fittedDistance
    let view = lookAt(eye, target, vec3(0, 1, 0))
    let projection = perspective(45'f32, window.size.x.float32/max(1,
        window.size.y).float32, 0.1'f32, 250'f32)
    let vp = projection*view
    proc actors(exclude = -1) =
      for i, c in world.cogs:
        if c.hp <= 0 or i == exclude or not seen(i): continue
        # Teammates may overlap exactly; don't put their helmet around the eye camera.
        if exclude >= 0 and distance2(c.pos, world.cogs[exclude].pos) <
            10000: continue
        let delta = vec2((c.aim.x-c.pos.x).float32, (c.aim.z-c.pos.z).float32)
        let facing = arctan2(delta.x.float32, delta.y.float32)
        let clip = if c.pos != previous[i].pos: runClip else: idleClip
        drawCharacter(scene, model, poses[i], facing, clip, (
            world.tick.float32+alpha)/24,
          tint = if team(i) == 0: color(1, 0.52, 0.37, 1) else: color(0.38,
              0.72, 1, 1))
    if visibilityTick != world.tick or visibilityLens != lens:
      var visibility = newSeq[uint8](GridTiles*GridTiles)
      for z in 0..<GridTiles:
        for x in 0..<GridTiles:
          let p = point((x-32)*100, (z-44)*100)
          var lit = lens < 0
          if not lit:
            for s in 0..<Seats:
              if (s == lens or lens >= Seats and team(s) == lens-Seats) and
                  world.cogs[s].hp > 0 and distance2(world.cogs[s].pos, p) <=
                  VisionRange.int64*VisionRange and world.lineClear(world.cogs[
                  s].pos, p): lit = true; break
          visibility[z*GridTiles+x] = if lit: 255'u8 else: 65'u8
      uploadTerrainVisibility(visibility)
      visibilityTick = world.tick; visibilityLens = lens
    sunDepthPasses(window.size):
      drawTerrainSunDepth()
      scene.sunDepthPass = true; actors(); scene.sunDepthPass = false
    glViewport(0, 0, window.size.x.GLsizei, window.size.y.GLsizei)
    glClearColor(0.08, 0.13, 0.15, 1)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
    scene.toon.drawBackground()
    drawTerrain(vp)
    beginCharacters(scene, window, view, projection, eye)
    actors(); finishCharacters(scene)
    shapes.clear()
    # Low stone courses exactly match collision bounds; capstones and stripes read at a glance.
    # Paint splashes and short bursts follow recorded tags, so seeking reconstructs them.
    for event in index.events:
      let age = world.tick-event.tick
      if event.kind != "tag" or age < 0 or age > 480: continue
      if lens >= 0 and not seen(event.victim): continue
      let p = position(point(event.x, event.z), 0.035)
      let color = teamColors[event.side]
      shapes.addCircle(p, 0.6, rgbx(color.r, color.g, color.b, 110))
      for n in 0..4:
        let a = n.float32*1.256+event.slot.float32
        shapes.addCircle(p+vec3(cos(a)*0.65, 0.001, sin(a)*0.65), 0.17, rgbx(
            color.r, color.g, color.b, 120))
        if age < 18:
          let f = age.float32/18
          shapes.gem(p+vec3(cos(a)*f*1.8, sin(f*PI.float32)*1.2+0.2, sin(
              a)*f*1.8), 0.11, color)
    # Brass boundary rails make the playable rectangle explicit within the grove.
    for z in [-20'f32, 20'f32]: shapes.box(0, 0, z, 32, 0.16, 0.07, rgbx(217,
        187, 111, 255))
    for x in [-32'f32, 32'f32]: shapes.box(x, 0, 0, 0.07, 0.16, 20, rgbx(217,
        187, 111, 255))
    for side in 0..1:
      let h = position(home(side))
      shapes.addCircle(h+vec3(0, 0.04, 0), 2.3, rgbx(45, 69, 64, 255))
      shapes.addCircle(h+vec3(0, 0.06, 0), 1.65, teamColors[side])
      shapes.addCircle(h+vec3(0, 0.07, 0), 1.45, rgbx(56, 76, 71, 255))
      let heart = world.hearts[side]
      if heart.carrier < 0 or seen(heart.carrier):
        let hp = position(heart.pos, if heart.carrier < 0: 1.45+sin(
            world.tick.float32/12)*0.12 else: 3.1)
        shapes.gem(hp, 0.62, teamColors[side])
        shapes.gem(hp+vec3(-0.25, 0.3, 0), 0.36, teamColors[side])
        shapes.gem(hp+vec3(0.25, 0.3, 0), 0.36, teamColors[side])
    for i, c in world.cogs:
      if c.hp <= 0 or not seen(i): continue
      let p = poses[i]
      shapes.addCircle(p+vec3(0, 0.04, 0), 0.65, teamColors[team(i)])
      shapes.addCircle(p+vec3(0, 0.05, 0), 0.48, rgbx(43, 68, 55, 255))
      if i == selected: shapes.addCircle(p+vec3(0, 0.03, 0), 0.9, rgbx(250, 226,
          140, 180))
      let d = direction(c.pos, c.aim, 105)
      shapes.addLine(p+vec3(0, 1.05, 0), p+vec3(d.x.float32/100, 1.05,
          d.z.float32/100), rgbx(49, 60, 66, 255), halfWidth = 0.13)
      if c.cooldown >= 7: shapes.gem(p+vec3(d.x.float32/100, 1.05,
          d.z.float32/100), 0.23, rgbx(255, 239, 177, 255))
      if c.shield > 0: shapes.addCircle(p+vec3(0, 0.09, 0), 0.75, rgbx(196, 241,
          243, 95))
      if trails:
        shapes.addLine(p+vec3(0, 0.08, 0), position(c.goal, 0.08), teamColors[
            team(i)], halfWidth = 0.035)
      if bars:
        for hp in 0..<c.hp: shapes.box(p.x-0.35+hp.float32*0.28, 2.5, p.z, 0.1,
            0.09, 0.09, rgbx(221, 253, 180, 255))
    for b in world.balls:
      if lens >= 0 and not seen(b.owner.int): continue
      shapes.addLine(position(b.pos, 1), position(point(
          b.pos.x-b.velocity.x div 2, b.pos.z-b.velocity.z div 2), 1),
          teamColors[team(b.owner.int)], halfWidth = 0.06)
      shapes.gem(position(b.pos, 1), 0.14, teamColors[team(b.owner.int)])
    shapes.draw(vp)
    # A real second 3D camera gives the selected bot's eye-level view.
    if firstPerson and selected >= 0 and world.cogs[selected].hp > 0:
      let c = world.cogs[selected]
      let p = poses[selected]+vec3(0, 1.5, 0)
      let d = direction(c.pos, c.aim, 100)
      let forward = vec3(d.x.float32/100, 0, d.z.float32/100)
      let v = lookAt(p, p+forward, vec3(0, 1, 0))
      let proj = perspective(78'f32, 1.6'f32, 0.15'f32, 180'f32)
      let wi = (window.size.x.float32*insetSize).int; let he = wi*5 div 8
      var ratio = 1'f32
      when defined(emscripten):
        {.emit: "`ratio`=emscripten_get_device_pixel_ratio();".}
      let right = (24*ratio).int
      let top = (100*ratio).int
      glEnable(GL_SCISSOR_TEST)
      glScissor((window.size.x-wi-right).GLint, (window.size.y-he-top).GLint,
          wi.GLsizei, he.GLsizei)
      glViewport((window.size.x-wi-right).GLint, (window.size.y-he-top).GLint,
          wi.GLsizei, he.GLsizei)
      glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
      scene.toon.drawBackground()
      drawTerrain(proj*v)
      beginCharacters(scene, window, v, proj, p)
      glViewport((window.size.x-wi-right).GLint, (window.size.y-he-top).GLint,
          wi.GLsizei, he.GLsizei)
      actors(selected); finishCharacters(scene)
      shapes.draw(proj*v)
      glDisable(GL_SCISSOR_TEST)
    window.swapBuffers()
    when defined(emscripten):
      if not announced:
        let payload = ViewerIndex(events: index.events,
            momentum: index.momentum, names: recording.names,
            communications: recording.communications,
            seed: recording.seed).toJson()
        let data = payload.cstring
        {.emit: "EM_ASM({if(Module.paintbotIndex)Module.paintbotIndex(JSON.parse(UTF8ToString($0)));}, `data`);".}
        announced = true
      if lastHud != world.tick or paused:
        var screens: array[Seats, array[2, float32]]
        var visibility: array[Seats, bool]
        var footprint: array[4, array[2, float32]]
        let inverse = vp.inverse
        for i, corner in [vec2(-1, -1), vec2(1, -1), vec2(1, 1), vec2(-1, 1)]:
          let a = inverse*vec4(corner.x, corner.y, -1, 1)
          let b = inverse*vec4(corner.x, corner.y, 1, 1)
          let origin = vec3(a.x, a.y, a.z)/a.w
          let ray = vec3(b.x, b.y, b.z)/b.w-origin
          let point = origin+ray*clamp(-origin.y/ray.y, 0'f32, 1'f32)
          footprint[i] = [point.x, point.z]
        for i in 0..<Seats:
          visibility[i] = seen(i)
          let clip = vp*vec4(poses[i]+vec3(0, 1, 0), 1)
          screens[i] = [(clip.x/clip.w*0.5+0.5).float32, (
              0.5-clip.y/clip.w*0.5).float32]
        let payload = ViewerState(world: world, total: recording.frames.len,
            paused: paused, screen: screens, visible: visibility,
            footprint: footprint).toJson()
        let data = payload.cstring
        let tick = world.tick
        {.emit: "EM_ASM({if(Module.polyworldFrame)Module.polyworldFrame($1,0);if(Module.paintbotState)Module.paintbotState(JSON.parse(UTF8ToString($0)));}, `data`, `tick`);".}
        lastHud = world.tick
  while not window.closeRequested: pollEvents()
