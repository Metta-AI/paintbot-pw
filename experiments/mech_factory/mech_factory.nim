## Mech factory: Total Annihilation-style procedural mechs assembled from the
## 271-part greeble kit. A procedural skeleton (biped, quad or hexapod legs)
## carries greeble parts fitted to each slot — torso, pelvis, thighs, shins,
## feet, head, weapons, back — and everything animates procedurally: walk
## gaits with analytic two-bone leg IK, servo-stepped idle scanning, turning
## in place, weapon recoil and power down/up. No baked clips, no toon shader:
## a custom metallic Blinn-Phong look via shady.
##
## Run from the repo root: nim r experiments/mech_factory/mech_factory.nim
##
## Screenshot mode: nim r -d:takeScreenshot ... with optional env vars
##   RANDOM_SEED=<n> ANIM=<idle|walk|turn|fire|powerdown|powerup>
##   SHOT=<path.png> SHOT_FRAME=<n> CAM_YAW=<f> CAM_PITCH=<f> CAM_DIST=<f>
##   MECH_SHOWROOM=1 shows the whole part library on a grid instead.
##
## Part roles come from parts_tags.json, authored by rendering contact
## sheets with tag_parts.nim and describing every part visually.

import
  std/[strformat, times, json, tables, random, strutils, math, os, algorithm],
  bumpy, vmath, chroma, shady, jsony,
  gltf,
  silky,
  polyworld/shapes

const
  DataDir = "../polyworld_data"
  GreeblePath = DataDir & "/greeble/271_greebles_low_poly_model.glb"
  ThemeDir = DataDir & "/themes/main/"
  TagsPath = "experiments/mech_factory/parts_tags.json"
  PresetsDir = "experiments/mech_factory/presets"

## Atlas

let builder = newAtlasBuilder(1024, 4)
builder.addDir(ThemeDir, ThemeDir)
builder.addFont(ThemeDir & "IBMPlexSans-Regular.ttf", "H1", 32.0)
builder.addFont(ThemeDir & "IBMPlexSans-Regular.ttf", "Default", 18.0)
builder.write("tmp/editor.atlas.png")

## Window

let window = newWindow(
  "Mech Factory",
  ivec2(1400, 900),
  vsync = false,
  msaa = msaa4x
)
makeContextCurrent(window)
loadExtensions()

let sk = newSilky(window, "tmp/editor.atlas.png")

window.runeInputEnabled = true
window.onRune = proc(rune: Rune) =
  sk.inputRunes.add(rune)

var renderer = newRenderer(window)

## Metal shader
#
# Blinn-Phong with a metallic mix, a fake vertical-gradient environment
# reflection and a steel-blue fresnel rim. Attribute names follow the gltf
# convention (compileShaderFiles binds them by name), so the primitives'
# existing vertex arrays bind unchanged — no skinning: mech parts are rigid.

var
  metalModel: Uniform[Mat4]
  metalNormalMatrix: Uniform[Mat3]
  metalView: Uniform[Mat4]
  metalProj: Uniform[Mat4]
  metalLightDirection: Uniform[Vec3]   # direction the light travels
  metalCameraPosition: Uniform[Vec3]
  metalTint: Uniform[Vec4]
  metalParams: Uniform[Vec4]           # metallic, gloss, rim strength, unused

proc metalVert(
  vertexPosition: Vec3,
  vertexNormal: Vec3,
  gl_Position: var Vec4,
  worldPos: var Vec3,
  normal: var Vec3
) =
  worldPos = (metalModel * vec4(vertexPosition, 1.0'f)).xyz
  normal = normalize(metalNormalMatrix * vertexNormal)
  gl_Position = metalProj * metalView * vec4(worldPos, 1.0'f)

proc metalFrag(
  worldPos: Vec3,
  normal: Vec3,
  fragColor: var Vec4
) =
  var n: Vec3 = normalize(normal)
  if not gl_FrontFacing:
    n = -n
  let
    eye: Vec3 = normalize(metalCameraPosition - worldPos)
    toLight: Vec3 = normalize(-metalLightDirection)
    metallic = metalParams.x
    gloss = metalParams.y
    rimStrength = metalParams.z
    albedo: Vec3 = metalTint.rgb
    diffuse = max(dot(n, toLight), 0.0'f)
    halfVec: Vec3 = normalize(toLight + eye)
    shininess = mix(8.0'f, 96.0'f, gloss)
    specular = pow(max(dot(n, halfVec), 0.0'f), shininess)
    reflected: Vec3 = reflect(-eye, n)
    envT = clamp(reflected.y * 0.5'f + 0.5'f, 0.0'f, 1.0'f)
    envColor: Vec3 = mix(
      vec3(0.11'f, 0.10'f, 0.09'f), vec3(0.52'f, 0.58'f, 0.68'f), envT)
    facing = 1.0'f - abs(dot(eye, n))
    rim = facing * facing * facing * facing
    ambient: Vec3 = vec3(0.30'f, 0.32'f, 0.38'f)
    sunColor: Vec3 = vec3(1.00'f, 0.98'f, 0.94'f)
  var lit: Vec3 = albedo * (ambient + sunColor * diffuse)
  # Metal picks up the environment and colours its own reflections.
  lit = lit + envColor * (albedo * 0.6'f + vec3(0.4'f)) * (metallic * 0.5'f)
  let specTint: Vec3 = mix(vec3(1.0'f), albedo, metallic)
  lit = lit + specTint * specular * (0.35'f + 0.65'f * gloss) *
    (0.8'f + 0.5'f * clamp(n.y, 0.0'f, 1.0'f))
  lit = lit + vec3(0.45'f, 0.58'f, 0.78'f) * rim * rimStrength
  fragColor = vec4(lit, 1.0'f)

const
  MetalVertSrc = toShader(metalVert, glsl4Desktop, shaderVertex)
  MetalFragSrc = toShader(metalFrag, glsl4Desktop, shaderFragment)

## Paint

type PaintRole = enum
  HullPaint, AccentPaint, DarkPaint

type PaintScheme = object
  name: string
  colors: array[PaintRole, Color]
  params: array[PaintRole, Vec3]       # metallic, gloss, rim strength

proc scheme(
  name, hull, accent, dark: string,
  hullParams = vec3(0.55, 0.45, 0.5),
  accentParams = vec3(0.3, 0.55, 0.5),
  darkParams = vec3(0.85, 0.6, 0.35)
): PaintScheme =
  PaintScheme(
    name: name,
    colors: [
      parseHtmlColor("#" & hull),
      parseHtmlColor("#" & accent),
      parseHtmlColor("#" & dark),
    ],
    params: [hullParams, accentParams, darkParams]
  )

const PaintSchemes = [
  scheme("Army", "5A6B44", "C2B280", "3A3D3B"),
  scheme("Arm blue", "3E5F8A", "D8DCE0", "2B2F38"),
  scheme("Core red", "8A2F2B", "1E1E22", "4A4A50"),
  scheme("Gunmetal", "6A7076", "9AA2AA", "3C4046"),
  scheme("Desert", "A98F5F", "6B5B3E", "4E4335"),
  scheme("Winter", "C9CFD4", "7A8AA0", "34383E"),
]

## Metal renderer context

type
  MetalUniforms = object
    model, normalMatrix, view, proj: GLint
    lightDirection, cameraPosition, tint, params: GLint

  MetalContext = ref object
    shader: GLuint
    uniforms: MetalUniforms
    view, proj: Mat4
    cameraPosition: Vec3
    lightDirection: Vec3
    schemeIndex: int
    paintRoles: Table[string, PaintRole]  # mesh node name -> role

proc newMetalContext(): MetalContext =
  result = MetalContext(lightDirection: normalize(vec3(0.7, -0.4, -0.6)))
  result.shader = compileShaderFiles(MetalVertSrc, MetalFragSrc)
  template loc(field: untyped, name: string) =
    result.uniforms.field = glGetUniformLocation(result.shader, name)
  loc(model, "metalModel")
  loc(normalMatrix, "metalNormalMatrix")
  loc(view, "metalView")
  loc(proj, "metalProj")
  loc(lightDirection, "metalLightDirection")
  loc(cameraPosition, "metalCameraPosition")
  loc(tint, "metalTint")
  loc(params, "metalParams")

proc drawNode(ctx: MetalContext, node: Node) =
  if not node.visible:
    return
  if node.mesh != nil:
    let
      role = ctx.paintRoles.getOrDefault(node.name, HullPaint)
      paint = PaintSchemes[ctx.schemeIndex]
      tint = paint.colors[role]
      params = paint.params[role]
    var
      modelMat = node.mat
      normalMat = node.mat.normalMatrix
    let u = ctx.uniforms
    glUniformMatrix4fv(u.model, 1, GL_FALSE, cast[ptr float32](modelMat.addr))
    glUniformMatrix3fv(
      u.normalMatrix, 1, GL_FALSE, cast[ptr float32](normalMat.addr))
    glUniform4f(u.tint, tint.r, tint.g, tint.b, tint.a)
    glUniform4f(u.params, params.x, params.y, params.z, 0)
    for primitive in node.mesh.primitives:
      primitive.uploadToGpu()
      glBindVertexArray(primitive.data.vertexArrayId)
      if primitive.indices16.len > 0:
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.data.indicesId)
        glDrawElements(
          GL_TRIANGLES, primitive.indices16.len.GLint, GL_UNSIGNED_SHORT, nil)
      elif primitive.indices32.len > 0:
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, primitive.data.indicesId)
        glDrawElements(
          GL_TRIANGLES, primitive.indices32.len.GLint, GL_UNSIGNED_INT, nil)
      else:
        glDrawArrays(GL_TRIANGLES, 0, primitive.points.len.cint)
  for child in node.nodes:
    ctx.drawNode(child)

proc draw(ctx: MetalContext, root: Node) =
  ## Draws every visible mesh under root with the metal shader. The greeble
  ## kit's material is double sided, so culling stays off.
  root.updateTransforms(mat4())
  glUseProgram(ctx.shader)
  let u = ctx.uniforms
  var
    viewMat = ctx.view
    projMat = ctx.proj
  glUniformMatrix4fv(u.view, 1, GL_FALSE, cast[ptr float32](viewMat.addr))
  glUniformMatrix4fv(u.proj, 1, GL_FALSE, cast[ptr float32](projMat.addr))
  glUniform3f(
    u.lightDirection, ctx.lightDirection.x, ctx.lightDirection.y,
    ctx.lightDirection.z)
  glUniform3f(
    u.cameraPosition, ctx.cameraPosition.x, ctx.cameraPosition.y,
    ctx.cameraPosition.z)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)
  glDisable(GL_BLEND)
  glDisable(GL_CULL_FACE)
  ctx.drawNode(root)
  glBindVertexArray(0)
  glUseProgram(0)

var metal = newMetalContext()

## Part library
#
# The greeble glb nests each part as a group node (pure grid translation)
# over an Object_N mesh leaf (identity), so the mesh vertices are already in
# part-local space with the base at y ~ 0. Only the meshes are kept; the
# source tree is never drawn. Roles per part come from parts_tags.json.

type PartDef = object
  name: string
  mesh: Mesh
  boundsMin, boundsMax: Vec3
  size: Vec3
  longAxis: int          # 0/1/2, axis of the largest extent
  vertCount: int
  tags: seq[string]
  roles: seq[string]

var parts: seq[PartDef]

proc linearIsIdentity(m: Mat4): bool =
  abs(m[0, 0] - 1) < 1e-3 and abs(m[1, 1] - 1) < 1e-3 and
    abs(m[2, 2] - 1) < 1e-3 and abs(m[0, 1]) < 1e-3 and
    abs(m[0, 2]) < 1e-3 and abs(m[1, 0]) < 1e-3 and
    abs(m[1, 2]) < 1e-3 and abs(m[2, 0]) < 1e-3 and abs(m[2, 1]) < 1e-3

block loadParts:
  let source = readGltfFile(GreeblePath)
  source.root.updateTransforms()
  for node in source.root.walkNodes:
    if not node.name.startsWith("greeble"):
      continue
    var meshNode: Node
    for child in node.walkNodes:
      if child.mesh != nil:
        doAssert meshNode == nil, "two meshes under " & node.name
        meshNode = child
    doAssert meshNode != nil, "no mesh under " & node.name
    doAssert linearIsIdentity(meshNode.mat),
      "unexpected rotation/scale on " & node.name
    var part = PartDef(name: node.name, mesh: meshNode.mesh)
    part.boundsMin = vec3(float32.high)
    part.boundsMax = vec3(float32.low)
    for primitive in part.mesh.primitives:
      for point in primitive.points:
        part.boundsMin = min(part.boundsMin, point)
        part.boundsMax = max(part.boundsMax, point)
      part.vertCount += primitive.points.len
    part.size = part.boundsMax - part.boundsMin
    part.longAxis = 0
    if part.size.y > part.size[part.longAxis]: part.longAxis = 1
    if part.size.z > part.size[part.longAxis]: part.longAxis = 2
    parts.add part
  doAssert parts.len == 271, "expected 271 greebles, got " & $parts.len

doAssert fileExists(TagsPath), "run tag_parts.nim and author " & TagsPath
block loadTags:
  let tags = parseFile(TagsPath)
  for part in parts.mitems:
    doAssert tags.hasKey(part.name), "untagged part " & part.name
    let entry = tags[part.name]
    for tag in entry["tags"]:
      part.tags.add tag.getStr
    for role in entry["roles"]:
      part.roles.add role.getStr

## Slots

type SlotKind = enum
  TorsoSlot, PelvisSlot, ThighSlot, ShinSlot, FootSlot, HipSlot,
  HeadSlot, WeaponLSlot, WeaponRSlot, BackSlot

const
  # Hips draw from the pelvis pool: compact chunky/round joint housings.
  SlotRole: array[SlotKind, string] = [
    "torso", "pelvis", "thigh", "shin", "foot", "pelvis",
    "head", "weapon", "weapon", "back"]
  SlotLabel: array[SlotKind, string] = [
    "Torso", "Pelvis", "Thigh", "Shin", "Foot", "Hip",
    "Head", "Weapon L", "Weapon R", "Back"]
  OptionalSlot = {HipSlot, HeadSlot, WeaponLSlot, WeaponRSlot, BackSlot}

var slotParts: array[SlotKind, seq[int]]
for slot in SlotKind:
  for i, part in parts:
    if SlotRole[slot] in part.roles:
      slotParts[slot].add i
  doAssert slotParts[slot].len > 0, "no parts tagged " & SlotRole[slot]

## Mech spec

type
  LegConfig = enum
    Biped, Quad, Hexapod

  SlotChoice = object
    part: int            # index into slotParts[slot], -1 = none (optionals)
    role: PaintRole
    girth: float32       # cross-axis thickness multiplier

  MechSpec = object
    seed: int
    legConfig: LegConfig
    kneesForward: bool                  # true = human knee, false = chicken
    symmetricTop: bool                  # right arm mirrors the left
    hipHeight, thighLen, shinLen: float32
    hipWidth, bodyLen, torsoHeight, headScale: float32
    splay: float32                      # 0 legs under hips .. 1 spider
    strideLen, gaitFreq, stepHeight: float32
    paletteIndex: int
    slots: array[SlotKind, SlotChoice]

proc randomMech(seed: int): MechSpec =
  result.seed = seed
  var rng = initRand(seed)
  let roll = rng.rand(1.0)
  result.legConfig =
    if roll < 0.45: Biped
    elif roll < 0.75: Quad
    else: Hexapod
  result.kneesForward = rng.rand(1.0) < 0.4
  result.symmetricTop = rng.rand(1.0) < 0.45
  result.thighLen = rng.rand(0.45 .. 0.9).float32
  result.shinLen = rng.rand(0.4 .. 0.8).float32
  let legLen = result.thighLen + result.shinLen
  case result.legConfig
  of Biped:
    result.hipHeight = legLen * rng.rand(0.82 .. 0.92).float32
    result.hipWidth = rng.rand(0.5 .. 1.1).float32
    result.bodyLen = 0
    result.torsoHeight = rng.rand(1.3 .. 2.2).float32
    result.splay = 0
  of Quad:
    result.hipHeight = legLen * rng.rand(0.75 .. 0.88).float32
    result.hipWidth = rng.rand(0.8 .. 1.6).float32
    result.bodyLen = rng.rand(1.2 .. 2.2).float32
    result.torsoHeight = rng.rand(0.8 .. 1.5).float32
    result.splay = rng.rand(0.15 .. 0.4).float32
  of Hexapod:
    result.hipHeight = legLen * rng.rand(0.5 .. 0.7).float32
    result.hipWidth = rng.rand(0.9 .. 1.6).float32
    result.bodyLen = rng.rand(1.4 .. 2.4).float32
    result.torsoHeight = rng.rand(0.7 .. 1.2).float32
    result.splay = rng.rand(0.55 .. 0.9).float32
    result.kneesForward = true
  result.headScale = rng.rand(0.6 .. 1.3).float32
  result.strideLen = legLen * rng.rand(0.5 .. 0.85).float32
  result.gaitFreq = rng.rand(0.9 .. 1.6).float32
  result.stepHeight = legLen * rng.rand(0.12 .. 0.3).float32
  result.paletteIndex = rng.rand(PaintSchemes.high)
  for slot in SlotKind:
    var choice = SlotChoice(
      part: rng.rand(slotParts[slot].high),
      girth: rng.rand(0.8 .. 1.3).float32,
    )
    let chance =
      case slot
      of HipSlot: 0.85
      of HeadSlot: 0.85
      of BackSlot: 0.7
      of WeaponLSlot: 0.8
      of WeaponRSlot: 0.6
      else: 1.0
    if slot in OptionalSlot and rng.rand(1.0) > chance:
      choice.part = -1
    choice.role =
      case slot
      of ThighSlot, ShinSlot, HipSlot:
        if rng.rand(1.0) < 0.6: DarkPaint else: HullPaint
      of TorsoSlot, PelvisSlot:
        if rng.rand(1.0) < 0.7: HullPaint else: AccentPaint
      of FootSlot:
        if rng.rand(1.0) < 0.5: DarkPaint else: HullPaint
      of HeadSlot:
        if rng.rand(1.0) < 0.4: AccentPaint else: HullPaint
      of WeaponLSlot, WeaponRSlot:
        if rng.rand(1.0) < 0.7: DarkPaint else: AccentPaint
      of BackSlot:
        [HullPaint, AccentPaint, DarkPaint][rng.rand(2)]
    result.slots[slot] = choice

## Mech build

proc newJoint(name: string): Node =
  ## Every hand-built node goes through here: a bare Node() has a zero
  ## quaternion and zero scale, and resetToBase restores the base fields
  ## every frame, so both sides must start sane.
  Node(
    name: name,
    rot: quat(0, 0, 0, 1), baseRot: quat(0, 0, 0, 1),
    scale: vec3(1), baseScale: vec3(1),
    visible: true, baseVisible: true,
  )

proc bake(node: Node) =
  ## Copies the built pose into the base fields, making it the bind pose
  ## that resetToBase restores each frame.
  node.basePos = node.pos
  node.baseRot = node.rot
  node.baseScale = node.scale
  node.baseVisible = node.visible
  for child in node.nodes:
    bake(child)

proc qmul(a, b: Quat): Quat =
  ## Hamilton product: the rotation b followed by a.
  quat(
    a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
    a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
    a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
  )

proc conj(q: Quat): Quat =
  quat(-q.x, -q.y, -q.z, q.w)

proc rotateVec(q: Quat, v: Vec3): Vec3 =
  (q.mat4 * vec4(v, 0)).xyz

type
  Leg = object
    thigh, knee, ankle: Node
    partHip, partThigh, partShin, partFoot: Node
    hipOffset: Vec3      # in pelvis space
    splayRot: Quat       # yaw of the leg's bend plane
    phase: float32       # gait phase offset
    rest: Vec3           # foot rest position, mech-root space, y = 0

  Mech = ref object
    spec: MechSpec
    root, pelvis, torso, head: Node
    partPelvis, partTorso, partHead, partBack: Node
    shoulders: array[2, Node]
    weapons: array[2, Node]
    legs: seq[Leg]
    joints: seq[Node]    # cached walkNodes for pose capture
    legLen: float32
    footHeight: float32  # sole-to-ankle distance of the fitted foot

type FitAxis = enum
  FitDown,     # long axis hangs -Y below the joint (thigh, shin)
  FitForward,  # long axis points +Z (weapons)
  FitFoot,     # smallest axis up, long axis +Z, toe-forward
  FitUpright,  # authored orientation, base resting on the joint (torso, head)
  FitCenter    # authored orientation, centered on the joint (pelvis, back)

var mirrorCache: Table[string, Mesh]

proc mirroredMesh(mesh: Mesh): Mesh =
  ## An X-mirrored copy of a part mesh, so left legs are true mirror images
  ## of right legs instead of translated copies. Positions and normals are
  ## negated on X and the triangle winding is reversed so faces still point
  ## outward. Cached per mesh; the copy uploads its own GPU buffers.
  if mesh.name in mirrorCache:
    return mirrorCache[mesh.name]
  result = Mesh(name: mesh.name & ".mirror")
  for src in mesh.primitives:
    let prim = Primitive(
      uvs: src.uvs,
      uvs1: src.uvs1,
      colors: src.colors,
      material: src.material,
      mode: src.mode,
      points: src.points,
      normals: src.normals,
      tangents: src.tangents,
      indices16: src.indices16,
      indices32: src.indices32,
    )
    for p in prim.points.mitems:
      p.x = -p.x
    for n in prim.normals.mitems:
      n.x = -n.x
    for t in prim.tangents.mitems:
      t.x = -t.x
      t.w = -t.w
    var i = 0
    while i + 2 < prim.indices16.len:
      swap(prim.indices16[i + 1], prim.indices16[i + 2])
      i += 3
    i = 0
    while i + 2 < prim.indices32.len:
      swap(prim.indices32[i + 1], prim.indices32[i + 2])
      i += 3
    if prim.indices16.len == 0 and prim.indices32.len == 0:
      i = 0
      while i + 2 < prim.points.len:
        swap(prim.points[i + 1], prim.points[i + 2])
        swap(prim.normals[i + 1], prim.normals[i + 2])
        i += 3
    result.primitives.add prim
  mirrorCache[mesh.name] = result

proc fitPart(
  spec: MechSpec, slot: SlotKind, axis: FitAxis, targetLen: float32,
  mirror = false
): tuple[node: Node, rmin, rmax: Vec3] =
  ## Builds a wrapper node carrying the slot's greeble scaled to targetLen
  ## along its fit axis and re-based onto the joint origin. Returns the
  ## placed bounds in the joint's frame so callers can stack mounts.
  ## With mirror the whole fitted part is reflected across the joint's
  ## X = 0 plane (mirrored mesh + conjugated transform).
  let choice = spec.slots[slot]
  doAssert choice.part >= 0
  let part = parts[slotParts[slot][choice.part]]

  var rot = quat(0, 0, 0, 1)
  case axis
  of FitDown:
    # Long axis onto +Y, then the part hangs below the joint.
    case part.longAxis
    of 0: rot = quatRotateZ(PI.float32 / 2)
    of 2: rot = quatRotateX(-PI.float32 / 2)
    else: discard
  of FitForward:
    case part.longAxis
    of 0: rot = quatRotateY(-PI.float32 / 2)
    of 1: rot = quatRotateX(PI.float32 / 2)
    else: discard
  of FitFoot:
    # Long axis onto +Z first...
    case part.longAxis
    of 0: rot = quatRotateY(-PI.float32 / 2)
    of 1: rot = quatRotateX(PI.float32 / 2)
    else: discard
    # ...then, if the smallest extent did not land on Y, roll about Z.
    var smallest = 0
    if part.size.y < part.size[smallest]: smallest = 1
    if part.size.z < part.size[smallest]: smallest = 2
    let smallestOnY =
      case part.longAxis
      of 0: smallest == 1          # X->Z keeps Y on Y
      of 1: smallest == 2          # Y->Z brings Z onto -Y
      else: smallest == 1          # Z->Z keeps Y on Y
    if not smallestOnY:
      rot = qmul(quatRotateZ(PI.float32 / 2), rot)
  of FitUpright, FitCenter:
    discard

  let s = targetLen / max(part.size[part.longAxis], 0.001)
  # Cross-section girth, clamped so limbs never outgrow their length.
  var girth = choice.girth
  if axis in {FitDown, FitForward}:
    var maxCross = 0'f32
    for i in 0 .. 2:
      if i != part.longAxis:
        maxCross = max(maxCross, part.size[i])
    let limit = if axis == FitDown: 0.55'f32 else: 0.8'f32
    girth = min(girth, limit * targetLen / max(maxCross * s, 0.001))
    girth = max(girth, 0.14'f32 * targetLen / max(maxCross * s, 0.001))
  var scale = vec3(s * girth)
  scale[part.longAxis] = s
  if axis in {FitUpright, FitCenter}:
    scale = vec3(s * choice.girth, s, s * choice.girth)

  # Rotated, scaled bounds via the 8 corners (exact: axis-aligned turns).
  var
    rmin = vec3(float32.high)
    rmax = vec3(float32.low)
  for i in 0 .. 7:
    let corner = vec3(
      if (i and 1) == 0: part.boundsMin.x else: part.boundsMax.x,
      if (i and 2) == 0: part.boundsMin.y else: part.boundsMax.y,
      if (i and 4) == 0: part.boundsMin.z else: part.boundsMax.z,
    )
    let placed = rotateVec(rot, corner * scale)
    rmin = min(rmin, placed)
    rmax = max(rmax, placed)

  var pos: Vec3
  case axis
  of FitDown:
    pos = vec3(
      -(rmin.x + rmax.x) * 0.5,
      -rmax.y,
      -(rmin.z + rmax.z) * 0.5)
  of FitForward:
    pos = vec3(
      -(rmin.x + rmax.x) * 0.5,
      -(rmin.y + rmax.y) * 0.5,
      -rmin.z - targetLen * 0.3)
  of FitFoot:
    pos = vec3(
      -(rmin.x + rmax.x) * 0.5,
      -rmax.y,
      -rmin.z - (rmax.z - rmin.z) * 0.35)
  of FitUpright:
    pos = vec3(-(rmin.x + rmax.x) * 0.5, -rmin.y, -(rmin.z + rmax.z) * 0.5)
  of FitCenter:
    pos = -(rmin + rmax) * 0.5

  let node = newJoint("part " & $slot)
  node.mesh = part.mesh
  node.rot = rot
  node.scale = scale
  node.pos = pos
  if mirror:
    # Reflect across X = 0: the mesh is pre-mirrored in part-local space,
    # and conjugating the fit rotation by that reflection negates its Y and
    # Z components (M Rx M = Rx, M Ry M = Ry^-1, M Rz M = Rz^-1).
    node.mesh = mirroredMesh(part.mesh)
    node.pos.x = -node.pos.x
    node.rot = quat(node.rot.x, -node.rot.y, -node.rot.z, node.rot.w)
    let flippedMin = -(rmax.x)
    rmax.x = -rmin.x
    rmin.x = flippedMin
  result = (node, rmin + node.pos, rmax + node.pos)

## Contact pass
#
# After assembly, parts get nudged (or grown) along their mount direction
# until their triangles actually touch their neighbour's, so nothing floats
# disconnected in the bind pose. Contact is a real surface test: segment vs
# triangle intersection over the AABB-pruned interface region.

type Tri = object
  a, b, c: Vec3

var triCache: Table[string, seq[Tri]]

proc localTris(mesh: Mesh): seq[Tri] =
  if mesh.name in triCache:
    return triCache[mesh.name]
  for primitive in mesh.primitives:
    template addTri(i0, i1, i2: int) =
      result.add Tri(
        a: primitive.points[i0],
        b: primitive.points[i1],
        c: primitive.points[i2])
    if primitive.indices16.len > 0:
      var i = 0
      while i + 2 < primitive.indices16.len:
        addTri(
          primitive.indices16[i].int, primitive.indices16[i + 1].int,
          primitive.indices16[i + 2].int)
        i += 3
    elif primitive.indices32.len > 0:
      var i = 0
      while i + 2 < primitive.indices32.len:
        addTri(
          primitive.indices32[i].int, primitive.indices32[i + 1].int,
          primitive.indices32[i + 2].int)
        i += 3
    else:
      var i = 0
      while i + 2 < primitive.points.len:
        addTri(i, i + 1, i + 2)
        i += 3
  triCache[mesh.name] = result

proc worldTris(node: Node): seq[Tri] =
  ## The node's triangles in mech-root space; updateTransforms must be
  ## current.
  if node == nil or node.mesh == nil:
    return
  result = localTris(node.mesh)
  for tri in result.mitems:
    tri.a = (node.mat * vec4(tri.a, 1)).xyz
    tri.b = (node.mat * vec4(tri.b, 1)).xyz
    tri.c = (node.mat * vec4(tri.c, 1)).xyz

proc segTriHit(p, q, a, b, c: Vec3): bool =
  ## Moller-Trumbore ray-triangle, restricted to the segment p..q.
  let
    dir = q - p
    e1 = b - a
    e2 = c - a
    h = cross(dir, e2)
    det = dot(e1, h)
  if abs(det) < 1e-12:
    return false
  let
    inv = 1 / det
    sv = p - a
    u = inv * dot(sv, h)
  if u < 0 or u > 1:
    return false
  let
    qv = cross(sv, e1)
    v = inv * dot(dir, qv)
  if v < 0 or u + v > 1:
    return false
  let t = inv * dot(e2, qv)
  t >= 0 and t <= 1

proc triBounds(tris: seq[Tri]): (Vec3, Vec3) =
  result[0] = vec3(float32.high)
  result[1] = vec3(float32.low)
  for tri in tris:
    result[0] = min(result[0], min(tri.a, min(tri.b, tri.c)))
    result[1] = max(result[1], max(tri.a, max(tri.b, tri.c)))

proc inBox(tri: Tri, lo, hi: Vec3): bool =
  let
    tlo = min(tri.a, min(tri.b, tri.c))
    thi = max(tri.a, max(tri.b, tri.c))
  tlo.x <= hi.x and thi.x >= lo.x and
    tlo.y <= hi.y and thi.y >= lo.y and
    tlo.z <= hi.z and thi.z >= lo.z

proc trisTouch(aTris, bTris: seq[Tri]): bool =
  ## True when the two triangle surfaces intersect. Two meshes cross iff an
  ## edge of one pierces a face of the other, so both edge sets are tested.
  let
    (aLo, aHi) = triBounds(aTris)
    (bLo, bHi) = triBounds(bTris)
  if aLo.x > bHi.x or aHi.x < bLo.x or aLo.y > bHi.y or aHi.y < bLo.y or
      aLo.z > bHi.z or aHi.z < bLo.z:
    return false
  let
    margin = vec3(0.002)
    lo = max(aLo, bLo) - margin
    hi = min(aHi, bHi) + margin
  var aNear, bNear: seq[Tri]
  for tri in aTris:
    if tri.inBox(lo, hi):
      aNear.add tri
  for tri in bTris:
    if tri.inBox(lo, hi):
      bNear.add tri
  if aNear.len == 0 or bNear.len == 0:
    return false
  if aNear.len * bNear.len > 300_000:
    # An interface this dense is as good as touching.
    return true
  for tri in aNear:
    for other in bNear:
      if segTriHit(tri.a, tri.b, other.a, other.b, other.c) or
          segTriHit(tri.b, tri.c, other.a, other.b, other.c) or
          segTriHit(tri.c, tri.a, other.a, other.b, other.c) or
          segTriHit(other.a, other.b, tri.a, tri.b, tri.c) or
          segTriHit(other.b, other.c, tri.a, tri.b, tri.c) or
          segTriHit(other.c, other.a, tri.a, tri.b, tri.c):
        return true
  false

proc targetTrisOf(mech: Mech, targets: openArray[Node]): seq[Tri] =
  mech.root.updateTransforms(mat4())
  for target in targets:
    if target != nil:
      result.add target.worldTris()

proc moveUntilTouch(
  mech: Mech, mover, probe: Node, targets: openArray[Node], dir: Vec3,
  maxMove: float32
): float32 =
  ## Slides mover along dir (in its parent frame, axis aligned in the bind
  ## pose) until probe's surface — a mesh node riding on mover — touches
  ## any target. Returns the distance applied; a slide that never connects
  ## is undone.
  if mover == nil or probe == nil or probe.mesh == nil or maxMove <= 0:
    return 0
  let fixed = mech.targetTrisOf(targets)
  if fixed.len == 0:
    return 0
  let
    start = mover.pos
    step = max(maxMove / 24'f32, 0.004'f32)
  var moved = 0'f32
  while moved <= maxMove:
    mech.root.updateTransforms(mat4())
    if trisTouch(probe.worldTris(), fixed):
      return moved
    mover.pos = mover.pos + dir * step
    moved += step
  mover.pos = start
  mech.root.updateTransforms(mat4())
  0'f32

proc growUntilTouch(
  mech: Mech, node: Node, targets: openArray[Node], maxFactor: float32
) =
  ## Uniformly grows node about its own origin until it touches a target;
  ## growth that never connects is undone.
  if node == nil or node.mesh == nil:
    return
  let fixed = mech.targetTrisOf(targets)
  if fixed.len == 0:
    return
  let startScale = node.scale
  var factor = 1'f32
  while factor <= maxFactor:
    mech.root.updateTransforms(mat4())
    if trisTouch(node.worldTris(), fixed):
      return
    factor *= 1.06'f32
    node.scale = startScale * factor
  node.scale = startScale
  mech.root.updateTransforms(mat4())

proc closeGaps(mech: Mech) =
  ## Bind-pose contact pass, run before bake: every part must touch what
  ## it mounts to.
  let spec = mech.spec
  # The torso rides down first, carrying head, weapons and back with it.
  discard mech.moveUntilTouch(
    mech.torso, mech.partTorso, [mech.partPelvis], vec3(0, -1, 0),
    mech.torso.pos.y * 0.8)
  discard mech.moveUntilTouch(
    mech.head, mech.partHead, [mech.partTorso], vec3(0, -1, 0),
    spec.torsoHeight * 0.5)
  for side in 0 .. 1:
    let inward = vec3(if side == 0: 1'f32 else: -1'f32, 0, 0)
    discard mech.moveUntilTouch(
      mech.shoulders[side], mech.weapons[side], [mech.partTorso], inward,
      if mech.shoulders[side] != nil: abs(mech.shoulders[side].pos.x) * 0.7
      else: 0)
  discard mech.moveUntilTouch(
    mech.partBack, mech.partBack, [mech.partTorso], vec3(0, 0, 1),
    spec.torsoHeight)
  for i in 0 ..< mech.legs.len:
    let body = [mech.partPelvis, mech.partTorso]
    if mech.legs[i].partHip != nil:
      mech.growUntilTouch(mech.legs[i].partHip, body, 2.5)
    else:
      discard mech.moveUntilTouch(
        mech.legs[i].partThigh, mech.legs[i].partThigh, body,
        vec3(0, 1, 0), spec.thighLen * 0.35)
    discard mech.moveUntilTouch(
      mech.legs[i].partShin, mech.legs[i].partShin,
      [mech.legs[i].partThigh], vec3(0, 1, 0), spec.shinLen * 0.4)
    let footMoved = mech.moveUntilTouch(
      mech.legs[i].partFoot, mech.legs[i].partFoot,
      [mech.legs[i].partShin], vec3(0, 1, 0), mech.footHeight * 0.6)
    if i == 0 and footMoved > 0:
      # Every leg's chain is identical, so leg 0 speaks for all: the sole
      # rides up with the foot and must stay on the floor.
      mech.footHeight -= footMoved

proc buildMech(spec: MechSpec): Mech =
  result = Mech(spec: spec)
  result.legLen = spec.thighLen + spec.shinLen
  metal.paintRoles.clear()
  for slot in SlotKind:
    metal.paintRoles["part " & $slot] = spec.slots[slot].role
  metal.schemeIndex = spec.paletteIndex

  result.root = newJoint("mech root")
  result.pelvis = newJoint("pelvis")
  result.pelvis.pos = vec3(0, spec.hipHeight, 0)
  result.root.nodes.add result.pelvis

  # Pelvis hull, centered between the hips.
  let pelvisFit = fitPart(spec, PelvisSlot, FitCenter, spec.hipWidth * 1.3)
  result.pelvis.nodes.add pelvisFit.node
  result.partPelvis = pelvisFit.node

  # Torso above the pelvis hull.
  let torsoJoint = newJoint("torso")
  torsoJoint.pos = vec3(0, max(pelvisFit.rmax.y * 0.9, 0.05), 0)
  result.pelvis.nodes.add torsoJoint
  result.torso = torsoJoint
  let torsoFit = fitPart(spec, TorsoSlot, FitUpright, spec.torsoHeight)
  torsoJoint.nodes.add torsoFit.node
  result.partTorso = torsoFit.node

  # Head on top of the torso.
  if spec.slots[HeadSlot].part >= 0:
    let headJoint = newJoint("head")
    headJoint.pos = vec3(0, torsoFit.rmax.y + 0.02, 0)
    torsoJoint.nodes.add headJoint
    result.head = headJoint
    let headFit = fitPart(
      spec, HeadSlot, FitUpright, spec.torsoHeight * 0.45 * spec.headScale)
    headJoint.nodes.add headFit.node
    result.partHead = headFit.node

  # Shoulder-mounted weapons.
  let weaponLen = max(spec.torsoHeight, 0.8) * 1.15
  for side in 0 .. 1:
    # Symmetric tops mirror the left arm onto the right shoulder instead
    # of rolling an independent right weapon.
    let slot =
      if spec.symmetricTop or side == 0: WeaponLSlot else: WeaponRSlot
    if spec.slots[slot].part < 0:
      continue
    let sideSign = if side == 0: -1'f32 else: 1'f32
    let shoulder = newJoint("shoulder " & $side)
    shoulder.pos = vec3(
      sideSign * ((torsoFit.rmax.x - torsoFit.rmin.x) * 0.5 + 0.1),
      torsoFit.rmax.y * 0.75,
      0)
    torsoJoint.nodes.add shoulder
    result.shoulders[side] = shoulder
    let weaponFit = fitPart(
      spec, slot, FitForward, weaponLen, spec.symmetricTop and side == 1)
    shoulder.nodes.add weaponFit.node
    result.weapons[side] = weaponFit.node

  # Back pack behind the torso.
  if spec.slots[BackSlot].part >= 0:
    let backJoint = newJoint("back")
    backJoint.pos = vec3(0, torsoFit.rmax.y * 0.5, torsoFit.rmin.z)
    torsoJoint.nodes.add backJoint
    let backFit = fitPart(spec, BackSlot, FitCenter, spec.torsoHeight * 0.8)
    # Slide the pack so it sits fully behind the mount point.
    backFit.node.pos.z -= backFit.rmax.z
    backJoint.nodes.add backFit.node
    result.partBack = backFit.node

  # Legs.
  var hips: seq[tuple[offset: Vec3, phase: float32]]
  case spec.legConfig
  of Biped:
    hips = @[
      (vec3(-spec.hipWidth / 2, 0, 0), 0'f32),
      (vec3(spec.hipWidth / 2, 0, 0), 0.5'f32),
    ]
  of Quad:
    hips = @[
      (vec3(-spec.hipWidth / 2, 0, spec.bodyLen / 2), 0'f32),
      (vec3(spec.hipWidth / 2, 0, spec.bodyLen / 2), 0.5'f32),
      (vec3(-spec.hipWidth / 2, 0, -spec.bodyLen / 2), 0.5'f32),
      (vec3(spec.hipWidth / 2, 0, -spec.bodyLen / 2), 0'f32),
    ]
  of Hexapod:
    for row in 0 .. 2:
      let z = spec.bodyLen / 2 - spec.bodyLen * row.float32 / 2
      for side in 0 .. 1:
        let sideSign = if side == 0: -1'f32 else: 1'f32
        # Alternating tripods: L front/rear + R mid vs the rest.
        let phase = if (row + side) mod 2 == 0: 0'f32 else: 0.5'f32
        hips.add (vec3(sideSign * spec.hipWidth / 2, 0, z), phase)

  let footLen = 0.28 * result.legLen + 0.25
  for i, hip in hips:
    var leg = Leg(hipOffset: hip.offset, phase: hip.phase)
    # The bend plane yaws outward with splay; front rows bias forward,
    # rear rows backward, so a spider's legs fan out.
    if spec.splay > 0.01 and abs(hip.offset.x) > 0.01:
      let sideSign = hip.offset.x / abs(hip.offset.x)
      var yaw = sideSign * spec.splay * PI.float32 / 2
      if spec.legConfig == Hexapod:
        if hip.offset.z > 0.01: yaw -= sideSign * 0.35 * spec.splay
        elif hip.offset.z < -0.01: yaw += sideSign * 0.35 * spec.splay
      leg.splayRot = quatRotateY(yaw)
    else:
      leg.splayRot = quat(0, 0, 0, 1)

    let hipJoint = newJoint("hip " & $i)
    hipJoint.pos = hip.offset
    hipJoint.rot = leg.splayRot
    result.pelvis.nodes.add hipJoint

    # Right-side legs are mirror images of the left, never translated
    # copies: asymmetric greebles read wrong when both sides lean the
    # same way.
    let mirrored = hip.offset.x > 0.01

    # A hip housing hides the leg-to-body joint so legs never float free.
    if spec.slots[HipSlot].part >= 0:
      let hipFit = fitPart(
        spec, HipSlot, FitCenter, max(spec.thighLen * 0.55, 0.3), mirrored)
      hipJoint.nodes.add hipFit.node
      leg.partHip = hipFit.node

    leg.thigh = newJoint("thigh " & $i)
    hipJoint.nodes.add leg.thigh
    let thighFit = fitPart(spec, ThighSlot, FitDown, spec.thighLen, mirrored)
    leg.thigh.nodes.add thighFit.node
    leg.partThigh = thighFit.node

    leg.knee = newJoint("knee " & $i)
    leg.knee.pos = vec3(0, -spec.thighLen, 0)
    leg.thigh.nodes.add leg.knee
    let shinFit = fitPart(spec, ShinSlot, FitDown, spec.shinLen, mirrored)
    leg.knee.nodes.add shinFit.node
    leg.partShin = shinFit.node

    leg.ankle = newJoint("ankle " & $i)
    leg.ankle.pos = vec3(0, -spec.shinLen, 0)
    leg.knee.nodes.add leg.ankle
    let footFit = fitPart(spec, FootSlot, FitFoot, footLen, mirrored)
    leg.ankle.nodes.add footFit.node
    leg.partFoot = footFit.node
    result.footHeight = footFit.rmax.y - footFit.rmin.y

    # Rest stance: under the hip, pushed outward along the splay direction.
    let maxReach = sqrt(max(
      pow(0.95 * result.legLen, 2) - spec.hipHeight * spec.hipHeight, 0.0001))
    let outward = rotateVec(leg.splayRot, vec3(0, 0, 1)) *
      min(maxReach, result.legLen * 0.5) * spec.splay
    leg.rest = vec3(
      hip.offset.x + outward.x,
      0,
      hip.offset.z + outward.z)
    result.legs.add leg

  result.closeGaps()
  bake(result.root)
  result.joints = result.root.walkNodes()

## Leg IK

proc solveLegIk(
  a, b: float32, target: Vec2, kneesForward: bool
): tuple[hipPitch, kneePitch: float32] =
  ## Two-bone analytic IK in the leg's bend plane. target = (forward z,
  ## downward y, negative below the hip) of the ankle relative to the thigh
  ## root; a = thigh, b = shin. Angles are rotations about X where zero is a
  ## straight leg pointing down and positive tips the leg tip backward.
  let d = clamp(target.length, abs(a - b) + 0.01, a + b - 0.01)
  let
    baseAng = arctan2(target.x, -target.y)    # forward lean of hip->ankle
    hipOff = arccos(clamp((a * a + d * d - b * b) / (2 * a * d), -1, 1))
    kneeAng = PI.float32 -
      arccos(clamp((a * a + b * b - d * d) / (2 * a * b), -1, 1))
  if kneesForward:
    result = (-(baseAng + hipOff), kneeAng)
  else:
    result = (-(baseAng - hipOff), -kneeAng)

proc plantFoot(mech: Mech, i: int, target: Vec3, toePitch = 0'f32) =
  ## Points leg i's joints so the ankle lands on target (mech-root space).
  ## Pelvis translation is honoured; its small animation tilts are ignored,
  ## which keeps the solve planar and is invisible at a few degrees.
  let
    leg = mech.legs[i]
    spec = mech.spec
    hipWorld = mech.pelvis.pos + leg.hipOffset
  var v = target + vec3(0, mech.footHeight, 0) - hipWorld
  v = rotateVec(conj(leg.splayRot), v)
  # A sideways component tilts the whole bend plane about Z.
  let
    down = sqrt(v.x * v.x + v.y * v.y)
    lateral = arctan2(v.x, -v.y)
    (hipPitch, kneePitch) = solveLegIk(
      spec.thighLen, spec.shinLen, vec2(v.z, -down), spec.kneesForward)
  leg.thigh.rot = qmul(quatRotateZ(lateral), quatRotateX(hipPitch))
  leg.knee.rot = quatRotateX(kneePitch)
  leg.ankle.rot = quatRotateX(-(hipPitch + kneePitch) + toePitch)

## Procedural animation
#
# No baked clips: every state is a pose generator, a pure function of time
# that writes joint transforms after resetToBase. Cross-fades sample both
# generators and blend per joint, the animblend.nim trick rebuilt for
# generators instead of clips.

type
  AnimState = enum
    IdleAnim = "idle"
    WalkAnim = "walk"
    TurnAnim = "turn"
    FireAnim = "fire"
    PowerDownAnim = "powerdown"
    PowerUpAnim = "powerup"

  JointPose = object
    pos: Vec3
    rot: Quat
    scale: Vec3

  AnimPlayer = ref object
    current, previous: AnimState
    time, prevTime: float32
    fading: bool
    fadeTime, fadeDuration: float32
    returnTo: AnimState
    fireSide: int
    outgoing, incoming: seq[JointPose]

const
  FireDuration = 0.55'f32
  PowerDuration = 1.3'f32
  LoopStates = {IdleAnim, WalkAnim, TurnAnim, PowerDownAnim}

proc gaitDuty(spec: MechSpec): float32 =
  ## Fraction of the cycle each foot spends on the ground.
  case spec.legConfig
  of Biped: 0.58
  of Quad: 0.56
  of Hexapod: 0.54

proc footCycle(
  spec: MechSpec, phase: float32
): tuple[along, lift, toe: float32] =
  ## One leg's place in the treadmill gait: along = offset from rest in the
  ## walk direction (+Z at the start of stance), lift = height, toe = ankle
  ## toe-off pitch. Swing lift is a sharpened sine for a piston-y snap.
  let duty = spec.gaitDuty
  if phase < duty:
    let t = phase / duty
    result.along = spec.strideLen * (0.5 - t)
    result.lift = 0
    if t > 0.85:
      result.toe = (t - 0.85) / 0.15 * 0.35
  else:
    let t = (phase - duty) / (1 - duty)
    let ease = t * t * (3 - 2 * t)
    result.along = spec.strideLen * (ease - 0.5)
    result.lift = spec.stepHeight * pow(sin(t * PI.float32), 0.7)
    result.toe = (1 - t) * 0.2

proc standPose(mech: Mech, crouch = 0'f32) =
  ## Feet planted at rest, pelvis at (possibly crouched) stand height.
  mech.pelvis.pos = vec3(0, mech.spec.hipHeight * (1 - crouch), 0)
  for i in 0 ..< mech.legs.len:
    mech.plantFoot(i, mech.legs[i].rest)

proc idlePose(mech: Mech, t: float32) =
  let spec = mech.spec
  mech.standPose()
  # A slow settle, as if hydraulics breathe.
  mech.pelvis.pos.y += sin(t * PI.float32) * 0.008'f32 * mech.legLen
  for i in 0 ..< mech.legs.len:
    mech.plantFoot(i, mech.legs[i].rest)
  # Torso sweeps, head scans in quantized servo steps.
  mech.torso.rot = quatRotateY(sin(t * 0.62'f32) * 0.14'f32)
  if mech.head != nil:
    let raw = sin(t * 0.37'f32 + 1.7'f32) * 0.45'f32
    mech.head.rot = quatRotateY(round(raw / 0.09'f32) * 0.09'f32)
  # Weapons hold, with an occasional micro elevation check.
  for side in 0 .. 1:
    if mech.shoulders[side] != nil:
      let pulse = sin(t * 0.23'f32 + side.float32 * 2.1'f32)
      mech.shoulders[side].rot =
        quatRotateX(-max(0'f32, pulse - 0.92'f32) * 1.2'f32)
  discard spec

proc walkPose(mech: Mech, t: float32) =
  let
    spec = mech.spec
    cycle = t * spec.gaitFreq
  for i in 0 ..< mech.legs.len:
    let
      leg = mech.legs[i]
      phase = fract(cycle + leg.phase)
      (along, lift, toe) = footCycle(spec, phase)
    mech.plantFoot(i, leg.rest + vec3(0, lift, along), toe)
  # Stiff military coupling: dip twice per cycle, roll to the stance side,
  # torso counter-twists, head stays level.
  let dip = (0.5'f32 - 0.5'f32 * cos(cycle * 4 * PI.float32)) * 0.025'f32 * mech.legLen
  mech.pelvis.pos = vec3(0, spec.hipHeight - dip, 0)
  let sway = sin(cycle * 2 * PI.float32)
  if spec.legConfig == Biped:
    mech.pelvis.rot = quatRotateZ(sway * 0.035'f32)
  mech.torso.rot = quatRotateY(sway * (
    if spec.legConfig == Biped: 0.06'f32 else: 0.025'f32))
  if mech.head != nil:
    mech.head.rot = quatRotateY(-sway * 0.03'f32)

proc turnPose(mech: Mech, t: float32) =
  ## Turning in place: the root yaw advances while stance feet counter-yaw
  ## around the center, so they read as planted.
  let
    spec = mech.spec
    cycle = t * spec.gaitFreq
    yawPerCycle = 0.5'f32
  mech.root.rot = quatRotateY(cycle * yawPerCycle)
  let duty = spec.gaitDuty
  for i in 0 ..< mech.legs.len:
    let
      leg = mech.legs[i]
      phase = fract(cycle + leg.phase)
    var behind: float32
    var lift = 0'f32
    if phase < duty:
      behind = yawPerCycle * (phase / duty - 0.5)
    else:
      let s = (phase - duty) / (1 - duty)
      behind = yawPerCycle * (0.5 - s)
      lift = spec.stepHeight * 0.8 * pow(sin(s * PI.float32), 0.7)
    let target = rotateVec(quatRotateY(-behind), leg.rest) + vec3(0, lift, 0)
    mech.plantFoot(i, target)
  let dip = (0.5'f32 - 0.5'f32 * cos(cycle * 4 * PI.float32)) * 0.015'f32 * mech.legLen
  mech.pelvis.pos = vec3(0, spec.hipHeight - dip, 0)
  mech.torso.rot = quatRotateY(sin(cycle * 2 * PI.float32) * 0.03'f32)

proc firePose(mech: Mech, t: float32, side: int) =
  ## Idle stance plus a sharp recoil impulse through the firing shoulder.
  mech.idlePose(t + 20)
  let kick = exp(-8'f32 * t)
  if mech.shoulders[side] != nil:
    mech.shoulders[side].pos.z -= kick * 0.22'f32 * mech.spec.torsoHeight
    mech.shoulders[side].rot = quatRotateX(kick * 0.3'f32)
  mech.torso.rot = qmul(mech.torso.rot, quatRotateX(kick * 0.11'f32))
  mech.pelvis.rot = qmul(mech.pelvis.rot, quatRotateX(kick * 0.025'f32))

proc powerPose(mech: Mech, t: float32, down: bool) =
  ## Fold to (or rise from) a crouched shutdown: knees fold with the feet
  ## planted, torso pitches forward, head drops, weapons droop.
  var u = smoothstep(0'f32, 1'f32, t / PowerDuration)
  if not down:
    u = 1 - u
  mech.standPose(crouch = 0.35'f32 * u)
  mech.torso.rot = quatRotateX(0.15'f32 * u)
  if mech.head != nil:
    mech.head.rot = quatRotateX(0.3'f32 * u)
    mech.head.pos.y -= 0.05'f32 * u * mech.spec.torsoHeight
  for side in 0 .. 1:
    if mech.shoulders[side] != nil:
      mech.shoulders[side].rot = quatRotateX(0.35'f32 * u)

proc generate(mech: Mech, state: AnimState, t: float32, fireSide: int) =
  case state
  of IdleAnim: mech.idlePose(t)
  of WalkAnim: mech.walkPose(t)
  of TurnAnim: mech.turnPose(t)
  of FireAnim: mech.firePose(min(t, FireDuration), fireSide)
  of PowerDownAnim: mech.powerPose(min(t, PowerDuration), true)
  of PowerUpAnim: mech.powerPose(min(t, PowerDuration), false)

proc capture(mech: Mech, pose: var seq[JointPose]) =
  pose.setLen(mech.joints.len)
  for i, node in mech.joints:
    pose[i] = JointPose(pos: node.pos, rot: node.rot, scale: node.scale)

proc play(player: AnimPlayer, state: AnimState, fade = 0.25'f32) =
  if state == player.current:
    if state == FireAnim:
      # Rapid fire: restart the impulse on the other shoulder.
      player.fireSide = 1 - player.fireSide
      player.time = 0
    return
  if player.current in LoopStates:
    player.returnTo = player.current
  player.previous = player.current
  player.prevTime = player.time
  player.current = state
  player.time = 0
  player.fading = fade > 0
  player.fadeTime = 0
  player.fadeDuration = fade
  if state == FireAnim:
    player.fireSide = 1 - player.fireSide

proc update(player: AnimPlayer, mech: Mech, dt: float32) =
  player.time += dt
  if player.fading:
    player.prevTime += dt
    player.fadeTime += dt
    if player.fadeTime >= player.fadeDuration:
      player.fading = false
  case player.current
  of FireAnim:
    if player.time >= FireDuration:
      player.play(player.returnTo, 0.2)
  of PowerUpAnim:
    if player.time >= PowerDuration:
      player.play(IdleAnim, 0.3)
  else:
    discard

  mech.root.resetToBase()
  mech.generate(player.current, player.time, player.fireSide)
  if player.fading:
    mech.capture(player.incoming)
    mech.root.resetToBase()
    mech.generate(player.previous, player.prevTime, player.fireSide)
    mech.capture(player.outgoing)
    let w = clamp(player.fadeTime / player.fadeDuration, 0, 1)
    for i, node in mech.joints:
      node.pos = mix(player.outgoing[i].pos, player.incoming[i].pos, w)
      node.rot = slerp(player.outgoing[i].rot, player.incoming[i].rot, w)
      node.scale = mix(player.outgoing[i].scale, player.incoming[i].scale, w)

## State

var
  spec = randomMech(7)
  mech = buildMech(spec)
  player = AnimPlayer(current: IdleAnim, returnTo: IdleAnim)
  paused = false
  playSpeed = 1.0'f32

proc rebuild() =
  mech = buildMech(spec)

## Showroom
#
# Debug view of the whole part library laid out on a grid, used to sanity
# check extraction. MECH_SHOWROOM=1.

proc buildShowroom(): Node =
  result = newJoint("showroom")
  for i, part in parts:
    let wrapper = newJoint("show " & part.name)
    wrapper.mesh = part.mesh
    wrapper.pos = vec3(
      float32(i mod 17) * 8.0,
      0,
      -float32(i div 17) * 8.0
    )
    wrapper.basePos = wrapper.pos
    result.nodes.add wrapper

## Camera

var
  cameraYaw = 0.55'f32
  cameraPitch = 0.18'f32
  cameraDistance = 9.0'f32
  cameraTarget = vec3(0, 2, 0)
  cameraEye = vec3(0, 0, 0)
  rotating = false
  panning = false
  showPanel = true

proc mouseOverUi(): bool =
  for state in subWindowStates.values:
    if state.visible and sk.mousePos.overlaps(rect(state.pos, state.size)):
      return true
  false

proc updateCamera() =
  let overUi = mouseOverUi()
  if window.buttonPressed[MouseLeft] and not overUi:
    if window.buttonDown[KeyLeftShift] or window.buttonDown[KeyRightShift]:
      panning = true
    else:
      rotating = true
  if window.buttonPressed[MouseRight] and not overUi:
    panning = true
  if not window.buttonDown[MouseLeft] and not window.buttonDown[MouseRight]:
    rotating = false
    panning = false

  let delta = window.mouseDelta.vec2
  if rotating:
    cameraYaw -= delta.x * 0.01
    cameraPitch = clamp(cameraPitch + delta.y * 0.01, -1.2, 1.5)
  if panning:
    let
      right = vec3(cos(cameraYaw), 0, -sin(cameraYaw))
      panSpeed = cameraDistance * 0.0012
    cameraTarget = cameraTarget - right * delta.x * panSpeed
    cameraTarget.y = cameraTarget.y + delta.y * panSpeed
  if not overUi and window.scrollDelta.y != 0:
    cameraDistance = clamp(
      cameraDistance * pow(0.92'f32, window.scrollDelta.y), 0.5, 200)

proc cameraView(): Mat4 =
  let eyeOffset = vec3(
    sin(cameraYaw) * cos(cameraPitch),
    sin(cameraPitch),
    cos(cameraYaw) * cos(cameraPitch)
  ) * cameraDistance
  cameraEye = cameraTarget + eyeOffset
  lookAt(cameraEye, cameraTarget, vec3(0, 1, 0))

proc frameCamera() =
  ## Frames the current mech: called on randomize and preset loads, never
  ## on scrubber rebuilds, so it does not fight manual orbiting.
  let height = spec.hipHeight + spec.torsoHeight
  cameraTarget = vec3(0, height * 0.55, 0)
  cameraDistance = clamp(
    (height + max(spec.hipWidth, spec.bodyLen) + spec.strideLen) * 1.7,
    5, 30)

frameCamera()

## Ground

var ground = initShapeRenderer()

proc drawGround(viewProjection: Mat4) =
  ground.clear()
  let
    lineColor = rgbx(70, 84, 100, 110)
    padColor = rgbx(96, 118, 138, 90)
  for i in -10 .. 10:
    let f = i.float32
    ground.addPolyline(
      [vec3(f, 0, -10), vec3(f, 0, 10)], lineColor, 0.012)
    ground.addPolyline(
      [vec3(-10, 0, f), vec3(10, 0, f)], lineColor, 0.012)
  ground.addCircle(vec3(0, 0.002, 0), max(spec.hipWidth, spec.bodyLen) * 1.1,
    padColor)
  ground.draw(viewProjection)

## Presets

var
  presetPaths: seq[string]
  presetIndex = 0

proc scanPresets() =
  presetPaths.setLen(0)
  if dirExists(PresetsDir):
    for kind, path in walkDir(PresetsDir):
      if kind == pcFile and path.endsWith(".json"):
        presetPaths.add path
    presetPaths.sort()

proc loadPreset(index: int) =
  if presetPaths.len == 0:
    return
  presetIndex = ((index mod presetPaths.len) + presetPaths.len) mod
    presetPaths.len
  spec = readFile(presetPaths[presetIndex]).fromJson(MechSpec)
  rebuild()
  frameCamera()

proc savePreset() =
  createDir(PresetsDir)
  let path = PresetsDir & "/mech_" & $spec.seed & ".json"
  writeFile(path, spec.toJson())
  scanPresets()
  presetIndex = presetPaths.find(path)

scanPresets()

## UI

const RowWidth = 320

proc cycleIndex(current, step, count: int): int =
  ## Steps through -1 (none) followed by 0 ..< count, wrapping both ways.
  let n = count + 1
  ((current + 1 + step) mod n + n) mod n - 1

template pickerRow(label, current: string, hasColors: bool, body: untyped) =
  ## One line of the panel: prev/next buttons, an optional paint button,
  ## then the label and current choice. The body runs with `step` set to
  ## -1, 1, or 0 for the paint button.
  group "row " & label:
    box RowWidth, 34
    layout LeftToRight
    itemSpacing 4
    button "<":
      block:
        let step {.inject.} = -1
        body
    button ">":
      block:
        let step {.inject.} = 1
        body
    if hasColors:
      button "paint":
        block:
          let step {.inject.} = 0
          body
    text label & ": " & current

template scrubFloat(id, caption: string, target: var float32,
    low, high: float32, changed: untyped) =
  text caption & ": " & target.formatFloat(ffDecimal, 2)
  let before = target
  scrubber(id, target, low, high, "")
  if target != before:
    changed

var rng = initRand(2026)

proc factoryPanel() =
  subWindow("Mech Factory", showPanel, vec2(1030, 10), vec2(360, 880)):
    group "preset row":
      box RowWidth, 34
      layout LeftToRight
      itemSpacing 4
      button "<":
        loadPreset(presetIndex - 1)
      button ">":
        loadPreset(presetIndex + 1)
      text(
        if presetPaths.len == 0: "no presets"
        else: presetPaths[presetIndex].extractFilename)
      button "Save":
        savePreset()

    group "random row":
      box RowWidth, 34
      layout LeftToRight
      itemSpacing 4
      button "Randomize":
        spec = randomMech(rng.rand(99999))
        rebuild()
        frameCamera()
      button "Reroll parts":
        # New parts, same skeleton proportions.
        let proportions = spec
        spec = randomMech(rng.rand(99999))
        spec.legConfig = proportions.legConfig
        spec.kneesForward = proportions.kneesForward
        spec.hipHeight = proportions.hipHeight
        spec.thighLen = proportions.thighLen
        spec.shinLen = proportions.shinLen
        spec.hipWidth = proportions.hipWidth
        spec.bodyLen = proportions.bodyLen
        spec.torsoHeight = proportions.torsoHeight
        spec.splay = proportions.splay
        rebuild()
      text "seed " & $spec.seed

    group "legs row":
      box RowWidth, 34
      layout LeftToRight
      itemSpacing 8
      text "Legs:"
      radioButton("2", spec.legConfig, Biped)
      radioButton("4", spec.legConfig, Quad)
      radioButton("6", spec.legConfig, Hexapod)
      button "Apply":
        spec = randomMech(spec.seed)
        rebuild()
    checkBox("Knees forward", spec.kneesForward)
    block:
      let before = spec.symmetricTop
      checkBox("Symmetric arms", spec.symmetricTop)
      if spec.symmetricTop != before:
        rebuild()

    for slot in SlotKind:
      let
        choice = spec.slots[slot]
        shown =
          if slot == WeaponRSlot and spec.symmetricTop: "= Weapon L"
          elif choice.part < 0: "None"
          else: parts[slotParts[slot][choice.part]].name.replace("greeble", "g")
      pickerRow(SlotLabel[slot], shown, true):
        if step == 0:
          spec.slots[slot].role = PaintRole(
            (spec.slots[slot].role.ord + 1) mod (PaintRole.high.ord + 1))
        else:
          if slot in OptionalSlot:
            spec.slots[slot].part =
              cycleIndex(choice.part, step, slotParts[slot].len)
          else:
            let n = slotParts[slot].len
            spec.slots[slot].part = ((choice.part + step) mod n + n) mod n
        rebuild()

    pickerRow("Palette", PaintSchemes[spec.paletteIndex].name, false):
      spec.paletteIndex = ((spec.paletteIndex + step) mod PaintSchemes.len +
        PaintSchemes.len) mod PaintSchemes.len
      metal.schemeIndex = spec.paletteIndex

    scrubFloat("thighLen", "Thigh", spec.thighLen, 0.5, 2.6):
      spec.hipHeight = min(
        spec.hipHeight, (spec.thighLen + spec.shinLen) * 0.95)
      rebuild()
    scrubFloat("shinLen", "Shin", spec.shinLen, 0.5, 2.4):
      spec.hipHeight = min(
        spec.hipHeight, (spec.thighLen + spec.shinLen) * 0.95)
      rebuild()
    scrubFloat("hipHeight", "Stand height", spec.hipHeight, 0.4, 4.0):
      spec.hipHeight = clamp(
        spec.hipHeight,
        (spec.thighLen + spec.shinLen) * 0.3,
        (spec.thighLen + spec.shinLen) * 0.95)
      rebuild()
    scrubFloat("hipWidth", "Hip width", spec.hipWidth, 0.3, 2.2):
      rebuild()
    if spec.legConfig != Biped:
      scrubFloat("bodyLen", "Body length", spec.bodyLen, 0.6, 3.0):
        rebuild()
      scrubFloat("splay", "Leg splay", spec.splay, 0.0, 1.0):
        rebuild()
    scrubFloat("torsoHeight", "Torso", spec.torsoHeight, 0.5, 2.6):
      rebuild()
    scrubFloat("stride", "Stride", spec.strideLen, 0.2, 2.5):
      discard
    scrubFloat("gaitFreq", "Gait speed", spec.gaitFreq, 0.3, 2.5):
      discard
    scrubFloat("stepHeight", "Step height", spec.stepHeight, 0.05, 1.0):
      discard

    text "Animation"
    group "anim row 1":
      box RowWidth, 34
      layout LeftToRight
      itemSpacing 4
      button "Idle":
        player.play(IdleAnim)
      button "Walk":
        player.play(WalkAnim)
      button "Turn":
        player.play(TurnAnim)
      button "Fire":
        player.play(FireAnim, 0.06)
    group "anim row 2":
      box RowWidth, 34
      layout LeftToRight
      itemSpacing 4
      button "Power down":
        player.play(PowerDownAnim, 0.3)
      button "Power up":
        player.play(PowerUpAnim, 0.3)
      button(if paused: "Resume" else: "Pause"):
        paused = not paused
    scrubFloat("speed", "Speed", playSpeed, 0.0, 3.0):
      discard
    text "Playing: " & $player.current
    text "Drag: orbit. Right drag: pan. Scroll: zoom."

## Frame

let showroomMode = getEnv("MECH_SHOWROOM") != ""
var showroom: Node
if showroomMode:
  showroom = buildShowroom()
  cameraTarget = vec3(64, 2, -60)
  cameraDistance = 100

var lastFrameTime = epochTime()

when defined(takeScreenshot):
  import pixie
  var screenshotFrame = 0
  if existsEnv("CAM_YAW"): cameraYaw = getEnv("CAM_YAW").parseFloat.float32
  if existsEnv("CAM_PITCH"): cameraPitch = getEnv("CAM_PITCH").parseFloat.float32
  if existsEnv("CAM_DIST"): cameraDistance = getEnv("CAM_DIST").parseFloat.float32
  if existsEnv("RANDOM_SEED"):
    spec = randomMech(getEnv("RANDOM_SEED").parseInt)
    rebuild()
    frameCamera()
  if existsEnv("SAVE_PRESET"):
    savePreset()
  if existsEnv("PRESET"):
    loadPreset(getEnv("PRESET").parseInt)
  if existsEnv("ANIM"):
    player.play(parseEnum[AnimState](getEnv("ANIM")), 0.0)
  let shotPath =
    if existsEnv("SHOT"): getEnv("SHOT")
    else: "experiments/mech_factory/mech_factory_shot.png"
  let shotFrame =
    if existsEnv("SHOT_FRAME"): getEnv("SHOT_FRAME").parseInt else: 40

window.onFrame = proc() =
  let now = epochTime()
  var dt = clamp(now - lastFrameTime, 0.0, 0.1).float32
  lastFrameTime = now
  when defined(takeScreenshot):
    dt = 1.0 / 60.0  # deterministic captures

  updateCamera()
  if not showroomMode:
    player.update(mech, if paused: 0'f32 else: dt * playSpeed)

  let
    aspect = window.size.x.float32 / max(window.size.y.float32, 1)
    view = cameraView()
    proj = perspective(45.0'f32, aspect, 0.02'f32, 500.0'f32)

  renderer.beginFrame(window, window.size)
  renderer.clearScreen(color(0.07, 0.08, 0.11, 1.0))
  glEnable(GL_MULTISAMPLE)

  metal.view = view
  metal.proj = proj
  metal.cameraPosition = cameraEye
  # The key light rides with the camera, from its upper left, so orbiting
  # never changes what is lit.
  let
    forward = normalize(cameraTarget - cameraEye)
    right = normalize(cross(forward, vec3(0, 1, 0)))
    up = cross(right, forward)
    keyLight = normalize(-right * 0.6 + up * 0.45 - forward * 0.7)
  metal.lightDirection = -keyLight
  if showroomMode:
    metal.draw(showroom)
  else:
    metal.draw(mech.root)
    drawGround(proj * view)

  renderer.endFrame()

  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  glDisable(GL_MULTISAMPLE)

  sk.beginUi(window, window.size)
  ui:
    factoryPanel()
  sk.endUi()

  when defined(takeScreenshot):
    inc screenshotFrame
    if screenshotFrame == shotFrame:
      let image = newImage(window.size.x, window.size.y)
      glReadPixels(
        0, 0, window.size.x, window.size.y,
        GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr
      )
      image.flipVertical()
      image.writeFile(shotPath)
      quit(0)

  window.swapBuffers()

while not window.closeRequested:
  pollEvents()
