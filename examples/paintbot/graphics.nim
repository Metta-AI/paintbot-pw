## Painted Polyworld arena with hash-verified spectator analysis.
import std/[math, times]
import windy, opengl, vmath, chroma, jsony
import polyworld/[shapes, characters, common, toon, shadows, quadterrain, pathing]
import game, sim, analysis, villagegraphics
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
    bounds: array[4,int]
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
  territoryOverlay = true
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
  camX = clamp(x, minX().float32/100-32, maxX().float32/100-32); camZ = clamp(z, minZ().float32/100-20, maxZ().float32/100-20); distance = clamp(d, 6,
      160); yaw = angle; tilt = clamp(pitch, 0.2, 1.56)
proc setInset(value: cfloat) {.exportc: "pw_inset", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} = insetSize = clamp(value,
        0.18, 0.5)
proc setOptions(f, p, b, t: cint) {.exportc: "pw_options", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  follow = f != 0; firstPerson = p != 0; bars = b != 0; trails = t != 0
proc setTerritory(value:cint) {.exportc:"pw_territory",cdecl,
    codegenDecl:"EMSCRIPTEN_KEEPALIVE $# $#$#".} = territoryOverlay=value!=0
const teamColors = [rgbx(255, 103, 81, 255), rgbx(74, 192, 255, 255)]
proc position(p: Point, y = 0'f32): Vec3 = vec3(p.x.float32/100-32, y+(
    if replayRulesVersion >= 9: world.elevation(p).float32/100 else: 0'f32),

p.z.float32/100-20)
proc seen(i: int): bool =
  if lens < 0: return true
  if lens < Seats: return world.visible(lens, i)
  for s in 0..<Seats:
    if team(s) == lens-Seats and world.cogs[s].hp > 0 and world.visible(s,
        i): return true
proc box(r: var ShapeRenderer, x, y, z, dx, dy, dz: float32, c: ColorRGBX, yaw: float32 = 0) =
  let light = rgbx(uint8(c.r.float*0.78), uint8(c.g.float*0.78), uint8(
      c.b.float*0.78), c.a)
  let dark = rgbx(uint8(c.r.float*0.55), uint8(c.g.float*0.55), uint8(
      c.b.float*0.55), c.a)
  proc corner(u,v:float32):Vec3 =
    vec3(x+cos(yaw)*u-sin(yaw)*v,y,z+sin(yaw)*u+cos(yaw)*v)
  let a=corner(-dx,-dz);let b=corner(dx,-dz)
  let d=corner(-dx,dz);let e=corner(dx,dz)
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

proc paintball(r: var ShapeRenderer, p: Vec3, radius: float32,
    color: ColorRGBX) =
  for ring in 0..<6:
    let a = -PI.float32/2+PI.float32*ring.float32/6
    let b = -PI.float32/2+PI.float32*(ring+1).float32/6
    for j in 0..<10:
      let c = 2*PI.float32*j.float32/10
      let d = 2*PI.float32*(j+1).float32/10
      let p0 = p+vec3(cos(a)*cos(c), sin(a), cos(a)*sin(c))*radius
      let p1 = p+vec3(cos(a)*cos(d), sin(a), cos(a)*sin(d))*radius
      let p2 = p+vec3(cos(b)*cos(d), sin(b), cos(b)*sin(d))*radius
      let p3 = p+vec3(cos(b)*cos(c), sin(b), cos(b)*sin(c))*radius
      let shade = 0.65+0.35*(ring.float32/6)
      let col = rgbx(uint8(color.r.float32*shade), uint8(color.g.float32*shade),
          uint8(color.b.float32*shade), 255)
      r.addQuad(p0, p3, p2, p1, col)

proc runGraphics*() =
  setup()
  let index = if replayMode: indexReplay() else: ReplayIndex()
  let window = newWindow("Paintbot · Heartwick", ivec2(1440, 900))
  makeContextCurrent(window)
  loadExtensions()
  # Keep only a narrow scenic strip around the playable arena.
  const border = 3
  let terrainWidth = (maxX()-minX()) div 100+2*border
  let terrainDepth = (maxZ()-minZ()) div 100+2*border
  let ground = QuadLayer(originX: 32-border+minX() div 100, originZ: 44-border+minZ() div 100, width: terrainWidth, depth: terrainDepth,
      tiles: newSeq[Tile](terrainWidth*terrainDepth))
  let terraces = QuadLayer(originX: 32-border+minX() div 100, originZ: 44-border+minZ() div 100, width: terrainWidth, depth: terrainDepth,
      slab: true, tiles: newSeq[Tile](terrainWidth*terrainDepth))
  for z in 0..<terrainDepth:
    for x in 0..<terrainWidth:
      let gx = x-border+minX() div 100; let gz = z-border+minZ() div 100
      var tile = Tile(flags: TileExists or TileConnectedEast or
          TileConnectedSouth, kind: GrassTile)
      if gx < minX() div 100 or gz < minZ() div 100 or gx >= maxX() div 100 or gz >= maxZ() div 100:
        let height = (sin(x.float*0.43)*cos(z.float*0.39)*0.8+0.3).float32
        tile.tops = pack([height, height, height, height])
        if (x*17+z*31) mod 13 == 0: tile.kind = TreeTile
      elif abs(gz-20) < 3 or (gx < 12 or gx > 52) and abs(gz-20) <
          6: tile.kind = RoadTile
      if replayRulesVersion >= 7 and gx >= 0 and gz >= 0 and gx < 64 and gz < 40:
        # Market square, cross streets, and paths between cottage fronts.
        if (abs(gx-32) < 6 and abs(gz-20) < 6) or
            abs(gx-21) < 2 or abs(gx-43) < 2 or
            (gx > 10 and gx < 54 and (abs(gz-11) < 2 or abs(gz-29) < 2)):
          tile.kind = RoadTile
      if replayRulesVersion >= 8 and gx >= 0 and gz >= 0 and gx < 64 and gz < 40:
        tile.kind = GrassTile
        let winding = 20.0+2.7*sin(gx.float/7.0)
        let plaza = sqrt((gx.float-32)*(gx.float-32)+(gz.float-20)*(gz.float-20))
        if abs(gz.float-winding) < 2 or (plaza > 5.0 and plaza < 7.2):
          tile.kind = RoadTile
      if wilderness and (gx<0 or gx>=64 or gz<0 or gz>=40):
        # A continuous perimeter loop, plus open links into village streets.
        if (deepWilderness and (forestRouteDistance(gx*100,gz*100)<180 or abs(gz-20)<2)) or
            (not deepWilderness and (abs(gz+2)<=1 or abs(gz-42)<=1 or abs(gx+4)<=1 or abs(gx-68)<=1)):
          tile.kind=RoadTile
      # Dig into the terrain itself; the rim and floor share textured earth.
      for t in world.trenches:
        let cx = (t.x.float32+t.w.float32/2)/100
        let cz = (t.z.float32+t.h.float32/2)/100
        let hx = t.w.float32/200
        let hz = t.h.float32/200
        if abs(gx.float32+0.5-cx) < hx+0.65 and abs(gz.float32+0.5-cz) < hz+0.65:
          tile.kind = RoadTile
          var heights: array[4, float32]
          for corner in 0..3:
            let px = gx.float32+(corner and 1).float32
            let pz = gz.float32+(corner shr 1).float32
            # Rounded, gently irregular banks rather than a square wooden outline.
            let dx = abs(px-cx)/hx
            let dz = abs(pz-cz)/hz
            let edge = pow(pow(dx, 4)+pow(dz, 4), 0.25'f32)
            let bank = clamp((1.15'f32-edge)*2.5, 0'f32, 1'f32)
            heights[corner] = -0.6'f32*bank
          tile.tops = pack(heights)
      if replayRulesVersion >= 9:
        var heights = tile.tops.unpack
        var elevated = false
        for corner in 0..3:
          let px = gx+(corner and 1)
          let pz = gz+(corner shr 1)
          let base = terrainHeight(px*100, pz*100).float32/100
          heights[corner] += base
          if raisedHeight(px*100, pz*100) > 0: elevated = true
        if elevated:
          var deck = tile
          deck.tops = pack(heights)
          deck.bottoms = pack([-0.1'f32, -0.1, -0.1, -0.1])
          terraces.tiles[z*terrainWidth+x] = deck
          tile.tops = pack([-0.125'f32, -0.125, -0.125, -0.125])
          tile.flags = tile.flags or TileImpassable
          tile.kind = RockTile
        else:
          tile.tops = pack(heights)
      ground.tiles[z*terrainWidth+x] = tile
  layers = if replayRulesVersion >= 9: @[ground, terraces] else: @[ground]
  amplitude = 1.2
  treeHeight = 5.5
  initTerrain(MixedTrees, GeneratedTerrain, PaintedRocks)
  computeWalkable()
  scatterGrass(if deepWilderness: 1800 else: 1500, recording.seed, matchTerrain = true)
  if replayRulesVersion >= 8:
    placeRoundVillage()
  elif replayRulesVersion >= 7:
    placeVillage(world)
  else:
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
  let models = [loadCharacterModel(when defined(emscripten): "/paintbot-cog-red.glb" else: "tmp/paintbot-cog-red.glb", 1.9),
                loadCharacterModel(when defined(
                    emscripten): "/paintbot-cog-blue.glb" else: "tmp/paintbot-cog-blue.glb", 1.9)]
  for model in models: model.unlitParts = @["eye", "smile"]
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
            (not replayMode and (world.tick >= options.maximumTicks or
                world.winner != -1)): paused = true; accumulator = 0; break
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
        window.size.y).float32, 0.1'f32, 600'f32)
    let vp = projection*view
    proc actors(exclude = -1) =
      for i, c in world.cogs:
        if c.hp <= 0 or i == exclude or not seen(i): continue
        # Teammates may overlap exactly; don't put their helmet around the eye camera.
        if exclude >= 0 and distance2(c.pos, world.cogs[exclude].pos) <
            10000: continue
        let delta = vec2((c.aim.x-c.pos.x).float32, (c.aim.z-c.pos.z).float32)
        let facing = arctan2(delta.x.float32, delta.y.float32)
        let rolling = if c.pos != previous[i].pos: (
            world.tick.float32+alpha)/24 else: 0
        let lowered = if replayRulesVersion < 9 and world.trenchAt(c.pos) >=
            0: 0.55'f32 else: 0'f32
        drawCharacter(scene, models[team(i)], poses[i]-vec3(0, lowered, 0),
            facing, 0, rolling)
    if visibilityTick != world.tick or visibilityLens != lens:
      var visibility = newSeq[uint8](GridTiles*GridTiles)
      for z in 0..<GridTiles:
        for x in 0..<GridTiles:
          let p = point((x-32)*100, (z-44)*100)
          var lit = lens < 0
          if not lit:
            for s in 0..<Seats:
              if (s == lens or lens >= Seats and team(s) == lens-Seats) and
                  world.canSeePoint(s, p): lit = true; break
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
      let age = world.tick.float32+alpha-event.tick.float32
      if event.kind != "tag" or age < 0 or age >= 48: continue
      let fade = 1-age/48
      if lens >= 0 and not seen(event.victim): continue
      let p = position(point(event.x, event.z), 0.035)
      let color = teamColors[event.side]
      shapes.addCircle(p, 0.6, rgbx(color.r, color.g, color.b, uint8(110*fade)))
      for n in 0..4:
        let a = n.float32*1.256+event.slot.float32
        shapes.addCircle(p+vec3(cos(a)*0.65, 0.001, sin(a)*0.65), 0.17, rgbx(
            color.r, color.g, color.b, uint8(120*fade)))
        if age < 18:
          let f = age.float32/18
          shapes.gem(p+vec3(cos(a)*f*1.8, sin(f*PI.float32)*1.2+0.2, sin(
              a)*f*1.8), 0.11, color)
    # Every damaging hit splashes the victim, including armor hits and survivors.
    for hit in index.hits:
      let age=world.tick.float32+alpha-hit.tick.float32
      if age<0 or age>=14 or not seen(hit.victim):continue
      let fade=1-age/14
      let center=(if world.cogs[hit.victim].hp>0:poses[hit.victim]
          else:position(point(hit.x,hit.z)))+vec3(0,1.3,0)
      let front=center+normalize(eye-center)*0.5
      let color=if hit.side==0:rgbx(255,103,112,255) else:rgbx(83,218,255,255)
      shapes.paintball(front,0.36*fade,color)
      for drop in 0..<7:
        let angle=drop.float32*0.8976+hit.slot.float32
        let spread=0.28+age*0.045
        let offset=vec3(cos(angle)*spread,sin(angle)*spread-age*0.025,
            sin(angle*2)*0.18)
        shapes.paintball(front+offset,(0.11+(drop mod 3).float32*0.035)*fade,color)
    # Brass boundary rails make the playable rectangle explicit within the grove.
    for z in [minZ().float32/100-20, maxZ().float32/100-20]: shapes.box(0, 0, z, (maxX()-minX()).float32/200, 0.16, 0.07, rgbx(217,
        187, 111, 255))
    for x in [minX().float32/100-32, maxX().float32/100-32]: shapes.box(x, 0, 0, 0.07, 0.16, (maxZ()-minZ()).float32/200, rgbx(217,
        187, 111, 255))
    for item in world.pickups:
      if item.readyAt > world.tick: continue
      if lens >= 0:
        var lit = false
        for seat in 0..<Seats:
          if (seat == lens or lens >= Seats and team(seat) == lens-Seats) and
              world.canSeePoint(seat, item.pos): lit = true
        if not lit: continue
      let special = item.kind in {grenadePickup,sprayPickup}
      let spin = (world.tick.float32+alpha)*0.045
      let p = position(item.pos, if special: 0.7+0.15*sin(spin*1.7) else: 0.28)
      let color = case item.kind
        of grenadePickup: rgbx(148, 165, 73, 255)
        of sprayPickup: rgbx(243, 160, 57, 255)
        of armorPickup: rgbx(96, 191, 241, 255)
        of medkitPickup: rgbx(243, 238, 207, 255)
      shapes.addCircle(position(item.pos, 0.04), if special: 1.0 else: 0.55, color)
      if special:
        shapes.box(p.x,p.y,p.z,0.55,1.05,0.4,color,spin)
        shapes.box(p.x,p.y+1.05,p.z,0.24,0.22,0.18,rgbx(234,240,224,255),spin)
        # An offset nozzle/lever makes rotation readable from above.
        shapes.box(p.x+cos(spin)*0.32,p.y+1.24,p.z+sin(spin)*0.32,
            0.35,0.13,0.12,rgbx(61,77,67,255),spin)
      else:
        shapes.box(p.x, p.y, p.z, 0.4, 0.48, 0.32, color,
            if item.kind == medkitPickup: spin else: 0'f32)
      if item.kind == medkitPickup:
        shapes.box(p.x, p.y+0.49, p.z, 0.26, 0.03, 0.08, rgbx(215, 69, 66, 255), spin)
        shapes.box(p.x, p.y+0.49, p.z, 0.08, 0.03, 0.26, rgbx(215, 69, 66, 255), spin)

    for g in world.grenades:
      let f = clamp((world.tick-g.releasedAt).float32/max(1,
          g.landsAt-g.releasedAt).float32, 0, 1)
      let p = mix(position(g.start, 1), position(g.target, 0.1), f)+vec3(0, sin(
          f*PI.float32)*3, 0)
      shapes.gem(p, 0.21, rgbx(157, 175, 66, 255))
      shapes.addCircle(position(g.target, 0.05), 0.24, rgbx(192, 161, 85, 160))
    for b in world.blasts:
      let age=clamp((world.tick.float32+alpha-b.tick.float32)/24,0'f32,1'f32)
      let bloom=min(age/0.18,1'f32)
      let settle=clamp((age-0.18)/0.72,0'f32,1'f32)
      let palette=if team(b.owner.int)==0:
        [rgbx(255,91,93,255),rgbx(255,168,57,255),rgbx(245,74,155,255)]
      else:
        [rgbx(67,203,255,255),rgbx(72,231,193,255),rgbx(164,127,255,255)]
      # Deterministic paint puffs: fast expansion, then a brief falling cloud.
      for n in 0..<16:
        let angle=n.float32*2.39996+b.owner.float32*0.7
        let reach=(0.55+(n mod 5).float32*0.4)*bloom
        var spot=point(b.pos.x.int+int(cos(angle)*reach*100),
            b.pos.z.int+int(sin(angle)*reach*100))
        if b.trench>=0:
          let trench=world.trenches[b.trench]
          spot.x=clamp(spot.x,trench.x+15,trench.x+trench.w-15)
          spot.z=clamp(spot.z,trench.z+15,trench.z+trench.h-15)
        let floor=position(spot,0.065)
        let height=(0.9+(n mod 4).float32*0.32)*bloom*(1-settle)*(1-settle)
        let radius=(0.26+0.34*bloom)*(1-settle*0.85)
        if age<0.9:
          shapes.paintball(floor+vec3(0,height+radius*0.5,0),radius,palette[n mod 3])
        # Irregular droplets flatten into paint as the cloud comes down.
        let stain=clamp((age-0.3)/0.35,0'f32,1'f32)*(1-age)
        if stain>0:
          shapes.addCircle(floor,(0.22+(n mod 3).float32*0.13)*stain,palette[n mod 3])
    for i, e in world.equipment:
      if world.cogs[i].hp <= 0 or not seen(i): continue
      let c = world.cogs[i]
      if e.charge > 0: shapes.addCircle(position(world.grenadeTarget(i), 0.08),
          GrenadeBlastRadius.float32/100, rgbx(229, 199, 88, 255))
      if e.burst > 0:
        for n in 1..10:
          let f = n.float32/10
          let p = Point(x: c.pos.x+e.sprayAim.x*n.int32 div 10,
              z: c.pos.z+e.sprayAim.z*n.int32 div 10)
          if not world.lineClear(c.pos, p): break
          shapes.gem(position(p, 0.9), 0.14+f*1.0, teamColors[team(i)])
      if e.grenade: shapes.gem(poses[i]+vec3(-0.45, 1.0, -0.3), 0.19, rgbx(157,
          175, 66, 255))
      if e.sprayCan: shapes.box(poses[i].x+0.5, poses[i].y+0.75, poses[i].z,
          0.3, 0.5, 0.25, rgbx(241, 175, 70, 255))
      for hp in 0..<e.armor: shapes.box(poses[i].x-0.3+hp.float32*0.25, poses[
          i].y+2.1, poses[i].z, 0.16, 0.09, 0.09, rgbx(65, 203, 245, 255))
    if world.controlHearts.len>0:
      if territoryOverlay:
        for z in countup(minZ(),maxZ()-200,200):
          for x in countup(minX(),maxX()-200,200):
            let center=point(x+100,z+100)
            var nearest=0
            for i,h in world.controlHearts:
              if distance2(center,h.pos)<distance2(center,world.controlHearts[nearest].pos):nearest=i
            let owner=world.controlHearts[nearest].owner
            let color=if owner<0:rgbx(150,155,160,55) else:rgbx(teamColors[owner].r,teamColors[owner].g,teamColors[owner].b,85)
            shapes.addQuad(position(point(x,z),0.09),position(point(x,z+200),0.09),
              position(point(x+200,z+200),0.09),position(point(x+200,z),0.09),color)
      for heart in world.controlHearts:
        let color=if heart.owner<0:rgbx(170,179,188,255) else:teamColors[heart.owner]
        let base=position(heart.pos,0.08)
        shapes.addCircle(base,1.4,color)
        shapes.addCircle(base+vec3(0,0.01,0),1.13,rgbx(47,63,58,255))
        let p=position(heart.pos,1.4+sin((world.tick.float32+alpha)/12)*0.12)
        shapes.gem(p,0.7,color)
        shapes.gem(p+vec3(-0.28,0.32,0),0.4,color)
        shapes.gem(p+vec3(0.28,0.32,0),0.4,color)
    else:
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
      if c.cooldown >= (if replayRulesVersion >=
          3: FireCooldownTicks-1 else: 7): shapes.gem(p+vec3(d.x.float32/100,
          1.05, d.z.float32/100), 0.23, rgbx(255, 239, 177, 255))
      if c.shield > 0: shapes.addCircle(p+vec3(0, 0.09, 0), 0.75, rgbx(196, 241,
          243, 95))
      if trails:
        shapes.addLine(p+vec3(0, 0.08, 0), position(c.goal, 0.08), teamColors[
            team(i)], halfWidth = 0.035)
      if bars:
        for hp in 0..<c.hp: shapes.box(p.x-0.35+hp.float32*0.28, p.y+2.5, p.z,
            0.1, 0.09, 0.09, rgbx(221, 253, 180, 255))
    for b in world.balls:
      if lens >= 0 and not seen(b.owner.int): continue
      let start = point(b.pos.x-b.velocity.x, b.pos.z-b.velocity.z)
      let duration = if replayRulesVersion >= 9: 6'f32 else: 2'f32
      let f = clamp((duration-b.life.float32+alpha)/duration, 0'f32, 1'f32)
      # Four visible beads represent one shot; hit resolution stays unchanged.
      for bead in 0..3:
        let travel=f-bead.float32*0.055
        if travel<0:continue
        let ball=mix(position(start,1.05),position(b.pos,1.05),travel)
        let color=if team(b.owner.int)==0:rgbx(255,108,74,255) else:rgbx(89,220,255,255)
        shapes.paintball(ball,0.32-bead.float32*0.035,color)
        shapes.paintball(ball+vec3(-0.07,0.12,-0.04),0.085,rgbx(255,250,214,255))
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
        let payload = ViewerState(world: world, bounds: [minX(),minZ(),maxX(),maxZ()], total: recording.frames.len,
            paused: paused, screen: screens, visible: visibility,
            footprint: footprint).toJson()
        let data = payload.cstring
        let tick = world.tick
        {.emit: "EM_ASM({if(Module.polyworldFrame)Module.polyworldFrame($1,0);if(Module.paintbotState)Module.paintbotState(JSON.parse(UTF8ToString($0)));}, `data`, `tick`);".}
        lastHud = world.tick
  while not window.closeRequested: pollEvents()
