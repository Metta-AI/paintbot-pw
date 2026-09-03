## Character viewer: loads the Footman glb (converted from the Unity FBX
## pack by tools/fbx_to_glb.nim) and plays its skinned animation clips with
## the gltf library's PBR renderer. Buttons in the panel switch clips.
## Run from the repo root: nim r experiments/characters/characters.nim

import
  std/[strformat, times],
  bumpy, vmath, chroma,
  gltf,
  silky

const CharacterPath = "../polyworld_data/characters/footman.glb"

## Atlas

let builder = newAtlasBuilder(1024, 4)
builder.addDir("../polyworld_data/themes/main/", "../polyworld_data/themes/main/")
builder.addFont("../polyworld_data/themes/main/IBMPlexSans-Regular.ttf", "H1", 32.0)
builder.addFont("../polyworld_data/themes/main/IBMPlexSans-Regular.ttf", "Default", 18.0)
builder.write("tmp/editor.atlas.png")

## Window

let window = newWindow(
  "Characters",
  ivec2(1100, 800),
  vsync = false
)
makeContextCurrent(window)
loadExtensions()

let sk = newSilky(window, "tmp/editor.atlas.png")

window.runeInputEnabled = true
window.onRune = proc(rune: Rune) =
  sk.inputRunes.add(rune)

## Renderer and model

var renderer = newRenderer(window)
var pbrContext = newPbrContext(renderer)
pbrContext.attachEnvironmentMap(loadDefaultEnvironmentMap())

let model = readGltfFile(CharacterPath)

var clipNames: seq[string]
for clip in model.root.animations:
  clipNames.add clip.name

var activeClip = 0
for i, name in clipNames:
  if name == "Idle":
    activeClip = i
model.root.activeClips = @[activeClip]
model.root.animTime = 0

# Frame the camera from the model bounds so any character size works.
let bounds = model.root.getAABounds()
let modelCenter = bounds.center

## Camera

var
  cameraYaw = 2.6'f32  # view the character from the front
  cameraPitch = 0.25'f32
  cameraDistance = max(bounds.radius.float32 * 2.6, 0.5)
  cameraTarget = modelCenter
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
      cameraDistance * pow(0.92'f32, window.scrollDelta.y),
      bounds.radius.float32 * 0.4, bounds.radius.float32 * 20)

proc cameraView(): Mat4 =
  let eyeOffset = vec3(
    sin(cameraYaw) * cos(cameraPitch),
    sin(cameraPitch),
    cos(cameraYaw) * cos(cameraPitch)
  ) * cameraDistance
  cameraEye = cameraTarget + eyeOffset
  lookAt(cameraEye, cameraTarget, vec3(0, 1, 0))

## Frame

var lastFrameTime = epochTime()

when defined(takeScreenshot):
  import pixie, std/os, std/strutils
  var screenshotFrame = 0
  if existsEnv("CAM_YAW"): cameraYaw = getEnv("CAM_YAW").parseFloat.float32
  if existsEnv("CAM_PITCH"): cameraPitch = getEnv("CAM_PITCH").parseFloat.float32
  if existsEnv("CAM_DIST"): cameraDistance = getEnv("CAM_DIST").parseFloat.float32
  if getEnv("ANIM") == "none":
    model.root.activeClips = @[]  # bind pose
  elif existsEnv("ANIM"):
    for i, name in clipNames:
      if name == getEnv("ANIM"):
        activeClip = i
        model.root.activeClips = @[i]
        model.root.animTime = 0

window.onFrame = proc() =
  let now = epochTime()
  var dt = clamp(now - lastFrameTime, 0.0, 0.1).float32
  lastFrameTime = now
  when defined(takeScreenshot):
    dt = 1.0 / 60.0  # deterministic captures

  updateCamera()
  model.root.updateAnimation(dt)

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
  # The PBR shader negates the light vectors: these light the model from the
  # camera side (upper front-left).
  pbrContext.ambientLightColor = color(0.32, 0.36, 0.46, 0.35)
  pbrContext.sunLightDirection = normalize(vec3(1, -4, -2))
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
  pbrContext.draw(model.root)
  renderer.endFrame()

  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  glDisable(GL_MULTISAMPLE)

  sk.beginUi(window, window.size)
  ui:
    subWindow("Animations", showPanel, vec2(10, 10), vec2(250, 620)):
      text "title":
        characters "Footman"
      for i in 0 ..< clipNames.len:
        button clipNames[i]:
          activeClip = i
          model.root.activeClips = @[i]
          model.root.animTime = 0
      text "playing":
        characters &"Playing: {clipNames[activeClip]}"
      text "help drag":
        characters "Drag: orbit"
      text "help pan":
        characters "Right/shift drag: pan"
      text "help zoom":
        characters "Scroll: zoom"
  sk.endUi()

  when defined(takeScreenshot):
    inc screenshotFrame
    if screenshotFrame == 40:
      let image = newImage(window.size.x, window.size.y)
      glReadPixels(
        0, 0, window.size.x, window.size.y,
        GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr
      )
      image.flipVertical()
      image.writeFile("characters_shot.png")
      quit(0)

  window.swapBuffers()

while not window.closeRequested:
  pollEvents()
