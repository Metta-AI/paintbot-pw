## Modular character viewer: the Layer Lab "Hero Core Vol.3" pack converted
## by tools/build_modular_chars.nim into one skeleton carrying every swappable
## part. Pick a skin tone, face, hair, expression, gear and weapons per
## category, load one of the pack's preset outfits, and play the humanoid
## clips retargeted onto the rig (plus the pack's held poses). Lighting
## switches between the gltf PBR renderer and toon shading
## (src/polyworld/toon.nim) with the game's time-of-day palettes.
##
## Run from the repo root: nim r experiments/modular_chars/modular_chars.nim
##
## Screenshot mode: nim r -d:takeScreenshot ... with optional env vars
##   PRESET=<n> RANDOM_SEED=<n> ANIM=<clip name> TOON=<palette index> RIM=1
##   MSAA=0 UNLIT=0 SHOT_FRAME=<n> ANIM2=<clip name> ANIM2_FRAME=<n> (switch clip
##   mid-run to capture a cross-fade)
##   CAM_YAW=<f> CAM_PITCH=<f> CAM_DIST=<f> SHOT=<path.png>

import
  std/[strformat, times, json, tables, random, strutils, sets],
  bumpy, vmath, chroma,
  gltf,
  silky,
  polyworld/[toon, animblend]

const
  DataDir = "../polyworld_data/characters/modular_chars"
  ManifestPath = DataDir & "/manifest.json"

## Manifest

type
  PartItem = object
    name, color, material: string
    style: int

  Category = object
    key: string
    items: seq[PartItem]

  BodyInfo = object
    skins, pieces: seq[string]

  ClipInfo = object
    name, source, kind, next: string
    duration, bounce: float
    loop: bool

  Preset = object
    name, pose: string
    parts: seq[string]

  Manifest = object
    pack, source, clipSource, generator, model, skeleton: string
    bytes, nodes, meshes: int
    body: BodyInfo
    categories: seq[Category]
    clips: seq[ClipInfo]
    presets: seq[Preset]

let manifest = parseFile(ManifestPath).to(Manifest)

## Atlas

let builder = newAtlasBuilder(1024, 4)
builder.addDir("../polyworld_data/themes/editor/", "../polyworld_data/themes/editor/")
builder.addFont("../polyworld_data/themes/editor/IBMPlexSans-Regular.ttf", "H1", 32.0)
builder.addFont("../polyworld_data/themes/editor/IBMPlexSans-Regular.ttf", "Default", 18.0)
builder.write("../polyworld_data/themes/editor.atlas.png")

## Window

# The window is always created with 4x multisampling; the MSAA switch
# toggles GL_MULTISAMPLE around the character draw.
let window = newWindow(
  "Modular Characters",
  ivec2(1400, 900),
  vsync = false,
  msaa = msaa4x
)
makeContextCurrent(window)
loadExtensions()

let sk = newSilky(window, "../polyworld_data/themes/editor.atlas.png")

window.runeInputEnabled = true
window.onRune = proc(rune: Rune) =
  sk.inputRunes.add(rune)

## Renderer and model

var renderer = newRenderer(window)
var pbrContext = newPbrContext(renderer)
pbrContext.attachEnvironmentMap(loadDefaultEnvironmentMap())

type Shading = enum
  NormalShading, ToonShading

var
  shading = ToonShading
  toonContext = newToonContext()
  paletteIndex = 0
  rimLight = true
  unlitFace = true          # eyes and mouth stay full-bright
  msaa = true
  rimStrength = 0.6'f32

let model = readGltfFile(DataDir & "/" & manifest.model)

# Every part is a mesh node with a unique name; the rig guides reuse a few
# names ("Head") but carry no mesh, so only mesh nodes go in the table.
var partNodes: Table[string, Node]
for node in model.root.walkNodes:
  if node.mesh != nil:
    doAssert node.name notin partNodes, "duplicate part " & node.name
    partNodes[node.name] = node

proc setShown(name: string, shown: bool) =
  ## Shows or hides a part. baseVisible matters because updateAnimation
  ## resets every node to its base state before applying the clip.
  let node = partNodes[name]
  node.visible = shown
  node.baseVisible = shown

for name in partNodes.keys:
  setShown(name, false)

## Selection state

type Selection = object
  skin: int             # index into manifest.body.skins
  body: int             # index into bodyPieces, -1 for none
  face: int             # index into facePieces, -1 for none
  parts: seq[int]       # per category: index into items, -1 for none

var
  bodyPieces: seq[string]   # "1".."4", "ArmA_1", ... everything but heads
  facePieces: seq[string]   # "Head_1".."Head_3"
for piece in manifest.body.pieces:
  if piece.startsWith("Head_"):
    facePieces.add piece
  else:
    bodyPieces.add piece

var selection = Selection(skin: 4, body: 0, face: 0)
selection.parts = newSeq[int](manifest.categories.len)
for i in 0 ..< selection.parts.len:
  selection.parts[i] = -1

proc applySelection() =
  ## Points visibility at exactly the selected parts.
  for name in partNodes.keys:
    setShown(name, false)
  let skin = manifest.body.skins[selection.skin]
  if selection.body >= 0:
    setShown("Body_" & skin & "_" & bodyPieces[selection.body], true)
  if selection.face >= 0:
    setShown("Body_" & skin & "_" & facePieces[selection.face], true)
  for i, category in manifest.categories:
    if selection.parts[i] >= 0:
      setShown(category.items[selection.parts[i]].name, true)

proc applyPreset(preset: Preset) =
  ## Loads one of the pack's preview outfits: parts it lists are shown,
  ## every other category is cleared.
  for i in 0 ..< selection.parts.len:
    selection.parts[i] = -1
  selection.body = -1
  selection.face = -1
  for part in preset.parts:
    if part.startsWith("Body_"):
      let fields = part.split("_", 2)  # Body, Skin, Piece
      selection.skin = manifest.body.skins.find(fields[1])
      let piece = fields[2]
      if piece.startsWith("Head_"):
        selection.face = facePieces.find(piece)
      else:
        selection.body = bodyPieces.find(piece)
      continue
    var found = false
    for i, category in manifest.categories:
      for j, item in category.items:
        if item.name == part:
          selection.parts[i] = j
          found = true
    doAssert found, "preset part not in any category: " & part
  applySelection()

proc cycleColor(categoryIdx: int) =
  ## Jumps to the same style in the next color this category offers.
  let category = manifest.categories[categoryIdx]
  let current = selection.parts[categoryIdx]
  if current < 0:
    return
  var colors: seq[string]
  for item in category.items:
    if item.color notin colors:
      colors.add item.color
  let
    style = category.items[current].style
    colorIdx = colors.find(category.items[current].color)
  for step in 1 ..< colors.len:
    let color = colors[(colorIdx + step) mod colors.len]
    for j, item in category.items:
      if item.color == color and item.style == style:
        selection.parts[categoryIdx] = j
        applySelection()
        return

proc shortName(category: Category, item: PartItem): string =
  ## Hair_Black_3 -> "Black 3", Eye_2 -> "2".
  item.name[category.key.len + 1 .. ^1].replace("_", " ")

var rng = initRand(7)

proc randomize() =
  ## Rolls a whole character: always a body and face, gear most of the time,
  ## face accessories now and then.
  selection.skin = rng.rand(manifest.body.skins.high)
  selection.body = 0
  selection.face = rng.rand(facePieces.high)
  for i, category in manifest.categories:
    let chance =
      case category.key
      of "Eye", "Mouth", "Brow", "Hair": 0.9
      of "Beard", "Earring", "Eyewear": 0.25
      of "Wield_Gear_Left": 0.5
      else: 0.8
    selection.parts[i] =
      if rng.rand(1.0) < chance: rng.rand(category.items.high) else: -1
  applySelection()

## Animation state

# The manifest says which clips loop and what a one-shot chains into; the
# player cross-fades between clips instead of snapping.
let player = newClipPlayer(model.root)
for clip in manifest.clips:
  player.setRule(clip.name, ClipRule(loop: clip.loop, next: clip.next))

var
  paused = false
  playSpeed = 1.0'f32
  fadeSeconds = 0.2'f32

proc playClip(name: string) =
  player.play(name, fadeSeconds)

var presetIndex = 0
applyPreset(manifest.presets[presetIndex])
playClip("Idle")

## Camera

let bounds = model.root.getAABounds()

var
  cameraYaw = 0.45'f32
  cameraPitch = 0.18'f32
  cameraDistance = 3.4'f32
  cameraTarget = vec3(0, bounds.center.y, 0)
  cameraEye = vec3(0, 0, 0)
  rotating = false
  panning = false
  showParts = true
  showAnimations = true

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
      cameraDistance * pow(0.92'f32, window.scrollDelta.y), 0.5, 20)

proc cameraView(): Mat4 =
  let eyeOffset = vec3(
    sin(cameraYaw) * cos(cameraPitch),
    sin(cameraPitch),
    cos(cameraYaw) * cos(cameraPitch)
  ) * cameraDistance
  cameraEye = cameraTarget + eyeOffset
  lookAt(cameraEye, cameraTarget, vec3(0, 1, 0))

## UI

const RowWidth = 320

proc cycle(current, step, count: int): int =
  ## Steps through -1 (none) followed by 0 ..< count, wrapping both ways.
  let n = count + 1
  ((current + 1 + step) mod n + n) mod n - 1

template pickerRow(label, current: string, hasColors: bool, body: untyped) =
  ## One line of the parts panel: prev/next buttons, an optional color
  ## button, then the label and current choice. The body runs with `step`
  ## set to -1, 1, or 0 for the color button.
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
      button "color":
        block:
          let step {.inject.} = 0
          body
    text label & ": " & current

proc partsPanel() =
  subWindow("Character", showParts, vec2(10, 10), vec2(360, 880)):
    group "preset row":
      box RowWidth, 34
      layout LeftToRight
      itemSpacing 4
      button "<":
        presetIndex = (presetIndex + manifest.presets.len - 1) mod manifest.presets.len
        applyPreset(manifest.presets[presetIndex])
        playClip(manifest.presets[presetIndex].pose)
      button ">":
        presetIndex = (presetIndex + 1) mod manifest.presets.len
        applyPreset(manifest.presets[presetIndex])
        playClip(manifest.presets[presetIndex].pose)
      text manifest.presets[presetIndex].name
      button "Random":
        randomize()
      button "Clear":
        for i in 0 ..< selection.parts.len:
          selection.parts[i] = -1
        selection.body = 0
        selection.face = 0
        applySelection()

    pickerRow("Skin", manifest.body.skins[selection.skin], false):
      selection.skin = (selection.skin + step + manifest.body.skins.len) mod
        manifest.body.skins.len
      applySelection()
    pickerRow(
      "Body", if selection.body < 0: "None" else: bodyPieces[selection.body], false
    ):
      selection.body = cycle(selection.body, step, bodyPieces.len)
      applySelection()
    pickerRow(
      "Face", if selection.face < 0: "None" else: facePieces[selection.face], false
    ):
      selection.face = cycle(selection.face, step, facePieces.len)
      applySelection()

    for i, category in manifest.categories:
      let
        current = selection.parts[i]
        label =
          case category.key
          of "Head": "Headgear"
          of "Wield_Gear_Left": "Left hand"
          of "Wield_Gear_Right": "Right hand"
          else: category.key
        shown =
          if current < 0: "None"
          else: shortName(category, category.items[current])
        hasColors = category.items[0].color != category.items[^1].color
      pickerRow(label, shown, hasColors):
        if step == 0:
          cycleColor(i)
        else:
          selection.parts[i] = cycle(current, step, category.items.len)
          applySelection()

    text "Drag: orbit. Right drag: pan. Scroll: zoom."

proc clipButtons(kind: string) =
  ## Buttons for every clip of one kind, packed into rows by measured width.
  var rows: seq[seq[string]] = @[@[]]
  var used = 0'f32
  for clip in manifest.clips:
    if clip.kind != kind:
      continue
    let width = sk.getTextSize(sk.textStyle, clip.name).x +
      sk.theme.padding.float32 * 3
    if used + width > RowWidth.float32 and rows[^1].len > 0:
      rows.add @[]
      used = 0
    rows[^1].add clip.name
    used += width
  for rowIndex, names in rows:
    group kind & " row " & $rowIndex:
      box RowWidth, 34
      layout LeftToRight
      itemSpacing 4
      for name in names:
        button name:
          playClip(name)

proc animationsPanel() =
  subWindow("Animations", showAnimations, vec2(1030, 10), vec2(360, 880)):
    group "lighting row":
      box RowWidth, 34
      layout LeftToRight
      itemSpacing 8
      text "Lighting:"
      radioButton("Normal", shading, NormalShading)
      radioButton("Toon", shading, ToonShading)
    checkBox("MSAA 4x", msaa)
    if shading == ToonShading:
      pickerRow("Palette", ToonPalettes[paletteIndex].name, false):
        paletteIndex = (paletteIndex + step + ToonPalettes.len) mod
          ToonPalettes.len
        toonContext.setPalette(ToonPalettes[paletteIndex])
      checkBox("Unlit eyes, mouth, brows", unlitFace)
      checkBox("Rim light", rimLight)
      if rimLight:
        text &"Rim strength: {rimStrength:.2f}"
        scrubber("rim", rimStrength, 0.0'f32, 1.0'f32, "")
    group "transport row":
      box RowWidth, 34
      layout LeftToRight
      itemSpacing 4
      button(if paused: "Resume" else: "Pause"):
        paused = not paused
      button "Restart":
        player.restart()
      button "Bind pose":
        playClip("")
    text &"Speed: {playSpeed:.2f}"
    scrubber("speed", playSpeed, 0.0'f32, 3.0'f32, "")
    text &"Cross-fade: {fadeSeconds:.2f}s"
    scrubber("fade", fadeSeconds, 0.0'f32, 1.0'f32, "")
    text(
      if player.current < 0: "Playing: bind pose"
      else:
        let clip = manifest.clips[player.current]
        let how =
          if clip.loop: "loops"
          elif clip.next.len > 0: "once, then " & clip.next
          else: "once, then back"
        &"Playing: {clip.name}  {clip.duration:.2f}s, {how}"
    )
    text "Retargeted clips"
    clipButtons("retargeted")
    text "Poses"
    clipButtons("pose")

## Frame

var lastFrameTime = epochTime()

when defined(takeScreenshot):
  import pixie, std/os
  var screenshotFrame = 0
  if existsEnv("CAM_YAW"): cameraYaw = getEnv("CAM_YAW").parseFloat.float32
  if existsEnv("CAM_PITCH"): cameraPitch = getEnv("CAM_PITCH").parseFloat.float32
  if existsEnv("CAM_DIST"): cameraDistance = getEnv("CAM_DIST").parseFloat.float32
  if existsEnv("PRESET"):
    presetIndex = getEnv("PRESET").parseInt - 1
    applyPreset(manifest.presets[presetIndex])
    playClip(manifest.presets[presetIndex].pose)
  if existsEnv("RANDOM_SEED"):
    rng = initRand(getEnv("RANDOM_SEED").parseInt)
    randomize()
  if existsEnv("ANIM"):
    playClip(getEnv("ANIM"))
  if existsEnv("TOON"):
    shading = ToonShading
    paletteIndex = getEnv("TOON").parseInt
    toonContext.setPalette(ToonPalettes[paletteIndex])
  if existsEnv("RIM"):
    rimLight = true
  if existsEnv("UNLIT"):
    unlitFace = getEnv("UNLIT") != "0"
  if existsEnv("MSAA"):
    msaa = getEnv("MSAA") != "0"
  let shotPath =
    if existsEnv("SHOT"): getEnv("SHOT")
    else: "experiments/modular_chars/modular_chars_shot.png"
  let shotFrame =
    if existsEnv("SHOT_FRAME"): getEnv("SHOT_FRAME").parseInt else: 40
  let anim2Frame =
    if existsEnv("ANIM2_FRAME"): getEnv("ANIM2_FRAME").parseInt else: -1

window.onFrame = proc() =
  let now = epochTime()
  var dt = clamp(now - lastFrameTime, 0.0, 0.1).float32
  lastFrameTime = now
  when defined(takeScreenshot):
    dt = 1.0 / 60.0  # deterministic captures

  updateCamera()
  player.update(if paused: 0'f32 else: dt * playSpeed)

  let
    aspect = window.size.x.float32 / max(window.size.y.float32, 1)
    view = cameraView()
    proj = perspective(45.0'f32, aspect, 0.02'f32, 500.0'f32)

  pbrContext.size = window.size
  pbrContext.clearColor = color(0.07, 0.08, 0.11, 1.0)
  pbrContext.transform = mat4()
  pbrContext.view = view
  pbrContext.proj = proj
  pbrContext.tint = color(1, 1, 1, 1)
  pbrContext.useTrs = true
  # The key light rides with the camera, from its upper left and slightly
  # behind it, so orbiting never changes what is lit: the face you are
  # looking at is always the lit one and the shadow side stays put.
  let
    forward = normalize(cameraTarget - cameraEye)
    right = normalize(cross(forward, vec3(0, 1, 0)))
    up = cross(right, forward)
    keyLight = normalize(-right * 0.6 + up * 0.45 - forward * 0.7)
  pbrContext.ambientLightColor = color(0.32, 0.36, 0.46, 0.35)
  pbrContext.sunLightDirection = -keyLight
  pbrContext.sunLightColor = color(0.95, 0.96, 1.0, 1.0)
  pbrContext.rimLightDirection = normalize(vec3(-1, 1, -1))
  pbrContext.rimLightColor = color(0.95, 0.72, 0.46, 0.25)
  pbrContext.debugView = dvLit
  pbrContext.cameraPosition = cameraEye
  pbrContext.useShadows = false
  pbrContext.drawSkybox = false
  pbrContext.skyboxLod = 0
  pbrContext.vsync = false

  renderer.beginFrame(window, window.size)
  renderer.clearScreen(color(0.07, 0.08, 0.11, 1.0))
  if msaa:
    glEnable(GL_MULTISAMPLE)
  else:
    glDisable(GL_MULTISAMPLE)
  case shading
  of NormalShading:
    pbrContext.draw(model.root)
  of ToonShading:
    toonContext.drawBackground()
    toonContext.view = view
    toonContext.proj = proj
    toonContext.cameraPosition = cameraEye
    toonContext.lightDirection = pbrContext.sunLightDirection
    toonContext.rimColor = color(1, 1, 1, if rimLight: rimStrength else: 0)
    toonContext.unlitNodes.clear()
    if unlitFace:
      for category in manifest.categories:
        if category.key in ["Eye", "Mouth", "Brow"]:
          for item in category.items:
            toonContext.unlitNodes.incl item.name
    toonContext.draw(model.root)
  renderer.endFrame()

  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  glDisable(GL_MULTISAMPLE)

  sk.beginUi(window, window.size)
  ui:
    partsPanel()
    animationsPanel()
  sk.endUi()

  when defined(takeScreenshot):
    inc screenshotFrame
    if screenshotFrame == anim2Frame:
      playClip(getEnv("ANIM2"))
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
