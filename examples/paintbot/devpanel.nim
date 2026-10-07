## Paintbot's desktop developer panels, three Silky windows: Scene (F1) has a button to
## stop and resume the match, Save/Load/Reset, the sky and a free camera set by position
## and rotation; Lake (F2) and Ocean (F3) have the same water shader parameters, one set
## for the lake and river and one for the ocean. Each key shows and hides its window.
## Each window saves and loads its own file in the working directory (scene-params.json,
## lake-params.json, ocean-params.json); Scene's Reset all returns everything to the
## compiled defaults. Desktop only, built with -d:pwDevPanel.

import std/[json, math, os, strutils]
import jsony, opengl, pixie, silky, vmath, windy
import polyworld/[common, viewers]
import watershader, sky

const
  AtlasPath = TmpRoot & "/paintbot-dev.atlas.png"
  PanelOrigin = vec2(16, 16)
  PanelSize = vec2(340, 890)
  ScenePath = "scene-params.json"
  LakePath = "lake-params.json"
  OceanPath = "ocean-params.json"
  ResetIcon = "reset.arrow"

# Colours as [r, g, b], easy to edit by hand.
proc dumpHook(s: var string, v: Vec3) = s.dumpHook([v.x, v.y, v.z])
proc parseHook(s: string, i: var int, v: var Vec3) =
  var a: array[3, float32]
  parseHook(s, i, a)
  v = vec3(a[0], a[1], a[2])

type DevPanel* = object
  sk: Silky
  showScene, showLake, showOcean: bool
  freeCamera*: bool ## the camera follows position and rotation, not the spectator camera
  position*: Vec3 ## camera eye, in metres
  rotation*: Vec3 ## camera Euler angles in degrees: pitch (x), yaw (y), roll (z)
  spectatorPosition, spectatorRotation: Vec3 ## the spectator camera's, where camera resets go
  sceneStatus, lakeStatus, oceanStatus: string ## what each window's last Save or Load did

proc resetIcon(size: int): Image =
  ## A counter-clockwise "back" arrow: most of a circle, with a head where it starts.
  result = newImage(size, size)
  let
    s = size.float32
    c = vec2(s * 0.5, s * 0.54)
    r = s * 0.31
    start = -PI.float32 * 0.55
    tip = vec2(c.x + r * cos(start), c.y + r * sin(start))
    ctx = newContext(result)
  ctx.strokeStyle = rgba(235, 235, 235, 255)
  ctx.lineWidth = s * 0.13
  ctx.lineCap = RoundCap
  ctx.beginPath()
  ctx.arc(c.x, c.y, r, start, PI.float32 * 0.95)
  ctx.stroke()
  ctx.fillStyle = rgba(235, 235, 235, 255)
  ctx.beginPath()
  ctx.moveTo(tip.x - s * 0.24, tip.y)
  ctx.lineTo(tip.x + s * 0.06, tip.y - s * 0.2)
  ctx.lineTo(tip.x + s * 0.06, tip.y + s * 0.2)
  ctx.closePath()
  ctx.fill()

proc initDevPanel*(window: Window): DevPanel =
  ## Builds the panel's atlas and Silky client; call once the GL context is current.
  let builder = newHudAtlas(4096)
  builder.addDefaultFonts()
  if not builder.addImage(ResetIcon, resetIcon(16)):
    raise newException(ValueError, "the panel atlas is too small for its reset icon")
  builder.write(AtlasPath)
  result.sk = newSilky(window, AtlasPath)
  result.sk.applyThemePatches()
  result.showScene = true
  result.showLake = true
  result.showOcean = true

proc freeView(panel: DevPanel): Mat4 =
  ## The view matrix of a camera at position, turned by yaw, then pitch, then roll.
  let r = panel.rotation * (PI.float32 / 180)
  inverse(translate(panel.position) * rotateY(r.y) * rotateX(r.x) * rotateZ(r.z))

proc updateCamera*(panel: var DevPanel, eye: var Vec3, view: var Mat4, target: Vec3) =
  ## With the free camera on, replaces the frame's eye and view. Otherwise the panel
  ## tracks the spectator camera looking from eye at target, so turning the free camera
  ## on starts from the current shot. Camera resets go to the spectator camera's values.
  let forward = normalize(target - eye)
  panel.spectatorPosition = eye
  panel.spectatorRotation = vec3(arcsin(forward.y), arctan2(-forward.x, -forward.z), 0) *
    (180 / PI.float32)
  if panel.freeCamera:
    eye = panel.position
    view = panel.freeView()
  else:
    panel.position = panel.spectatorPosition
    panel.rotation = panel.spectatorRotation

proc saveParams[T](path: string, params: T, status: var string) =
  ## Writes one window's parameters to its file.
  try:
    writeFile(path, params.toJson())
    status = "Saved " & path
  except IOError as e:
    status = "Save failed: " & e.msg

proc loadParams[T](path: string, params: var T, defaults: T, status: var string) =
  ## Reads one window's parameters from its file, leaving them unchanged on failure.
  ## Fields the file lacks (it predates them) take this window's compiled defaults.
  if not fileExists(path):
    status = "No " & path & " yet"
    return
  try:
    let merged = parseJson(defaults.toJson())
    for key, value in parseJson(readFile(path)).pairs:
      merged[key] = value
    params = ($merged).fromJson(T)
    status = "Loaded " & path
  except CatchableError as e:
    status = "Load failed: " & e.msg

template fileRow(id, path: string, params, defaults: untyped, status: var string) =
  ## Save and Load buttons for one window's file, with what they last did.
  group id:
    box 300, 32
    layout LeftToRight
    itemSpacing 6
    button("Save"): saveParams(path, params, status)
    button("Load"): loadParams(path, params, defaults, status)
  if status.len > 0: text(status)

proc resetButton(sk: Silky, at: Vec2, side: float32): bool =
  ## A square button with the back arrow; true on the frame it is clicked.
  let
    area = rect(at, vec2(side, side))
    interaction = sk.interact(area, true, false)
  var patch = "button.9patch"
  case interaction
  of Hovered: patch = "button.hover.9patch"
  of Pressed, Held: patch = "button.down.9patch"
  of Released: result = true
  else: discard
  sk.draw9Patch(patch, sk.theme.buttonPatch, at, vec2(side, side), sk.theme.iconButtonDownColor)
  sk.drawImage(ResetIcon, at + (vec2(side, side) - sk.getImageSize(ResetIcon)) * 0.5)

template slider(id: string, value: var float32, resetTo: float32, low, high: float32,
    caption: string) =
  ## A captioned scrubber showing its value, with a button that sets it back to resetTo.
  text(caption & " " & formatFloat(value, ffDecimal, 2))
  let
    rowAt = sk.placedAt(vec2(0, 0))
    side = max(sk.getImageSize("scrubber.handle").y, 20'f32)
    gap = 6'f32
    rowWidth = sk.size.x
  # The scrubber spans its region less the theme padding; narrowing the region leaves
  # room for the button, whose right edge lines up with full-width scrubbers.
  sk.pushLayout(rowAt, vec2(rowWidth - side - gap, side))
  scrubber(id, value, low, high)
  sk.popLayout()
  if sk.resetButton(vec2(rowAt.x + rowWidth - sk.theme.padding.float32 * 3 - side, rowAt.y),
      side):
    value = resetTo
  sk.advance(vec2(rowWidth, side))

template waterSections(title, prefix: string, params: var WaterParams,
    defaults: WaterParams, surface: float32) =
  ## The Water, Ripples and Refraction sliders for one body of water, baked at `surface`;
  ## `prefix` keeps its slider ids apart from the other body's.
  h1text(title)
  slider(prefix & "waterR", params.color.x, defaults.color.x, 0, 1, "Colour red")
  slider(prefix & "waterG", params.color.y, defaults.color.y, 0, 1, "Colour green")
  slider(prefix & "waterB", params.color.z, defaults.color.z, 0, 1, "Colour blue")
  slider(prefix & "colorStrength", params.colorStrength, defaults.colorStrength, 0, 1, "Colour strength")
  slider(prefix & "waterHeight", params.height, defaults.height, surface - 2, surface + 2,
    "Height (m)")
  slider(prefix & "reflectiveness", params.reflectiveness, defaults.reflectiveness, 0, 1, "Reflectiveness")
  slider(prefix & "fresnelStrength", params.fresnelStrength, defaults.fresnelStrength, 0, 1, "Fresnel strength")
  slider(prefix & "fresnelPower", params.fresnelPower, defaults.fresnelPower, 1, 10, "Fresnel power")
  slider(prefix & "sheenStrength", params.sheenStrength, defaults.sheenStrength, 0, 10, "Sun sheen strength")
  slider(prefix & "sheenSharpness", params.sheenSharpness, defaults.sheenSharpness, 1, 64, "Sun sheen sharpness")

  h1text("Ripples")
  slider(prefix & "waveHeight", params.waveHeight, defaults.waveHeight, 0, 2, "Wave height (m)")
  slider(prefix & "waveScale", params.waveScale, defaults.waveScale, 0.05, 20, "Wave scale (m)")
  slider(prefix & "waveSpeed", params.waveSpeed, defaults.waveSpeed, 0, 4, "Wave speed")
  slider(prefix & "waveDrag", params.waveDrag, defaults.waveDrag, 0, 1, "Wave drag")
  slider(prefix & "waveCount", params.waveCount, defaults.waveCount, 1, MaxWaves.float32, "Wave count")
  slider(prefix & "rippleFade", params.rippleFade, defaults.rippleFade, 5, 400, "Ripple fade (m)")
  slider(prefix & "distortion", params.distortion, defaults.distortion, 0, 1, "Reflection distortion")
  slider(prefix & "glintStrength", params.glintStrength, defaults.glintStrength, 0, 100, "Glint strength")
  slider(prefix & "glintSharpness", params.glintSharpness, defaults.glintSharpness, 16, 4000, "Glint sharpness")

  h1text("Refraction")
  slider(prefix & "refraction", params.refraction, defaults.refraction, 0, 0.5, "Refraction strength")
  slider(prefix & "refractionDepth", params.refractionDepth, defaults.refractionDepth, 0.01, 2, "Refraction depth (m)")

  h1text("Foam")
  slider(prefix & "foamR", params.foamColor.x, defaults.foamColor.x, 0, 1, "Colour red")
  slider(prefix & "foamG", params.foamColor.y, defaults.foamColor.y, 0, 1, "Colour green")
  slider(prefix & "foamB", params.foamColor.z, defaults.foamColor.z, 0, 1, "Colour blue")
  slider(prefix & "foamDistance", params.foamDistance, defaults.foamDistance, 0, 10, "Distance (m)")
  slider(prefix & "foamScale", params.foamScale, defaults.foamScale, 0.1, 20, "Noise scale (m)")
  slider(prefix & "foamSpeed", params.foamSpeed, defaults.foamSpeed, -3, 3, "Speed toward shore")
  slider(prefix & "foamOpacity", params.foamOpacity, defaults.foamOpacity, 0, 1, "Opacity")
  slider(prefix & "foamSoftness", params.foamSoftness, defaults.foamSoftness, 0.01, 1, "Softness")

  h1text("Shore fade")
  slider(prefix & "shoreHeight", params.shoreHeight, defaults.shoreHeight, 0, 10,
    "Shore height (m), foam and fade")
  slider(prefix & "fadeDistance", params.fadeDistance, defaults.fadeDistance, 0, 10, "Distance (m)")
  slider(prefix & "fadeCurve", params.fadeCurve, defaults.fadeCurve, 0.1, 5, "Curve")

proc draw*(panel: var DevPanel, window: Window, paused: bool): bool =
  ## Draws the panels over the frame. Returns true when Stop / Resume was pressed.
  if window.buttonPressed[KeyF1]: panel.showScene = not panel.showScene
  if window.buttonPressed[KeyF2]: panel.showLake = not panel.showLake
  if window.buttonPressed[KeyF3]: panel.showOcean = not panel.showOcean
  if not (panel.showScene or panel.showLake or panel.showOcean): return
  let sk = panel.sk
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
  sk.beginUi(window, window.size)
  subWindow("Scene (F1)", panel.showScene, PanelOrigin, PanelSize):
    button(if paused: "Resume game" else: "Stop game"):
      result = true

    group "scene file row":
      box 300, 32
      layout LeftToRight
      itemSpacing 6
      button("Save"): saveParams(ScenePath, skyParams, panel.sceneStatus)
      button("Load"):
        loadParams(ScenePath, skyParams, DefaultSkyParams, panel.sceneStatus)
      button("Reset all"):
        waterParams = DefaultWaterParams
        oceanParams = DefaultOceanParams
        skyParams = DefaultSkyParams
        panel.sceneStatus = "Reset everything to defaults"
    if panel.sceneStatus.len > 0: text(panel.sceneStatus)

    h1text("Sky")
    slider("cloudSpeed", skyParams.cloudSpeed, DefaultSkyParams.cloudSpeed, -3, 3, "Cloud speed (0 = still)")
    slider("sunRotation", skyParams.sunRotation, DefaultSkyParams.sunRotation, -180, 180, "Sun layer rotation (deg)")
    slider("sunAzimuth", skyParams.sunAzimuth, DefaultSkyParams.sunAzimuth, -180, 180, "Sun azimuth")
    slider("sunElevation", skyParams.sunElevation, DefaultSkyParams.sunElevation, -10, 90, "Sun elevation")
    slider("sunSize", skyParams.sunSize, DefaultSkyParams.sunSize, 0.2, 10, "Sun size (deg)")
    slider("sunBrightness", skyParams.sunBrightness, DefaultSkyParams.sunBrightness, 0, 60, "Sun brightness")
    slider("glowStrength", skyParams.glowStrength, DefaultSkyParams.glowStrength, 0, 3, "Glow strength")
    slider("glowSharpness", skyParams.glowSharpness, DefaultSkyParams.glowSharpness, 1, 200, "Glow sharpness")
    slider("gradientPower", skyParams.gradientPower, DefaultSkyParams.gradientPower, 0.1, 4, "Gradient power")
    slider("skyExposure", skyParams.exposure, DefaultSkyParams.exposure, 0, 4, "Sky exposure")

    h1text("Camera")
    checkBox("Free camera", panel.freeCamera)
    let before = (panel.position, panel.rotation)
    slider("camX", panel.position.x, panel.spectatorPosition.x, -120, 120, "Position x")
    slider("camY", panel.position.y, panel.spectatorPosition.y, -5, 160, "Position y")
    slider("camZ", panel.position.z, panel.spectatorPosition.z, -120, 120, "Position z")
    slider("camPitch", panel.rotation.x, panel.spectatorRotation.x, -90, 90, "Pitch (x)")
    slider("camYaw", panel.rotation.y, panel.spectatorRotation.y, -180, 180, "Yaw (y)")
    slider("camRoll", panel.rotation.z, panel.spectatorRotation.z, -180, 180, "Roll (z)")
    # Moving the camera by hand takes it over from the spectator camera.
    if (panel.position, panel.rotation) != before: panel.freeCamera = true
  # Lake and ocean take the same parameters, in windows of the same size side by side.
  subWindow("Lake (F2)", panel.showLake, PanelOrigin + vec2(PanelSize.x + 16, 0), PanelSize):
    fileRow("lake file row", LakePath, waterParams, DefaultWaterParams, panel.lakeStatus)
    waterSections("Lake", "lake.", waterParams, DefaultWaterParams, RiverSurface)
  subWindow("Ocean (F3)", panel.showOcean, PanelOrigin + vec2((PanelSize.x + 16) * 2, 0),
      PanelSize):
    fileRow("ocean file row", OceanPath, oceanParams, DefaultOceanParams, panel.oceanStatus)
    waterSections("Ocean", "ocean.", oceanParams, DefaultOceanParams, SeaSurface)
  sk.endUi()
