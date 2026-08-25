## Renders each given model into one tile of a contact sheet, so a whole
## converted pack can be eyeballed at once for the failures that structural
## checks cannot see: a clip that grafted onto nothing leaves the model in
## its bind pose, an unresolved texture renders flat, a joint mismatch
## explodes the mesh.
##
## Run from the repo root:
##   nim r tools/shoot_glb.nim sheet.png ../polyworld_data/characters/mini_legion/human/*.glb
##
## Each model is posed at its first clip whose name matches CLIP (default
## Idle, falling back to the first clip the model has).

import
  std/[math, os, strformat, strutils],
  chroma, gltf, opengl, pixie, vmath, windy,
  posedbounds

const
  TileSize = 320
  WarmupFrames = 8   ## give the renderer time to upload textures
  PoseSeconds = 0.6'f32
  VerticalFov = 45.0'f32
  FitPadding = 1.5'f32

let params = commandLineParams()
if params.len < 2:
  quit("usage: shoot_glb <sheet.png> <model.glb> [more.glb ...]", 1)

let
  sheetPath = params[0]
  modelPaths = params[1 .. ^1]
  wanted = getEnv("CLIP", "Idle")
  columns = max(1, ceil(sqrt(modelPaths.len.float)).int)
  rows = (modelPaths.len + columns - 1) div columns

let window = newWindow(
  "shoot", ivec2(TileSize, TileSize), visible = false, msaa = msaa4x)
makeContextCurrent(window)
loadExtensions()

var
  renderer = newRenderer(window)
  pbrContext = newPbrContext(renderer)
pbrContext.attachEnvironmentMap(loadDefaultEnvironmentMap())

let sheet = newImage(columns * TileSize, rows * TileSize)
sheet.fill(rgba(18, 20, 28, 255))

proc shoot(path: string): Image =
  ## Renders one model centred in a TileSize square and returns the pixels.
  let file = readGltfFile(path)
  # Exact name first, then prefix, so CLIP=Idle finds IdleNormal on packs
  # that never spell a clip plainly "Idle".
  var clip = -1
  for i, animation in file.root.animations:
    if animation.name == wanted:
      clip = i
      break
  if clip < 0:
    for i, animation in file.root.animations:
      if animation.name.startsWith(wanted):
        clip = i
        break
  if clip < 0 and file.root.animations.len > 0:
    clip = 0
  file.root.poseAt(clip, PoseSeconds)

  let
    bounds = posedBounds(file.root)
    size = bounds.max - bounds.min
    target = (bounds.min + bounds.max) * 0.5
    extent = max(max(size.x, size.y), size.z)
    distance = max(
      extent * 0.5 / tan(VerticalFov.degToRad * 0.5) * FitPadding, 0.5)
    yaw = getEnv("YAW", "0.35").parseFloat.float32
    pitch = getEnv("PITCH", "0.22").parseFloat.float32
    eye = target + vec3(
      sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance

  pbrContext.size = window.size
  pbrContext.transform = mat4()
  pbrContext.view = lookAt(eye, target, vec3(0, 1, 0))
  pbrContext.proj = perspective(VerticalFov, 1.0'f32, 0.02'f32, 500.0'f32)
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
  pbrContext.cameraPosition = eye
  pbrContext.useShadows = false
  pbrContext.drawSkybox = false
  pbrContext.vsync = false

  for _ in 0 ..< WarmupFrames:
    renderer.beginFrame(window, window.size)
    renderer.clearScreen(color(0.07, 0.08, 0.11, 1.0))
    pbrContext.draw(file.root)
    renderer.endFrame()
    window.swapBuffers()
    pollEvents()

  result = newImage(TileSize, TileSize)
  glReadPixels(
    0, 0, TileSize.GLsizei, TileSize.GLsizei,
    GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr)
  result.flipVertical()

for i, path in modelPaths:
  let tile = shoot(path)
  sheet.draw(tile, translate(vec2(
    ((i mod columns) * TileSize).float32,
    ((i div columns) * TileSize).float32)))
  echo &"  {i + 1:2d}/{modelPaths.len} {path.lastPathPart}"

sheet.writeFile(sheetPath)
echo &"wrote {sheetPath} ({columns}x{rows} tiles, clip {wanted})"
