## Renders a portrait of each given character or named prop, as
## <model>.profile.png — a 256x256 toon-shaded shot on a transparent
## background, for roster panels, unit cards, and building tiles.
##
## Characters: framing is driven by skin weights rather than a guess at a
## box. The head joint and everything beneath it select the vertices they
## control, so a snout, horns, a helmet or a hood all land inside the shot
## and a held weapon never does. Not everything has a head, so the search
## falls back through the next most face-like thing each rig actually names
## — the beholder's eye, the undead siege engine's jaws, the human one's
## turret — and finally to the upper body.
##
## Buildings and other props live many-to-a-file. Pass `pack.glb:node` to
## isolate that node, frame the whole mesh, and write
## <pack>.<node>.profile.png next to the pack.
##
## Modular characters keep every outfit in one file with a manifest.json
## beside it. Pass `character.glb:Preset 5` and, when the name is a manifest
## preset rather than a node, only that preset's parts show, the face parts
## (head, hair, eyes, headgear ...) frame the shot, and the file is written
## as <pack>.preset_5.profile.png.
##
## Run from the repo root:
##   nim r tools/profile_glb.nim ../polyworld_data/characters/rpg_monsters/*.glb
##   nim r tools/profile_glb.nim ../polyworld_data/terrain/low_poly_village.glb:house_lvl7
##   nim r tools/profile_glb.nim "../polyworld_data/characters/modular_chars/character.glb:Preset 5"

import
  std/[json, math, os, sets, strformat, strutils, tables],
  chroma, gltf, opengl, pixie, vmath, windy,
  posedbounds, polyworld/[characters, toon]

const
  ProfileSize = 256     ## what lands on disk
  RenderSize = 1024     ## supersampled, then boxed down for clean edges
  WarmupFrames = 8      ## give the renderer time to upload textures
  PoseSeconds = 0.4'f32
  VerticalFov = 35.0'f32  ## a longer lens flatters a face
  # Generous, because the shot is auto-cropped to the subject afterwards:
  # framing comes from the crop, and these only have to avoid clipping.
  HeadPadding = 1.30'f32
  WholePadding = 1.20'f32
  CropMargin = 0.08'f32  ## breathing room around the subject, as a fraction
  IdlePrefix = "Idle"
  ProfileHour = 12.0'f32  ## noon Day palette, same as in-game daylight

let args = commandLineParams()
if args.len == 0:
  quit(
    "usage: profile_glb <model.glb> [pack.glb:node ...]",
    1
  )

type Shot = object
  path: string
  prop: string

proc parseShot(arg: string): Shot =
  ## Splits `file.glb` or `file.glb:node` into a render job.
  const Marker = ".glb:"
  let split = arg.find(Marker)
  if split >= 0:
    result.path = arg[0 .. split + 3]
    result.prop = arg[split + Marker.len .. ^1]
    if result.prop.len == 0:
      quit("missing node name in " & arg, 1)
  else:
    result.path = arg

var shots: seq[Shot]
for arg in args:
  shots.add parseShot(arg)

let window = newWindow(
  "profile", ivec2(RenderSize, RenderSize), visible = false, msaa = msaa8x)
makeContextCurrent(window)
loadExtensions()

var
  renderer = newRenderer(window)
  toonContext = newToonContext()
let hour =
  if existsEnv("TOON_HOUR"):
    getEnv("TOON_HOUR").parseFloat.float32
  else:
    ProfileHour
# Same rim, light, and noon palette the games start from.
toonContext.rimColor = color(1, 1, 1, ToonRimStrength)
toonContext.lightDirection = ToonLightDirection
toonContext.setPalette(paletteAtHour(hour))
if existsEnv("TOON_LIGHT"):
  let parts = getEnv("TOON_LIGHT").split(",")
  toonContext.lightDirection = normalize(vec3(
    parts[0].parseFloat.float32, parts[1].parseFloat.float32,
    parts[2].parseFloat.float32))

## Face

# Tried in order. Not every character has a head — a beholder is one huge
# eye, a siege engine is a cannon with a turret on top — so the fallbacks
# name the next most face-like thing each of those actually rigs.
type FaceGroup = object
  label: string
  matches: proc(lowered: string): bool {.nimcall.}

proc isHead(lowered: string): bool =
  # Deliberately not "forehead": this wants the joint the whole head hangs
  # from, not a feature on it.
  lowered == "head" or lowered.endsWith("_head") or
    (lowered.endsWith("head") and not lowered.endsWith("forehead"))

proc isEye(lowered: string): bool =
  lowered.contains("eye")

proc isMouth(lowered: string): bool =
  lowered.contains("jaw") or lowered.contains("muzzle") or
    lowered.contains("snout") or lowered.contains("beak")

proc isTurret(lowered: string): bool =
  lowered.contains("tower") or lowered.contains("turret")

const FaceGroups = [
  FaceGroup(label: "head", matches: isHead),
  FaceGroup(label: "eye", matches: isEye),
  FaceGroup(label: "mouth", matches: isMouth),
  FaceGroup(label: "turret", matches: isTurret),
]

proc isDescendant(ancestor, node: Node): bool =
  for child in ancestor.nodes:
    if child == node or isDescendant(child, node):
      return true
  false

proc setTreeVisible(node: Node, value: bool) =
  ## Shows or hides a node and every node beneath it.
  node.visible = value
  for child in node.nodes:
    setTreeVisible(child, value)

proc findNamed(root: Node, name: string): Node =
  ## Returns the first node whose name matches, or nil.
  if root.name == name:
    return root
  for child in root.nodes:
    let found = findNamed(child, name)
    if found != nil:
      return found

proc isolateProp(root: Node, name: string) =
  ## Hides every sibling so only one named mesh remains in the shot.
  let keep = findNamed(root, name)
  if keep == nil:
    quit("no node named '" & name & "'", 1)
  proc hideExcept(node: Node) =
    if node == keep:
      setTreeVisible(node, true)
      return
    if isDescendant(node, keep):
      node.visible = true
      for child in node.nodes:
        hideExcept(child)
      return
    node.visible = false
  hideExcept(root)
  root.visible = true

## Modular presets

const FacePartPrefixes = [
  "Head_", "Hair_", "Eye_", "Mouth_", "Brow_", "Beard_", "Eyewear_",
  "Earring_"
]

proc presetParts(path, name: string): seq[string] =
  ## Part node names of a manifest preset next to the glb, or empty when
  ## there is no manifest or no such preset.
  let manifestPath = path.parentDir / "manifest.json"
  if not fileExists(manifestPath):
    return
  for preset in parseFile(manifestPath){"presets"}:
    if preset["name"].getStr == name:
      for part in preset["parts"]:
        result.add part.getStr

proc isolatePreset(root: Node, parts: seq[string]) =
  ## Shows exactly one outfit: every mesh node off, the preset's on.
  var wanted: Table[string, bool]
  for part in parts:
    wanted[part] = true
  proc visit(node: Node) =
    if node.mesh != nil:
      node.visible = wanted.hasKey(node.name)
    else:
      node.visible = true
    for child in node.nodes:
      visit(child)
  visit(root)

proc isFacePart(name: string): bool =
  ## Body_<Skin>_Head_N is the face itself; the rest are worn on it.
  if name.startsWith("Body_"):
    return name.contains("_Head_")
  for prefix in FacePartPrefixes:
    if name.startsWith(prefix):
      return true
  false

proc presetFaceBounds(root: Node, parts: seq[string]): AABounds =
  ## Posed bounds of the preset's face parts alone.
  var faceParts: seq[string]
  for part in parts:
    if isFacePart(part):
      faceParts.add part
  isolatePreset(root, faceParts)
  result = posedBounds(root, visibleOnly = true)
  isolatePreset(root, parts)

proc faceJoints(root: Node): (seq[Node], string) =
  ## Picks the joints that define this character's face.
  for group in FaceGroups:
    var candidates: seq[Node]
    proc collect(node: Node) =
      if group.matches(node.name.toLowerAscii):
        candidates.add node
      for child in node.nodes:
        collect(child)
    collect(root)
    if candidates.len == 0:
      continue

    # Keep only the outermost of any nested pair, so cyclops_head wins over
    # cyclops_headTop and the whole head still comes along beneath it.
    var outer: seq[Node]
    for candidate in candidates:
      var nested = false
      for other in candidates:
        if other != candidate and isDescendant(other, candidate):
          nested = true
          break
      if not nested:
        outer.add candidate

    # Independent candidates mean a mount — the horseman rigs horseHead and
    # man_head — or a pair like UpperJaw and LowerJaw. Frame them together:
    # cropping to the rider alone puts the horse's head in front of the lens.
    var label = group.label & " " & outer[0].name
    if outer.len > 1:
      label = &"{group.label} x{outer.len}"
    return (outer, label)
  (@[], "")

proc faceMask(root: Node, face: seq[Node]): seq[bool] =
  ## Marks the face joints and every joint beneath them, per skin joint index.
  var mask: seq[bool]
  proc visit(node: Node) =
    if node.mesh != nil and node.skin != nil and mask.len == 0:
      mask.setLen(node.skin.joints.len)
      for i, joint in node.skin.joints:
        for chosen in face:
          if joint == chosen or isDescendant(chosen, joint):
            mask[i] = true
            break
    for child in node.nodes:
      visit(child)
  visit(root)
  mask

proc cropToSubject(rendered: Image): Image =
  ## Squares the shot around whatever actually drew.
  ##
  ## Camera framing alone leaves each subject a different size in frame,
  ## because a bounding box says nothing about how much of itself a head
  ## actually fills. Cropping to the rendered alpha instead makes every
  ## portrait sit the same way in its tile.
  var
    low = ivec2(rendered.width.int32, rendered.height.int32)
    high = ivec2(-1, -1)
  for y in 0 ..< rendered.height:
    for x in 0 ..< rendered.width:
      if rendered[x, y].a > 16:
        low.x = min(low.x, x.int32)
        low.y = min(low.y, y.int32)
        high.x = max(high.x, x.int32)
        high.y = max(high.y, y.int32)
  if high.x < low.x:
    return rendered

  let
    centre = vec2((low.x + high.x).float32, (low.y + high.y).float32) * 0.5
    span = max(high.x - low.x, high.y - low.y).float32 * (1 + CropMargin * 2)
    side = max(span.int, 8)
  var
    x = (centre.x - side.float32 * 0.5).int
    y = (centre.y - side.float32 * 0.5).int
  # Keep the square on the canvas rather than shrinking it, so the subject
  # stays the same size even when it sits near an edge.
  x = clamp(x, 0, max(rendered.width - side, 0))
  y = clamp(y, 0, max(rendered.height - side, 0))
  let clipped = min(side, min(rendered.width, rendered.height))
  rendered.subImage(x, y, clipped, clipped)

proc profile(file: GltfFile, shot: Shot) =
  ## Renders one character file, one named prop from an already posed pack,
  ## or one modular preset.
  let preset =
    if shot.prop.len > 0: presetParts(shot.path, shot.prop) else: @[]
  if preset.len > 0:
    isolatePreset(file.root, preset)
  elif shot.prop.len > 0:
    setTreeVisible(file.root, true)
    isolateProp(file.root, shot.prop)

  let whole = posedBounds(file.root, shot.prop.len > 0)
  var
    bounds = whole
    padding = HeadPadding
    framing = ""
    yaw = getEnv("YAW", "0.5").parseFloat.float32
    pitch = getEnv("PITCH", "0.12").parseFloat.float32

  if preset.len > 0:
    let faceBox = presetFaceBounds(file.root, preset)
    if faceBox.min.x <= faceBox.max.x:
      bounds = faceBox
    framing = "preset face"
  elif shot.prop.len > 0:
    padding = WholePadding
    framing = "prop " & shot.prop
    yaw = getEnv("YAW", "0.55").parseFloat.float32
    pitch = getEnv("PITCH", "0.38").parseFloat.float32
  else:
    let (face, label) = faceJoints(file.root)
    if face.len > 0:
      let faceBox = posedBoundsWeighted(file.root, faceMask(file.root, face))
      if faceBox.min.x <= faceBox.max.x:
        bounds = faceBox
        framing = label
    if framing.len == 0:
      # Nothing nameable to aim at: frame the upper structure, which still
      # reads as a portrait where the whole silhouette would not.
      let upper = posedBoundsAbove(
        file.root, whole.min.y + (whole.max.y - whole.min.y) * 0.55'f32)
      if upper.min.x <= upper.max.x:
        bounds = upper
        framing = "upper body"
      else:
        bounds = whole
        padding = WholePadding
        framing = "whole"

  let
    size = bounds.max - bounds.min
    target = (bounds.min + bounds.max) * 0.5
    # Fit the box's diagonal, not its longest axis: a head seen three-quarter
    # on presents its corners to the camera, and fitting the axis alone
    # crops them.
    extent = length(size)
    distance = max(
      extent * 0.5 / tan(VerticalFov.degToRad * 0.5) * padding, 0.05)
    eye = target + vec3(
      sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance

  toonContext.transform = mat4()
  toonContext.view = lookAt(eye, target, vec3(0, 1, 0))
  toonContext.proj = perspective(
    VerticalFov, 1.0'f32, max(distance * 0.01'f32, 0.001'f32), 500.0'f32)
  toonContext.tint = color(1, 1, 1, 1)
  toonContext.cameraPosition = eye
  toonContext.unlitNodes.clear()
  for part in preset:
    if part.startsWith("Eye_") or part.startsWith("Mouth_") or
        part.startsWith("Brow_"):
      toonContext.unlitNodes.incl part

  for _ in 0 ..< WarmupFrames:
    renderer.beginFrame(window, window.size)
    # Clear to fully transparent so the portrait composites onto any panel.
    renderer.clearScreen(color(0, 0, 0, 0))
    toonContext.draw(file.root)
    renderer.endFrame()
    window.swapBuffers()
    pollEvents()

  let rendered = newImage(RenderSize, RenderSize)
  glReadPixels(
    0, 0, RenderSize.GLsizei, RenderSize.GLsizei,
    GL_RGBA, GL_UNSIGNED_BYTE, rendered.data[0].addr)
  rendered.flipVertical()
  # Render large and box down so antialiasing survives the crop.
  let image = cropToSubject(rendered).resize(ProfileSize, ProfileSize)
  let profilePath =
    if preset.len > 0:
      shot.path.changeFileExt(
        shot.prop.toLowerAscii.replace(" ", "_") & ".profile.png")
    elif shot.prop.len > 0:
      shot.path.changeFileExt(shot.prop & ".profile.png")
    else:
      shot.path.changeFileExt("profile.png")
  image.writeFile(profilePath)
  echo &"{profilePath.lastPathPart:34s} {framing}"

proc loadShotFile(path: string): GltfFile =
  ## Loads one GLB and poses it at Idle, or bind pose when it has no clips.
  result = readGltfFile(path)
  var clip = -1
  for i, animation in result.root.animations:
    if animation.name.startsWith(IdlePrefix):
      clip = i
      break
  if clip < 0 and result.root.animations.len > 0:
    clip = 0
  result.root.poseAt(clip, PoseSeconds)

var files: OrderedTable[string, GltfFile]
for shot in shots:
  if shot.path notin files:
    files[shot.path] = loadShotFile(shot.path)
  profile(files[shot.path], shot)
echo &"wrote {shots.len} profile(s)"
