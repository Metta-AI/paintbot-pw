## Painted Polyworld arena with hash-verified spectator analysis.
import std/[math, times, algorithm, strutils]
when defined(emscripten) and defined(workerReplayIndex): import flatty
import windy, opengl, vmath, chroma, jsony, gltf
import polyworld/[shapes, characters, common, toon, shadows, quadterrain, pathing, actioncam, selectionoutlines]
import game, sim, analysis, villagegraphics, controls, celebration, projection, kinhue
from kinship import activeKinship, rPercent
import polyworld/[player, tapes]
when defined(emscripten): {.emit: "#include <emscripten.h>\n#include <emscripten/html5.h>".}
else: {.emit: "#define EMSCRIPTEN_KEEPALIVE".}
type
  ViewerIndex = object
    events: seq[Moment]
    momentum: seq[Sample]
    names: array[Seats, string]
    communications: seq[Communication]
    seed: int32
  CogTerrain = object
    elevation, trench, spread: int
    territoryBoost: int # FFA-kin territory boost in percent (sim.territoryBoost); 0 in teams
  Inspectable = object
    kind: string
    id: int
    bottom, top: array[2, float32]
  ViewerState = object
    terrain: array[Seats, CogTerrain]
    objects: seq[Inspectable]
    heartHeld: seq[int]
    heartValues: seq[int32]
    combat: array[Seats, CombatStats]
    rulesVersion: int
    maxHp: int32 # 3, or FfaMaxHp in FFA-kin: the HUD's "hp / max".
    world: World
    bounds: array[4,int]
    recorded: int
    total: int
    live: bool
    playerSlot: int
    paused: bool
    celebrating: bool
    celebrationSeconds: float32
    actionCamera: bool
    camera: array[3, float32]
    screen: array[Seats, array[2, float32]]
    visible: array[Seats, bool]
    footprint: array[4, array[2, float32]]
    # FFA-kin (mode "ffa_kin"); empty in the teams game. Raw scores, heart-seconds, great-heart
    # shares and great hearts travel inside world.
    mode: string
    family: seq[int] # family id per seat, -1 = loner
    genes: seq[uint32]
    rPct: seq[array[Seats, int32]] # round(100 r), row = seat
    kinHue: seq[float32] # family hue in degrees, -1 = loner (grey)
    map: string ## rules 41: the map's name, or "" for the rules' own island
    staticOmitted: bool ## family, genes, rPct, kinHue and world.cover are as in the last state
    land: string ## rules 41 maps, first state only: '1' per dry-land metre cell, row-major
var hudStaticSent = false ## the first viewer state (with the static tables) has gone out
proc landMask(): string =
  ## The minimap's coastline for a map, sent once; the island's own coast is computed in JS.
  var sent {.global.} = false
  if activeMap() < 0 or sent: return
  sent = true
  for z in countup(minZ(), maxZ()-1, 100):
    for x in countup(minX(), maxX()-1, 100):
      result.add(if islandMargin(x+50, z+50) >= 40: '1' else: '0')
var
  kinHues: array[Seats, float32] # FFA-kin family hue per seat; set once the match is loaded.
  kinRgb: array[Seats, ColorRGBX] # kinHues as colours, cached with them (hues are fixed per match).
  transport: Player
  victory: Celebration
  playbackRate = 1'f32
  orderX, orderY: float32
  orderKind = 0
  orderSeat = -1
  inspectedKind = 0
  inspectedId = -1
  selected = -1
  lens = -1
  follow = false
  autoCamera = true
  director = initActionCam(minDistance = 26, maxDistance = 150, tight = 0.6,
    followRate = 1.0, zoomRate = 0.7, holdSeconds = 2.8, mapSpan = 160)
  directorTick = -1
  directorLens = -2
  camY = 0'f32
  firstPerson = false
  territoryOverlay = false
  territoryNearest: seq[int16] ## per 200-unit overlay cell: nearest control heart, -1 off the island
  territoryKey = (-2, -1, -1) ## (map, heart count, rules) territoryNearest was built for
  insetSize = 0.25'f32
  bars = true
  trails = false
  camX = 0'f32
  camZ = 0'f32
  distance = 60'f32
  yaw = 0'f32
  tilt = 0.92'f32
proc setPlaying(value: cint) {.exportc: "pw_play", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  if victory.active: victory.paused = value == 0
  elif value == 0: transport.pause()
  else: transport.play()
proc setSpeed(value: cfloat) {.exportc: "pw_speed", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  playbackRate = clamp(value, 0.25, 32)
  transport.setSpeed(speedIndexOf(value.int32))
proc setTick(value: cint) {.exportc: "pw_seek", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  victory = Celebration()
  transport.seekTo(value.int32, play = false)
proc saveLiveRecording() {.exportc: "pw_save", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  if not replayMode:
    saveRecording("/human.replay", recording)
proc chargeGrenade(held: cint) {.exportc: "pw_charge", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  setGrenadeCharge(held != 0 and options.playerSlot > 0 and not replayMode and not transport.inHistory)
proc sneak(held: cint) {.exportc: "pw_sneak", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  setSneaking(held != 0 and options.playerSlot > 0 and not replayMode and not transport.inHistory)
proc issueOrder(x, y: cfloat, kind, seat: cint) {.exportc: "pw_order", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  if options.playerSlot > 0 and not replayMode and not transport.inHistory:
    orderX = x; orderY = y; orderKind = kind.int; orderSeat = seat.int
proc selectSeat(value: cint) {.exportc: "pw_select", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} = selected = clamp(value.int,
    -1, Seats-1)
var kinFocus = 0 ## FFA-kin: seats of the families picked in the header (bit i = seat i).
proc setKinFocus(mask: cint) {.exportc: "pw_kin_focus", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} = kinFocus = mask.int and 0xFFFF
proc inspectObject(kind, id: cint) {.exportc: "pw_inspect", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  inspectedKind = kind.int
  inspectedId = id.int
proc setView(value: cint) {.exportc: "pw_lens", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} = lens = clamp(value.int, -1, Seats+1)
proc setCamera(x, z, d, angle, pitch: cfloat) {.exportc: "pw_camera", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  autoCamera = false
  camY = 0
  camX = clamp(x, minX().float32/100-32, maxX().float32/100-32); camZ = clamp(z, minZ().float32/100-20, maxZ().float32/100-20); distance = clamp(d, 6,
      160); yaw = angle; tilt = clamp(pitch, 0.2, 1.56)
proc setInset(value: cfloat) {.exportc: "pw_inset", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} = insetSize = clamp(value,
        0.18, 0.5)
proc setOptions(f, p, b, t: cint) {.exportc: "pw_options", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  if f != 0: autoCamera = false
  follow = f != 0; firstPerson = p != 0; bars = b != 0; trails = t != 0
proc setActionCamera(value: cint) {.exportc: "pw_action_camera", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  autoCamera = value != 0
  if autoCamera: follow = false
  director = initActionCam(minDistance = 26, maxDistance = 150, tight = 0.6,
    followRate = 1.0, zoomRate = 0.7, holdSeconds = 2.8,
    mapSpan = (maxX()-minX()).float32/100)
  directorTick = -1
  directorLens = lens
proc setTerritory(value:cint) {.exportc:"pw_territory",cdecl,
    codegenDecl:"EMSCRIPTEN_KEEPALIVE $# $#$#".} = territoryOverlay=value!=0
const teamColors = [rgbx(255, 103, 81, 255), rgbx(74, 192, 255, 255)]
const lonerColor = rgbx(150, 155, 160, 255)
proc kinColor(seat: int, alpha = 255'u8): ColorRGBX =
  ## FFA-kin: the seat's family hue; loners are grey.
  let c = if seat in 0..<Seats: kinRgb[seat] else: lonerColor
  rgbx(c.r, c.g, c.b, alpha)
proc seatColor(seat: int): ColorRGBX =
  ## Paint colour of a seat: its team in the teams game, its family in FFA-kin.
  if ffa(): kinColor(seat) else: teamColors[team(seat)]
proc kinPercent(a, b: int): int32 =
  ## round(100 r) between two seats in FFA-kin; 0 in the teams game.
  if ffa() and a in 0..<Seats and b in 0..<Seats: activeKinship.rPercent(a, b) else: 0
proc kinEmphasis(i: int): tuple[dim: bool, halo: int] =
  ## FFA-kin cog emphasis, as kinhud.js cogEmphasis. Kin view (a selected cog) wins: kin get a
  ## halo as bright as r and the unrelated dim. Otherwise, with families picked in the header,
  ## their cogs get a halo and every other cog dims. Halo is an alpha, 0 for none.
  if selected >= 0:
    let r = kinPercent(selected, i)
    result.dim = i != selected and r == 0
    result.halo = if i != selected and r > 0: 40+r*2 else: 0
  elif kinFocus != 0:
    let on = (kinFocus shr i and 1) == 1
    result.dim = not on
    result.halo = if on: 110 else: 0
proc position(p: Point, y = 0'f32): Vec3 = vec3(p.x.float32/100-32, y+(
    if replayRulesVersion >= 9: world.elevation(p).float32/100 else: 0'f32),

p.z.float32/100-20)
proc seen(i: int): bool =
  if lens < 0: return true
  if lens < Seats: return world.visible(lens, i)
  for s in 0..<Seats:
    if team(s) == lens-Seats and world.cogs[s].hp > 0 and world.visible(s,
        i): return true
proc pointSeen(p: Point): bool =
  if lens < 0: return true
  for seat in 0..<Seats:
    if (seat == lens or lens >= Seats and team(seat) == lens-Seats) and
        world.canSeePoint(seat, p): return true

proc box(r: var ShapeRenderer, x, y, z, dx, dy, dz: float32, color: ColorRGBX, yaw: float32 = 0) =
  let c = rgbx(color.r,color.g,color.b,if color.a==255:254'u8 else:color.a)
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
proc sprayCan(r: var ShapeRenderer, p: Vec3) =
  # A compact aerosol can: rolled rims, tapered shoulder and exposed nozzle.
  const sides = 16
  proc section(r: var ShapeRenderer, y, height, bottomRadius, topRadius: float32, color: ColorRGBX) =
    let bottom = p+vec3(0, y, 0)
    let top = bottom+vec3(0, height, 0)
    for i in 0..<sides:
      let a = i.float32*2*PI.float32/sides.float32
      let b = (i+1).float32*2*PI.float32/sides.float32
      let u = vec3(cos(a), 0, sin(a))
      let v = vec3(cos(b), 0, sin(b))
      let shade = 0.72'f32+0.22'f32*cos((a+b)/2-0.7'f32)
      let side = rgbx(uint8(color.r.float32*shade),
          uint8(color.g.float32*shade), uint8(color.b.float32*shade), 254)
      r.addQuad(bottom+u*bottomRadius, top+u*topRadius,
          top+v*topRadius, bottom+v*bottomRadius, side)
      r.addTriangle(top, top+v*topRadius, top+u*topRadius, color)
      r.addTriangle(bottom, bottom+u*bottomRadius, bottom+v*bottomRadius, side)
  let metal = rgbx(192, 202, 205, 254)
  let orange = rgbx(241, 175, 70, 254)
  section(r, 0, 0.07, 0.29, 0.29, metal)
  section(r, 0.07, 0.75, 0.27, 0.27, orange)
  section(r, 0.30, 0.16, 0.273, 0.273, rgbx(248, 236, 202, 254))
  section(r, 0.82, 0.07, 0.29, 0.29, metal)
  section(r, 0.89, 0.13, 0.27, 0.14, metal)
  section(r, 1.02, 0.12, 0.105, 0.105, rgbx(48, 55, 64, 254))
  r.box(p.x, p.y+1.055, p.z-0.10, 0.045, 0.045, 0.025,
      rgbx(16, 22, 27, 254))

proc gem(r: var ShapeRenderer, p: Vec3, s: float32, color: ColorRGBX) =
  let c = rgbx(color.r,color.g,color.b,if color.a==255:254'u8 else:color.a)
  let top = p+vec3(0, s, 0); let bottom = p-vec3(0, s, 0)
  let ring = [p+vec3(s, 0, 0), p+vec3(0, 0, s), p+vec3(-s, 0, 0), p+vec3(0, 0, -s)]
  for i in 0..3:
    r.addTriangle(top, ring[i], ring[(i+1) mod 4], c)
    r.addTriangle(bottom, ring[(i+1) mod 4], ring[i], c)

proc trenchCover(r: var ShapeRenderer, t: Cover) =
  # Dark earth, exposed banks and duckboards distinguish cover from ordinary roads.
  let cx = t.x.float32+t.w.float32/2
  let cz = t.z.float32+t.h.float32/2
  proc vertex(dx, dz, height: float32): Vec3 =
    let x = cx+dx; let z = cz+dz
    vec3(x/100-32, (if replayRulesVersion >= 9: terrainHeight(x.int,z.int).float32/100 else: 0)+height, z/100-20)
  for side in 0..<24:
    let a = side.float32*2*PI/24
    let b = (side+1).float32*2*PI/24
    proc rim(angle, scale, height: float32): Vec3 =
      let x = cos(angle); let z = sin(angle)
      let k = pow(pow(abs(x),4)+pow(abs(z),4), -0.25'f32)
      vertex(x*k*t.w.float32*scale/2,z*k*t.h.float32*scale/2,height)
    r.addQuad(rim(a,0.67,-0.45),rim(b,0.67,-0.45),
      rim(b,1.12,0.08),rim(a,1.12,0.08),rgbx(118,77,40,254))
    r.addQuad(rim(a,1.12,0.08),rim(b,1.12,0.08),
      rim(b,1.24,0.13),rim(a,1.24,0.13),rgbx(206,174,105,254))
    r.addTriangle(vertex(0,0,-0.43),rim(b,0.67,-0.43),
      rim(a,0.67,-0.43),rgbx(49,37,24,254))
  for plank in -2..2:
    let p = vertex(plank.float32*31,0,-0.38)
    r.box(p.x,p.y,p.z,0.13,0.07,t.h.float32/200*0.57,
      rgbx(144,111,67,254))

proc equipmentPickup(r: var ShapeRenderer, p, eye: Vec3, spin: float32,
    grenade: bool) =
  # Closed, lit meshes with distinct silhouettes: round pineapple vs tall aerosol.
  type Face = tuple[a,b,c: Vec3, color: ColorRGBX, depth: float32]
  var faces: seq[Face]
  proc vertex(v: Vec3): Vec3 =
    p+vec3(v.x*cos(spin)-v.z*sin(spin),v.y,v.x*sin(spin)+v.z*cos(spin))
  proc triangle(a,b,c: Vec3, color: ColorRGBX) =
    let va=vertex(a); let vb=vertex(b); let vc=vertex(c)
    let normal=normalize(cross(vb-va,vc-va))
    let light=0.65'f32+0.35*abs(dot(normal,normalize(vec3(-0.5,0.9,0.4))))
    let center=(va+vb+vc)/3
    faces.add((va,vb,vc,rgbx(uint8(color.r.float32*light),
      uint8(color.g.float32*light),uint8(color.b.float32*light),254),
      dot(center-eye,center-eye)))
  proc quad(a,b,c,d:Vec3,color:ColorRGBX) =
    triangle(a,b,c,color); triangle(a,c,d,color)
  proc band(y0,y1,r0,r1:float32,color:ColorRGBX) =
    for i in 0..<24:
      let a=i.float32*2*PI.float32/24
      let b=(i+1).float32*2*PI.float32/24
      quad(vec3(cos(a)*r0,y0,sin(a)*r0),vec3(cos(b)*r0,y0,sin(b)*r0),
        vec3(cos(b)*r1,y1,sin(b)*r1),vec3(cos(a)*r1,y1,sin(a)*r1),color)
  proc solidBox(center,half:Vec3,color:ColorRGBX) =
    let a=center+vec3(-half.x,-half.y,-half.z)
    let b=center+vec3(half.x,-half.y,-half.z)
    let c=center+vec3(half.x,-half.y,half.z)
    let d=center+vec3(-half.x,-half.y,half.z)
    let up=vec3(0,half.y*2,0)
    quad(a,b,c,d,color);quad(a+up,d+up,c+up,b+up,color)
    quad(a,a+up,b+up,b,color);quad(b,b+up,c+up,c,color)
    quad(c,c+up,d+up,d,color);quad(d,d+up,a+up,a,color)
  let metal=rgbx(240,246,255,255)
  let dark=rgbx(36,47,57,255)
  if grenade:
    # Lime enamel body with dark horizontal grooves and a silver safety ring.
    let green=rgbx(183,237,62,255)
    band(0,0.16,0,0.48,dark)
    for j in 0..<6:
      let y0=0.16'f32+j.float32*0.2
      let y1=y0+0.17
      let r0=0.7'f32*sin((y0/1.55)*PI.float32)
      let r1=0.7'f32*sin((y1/1.55)*PI.float32)
      band(y0,y1,r0,r1,green)
      band(y1,y0+0.2,r1,0.7*sin(((y0+0.2)/1.55)*PI.float32),dark)
    band(1.36,1.5,0.26,0.19,dark)
    solidBox(vec3(0.28,1.52,0),vec3(0.48,0.09,0.16),metal)
    solidBox(vec3(0.68,1.18,0),vec3(0.09,0.36,0.16),metal)
    for i in 0..<24:
      let a=i.float32*2*PI.float32/24
      let b=(i+1).float32*2*PI.float32/24
      quad(vec3(-0.22+cos(a)*0.25,1.73+sin(a)*0.25,0),
        vec3(-0.22+cos(b)*0.25,1.73+sin(b)*0.25,0),
        vec3(-0.22+cos(b)*0.16,1.73+sin(b)*0.16,0),
        vec3(-0.22+cos(a)*0.16,1.73+sin(a)*0.16,0),metal)
  else:
    let paint=rgbx(255,89,195,255)
    band(0,0.09,0,0.43,metal)
    band(0.09,0.18,0.43,0.46,metal)
    band(0.18,0.5,0.46,0.46,paint)
    band(0.5,1.18,0.46,0.46,metal)
    band(1.18,1.65,0.46,0.46,paint)
    band(1.65,1.78,0.46,0.34,metal)
    band(1.78,1.82,0.34,0,metal)
    solidBox(vec3(0,1.96,0),vec3(0.18,0.14,0.16),dark)
    solidBox(vec3(0.23,1.96,0),vec3(0.13,0.07,0.1),metal)
    # Bold paint drips across the white label, visible from every direction.
    for i in 0..<5:
      let a=i.float32*2*PI.float32/5
      let b=a+0.25
      quad(vec3(cos(a)*0.47,1.21,sin(a)*0.47),
        vec3(cos(b)*0.47,1.21,sin(b)*0.47),
        vec3(cos(b)*0.47,0.72,sin(b)*0.47),
        vec3(cos(a)*0.47,0.88,sin(a)*0.47),paint)
  faces.sort(proc(a,b:Face):int=cmp(b.depth,a.depth))
  for face in faces:r.addTriangle(face.a,face.b,face.c,face.color)

proc heartSculpture(r: var ShapeRenderer, p, eye: Vec3, color: ColorRGBX,
    spin: float32, scale = 1'f32) =
  # A closed, inflated heart surface: rounded front and back meet at the rim.
  const segments = 48
  const rings = 8
  type Facet = tuple[a,b,c: Vec3, tint: ColorRGBX, depth: float32]
  var facets: seq[Facet]
  # The leaned heart surface before spin, scale and placement, computed once.
  var local {.global.}: array[2, array[rings+1, array[segments+1, Vec3]]]
  var localReady {.global.} = false
  if not localReady:
    for s in 0..1:
      for j in 0..rings:
        for i in 0..segments:
          let t=i.float32*2*PI.float32/segments.float32
          let latitude=j.float32*PI.float32/(2*rings).float32
          let radius=sin(latitude)
          let x=1.5'f32*radius*pow(sin(t),3'f32)
          let y=1.5'f32*radius*(13*cos(t)-5*cos(2*t)-2*cos(3*t)-cos(4*t))/17
          let z=(s*2-1).float32*0.8'f32*cos(latitude)
          # A gentle backwards lean shows the sculpted face from the arena camera.
          local[s][j][i]=vec3(x,y*cos(0.45'f32)+z*sin(0.45'f32),-y*sin(0.45'f32)+z*cos(0.45'f32))
    localReady=true
  let spinCos=cos(spin)
  let spinSin=sin(spin)
  proc vertex(i,j,side:int):Vec3 =
    let q=local[(side+1) div 2][j][i]
    p+vec3(q.x*spinCos+q.z*spinSin,q.y,-q.x*spinSin+q.z*spinCos)*scale
  proc facet(a,b,c:Vec3) =
    let center=(a+b+c)/3
    var normal=cross(b-a,c-a)
    if dot(normal,normal)<0.0000001:return
    normal=normalize(normal)
    if dot(normal,center-p)<0:normal= -normal
    # The surface is star-shaped about p, so this normal faces outward: a face turned
    # away from the eye sits behind an opaque front face and is never seen.
    if dot(normal,eye-center)<=0:return
    let light=normalize(vec3(-0.45,0.8,0.65))
    let view=normalize(eye-center)
    let diffuse=0.48'f32+0.52*max(0'f32,dot(normal,light))
    let gloss=pow(max(0'f32,dot(normal,normalize(light+view))),36'f32)*0.8
    let rim=pow(1-abs(dot(normal,view)),3'f32)*0.22
    proc channel(c:uint8):uint8 =
      uint8(clamp(c.float32*diffuse+255*(gloss+rim),0,255))
    let delta=center-eye
    facets.add((a,b,c,rgbx(channel(color.r),channel(color.g),channel(color.b),254),dot(delta,delta)))
  # Each grid vertex is shared by four quads; evaluate it once.
  var grid: array[2, array[rings+1, array[segments+1, Vec3]]]
  for s in 0..1:
    for j in 0..rings:
      for i in 0..segments: grid[s][j][i]=vertex(i,j,s*2-1)
  for s in 0..1:
    for j in 0..<rings:
      for i in 0..<segments:
        let a=grid[s][j][i]
        let b=grid[s][j][i+1]
        let c=grid[s][j+1][i+1]
        let d=grid[s][j+1][i]
        if j>0:facet(a,b,c)
        facet(a,c,d)
  # The shared shape batch does not write depth; sort the closed mesh faces.
  # Sort compact (depth, index) keys, not the facets; draw farthest first.
  var order = newSeq[(float32, int32)](facets.len)
  for n, face in facets: order[n] = (face.depth, n.int32)
  order.sort()
  for n in countdown(order.high, 0):
    let face = facets[order[n][1]]
    r.addTriangle(face.a,face.b,face.c,face.tint)

proc heartTower(r: var ShapeRenderer, base, eye: Vec3, color: ColorRGBX,
    time: float32, big = false) =
  let heart=base+vec3(0,(if big: 4.1 else: 3.05)+sin(time)*0.05,0)
  let front=normalize(eye-heart)
  let right=normalize(cross(vec3(0,1,0),front))
  let up=cross(front,right)
  # Layered translucent halos soften to nothing at the outer edge.
  var rim: array[33, Vec3]
  for i in 0..32:
    let a=i.float32*2*PI.float32/32
    rim[i]=right*cos(a)+up*sin(a)
  for layer in 0..<7:
    let radius=(2.15'f32-layer.float32*0.19)*(if big: 1.8'f32 else: 1'f32)
    let center=heart-front*0.85
    for i in 0..<32:
      r.addTriangle(center,center+rim[i]*radius,center+rim[i+1]*radius,
        rgbx(color.r,color.g,color.b,uint8(5+layer*2)))
  proc course(r:var ShapeRenderer,y,height,bottomRadius,topRadius:float32,tint:ColorRGBX,offset=0'f32) =
    let top=base+vec3(0,y+height,0)
    for i in 0..<12:
      let a=i.float32*2*PI.float32/12+offset
      let b=(i+1).float32*2*PI.float32/12+offset
      let va=vec3(cos(a),0,sin(a));let vb=vec3(cos(b),0,sin(b))
      let mid=normalize(va+vb)
      let shade=0.68'f32+0.26*max(0'f32,dot(mid,normalize(vec3(-1,0,1))))
      let col=rgbx(uint8(tint.r.float32*shade),uint8(tint.g.float32*shade),uint8(tint.b.float32*shade),254)
      if dot(mid,eye-base)>0:
        r.addQuad(base+vec3(0,y,0)+va*bottomRadius,
          base+vec3(0,y,0)+vb*bottomRadius,top+vb*topRadius,top+va*topRadius,col)
      r.addTriangle(top,top+va*topRadius,top+vb*topRadius,rgbx(tint.r,tint.g,tint.b,254))
  course(r,0,0.28,1.0,0.94,rgbx(155,165,137,254))
  for row in 0..<4:
    course(r,0.3+row.float32*0.34,0.31,0.71,0.69,
      rgbx(uint8(177+row*5),uint8(182+row*4),uint8(153+row*5),254),row.float32*0.16)
  course(r,1.68,0.12,0.74,0.74,color)
  course(r,1.8,0.22,0.86,0.98,rgbx(209,193,142,254))
  r.heartSculpture(heart,eye,color,time*2*PI.float32/6,(if big: 1.44 else: 0.72))
  if big:
    for i in 0..<32:
      let a=i.float32*2*PI.float32/32
      let b=(i+1).float32*2*PI.float32/32
      r.addLine(base+vec3(cos(a)*1.8,0.12,sin(a)*1.8),
        base+vec3(cos(b)*1.8,0.12,sin(b)*1.8),rgbx(255,215,85,255),halfWidth=0.08)

proc spawnBeam(r: var ShapeRenderer, p: Vec3, color: ColorRGBX,
    progress: float32, slot: int) =
  # Replay-clock animation: the spawn shield gives a seek-safe 1.5 second age.
  let fade = 1-progress
  let height = 7'f32
  for segment in 0..<20:
    let a = segment.float32*2*PI.float32/20
    let b = (segment+1).float32*2*PI.float32/20
    let pa = p+vec3(cos(a)*0.68,0.06,sin(a)*0.68)
    let pb = p+vec3(cos(b)*0.68,0.06,sin(b)*0.68)
    r.addQuad(pa,pb,pb+vec3(0,height,0),pa+vec3(0,height,0),
      rgbx(color.r,color.g,color.b,uint8(48*fade)))
  # Bright scanning rings descend through the cog and dissolve at its feet.
  for ring in 0..<3:
    let y = max(0.08'f32,height*(1-progress)-ring.float32*0.8)
    for segment in 0..<24:
      let a = segment.float32*2*PI.float32/24
      let b = (segment+1).float32*2*PI.float32/24
      r.addLine(p+vec3(cos(a)*0.73,y,sin(a)*0.73),
        p+vec3(cos(b)*0.73,y,sin(b)*0.73),
        rgbx(color.r,color.g,color.b,uint8(230*fade)),halfWidth=0.045)
  for particle in 0..<28:
    let phase = particle.float32*2.39996+slot.float32
    let radius = 0.25+(particle mod 5).float32*0.13
    let y = (1-progress)*(0.5+(particle mod 9).float32*0.72)
    let center = p+vec3(cos(phase+progress*3)*radius,y+0.1,
      sin(phase+progress*3)*radius)
    r.gem(center,(0.065+(particle mod 3).float32*0.02)*fade,
      rgbx(255,245,220,uint8(254*fade)))

let paintballSphere = block:
  # Unit sphere lattice (7 latitudes x 11 longitudes) shared by every paintball.
  var sphere: array[7, array[11, Vec3]]
  for ring in 0..6:
    let a = -PI.float32/2+PI.float32*ring.float32/6
    for j in 0..10:
      let c = 2*PI.float32*j.float32/10
      sphere[ring][j] = vec3(cos(a)*cos(c), sin(a), cos(a)*sin(c))
  sphere
proc paintball(r: var ShapeRenderer, p: Vec3, radius: float32,
    color: ColorRGBX) =
  for ring in 0..<6:
    for j in 0..<10:
      let p0 = p+paintballSphere[ring][j]*radius
      let p1 = p+paintballSphere[ring][j+1]*radius
      let p2 = p+paintballSphere[ring+1][j+1]*radius
      let p3 = p+paintballSphere[ring+1][j]*radius
      let shade = 0.65+0.35*(ring.float32/6)
      let col = rgbx(uint8(color.r.float32*shade), uint8(color.g.float32*shade),
          uint8(color.b.float32*shade), if color.a==255:254'u8 else:color.a)
      r.addQuad(p0, p3, p2, p1, col)

proc sprayCloud(renderer: var ShapeRenderer, world: World, slot: int,
    phase, spread: float32, far = false) =
  # A far cog in a crowd gets one sheet per orientation instead of seven.
  # Intersecting translucent sheets form a continuous volume from every camera,
  # with density feathered across the cone and advecting away from the nozzle.
  const Steps = 20
  const Across = 12
  let origin = world.cogs[slot].pos
  let aim = world.equipment[slot].sprayAim
  let baseColor = teamColors[world.apparentTeam(slot)]
  let color = rgbx(uint8(baseColor.r.float32*0.65),
    uint8(baseColor.g.float32*0.65), uint8(baseColor.b.float32*0.65), 255)
  # Height does not affect the game's 2D visibility query. Reuse each ray's
  # result across the intersecting sheets instead of tracing every vertex.
  var horizontalClear: array[Steps+1, array[Across+1, bool]]
  var verticalClear: array[Steps+1, array[7, bool]]
  for vertical in [false, true]:
    let firstLayer = if far: 0 else: -3
    for layer in firstLayer..(-firstLayer):
      var vertices: array[Steps+1, array[Across+1, Vec3]]
      var colors: array[Steps+1, array[Across+1, ColorRGBX]]
      for step in 0..Steps:
        let f = step.float32/Steps.float32
        for column in 0..Across:
          let across = column.float32/Across.float32*2-1
          let depth = layer.float32/3.5
          let u = if vertical: depth else: across
          let v = if vertical: across else: depth
          let p = point(origin.x.int+int((aim.x.float32-aim.z.float32*u*spread)*f),
            origin.z.int+int((aim.z.float32+aim.x.float32*u*spread)*f))
          vertices[step][column] = position(p, 0.9+v*f*0.85)
          let radius2 = u*u+v*v
          let feather = max(0'f32, 1-radius2)
          let billow = 0.75+0.25*sin(f*24-phase*0.22+u*4+v*3)
          let density = feather*feather*billow*min(f*10, 1'f32)*min((1-f)*6, 1'f32)
          if not vertical and layer == firstLayer:
            horizontalClear[step][column] = world.lineClear(origin, p)
          elif vertical and column == 0:
            verticalClear[step][layer+3] = world.lineClear(origin, p)
          let visible = if vertical: verticalClear[step][layer+3]
            else: horizontalClear[step][column]
          let opacity = if visible: uint8(60*density) else: 0'u8
          colors[step][column] = rgbx(color.r, color.g, color.b, opacity)
      for step in 0..<Steps:
        for column in 0..<Across:
          renderer.addGradientTriangle(vertices[step][column], vertices[step+1][column],
            vertices[step+1][column+1], colors[step][column], colors[step+1][column],
            colors[step+1][column+1])
          renderer.addGradientTriangle(vertices[step][column], vertices[step+1][column+1],
            vertices[step][column+1], colors[step][column], colors[step+1][column+1],
            colors[step][column+1])

proc startupPhase(label: string) =
  when defined(emscripten):
    let text = label.cstring
    {.emit: "EM_ASM({if(Module.startupPhase)Module.startupPhase(UTF8ToString($0));}, `text`);".}
    {.emit: "emscripten_sleep(0);".}

when defined(pwViewerProfile):
  const ProfPhases = ["tick", "camera", "visibility", "shadows", "terrain", "outline", "actors", "shapesBuild", "shapesDraw", "ui", "swap", "hud", "splashes", "greatHearts", "cogShapes", "equip", "hearts"]
  var profMs: array[ProfPhases.len, float]
  var profFrames = 0
  var profT = 0.0
  template profMark(k: int) =
    let profNow = epochTime(); profMs[k] += (profNow-profT)*1000; profT = profNow
  proc profReport() =
    inc profFrames
    if profFrames mod 120 == 0:
      var line = "VIEWERPROF frames=120"
      var total = 0.0
      for k, name in ProfPhases:
        line.add " " & name & "=" & formatFloat(profMs[k]/120, ffDecimal, 2); total += profMs[k]/120
        profMs[k] = 0
      echo line, " total=", formatFloat(total, ffDecimal, 2)
else:
  template profMark(k: int) = discard
  proc profReport() = discard
proc runGraphics*() =
  startupPhase("Preparing replay")
  setup()
  if ffa():
    kinHues = familyHues(activeKinship)
    for i in 0..<Seats:
      kinRgb[i] = if kinHues[i] < 0: lonerColor
        else: hsl(kinHues[i], KinSaturation, KinLightness).color.asRgbx
  var index: ReplayIndex
  if replayMode:
    when defined(emscripten) and defined(workerReplayIndex):
      # Produced by our worker from these exact replay bytes, after all hashes
      # passed. It uses the same Flatty ABI and indexReplay implementation.
      index = readFile("/episode.index").fromFlatty(ReplayIndex)
    else:
      index = indexReplay()
  else:
    index = ReplayIndex(checkpoints: @[Checkpoint(state: snapshot(world))],
      momentum: @[graphSample(world)])
  transport = initPlayer(not replayMode, if replayMode: recording.frames.len.int32 else: options.maximumTicks,
    playing = not options.pauseOnStart, speed = options.speed)
  # Paintbot owns looping so the shared transport cannot skip the celebration.
  transport.repeating = false
  playbackRate = options.speed.float32
  transport.sync(world.tick, recording.frames.len.int32, world.winner != -1)
  if options.playerSlot > 0:
    selected = options.playerSlot.int-1
    lens = selected

  startupPhase("Building terrain")
  let window = newWindow("Paintbot · Heartwick", ivec2(1440, 900))
  makeContextCurrent(window)
  loadExtensions()
  # Keep only a narrow scenic strip around the playable arena.
  const border = 3
  let terrainWidth = (maxX()-minX()) div 100+2*border
  let terrainDepth = (maxZ()-minZ()) div 100+2*border
  let ground = QuadLayer(originX: HalfGrid.int-32-border+minX() div 100, originZ: HalfGrid.int-20-border+minZ() div 100, width: terrainWidth, depth: terrainDepth,
      tiles: newSeq[Tile](terrainWidth*terrainDepth))
  let terraces = QuadLayer(originX: HalfGrid.int-32-border+minX() div 100, originZ: HalfGrid.int-20-border+minZ() div 100, width: terrainWidth, depth: terrainDepth,
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
      if organicTerrain and activeMap() < 0 and gx>=minX() div 100 and gx<maxX() div 100 and gz>=minZ() div 100 and gz<maxZ() div 100:
        let px=gx*100+50;let pz=gz*100+50
        let local=landCoordinates(px,pz)
        let width=130+landWave(px+pz,1600,35)
        let radius=sqrt(((local.x-3200)*(local.x-3200)+(local.z-2000)*(local.z-2000)).float)
        tile.kind=GrassTile
        if forestRouteDistance(px,pz)<width or villageLaneDistance(px,pz)<width or abs(radius-620)<110:
          tile.kind=RoadTile
      if activeMap() >= 0 and gx>=minX() div 100 and gx<maxX() div 100 and gz>=minZ() div 100 and gz<maxZ() div 100:
        # Rules 41 maps: grass, worn earth around each heart, and bare rock on cliff faces.
        let px=gx*100+50;let pz=gz*100+50
        tile.kind=GrassTile
        for h in world.controlHearts:
          if distance2(point(px,pz),h.pos)<260*260:tile.kind=RoadTile
        let slope=max(abs(terrainHeight(px+50,pz)-terrainHeight(px-50,pz)),
          abs(terrainHeight(px,pz+50)-terrainHeight(px,pz-50)))
        if slope>100:tile.kind=RockTile
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
          if raisedHeight(px*100, pz*100) > 0 and
              riverBlend(px*100, pz*100) == 0: elevated = true
        if riverTerrain:
          for corner in 0..3:
            if riverBlend((gx+(corner and 1))*100,(gz+(corner shr 1))*100)>0:
              elevated = false
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
      if riverBlend(gx*100+50,gz*100+50)>0:
        tile.kind = MarshTile
      if islandTerrain:
        let coast=islandMargin(gx*100+50,gz*100+50)
        if coast< -25:
          tile.flags=0
          terraces.tiles[z*terrainWidth+x].flags=0
        elif coast<85:
          tile.kind=RoadTile
      ground.tiles[z*terrainWidth+x] = tile
  layers = if replayRulesVersion >= 9: @[ground, terraces] else: @[ground]
  if islandTerrain:
    let ocean = QuadLayer(originX: HalfGrid.int-400, originZ: HalfGrid.int-400, width: 800,
      depth: 800, water: true, tiles: newSeq[Tile](800*800))
    for tile in ocean.tiles.mitems:
      tile = Tile(flags: TileExists, tops: pack([-2.75'f32, -2.75, -2.75, -2.75]),
        bottoms: pack([-3'f32, -3, -3, -3]))
    layers.add ocean
  if riverTerrain:
    # As in GOTA, water covers submerged ground corners and the bank clips it.
    let river = QuadLayer(originX: ground.originX, originZ: ground.originZ,
      width: terrainWidth, depth: terrainDepth, slab: true, water: true,
      tiles: newSeq[Tile](terrainWidth*terrainDepth))
    for z in 0..<terrainDepth:
      for x in 0..<terrainWidth:
        let gx = x-border+minX() div 100
        let gz = z-border+minZ() div 100
        var submerged = false
        for corner in 0..3:
          let px = (gx+(corner and 1))*100
          let pz = (gz+(corner shr 1))*100
          if riverBlend(px,pz)>0 and islandMargin(px,pz)>0 and
              terrainHeight(px,pz)<RiverWaterHeight:
            submerged = true
        if submerged:
          var levels: array[4,float32]
          for corner in 0..3:
            let px = (gx+(corner and 1))*100
            let pz = (gz+(corner shr 1))*100
            # The mouth descends to the existing sea rather than floating above it.
            levels[corner] = min(RiverWaterHeight,
              max(-275,(islandMargin(px,pz)-35)*5+38)).float32/100
          river.tiles[z*terrainWidth+x] = Tile(flags: TileExists,
            tops: pack(levels),
            bottoms: pack([-2'f32,-2,-2,-2]))
    layers.add river
  amplitude = 1.2
  treeHeight = 5.5
  startupPhase("Loading terrain textures")
  initTerrain(MixedTrees, GeneratedTerrain, PaintedRocks)
  computeWalkable()
  scatterGrass(if deepWilderness: 1800 else: 1500, recording.seed, matchTerrain = true)
  startupPhase("Placing village and woodland")
  if activeMap() >= 0:
    placeMapScenery()
  elif replayRulesVersion >= 8:
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
  startupPhase("Uploading terrain and foliage")
  bakeTerrain(rebuildWalkability = false)
  startupPhase("Preparing first frame")
  let scene = newCharacterScene(window)
  scene.useToonShading()
  scene.setToonHour(15.4)
  setEnvironmentPalette(scene.toon)
  # Spectators can distinguish the true-team head from the uniform below it.
  var models: array[2, array[2, CharacterModel]]
  for side, head in ["red", "blue"]:
    for apparent, uniform in ["red", "blue"]:
      let name = if side == apparent: head else: head & "-" & uniform
      let path = (when defined(emscripten): "/" else: "tmp/") &
        "paintbot-cog-" & name & ".glb"
      models[side][apparent] = loadCharacterModel(path, 1.9)
      models[side][apparent].unlitParts = @["eye", "smile"]
  # FFA-kin cogs share one body model; its paint (shell, fenders, hopper) is recoloured
  # per cog to the family colour just before each draw. The toon pass reads baseColorFactor at
  # draw time, so rewriting the shared material between drawCharacter calls is per-instance.
  # Eyes, screen, rubber and metal keep their own materials; loners keep the stock grey.
  var neutralModel: CharacterModel
  var paintMaterials: seq[Material]
  var paintGrey: Color
  if ffa():
    neutralModel = loadCharacterModel((when defined(emscripten): "/" else: "tmp/") &
      "paintbot-cog-grey.glb", 1.9)
    neutralModel.unlitParts = @["eye", "smile"]
    # By node name (build_cog.py): the gltf reader gives each primitive its own unnamed Material.
    for node in neutralModel.file.root.walkNodes:
      if node.mesh == nil or node.name notin ["shell", "fender", "hopper"]: continue
      for primitive in node.mesh.primitives:
        if primitive.material != nil: paintMaterials.add primitive.material
    if paintMaterials.len > 0: paintGrey = paintMaterials[0].baseColorFactor
  proc paintCog(seat: int) =
    ## Sets the shared FFA body paint to this seat's family colour (same RGB as the HUD chips).
    let c = if seat in 0..<Seats and kinHues[seat] >= 0:
        color(kinRgb[seat].r.float32/255, kinRgb[seat].g.float32/255,
          kinRgb[seat].b.float32/255, 1)
      else: paintGrey
    for m in paintMaterials: m.baseColorFactor = c
  var occlusionOutline = initSelectionOutline(OccludedOutline)
  var shapes = initShapeRenderer()
  var last = epochTime()
  var heartAnimationTime = 0'f32
  var previous = world.cogs
  var announced = false
  var lastHud = -1
  var sentGraphSamples = 0
  var visibilityTick = -1
  var visibilityLens = -2
  window.onFrame = proc() =
    let now = epochTime(); let frameDt = max(0.0, now-last)
    when defined(pwViewerProfile): profT = epochTime()
    let dt = min(frameDt, 0.1); last = now
    # Decorative hearts keep turning while playback is paused or slowed.
    heartAnimationTime = (heartAnimationTime+dt.float32)
    let restore = transport.takeRestore()
    if restore >= 0:
      setActionCamera(cint(autoCamera))
      index.restore(restore.int)
      previous = world.cogs
      transport.sync(world.tick, recording.frames.len.int32, world.winner != -1)
    if not replayMode and replayRulesVersion in 20..22 and options.maximumTicks >= 7200 and
        world.tick >= transport.durationTicks and world.winner < 0:
      transport.durationTicks = world.tick + TickRate*60
    transport.startFrame(dt.float32 * playbackRate / transport.speed.float32, TickRate)
    let frameStart = epochTime()
    while transport.shouldTick(frameStart):
      previous = world.cogs
      let atFrontier = world.tick == recording.frames.len
      if atFrontier: index.advanceIndexed()
      else: advance()
      if atFrontier: index.sampleGraphs(world)
      if atFrontier and world.tick mod 240 == 0:
        index.checkpoints.add Checkpoint(state: snapshot(world))
      transport.sync(world.tick, recording.frames.len.int32, world.winner != -1)
    profMark(0)
    victory.update(world.tick >= transport.timelineEnd and transport.timelineEnd > 0, frameDt.float32)
    let paused = if victory.active: victory.paused else: not transport.playing
    let alpha = if paused or victory.active: 1'f32 else: clamp(transport.accumulator*TickRate.float32, 0, 1)
    var poses: array[Seats, Vec3]
    for i, c in world.cogs:
      poses[i] = if previous[i].hp > 0 and c.hp > 0: mix(position(previous[
          i].pos), position(c.pos), alpha) else: position(c.pos)
      if victory.active and world.winner == team(i).int32 and c.hp > 0:
        let beat = victory.elapsed*5 + i.float32*0.6
        poses[i].y += abs(sin(beat))*0.65
        poses[i].x += sin(beat*0.5)*0.22
    proc shown(i: int): bool =
      seen(i) and not victory.removed(world.winner.int, team(i))
    if follow and selected >= 0:
      let blend = 1-exp(-5*dt.float32)
      camX = mix(camX, poses[selected].x, blend)
      camZ = mix(camZ, poses[selected].z, blend)
      camY = mix(camY, poses[selected].y+1, blend)
    var target = vec3(camX, camY, camZ)
    # Frame the surviving winners while the automatic camera is enabled.
    if autoCamera and victory.active and world.winner >= 0:
      var center: Vec3
      var count = 0
      for i, c in world.cogs:
        if c.hp > 0 and shown(i):
          center += position(c.pos)
          inc count
      if count > 0:
        center = center/count.float32 + vec3(0, 1, 0)
        var radius = 0'f32
        for i, c in world.cogs:
          if c.hp > 0 and shown(i): radius = max(radius, length(position(c.pos)-center))
        let blend = 1-exp(-2*dt.float32)
        target = mix(target, center, blend)
        distance = mix(distance, max(12'f32, radius*2.8+8), blend)
        camX = target.x; camY = target.y; camZ = target.z
    # The gameplay director stops when the match ends.
    let cameraFinished = world.winner >= 0 or world.tick >= transport.timelineEnd
    if autoCamera and not cameraFinished:
      if directorLens != lens: setActionCamera(1)
      # Rebuild visible interests each simulation tick, including after lens changes.
      let cameraTickChanged = directorTick != world.tick
      if cameraTickChanged:
        director.beginFrame(world.tick)
        for i, c in world.cogs:
          if c.hp <= 0 or not seen(i): continue
          director.noteInterest(int32(i+1), poses[i], 15, 5, world.tick, 1)
          when Seats <= 16:
            for j in i+1..<Seats:
              if (not ffa() and team(i) == team(j)) or world.cogs[j].hp <= 0 or not seen(j): continue
              let gap = length(poses[i]-poses[j])
              if gap < 40:
                director.noteInterest(int32(100+i*Seats+j), (poses[i]+poses[j])*0.5,
                  100-gap, gap*0.5+3, world.tick, 1)
          else:
            # Crowds: every pair within 40 m is thousands of interests a tick. Each cog adds
            # only its nearest opponent (unrelated, in FFA-kin), in an id range of its own.
            var nearest = -1
            var nearestGap = 40'f32
            for j in 0..<Seats:
              if j == i or world.cogs[j].hp <= 0 or not seen(j): continue
              if (not ffa() and team(i) == team(j)) or (ffa() and kinPercent(i, j) > 0): continue
              let gap = length(poses[i]-poses[j])
              if gap < nearestGap: nearest = j; nearestGap = gap
            if nearest >= 0:
              director.noteInterest(int32(1_500_000_000+i), (poses[i]+poses[nearest])*0.5,
                100-nearestGap, nearestGap*0.5+3, world.tick, 1)
        for n, h in world.controlHearts:
          var nearby: array[2, int]
          var total = 0
          for i, c in world.cogs:
            if c.hp > 0 and seen(i) and distance2(c.pos,h.pos) < 1000000:
              inc nearby[team(i)]
              inc total
          if total > 0:
            let contested = if ffa(): total > 1 else: nearby[0] > 0 and nearby[1] > 0
            director.noteInterest(int32(1000+n), position(h.pos, 2),
              (if contested: 125'f32 else: 45'f32), 9, world.tick, 1)
        # Events are recorded in tick order: start at the first one from the last 36 ticks.
        var first = 0
        var hi = index.events.len
        while first < hi:
          let mid = (first+hi) div 2
          if index.events[mid].tick < world.tick-36: first = mid+1 else: hi = mid
        for n in first..<index.events.len:
          let event = index.events[n]
          if event.tick > world.tick: break
          if world.tick-event.tick > 36: continue
          if event.slot >= 0 and not seen(event.slot): continue
          let weight = case event.kind
            of "grenade blast": 165'f32
            of "down": 145'f32
            of "tag", "spray": 100'f32
            of "territory": 130'f32
            else: 0'f32
          if weight > 0 and (lens < 0 or event.slot >= 0):
            director.noteInterest(int32(10000+n), position(point(event.x,event.z),1),
              weight, 9, world.tick, 1)
        directorTick = world.tick
      if not paused or cameraTickChanged:
        director.chooseShot(dt.float32, max(1, playbackRate.int32))
      director.follow(target, distance, dt.float32, max(1, playbackRate.int32))
      camX = target.x; camY = target.y; camZ = target.z

    let (eye, view, projection) = spectatorCamera(target, distance, yaw, tilt,
        window.size.x, window.size.y)
    profMark(1)
    let vp = projection*view
    proc onScreen(p: Vec3, margin = 1.15'f32): bool =
      ## Near the camera view; crowd decorations and characters off screen are skipped.
      let q = vp * vec4(p.x, p.y+1, p.z, 1)
      q.w > 0 and abs(q.x) <= q.w*margin+1.5 and abs(q.y) <= q.w*margin+1.5
    proc groundView(): array[4, int] =
      ## The world rectangle the camera shows on the ground (with a margin for relief), or
      ## the whole map when a screen corner looks above the horizon.
      result = [minX(), minZ(), maxX(), maxZ()]
      let inverse = vp.inverse
      var lo = vec2(float32.high, float32.high)
      var hi = vec2(float32.low, float32.low)
      for c in [(-1'f32, -1'f32), (1'f32, -1'f32), (-1'f32, 1'f32), (1'f32, 1'f32)]:
        let a = inverse*vec4(c[0], c[1], -1, 1)
        let b = inverse*vec4(c[0], c[1], 1, 1)
        let near = vec3(a.x, a.y, a.z)/a.w
        let far = vec3(b.x, b.y, b.z)/b.w
        if near.y <= 0 or far.y >= near.y: return
        let g = near+(far-near)*(near.y/(near.y-far.y))
        lo = vec2(min(lo.x, g.x), min(lo.y, g.z)); hi = vec2(max(hi.x, g.x), max(hi.y, g.z))
      const Margin = 30'f32
      result = [max(minX(), int((lo.x-Margin+32)*100)), max(minZ(), int((lo.y-Margin+20)*100)),
        min(maxX(), int((hi.x+Margin+32)*100)), min(maxZ(), int((hi.y+Margin+20)*100))]
    if orderKind != 0:
      # Unproject the click into the same world coordinates used by bot commands.
      let inverse = vp.inverse
      let a = inverse*vec4(orderX*2-1, 1-orderY*2, -1, 1)
      let b = inverse*vec4(orderX*2-1, 1-orderY*2, 1, 1)
      let origin = vec3(a.x, a.y, a.z)/a.w
      let ray = normalize(vec3(b.x, b.y, b.z)/b.w-origin)
      let hit = pickWalkableTile(origin, ray)
      if orderSeat in 0..<Seats and world.visible(options.playerSlot.int-1, orderSeat):
        queueShootAt(world.cogs[orderSeat].pos)
      elif hit.hit:
        let point = tileCenter(hit.layer, hit.x, hit.z)
        let target = Point(x: int32(round((point.x+32)*100)), z: int32(round((point.z+20)*100)))
        if orderKind == 1: queueWalkTo(target)
        else: queueShootAt(target)
      orderKind = 0
    # Crowds: shadows and occlusion outlines go to the cogs nearest the camera target only.
    const CrowdDetail = 48
    var nearRank: array[Seats, int]
    block:
      var order: seq[(float32, int)]
      for i, c in world.cogs:
        if c.hp > 0: order.add (length(poses[i]-target), i)
      order.sort(proc(a, b: (float32, int)): int = cmp(a[0], b[0]))
      for i in 0..<Seats: nearRank[i] = Seats
      for r, e in order: nearRank[e[1]] = r
    proc actors(exclude = -1, margin = 1.15'f32, maxRank = Seats) =
      # Crowds: draw only cogs near the view (a looser margin for the shadow pass, whose casters
      # may stand off screen), still cogs before rolling ones so each pose is computed once.
      for pass in 0..1:
       for i, c in world.cogs:
        if c.hp <= 0 or i == exclude or not shown(i): continue
        let still = c.pos == previous[i].pos
        if (pass == 0) != still: continue
        if nearRank[i] >= maxRank or not onScreen(poses[i], margin): continue
        # Teammates may overlap exactly; don't put their helmet around the eye camera.
        if exclude >= 0 and distance2(c.pos, world.cogs[exclude].pos) <
            10000: continue
        let delta = vec2((c.aim.x-c.pos.x).float32, (c.aim.z-c.pos.z).float32)
        let facing = arctan2(delta.x.float32, delta.y.float32) +
          (if victory.active and world.winner == team(i).int32: victory.elapsed*2.5 + sin(victory.elapsed*5+i.float32)*0.5 else: 0)
        let rolling = if victory.active: victory.elapsed*2 else: (if c.pos != previous[i].pos: (
            world.tick.float32+alpha)/24 else: 0)
        let lowered = if replayRulesVersion < 9 and world.trenchAt(c.pos) >=
            0: 0.55'f32 else: 0'f32
        if ffa():
          # Kin view or picked families: the rest fade to 40%.
          let dim = kinEmphasis(i).dim
          # tint.a < 1 takes the blended pass (characters.nim:207); visually verified for the dim.
          paintCog(i)
          drawCharacter(scene, neutralModel, poses[i]-vec3(0, lowered, 0), facing, 0, rolling,
            tint = (if dim: color(1, 1, 1, 0.4) else: color(1, 1, 1, 1)))
        else:
          drawCharacter(scene, models[team(i)][if victory.active: team(i) else: world.apparentTeam(i)], poses[i]-vec3(0, lowered, 0),
              facing, 0, rolling)
    # Terrain is public in a live match. Keep actor/target visibility exact;
    # thousands of terrain rays per tick otherwise stall human input.
    let terrainLens = if not replayMode: -1 else: lens
    if (terrainLens >= 0 and visibilityTick != world.tick) or visibilityLens != terrainLens:
      var visibility = newSeq[uint8](GridTiles*GridTiles)
      for z in 0..<GridTiles:
        for x in 0..<GridTiles:
          let p = point((x-HalfGrid.int+32)*100, (z-HalfGrid.int+20)*100)
          var lit = terrainLens < 0
          if not lit:
            for s in 0..<Seats:
              if (s == lens or lens >= Seats and team(s) == lens-Seats) and
                  world.canSeePoint(s, p): lit = true; break
          visibility[z*GridTiles+x] = if lit: 255'u8 else: 65'u8
      uploadTerrainVisibility(visibility)
      visibilityTick = world.tick; visibilityLens = terrainLens
    profMark(2)
    sunDepthPasses(window.size):
      drawTerrainSunDepth()
      scene.sunDepthPass = true; actors(margin = 1.8, maxRank = CrowdDetail); scene.sunDepthPass = false
    profMark(3)
    glViewport(0, 0, window.size.x.GLsizei, window.size.y.GLsizei)
    glClearColor(0.08, 0.13, 0.15, 1)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
    scene.toon.drawBackground()
    drawTerrain(vp)
    profMark(4)
    # Reuse the visible actors and their exact animated poses. Only scenery is
    # in the window depth buffer, so outlines reveal camera occlusion without
    # revealing cogs excluded by the current player/team visibility lens.
    occlusionOutline.beginMask(window.size)
    beginCharacters(scene, window, view, projection, eye)
    actors(maxRank = CrowdDetail); finishCharacters(scene)
    occlusionOutline.drawOutline(OccludedOutlineColor)
    profMark(5)
    beginCharacters(scene, window, view, projection, eye)
    actors(); finishCharacters(scene)
    profMark(6)
    shapes.clear()
    for trench in world.trenches:
      if onScreen(position(point(trench.x.int+trench.w.int div 2, trench.z.int+trench.h.int div 2)), 1.4):
        shapes.trenchCover(trench)
    # Low stone courses exactly match collision bounds; capstones and stripes read at a glance.
    # Paint splashes and short bursts follow recorded tags, so seeking reconstructs them.
    proc paintOut(p: Vec3, color: ColorRGBX, age, seed: float32) =
      if age < 0 or age >= 48: return
      let fade = 1-age/48
      shapes.addCircle(p, 0.6, rgbx(color.r, color.g, color.b, uint8(110*fade)))
      for n in 0..4:
        let a = n.float32*1.256+seed
        shapes.addCircle(p+vec3(cos(a)*0.65, 0.001, sin(a)*0.65), 0.17,
          rgbx(color.r, color.g, color.b, uint8(120*fade)))
        if age < 18:
          let f = age/18
          shapes.gem(p+vec3(cos(a)*f*1.8, sin(f*PI.float32)*1.2+0.2,
            sin(a)*f*1.8), 0.11, color)
    # Moments are recorded in tick order; only the last 48 ticks (splash lifetime) can draw.
    proc firstFrom(moments: seq[Moment], tick: int): int =
      var hi = moments.len
      while result < hi:
        let mid = (result+hi) div 2
        if moments[mid].tick < tick: result = mid+1 else: hi = mid
    for n in firstFrom(index.events, world.tick-48)..<index.events.len:
      let event = index.events[n]
      if event.tick > world.tick+1: break
      let age = world.tick.float32+alpha-event.tick.float32 +
        (if victory.active: victory.elapsed*TickRate.float32 else: 0)
      if event.kind != "tag" or (lens >= 0 and not seen(event.victim)): continue
      if not onScreen(position(point(event.x, event.z)), 1.3): continue
      paintOut(position(point(event.x, event.z), 0.035),
        (if ffa(): kinColor(event.slot) else: teamColors[event.side]), age, event.slot.float32)
    if victory.active and world.winner >= 0:
      for i, c in world.cogs:
        if c.hp > 0 and seen(i) and victory.removed(world.winner.int, team(i)):
          paintOut(position(c.pos, 0.035), teamColors[world.winner], victory.elapsed*TickRate.float32, i.float32)
    # Every damaging hit splashes the victim, including armor hits and survivors.
    for n in firstFrom(index.hits, world.tick-14)..<index.hits.len:
      let hit = index.hits[n]
      if hit.tick > world.tick+1: break
      let age=world.tick.float32+alpha-hit.tick.float32 +
        (if victory.active: victory.elapsed*TickRate.float32 else: 0)
      if age<0 or age>=14 or not seen(hit.victim):continue
      if not onScreen(position(point(hit.x,hit.z)),1.3):continue
      let fade=1-age/14
      let center=(if world.cogs[hit.victim].hp>0:poses[hit.victim]
          else:position(point(hit.x,hit.z)))+vec3(0,1.3,0)
      let front=center+normalize(eye-center)*0.5
      let color=if ffa():kinColor(hit.slot) elif hit.side==0:rgbx(255,103,112,255) else:rgbx(83,218,255,255)
      shapes.paintball(front,0.36*fade,color)
      for drop in 0..<7:
        let angle=drop.float32*0.8976+hit.slot.float32
        let spread=0.28+age*0.045
        let offset=vec3(cos(angle)*spread,sin(angle)*spread-age*0.025,
            sin(angle*2)*0.18)
        shapes.paintball(front+offset,(0.11+(drop mod 3).float32*0.035)*fade,color)
    if not islandTerrain:
      # Brass boundary rails make the playable rectangle explicit within the grove.
      for z in [minZ().float32/100-20, maxZ().float32/100-20]: shapes.box(0, 0, z, (maxX()-minX()).float32/200, 0.16, 0.07, rgbx(217,
          187, 111, 255))
      for x in [minX().float32/100-32, maxX().float32/100-32]: shapes.box(x, 0, 0, 0.07, 0.16, (maxZ()-minZ()).float32/200, rgbx(217,
          187, 111, 255))
    for itemId, item in world.pickups:
      if item.readyAt > world.tick: continue
      if not pointSeen(item.pos) or not onScreen(position(item.pos), 1.3): continue
      if inspectedKind == 2 and inspectedId == itemId:
        shapes.addCircle(position(item.pos, 0.025), 1.25, rgbx(250,226,140,180))
      let special = item.kind in {grenadePickup,sprayPickup}
      let spin = heartAnimationTime*1.08
      let p = position(item.pos, if special: 0.7+0.15*sin(spin*1.7) else: 0.28)
      let color = case item.kind
        of grenadePickup: rgbx(183, 237, 62, 255)
        of sprayPickup: rgbx(255, 89, 195, 255)
        of uniformPickup: rgbx(192, 126, 245, 255)
        of armorPickup: rgbx(96, 191, 241, 255)
        of medkitPickup: rgbx(243, 238, 207, 255)
      shapes.addCircle(position(item.pos, 0.04), if special: 1.0 else: 0.55, color)
      if special:
        shapes.equipmentPickup(p,eye,spin,item.kind == grenadePickup)
      else:
        shapes.box(p.x, p.y, p.z, 0.4, 0.48, 0.32, color,
            if item.kind == medkitPickup: spin else: 0'f32)
      if item.kind == uniformPickup:
        # A two-tone shirt: body and sleeves make the disguise pickup legible.
        shapes.box(p.x,p.y+0.65,p.z,0.42,0.55,0.15,rgbx(255,103,81,255),spin)
        shapes.box(p.x-0.3,p.y+0.82,p.z,0.22,0.22,0.15,rgbx(74,192,255,255),spin)
        shapes.box(p.x+0.3,p.y+0.82,p.z,0.22,0.22,0.15,rgbx(74,192,255,255),spin)
      if item.kind == medkitPickup:
        shapes.box(p.x, p.y+0.49, p.z, 0.26, 0.03, 0.08, rgbx(215, 69, 66, 255), spin)
        shapes.box(p.x, p.y+0.49, p.z, 0.08, 0.03, 0.26, rgbx(215, 69, 66, 255), spin)

    # Rules 38 glory hearts: small spinning gold hearts that blink out in their last five seconds.
    for heart in world.gloryHearts:
      if not pointSeen(heart.pos) or not onScreen(position(heart.pos), 1.3): continue
      let left = heart.expiresAt-world.tick
      if left < 5*TickRate and int(heartAnimationTime*6) mod 2 == 0: continue
      let pulse = 0.5+0.5*sin(heartAnimationTime*4)
      shapes.addCircle(position(heart.pos, 0.04), 0.7+0.12*pulse, rgbx(255, 214, 92, 120))
      shapes.heartSculpture(position(heart.pos, 1.1+0.18*sin(heartAnimationTime*2.2)), eye,
        rgbx(255, 196, 60, 255), heartAnimationTime*3, 0.32)
    for g in world.grenades:
      let f = clamp((world.tick-g.releasedAt).float32/max(1,
          g.landsAt-g.releasedAt).float32, 0, 1)
      let p = mix(position(g.start, if g.owner < 0: 14 else: 1), position(g.target, 0.1), f)+vec3(0, sin(
          f*PI.float32)*3, 0)
      shapes.gem(p, 0.4, rgbx(190, 211, 79, 254))
      shapes.addCircle(position(g.target, 0.05), 0.24, rgbx(192, 161, 85, 160))
    for b in world.blasts:
      if not onScreen(position(b.pos), 1.4): continue
      let age=clamp((world.tick.float32+alpha-b.tick.float32)/24,0'f32,1'f32)
      let bloom=min(age/0.18,1'f32)
      let settle=clamp((age-0.18)/0.72,0'f32,1'f32)
      let kin=kinColor(b.owner.int)
      let palette=if ffa():
        [kin,rgbx(uint8(min(255,kin.r.int+50)),uint8(min(255,kin.g.int+50)),uint8(min(255,kin.b.int+50)),255),
          rgbx(uint8(kin.r.int*3 div 4),uint8(kin.g.int*3 div 4),uint8(kin.b.int*3 div 4),255)]
      elif team(b.owner.int)==0:
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
    profMark(12)
    for i, e in world.equipment:
      if world.cogs[i].hp <= 0 or not shown(i) or victory.active or not onScreen(poses[i], 1.4): continue
      if e.charge > 0: shapes.addCircle(position(world.grenadeTarget(i), 0.08),
          grenadeBlastRadius().float32/100, rgbx(229, 199, 88, 255))
      if e.burst > 0:
        let spread = if replayRulesVersion >= 17: 0.6'f32 else: 0.25'f32
        shapes.sprayCloud(world, i, world.tick.float32+alpha, spread, nearRank[i] >= CrowdDetail)
      if e.grenade: shapes.gem(poses[i]+vec3(-0.45, 1.0, -0.3), 0.19, rgbx(157,
          175, 66, 255))
      if e.sprayCan:
        shapes.sprayCan(poses[i]+vec3(0.72, 0.65, 0))
      for hp in 0..<e.armor: shapes.box(poses[i].x-0.3+hp.float32*0.25, poses[
          i].y+2.1, poses[i].z, 0.16, 0.09, 0.09, rgbx(65, 203, 245, 255))
    when defined(pwViewerProfile): profMark(15)
    if world.controlHearts.len>0:
      if territoryOverlay:
        # Hearts never move: each cell's nearest heart is found once per map, and only the
        # cells on screen are drawn (a big map has ~37,000 of them).
        let cellsX=(maxX()-200-minX()) div 200+1
        let cellsZ=(maxZ()-200-minZ()) div 200+1
        let key=(activeMap(),world.controlHearts.len,replayRulesVersion)
        if territoryKey!=key:
          territoryKey=key
          territoryNearest=newSeq[int16](cellsX*cellsZ)
          for iz in 0..<cellsZ:
            for ix in 0..<cellsX:
              let center=point(minX()+ix*200+100,minZ()+iz*200+100)
              var nearest=0
              if islandTerrain and islandMargin(center.x.int,center.z.int)<60:nearest= -1
              else:
                for i,h in world.controlHearts:
                  if distance2(center,h.pos)<distance2(center,world.controlHearts[nearest].pos):nearest=i
              territoryNearest[iz*cellsX+ix]=nearest.int16
        let view=groundView()
        for iz in max(0,(view[1]-minZ()) div 200)..min(cellsZ-1,(view[3]-minZ()) div 200):
          for ix in max(0,(view[0]-minX()) div 200)..min(cellsX-1,(view[2]-minX()) div 200):
            let nearest=territoryNearest[iz*cellsX+ix].int
            if nearest<0:continue
            let x=minX()+ix*200
            let z=minZ()+iz*200
            let owner=world.controlHearts[nearest].owner
            # FFA-kin owners are seats, coloured by family.
            let color=if owner<0:rgbx(150,155,160,55) elif ffa():kinColor(owner.int,85)
              elif owner notin 0..1:rgbx(150,155,160,55) else:rgbx(teamColors[owner].r,teamColors[owner].g,teamColors[owner].b,85)
            shapes.addQuad(position(point(x,z),0.09),position(point(x,z+200),0.09),
              position(point(x+200,z+200),0.09),position(point(x+200,z),0.09),color)
      for index, heart in world.controlHearts:
        if not onScreen(position(heart.pos), 1.6): continue
        if inspectedKind == 1 and inspectedId == index:
          shapes.addCircle(position(heart.pos, 0.025), 1.8, rgbx(250,226,140,180))
        let color=if heart.owner<0:rgbx(220,229,238,255)
          elif ffa():kinColor(heart.owner.int)
          elif heart.owner==0:rgbx(255,75,99,255) else:rgbx(65,221,255,255)
        let big = world.heartPoints(index) == BigHeartPoints
        shapes.heartTower(position(heart.pos),eye,color,heartAnimationTime,big)
        if index < world.heartCaptures.len:
          let capture = world.heartCaptures[index]
          if capture.ticks > 0 or capture.contested:
            let center = position(heart.pos, if big: 6.7 else: 4.9)
            let right = normalize(cross(vec3(0,1,0), normalize(eye-center)))
            let start = center-right*1.4
            let finish = center+right*1.4
            shapes.addLine(start, finish, rgbx(28,35,43,255), halfWidth=0.18)
            if capture.ticks > 0:
              let progressColor = if ffa(): kinColor(capture.team.int)
                elif capture.team == 0: rgbx(255,75,99,255)
                else: rgbx(65,221,255,255)
              shapes.addLine(start, start+right*(2.8*capture.ticks.float32/HeartCaptureTicks.float32),
                progressColor, halfWidth=0.12)
            if capture.contested:
              shapes.addLine(start+vec3(0,0.3,0),finish+vec3(0,0.3,0),
                rgbx(255,214,82,255),halfWidth=0.06)
    else:
      for side in 0..1:
        let heart = world.hearts[side]
        if heart.carrier < 0 or seen(heart.carrier):
          let p = position(heart.pos, if heart.carrier < 0: 1.8+sin(
              world.tick.float32/12)*0.12 else: 3.1)
          shapes.heartSculpture(p,eye,(if side==0:rgbx(255,75,99,255) else:rgbx(65,221,255,255)),heartAnimationTime*2*PI.float32/6)
    when defined(pwViewerProfile): profMark(16)
    if ffa():
      # FFA-kin great hearts: a big gold heart over its capture zone; the ring fills with the
      # charge while a quorum stands in it, and a spent heart sits grey until it wakes.
      for g in world.greatHearts:
        if not pointSeen(g.pos): continue
        let dormant = world.tick < g.dormantUntil
        let base = position(g.pos)
        let radius = GreatHeartRadius.float32/100
        proc ring(fraction: float32, color: ColorRGBX, width: float32, y: float32) =
          let segments = max(1, int(ceil(64*fraction)))
          for n in 0..<segments:
            let a = -PI.float32/2+2*PI.float32*fraction*n.float32/segments.float32
            let b = -PI.float32/2+2*PI.float32*fraction*(n+1).float32/segments.float32
            shapes.addLine(base+vec3(cos(a)*radius, y, sin(a)*radius),
              base+vec3(cos(b)*radius, y, sin(b)*radius), color, halfWidth = width)
        ring(1, (if dormant: rgbx(120, 125, 130, 200) else: rgbx(255, 214, 92, 170)), 0.05, 0.07)
        if not dormant and g.progress > 0:
          ring(clamp(g.progress.float32/GreatHeartCaptureTicks.float32, 0, 1),
            rgbx(255, 244, 190, 255), 0.13, 0.09)
        shapes.heartTower(base, eye, (if dormant: rgbx(128, 132, 138, 255) else: rgbx(255, 196, 60, 255)),
          heartAnimationTime, big = true)
    profMark(13)
    for i, c in world.cogs:
      if c.hp <= 0 or not shown(i) or not onScreen(poses[i]): continue
      let p = poses[i]
      if ffa():
        # Kin view: kin of the selected cog get a halo as bright as their relatedness; with
        # families picked in the header, their cogs get the halo. Everyone else fades to 40%.
        let (dim, halo) = kinEmphasis(i)
        if halo > 0:
          shapes.addCircle(p+vec3(0, 0.02, 0), 1.3, rgbx(255, 240, 170, uint8(halo)))
        shapes.addCircle(p+vec3(0, 0.04, 0), 0.65, kinColor(i, if dim: 102'u8 else: 255'u8))
        shapes.addCircle(p+vec3(0, 0.05, 0), 0.48, rgbx(43, 68, 55, if dim: 102'u8 else: 255'u8))
      else:
        shapes.addCircle(p+vec3(0, 0.04, 0), 0.65, teamColors[world.apparentTeam(i)])
        shapes.addCircle(p+vec3(0, 0.05, 0), 0.48, rgbx(43, 68, 55, 255))
      if i == selected: shapes.addCircle(p+vec3(0, 0.03, 0), 0.9, rgbx(250, 226,
          140, 180))
      if victory.active: continue
      let d = direction(c.pos, c.aim, 105)
      shapes.addLine(p+vec3(0, 1.05, 0), p+vec3(d.x.float32/100, 1.05,
          d.z.float32/100), rgbx(49, 60, 66, 255), halfWidth = 0.13)
      if c.cooldown >= (if replayRulesVersion >=
          3: FireCooldownTicks-1 else: 7): shapes.gem(p+vec3(d.x.float32/100,
          1.05, d.z.float32/100), 0.23, rgbx(255, 239, 177, 255))
      if c.shield > 0:
        let spawnProgress = clamp((36-c.shield.float32+alpha)/36,0'f32,1'f32)
        shapes.spawnBeam(p,(if ffa(): kinColor(i) else: teamColors[world.apparentTeam(i)]),spawnProgress,i)
      if trails:
        shapes.addLine(p+vec3(0, 0.08, 0), position(c.goal, 0.08), seatColor(i),
            halfWidth = 0.035)
      if bars:
        # Three pips in the teams game; FFA-kin's ten squeeze into the same 0.84-wide bar.
        let pitch = (if maxHp() > 3: 0.84'f32 / maxHp().float32 else: 0.28'f32)
        let pip = (if maxHp() > 3: 0.035'f32 else: 0.1'f32)
        for hp in 0..<c.hp: shapes.box(p.x-0.35+hp.float32*pitch, p.y+2.5, p.z,
            pip, 0.09, 0.09, rgbx(221, 253, 180, 255))
    profMark(14)
    for b in world.balls:
      if victory.active: continue
      if lens >= 0 and not seen(b.owner.int): continue
      if not onScreen(position(b.pos), 1.3): continue
      let start = point(b.pos.x-b.velocity.x, b.pos.z-b.velocity.z)
      let duration = if replayRulesVersion >= 9: 6'f32 else: 2'f32
      let f = clamp((duration-b.life.float32+alpha)/duration, 0'f32, 1'f32)
      # Four visible beads represent one shot; hit resolution stays unchanged.
      for bead in 0..3:
        let travel=f-bead.float32*0.055
        if travel<0:continue
        let ball=mix(position(start,1.05),position(b.pos,1.05),travel)
        let color=if ffa():kinColor(b.owner.int) elif team(b.owner.int)==0:rgbx(255,108,74,255) else:rgbx(89,220,255,255)
        shapes.paintball(ball,0.32-bead.float32*0.035,color)
        shapes.paintball(ball+vec3(-0.07,0.12,-0.04),0.085,rgbx(255,250,214,255))
    if islandTerrain: drawWater(vp, eye, (world.tick.float32+alpha)/24)
    profMark(7)
    shapes.draw(vp)
    profMark(8)
    # A real second 3D camera gives the selected bot's eye-level view.
    if firstPerson and selected >= 0 and world.cogs[selected].hp > 0 and shown(selected):
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
      if islandTerrain: drawWater(proj*v, p, (world.tick.float32+alpha)/24)
      shapes.draw(proj*v)
      glDisable(GL_SCISSOR_TEST)
    profMark(9)
    window.swapBuffers()
    profMark(10)
    when defined(emscripten):
      if not announced:
        let payload = ViewerIndex(events: index.events,
            momentum: index.momentum, names: recording.names,
            communications: recording.communications,
            seed: recording.seed).toJson()
        let data = payload.cstring
        {.emit: "EM_ASM({if(Module.paintbotIndex)Module.paintbotIndex(JSON.parse(UTF8ToString($0)));}, `data`);".}
        announced = true
      if not replayMode and sentGraphSamples != index.momentum.len:
        let samples = index.momentum.toJson().cstring
        {.emit: "EM_ASM({if(Module.paintbotGraphs)Module.paintbotGraphs(JSON.parse(UTF8ToString($0)));}, `samples`);".}
        sentGraphSamples = index.momentum.len
      if lastHud != world.tick or paused or victory.active:
        var screens: array[Seats, array[2, float32]]
        var visibility: array[Seats, bool]
        let footprint = groundFootprint(vp)
        for i in 0..<Seats:
          visibility[i] = shown(i)
          screens[i] = screenPoint(vp, poses[i]+vec3(0, 1, 0))
        var terrain: array[Seats, CogTerrain]
        for i, cog in world.cogs:
          let aim = if world.equipment[i].windup > 0:
              Point(x: cog.pos.x+world.equipment[i].gunAim.x,
                z: cog.pos.z+world.equipment[i].gunAim.z)
            else: cog.aim
          terrain[i] = CogTerrain(elevation: world.elevation(cog.pos),
            trench: world.trenchAt(cog.pos), spread: world.gunSpreadPercent(cog.pos, aim),
            territoryBoost: world.territoryBoost(i))
        var objects: seq[Inspectable]
        var heartHeld: seq[int]
        var heartValues: seq[int32]
        for i, h in world.controlHearts:
          heartHeld.add index.heartHeldTicks(i, world.tick.int)
          heartValues.add world.heartPoints(i)
          objects.add Inspectable(kind: "heart", id: i,
            bottom: projected(vp, position(h.pos, 0.4)),
            top: projected(vp, position(h.pos, if world.heartPoints(i) == BigHeartPoints: 6.2 else: 4.5)))
        for i, item in world.pickups:
          if item.readyAt > world.tick or not pointSeen(item.pos): continue
          objects.add Inspectable(kind: "pickup", id: i,
            bottom: projected(vp, position(item.pos, 0.1)), top: projected(vp, position(item.pos, 1.7)))
        var mode = "teams"
        var family: seq[int]
        var genes: seq[uint32]
        var rPct: seq[array[Seats, int32]]
        var kinHue: seq[float32]
        # The kinship tables and the cover never change within a match: the first state carries
        # them and later ones omit them (staticOmitted); viewer.js keeps the last copy.
        var hudWorld = world
        let staticOmitted = hudStaticSent and replayMode
        if staticOmitted: hudWorld.cover = @[]
        if ffa(): mode = "ffa_kin"
        if ffa() and not staticOmitted:
          for i in 0..<Seats:
            family.add activeKinship.family[i].int
            genes.add activeKinship.genes[i]
            kinHue.add kinHues[i]
            var row: array[Seats, int32]
            for j in 0..<Seats: row[j] = activeKinship.rPercent(i, j)
            rPct.add row
        let payload = ViewerState(mode: mode, family: family, genes: genes, rPct: rPct, kinHue: kinHue, terrain: terrain, objects: objects, heartHeld: heartHeld, heartValues: heartValues, combat: (if world.tick < index.combat.len: index.combat[world.tick] else: default(array[Seats, CombatStats])), rulesVersion: replayRulesVersion, maxHp: maxHp(), world: hudWorld, staticOmitted: staticOmitted, bounds: [minX(),minZ(),maxX(),maxZ()], recorded: recording.frames.len, total: transport.timelineEnd.int, live: not replayMode, playerSlot: options.playerSlot.int,
            paused: paused, celebrating: victory.active, celebrationSeconds: victory.elapsed, actionCamera: autoCamera, camera: [camX,camZ,distance], screen: screens, visible: visibility,
            footprint: footprint, map: mapName(), land: landMask()).toJson()
        let data = payload.cstring
        let tick = world.tick
        {.emit: "EM_ASM({if(Module.polyworldFrame)Module.polyworldFrame($1,0);if(Module.paintbotState)Module.paintbotState(JSON.parse(UTF8ToString($0)));}, `data`, `tick`);".}
        lastHud = world.tick
        hudStaticSent = true
    profMark(11)
    profReport()
  while not window.closeRequested: pollEvents()
  occlusionOutline.closeSelectionOutline()
