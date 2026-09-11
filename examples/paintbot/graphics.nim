## Painted Polyworld arena with hash-verified spectator analysis.
import std/[math, times, algorithm]
import windy, opengl, vmath, chroma, jsony
import polyworld/[shapes, characters, common, toon, shadows, quadterrain, pathing, actioncam]
import game, sim, analysis, villagegraphics, controls
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
  ViewerState = object
    rulesVersion: int
    world: World
    bounds: array[4,int]
    recorded: int
    total: int
    live: bool
    playerSlot: int
    paused: bool
    actionCamera: bool
    camera: array[3, float32]
    screen: array[Seats, array[2, float32]]
    visible: array[Seats, bool]
    footprint: array[4, array[2, float32]]
var
  transport: Player
  playbackRate = 1'f32
  orderX, orderY: float32
  orderKind = 0
  orderSeat = -1
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
  if value == 0: transport.pause()
  else: transport.play()
proc setSpeed(value: cfloat) {.exportc: "pw_speed", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  playbackRate = clamp(value, 0.25, 32)
  transport.setSpeed(speedIndexOf(value.int32))
proc setTick(value: cint) {.exportc: "pw_seek", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} = transport.seekTo(value.int32, play = false)
proc saveLiveRecording() {.exportc: "pw_save", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  if not replayMode:
    saveReplayFile("/human.replay", "paintbot_pw", replayRulesVersion.uint16, recording)
proc chargeGrenade(held: cint) {.exportc: "pw_charge", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  setGrenadeCharge(held != 0 and options.playerSlot > 0 and not replayMode and not transport.inHistory)
proc issueOrder(x, y: cfloat, kind, seat: cint) {.exportc: "pw_order", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  if options.playerSlot > 0 and not replayMode and not transport.inHistory:
    orderX = x; orderY = y; orderKind = kind.int; orderSeat = seat.int
proc selectSeat(value: cint) {.exportc: "pw_select", cdecl,
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} = selected = clamp(value.int,
    -1, Seats-1)
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
proc position(p: Point, y = 0'f32): Vec3 = vec3(p.x.float32/100-32, y+(
    if replayRulesVersion >= 9: world.elevation(p).float32/100 else: 0'f32),

p.z.float32/100-20)
proc seen(i: int): bool =
  if lens < 0: return true
  if lens < Seats: return world.visible(lens, i)
  for s in 0..<Seats:
    if team(s) == lens-Seats and world.cogs[s].hp > 0 and world.visible(s,
        i): return true
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
proc gem(r: var ShapeRenderer, p: Vec3, s: float32, color: ColorRGBX) =
  let c = rgbx(color.r,color.g,color.b,if color.a==255:254'u8 else:color.a)
  let top = p+vec3(0, s, 0); let bottom = p-vec3(0, s, 0)
  let ring = [p+vec3(s, 0, 0), p+vec3(0, 0, s), p+vec3(-s, 0, 0), p+vec3(0, 0, -s)]
  for i in 0..3:
    r.addTriangle(top, ring[i], ring[(i+1) mod 4], c)
    r.addTriangle(bottom, ring[(i+1) mod 4], ring[i], c)

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
  proc vertex(i,j,side:int):Vec3 =
    let t=i.float32*2*PI.float32/segments.float32
    let latitude=j.float32*PI.float32/(2*rings).float32
    let radius=sin(latitude)
    let x=1.5'f32*radius*pow(sin(t),3'f32)
    let y=1.5'f32*radius*(13*cos(t)-5*cos(2*t)-2*cos(3*t)-cos(4*t))/17
    let z=side.float32*0.8'f32*cos(latitude)
    # A gentle backwards lean shows the sculpted face from the arena camera.
    let yy=y*cos(0.45'f32)+z*sin(0.45'f32)
    let zz = -y*sin(0.45'f32)+z*cos(0.45'f32)
    p+vec3(x*cos(spin)+zz*sin(spin),yy,-x*sin(spin)+zz*cos(spin))*scale
  proc facet(a,b,c:Vec3) =
    let center=(a+b+c)/3
    var normal=cross(b-a,c-a)
    if dot(normal,normal)<0.0000001:return
    normal=normalize(normal)
    if dot(normal,center-p)<0:normal= -normal
    let light=normalize(vec3(-0.45,0.8,0.65))
    let view=normalize(eye-center)
    let diffuse=0.48'f32+0.52*max(0'f32,dot(normal,light))
    let gloss=pow(max(0'f32,dot(normal,normalize(light+view))),36'f32)*0.8
    let rim=pow(1-abs(dot(normal,view)),3'f32)*0.22
    proc channel(c:uint8):uint8 =
      uint8(clamp(c.float32*diffuse+255*(gloss+rim),0,255))
    let delta=center-eye
    facets.add((a,b,c,rgbx(channel(color.r),channel(color.g),channel(color.b),254),dot(delta,delta)))
  for side in [-1,1]:
    for j in 0..<rings:
      for i in 0..<segments:
        let a=vertex(i,j,side)
        let b=vertex(i+1,j,side)
        let c=vertex(i+1,j+1,side)
        let d=vertex(i,j+1,side)
        if j>0:facet(a,b,c)
        facet(a,c,d)
  # The shared shape batch does not write depth; sort the closed mesh faces.
  facets.sort(proc(a,b:Facet):int=cmp(b.depth,a.depth))
  for face in facets:r.addTriangle(face.a,face.b,face.c,face.tint)

proc heartTower(r: var ShapeRenderer, base, eye: Vec3, color: ColorRGBX,
    time: float32, big = false) =
  let heart=base+vec3(0,(if big: 4.1 else: 3.05)+sin(time)*0.05,0)
  let front=normalize(eye-heart)
  let right=normalize(cross(vec3(0,1,0),front))
  let up=cross(front,right)
  # Layered translucent halos soften to nothing at the outer edge.
  for layer in 0..<7:
    let radius=(2.15'f32-layer.float32*0.19)*(if big: 1.8'f32 else: 1'f32)
    let center=heart-front*0.85
    for i in 0..<32:
      let a=i.float32*2*PI.float32/32
      let b=(i+1).float32*2*PI.float32/32
      r.addTriangle(center,center+(right*cos(a)+up*sin(a))*radius,
        center+(right*cos(b)+up*sin(b))*radius,
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
          uint8(color.b.float32*shade), if color.a==255:254'u8 else:color.a)
      r.addQuad(p0, p3, p2, p1, col)

proc runGraphics*() =
  setup()
  var index = if replayMode: indexReplay() else:
    ReplayIndex(checkpoints: @[Checkpoint(state: snapshot(world))], momentum: @[graphSample(world)])
  transport = initPlayer(not replayMode, if replayMode: recording.frames.len.int32 else: options.maximumTicks,
    playing = not options.pauseOnStart, speed = options.speed)
  playbackRate = options.speed.float32
  transport.sync(world.tick, recording.frames.len.int32, world.winner != -1)
  if options.playerSlot > 0:
    selected = options.playerSlot.int-1
    lens = selected

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
      if organicTerrain and gx>=minX() div 100 and gx<maxX() div 100 and gz>=minZ() div 100 and gz<maxZ() div 100:
        let px=gx*100+50;let pz=gz*100+50
        let local=landCoordinates(px,pz)
        let width=130+landWave(px+pz,1600,35)
        let radius=sqrt(((local.x-3200)*(local.x-3200)+(local.z-2000)*(local.z-2000)).float)
        tile.kind=GrassTile
        if forestRouteDistance(px,pz)<width or villageLaneDistance(px,pz)<width or abs(radius-620)<110:
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
  var heartAnimationTime = 0'f32
  var previous = world.cogs
  var announced = false
  var lastHud = -1
  var sentGraphSamples = 0
  var visibilityTick = -1
  var visibilityLens = -2
  window.onFrame = proc() =
    let now = epochTime(); let dt = min(now-last, 0.1); last = now
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
      advance()
      if atFrontier: index.sampleGraphs(world)
      if atFrontier and world.tick mod 240 == 0:
        index.checkpoints.add Checkpoint(state: snapshot(world))
      transport.sync(world.tick, recording.frames.len.int32, world.winner != -1)
    let paused = not transport.playing
    let alpha = if paused: 1'f32 else: clamp(transport.accumulator*TickRate.float32, 0, 1)
    var poses: array[Seats, Vec3]
    for i, c in world.cogs:
      poses[i] = if previous[i].hp > 0 and c.hp > 0: mix(position(previous[
          i].pos), position(c.pos), alpha) else: position(c.pos)
    if follow and selected >= 0:
      let blend = 1-exp(-5*dt.float32)
      camX = mix(camX, poses[selected].x, blend)
      camZ = mix(camZ, poses[selected].z, blend)
      camY = mix(camY, poses[selected].y+1, blend)
    var target = vec3(camX, camY, camZ)
    # Keep the final frame still behind the results, including camera toggles.
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
          for j in i+1..<Seats:
            if team(i) == team(j) or world.cogs[j].hp <= 0 or not seen(j): continue
            let gap = length(poses[i]-poses[j])
            if gap < 40:
              director.noteInterest(int32(100+i*Seats+j), (poses[i]+poses[j])*0.5,
                100-gap, gap*0.5+3, world.tick, 1)
        for n, h in world.controlHearts:
          var nearby: array[2, int]
          for i, c in world.cogs:
            if c.hp > 0 and seen(i) and distance2(c.pos,h.pos) < 1000000:
              inc nearby[team(i)]
          if nearby[0]+nearby[1] > 0:
            let contested = nearby[0] > 0 and nearby[1] > 0
            director.noteInterest(int32(1000+n), position(h.pos, 2),
              (if contested: 125'f32 else: 45'f32), 9, world.tick, 1)
        for n, event in index.events:
          if event.tick > world.tick or world.tick-event.tick > 36: continue
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

    let fittedDistance = distance*max(1'f32, 1.6'f32/(window.size.x.float32/max(
        1, window.size.y).float32))
    let eye = target+vec3(sin(yaw)*cos(tilt), sin(tilt), cos(yaw)*cos(
        tilt))*fittedDistance
    let view = lookAt(eye, target, vec3(0, 1, 0))
    let projection = perspective(45'f32, window.size.x.float32/max(1,
        window.size.y).float32, 0.1'f32, 600'f32)
    let vp = projection*view
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
    if not islandTerrain:
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
      let spin = heartAnimationTime*1.08
      let p = position(item.pos, if special: 0.7+0.15*sin(spin*1.7) else: 0.28)
      let color = case item.kind
        of grenadePickup: rgbx(183, 237, 62, 255)
        of sprayPickup: rgbx(255, 89, 195, 255)
        of armorPickup: rgbx(96, 191, 241, 255)
        of medkitPickup: rgbx(243, 238, 207, 255)
      shapes.addCircle(position(item.pos, 0.04), if special: 1.0 else: 0.55, color)
      if special:
        shapes.equipmentPickup(p,eye,spin,item.kind == grenadePickup)
      else:
        shapes.box(p.x, p.y, p.z, 0.4, 0.48, 0.32, color,
            if item.kind == medkitPickup: spin else: 0'f32)
      if item.kind == medkitPickup:
        shapes.box(p.x, p.y+0.49, p.z, 0.26, 0.03, 0.08, rgbx(215, 69, 66, 255), spin)
        shapes.box(p.x, p.y+0.49, p.z, 0.08, 0.03, 0.26, rgbx(215, 69, 66, 255), spin)

    for g in world.grenades:
      let f = clamp((world.tick-g.releasedAt).float32/max(1,
          g.landsAt-g.releasedAt).float32, 0, 1)
      let p = mix(position(g.start, if g.owner < 0: 14 else: 1), position(g.target, 0.1), f)+vec3(0, sin(
          f*PI.float32)*3, 0)
      shapes.gem(p, 0.4, rgbx(190, 211, 79, 254))
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
        let spread = if replayRulesVersion >= 17: 0.6'f32 else: 0.25'f32
        for ray in -4..4:
          for n in 1..10:
            let f = n.float32/10
            let lateral=ray.float32/4*spread
            let p = point(c.pos.x.int+int((e.sprayAim.x.float32-e.sprayAim.z.float32*lateral)*f),
              c.pos.z.int+int((e.sprayAim.z.float32+e.sprayAim.x.float32*lateral)*f))
            if not world.lineClear(c.pos,p):break
            shapes.paintball(position(p,0.9+sin(n.float32+ray.float32)*0.15),
              0.08+f*0.16,teamColors[team(i)])
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
            if islandTerrain and islandMargin(center.x.int,center.z.int)<60:continue
            var nearest=0
            for i,h in world.controlHearts:
              if distance2(center,h.pos)<distance2(center,world.controlHearts[nearest].pos):nearest=i
            let owner=world.controlHearts[nearest].owner
            let color=if owner<0:rgbx(150,155,160,55) else:rgbx(teamColors[owner].r,teamColors[owner].g,teamColors[owner].b,85)
            shapes.addQuad(position(point(x,z),0.09),position(point(x,z+200),0.09),
              position(point(x+200,z+200),0.09),position(point(x+200,z),0.09),color)
      for index, heart in world.controlHearts:
        let color=if heart.owner<0:rgbx(220,229,238,255)
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
              let progressColor = if capture.team == 0: rgbx(255,75,99,255)
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
      if c.shield > 0:
        let spawnProgress = clamp((36-c.shield.float32+alpha)/36,0'f32,1'f32)
        shapes.spawnBeam(p,teamColors[team(i)],spawnProgress,i)
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
    if islandTerrain: drawWater(vp, eye, (world.tick.float32+alpha)/24)
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
      if islandTerrain: drawWater(proj*v, p, (world.tick.float32+alpha)/24)
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
      if not replayMode and sentGraphSamples != index.momentum.len:
        let samples = index.momentum.toJson().cstring
        {.emit: "EM_ASM({if(Module.paintbotGraphs)Module.paintbotGraphs(JSON.parse(UTF8ToString($0)));}, `samples`);".}
        sentGraphSamples = index.momentum.len
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
        let payload = ViewerState(rulesVersion: replayRulesVersion, world: world, bounds: [minX(),minZ(),maxX(),maxZ()], recorded: recording.frames.len, total: transport.timelineEnd.int, live: not replayMode, playerSlot: options.playerSlot.int,
            paused: paused, actionCamera: autoCamera, camera: [camX,camZ,distance], screen: screens, visible: visibility,
            footprint: footprint).toJson()
        let data = payload.cstring
        let tick = world.tick
        {.emit: "EM_ASM({if(Module.polyworldFrame)Module.polyworldFrame($1,0);if(Module.paintbotState)Module.paintbotState(JSON.parse(UTF8ToString($0)));}, `data`, `tick`);".}
        lastHud = world.tick
  while not window.closeRequested: pollEvents()
