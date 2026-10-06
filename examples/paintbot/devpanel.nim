## Paintbot's desktop developer panel: a Silky window with every water shader parameter,
## a button to stop and resume the match, and a free camera set by position and rotation.
## F1 shows and hides it. Save, Load and Reset keep the shader parameters in
## shader-params.json (in the working directory) or return them to their compiled defaults.

import std/[math, os, strutils]
import jsony, opengl, silky, vmath, windy
import polyworld/[common, viewers]
import watershader, sky

const
  AtlasPath = TmpRoot & "/paintbot-dev.atlas.png"
  PanelOrigin = vec2(16, 16)
  PanelSize = vec2(340, 890)
  ParamsPath = "shader-params.json"

type ShaderParams = object
  ## Everything Save writes and Load reads.
  water: WaterParams
  sky: SkyParams

# Fields and sections a saved file lacks (it predates them) keep their compiled defaults.
proc newHook(p: var ShaderParams) = p = ShaderParams(water: DefaultWaterParams,
  sky: DefaultSkyParams)
proc newHook(p: var WaterParams) = p = DefaultWaterParams
proc newHook(p: var SkyParams) = p = DefaultSkyParams

# Colours as [r, g, b], easy to edit by hand.
proc dumpHook(s: var string, v: Vec3) = s.dumpHook([v.x, v.y, v.z])
proc parseHook(s: string, i: var int, v: var Vec3) =
  var a: array[3, float32]
  parseHook(s, i, a)
  v = vec3(a[0], a[1], a[2])

type DevPanel* = object
  sk: Silky
  show: bool
  freeCamera*: bool ## the camera follows position and rotation, not the spectator camera
  position*: Vec3 ## camera eye, in metres
  rotation*: Vec3 ## camera Euler angles in degrees: pitch (x), yaw (y), roll (z)
  status: string ## what the last Save, Load or Reset did

proc initDevPanel*(window: Window): DevPanel =
  ## Builds the panel's atlas and Silky client; call once the GL context is current.
  let builder = newHudAtlas(4096)
  builder.addDefaultFonts()
  builder.write(AtlasPath)
  result.sk = newSilky(window, AtlasPath)
  result.sk.applyThemePatches()
  result.show = true

proc freeView(panel: DevPanel): Mat4 =
  ## The view matrix of a camera at position, turned by yaw, then pitch, then roll.
  let r = panel.rotation * (PI.float32 / 180)
  inverse(translate(panel.position) * rotateY(r.y) * rotateX(r.x) * rotateZ(r.z))

proc updateCamera*(panel: var DevPanel, eye: var Vec3, view: var Mat4, target: Vec3) =
  ## With the free camera on, replaces the frame's eye and view. Otherwise the panel
  ## tracks the spectator camera looking from eye at target, so turning the free camera
  ## on starts from the current shot.
  if panel.freeCamera:
    eye = panel.position
    view = panel.freeView()
  else:
    let forward = normalize(target - eye)
    panel.position = eye
    panel.rotation = vec3(arcsin(forward.y), arctan2(-forward.x, -forward.z), 0) *
      (180 / PI.float32)

proc saveParams(panel: var DevPanel) =
  ## Writes the shader parameters to ParamsPath.
  try:
    writeFile(ParamsPath, ShaderParams(water: waterParams, sky: skyParams).toJson())
    panel.status = "Saved " & ParamsPath
  except IOError as e:
    panel.status = "Save failed: " & e.msg

proc loadParams(panel: var DevPanel) =
  ## Reads the shader parameters from ParamsPath, leaving them unchanged on failure.
  if not fileExists(ParamsPath):
    panel.status = "No " & ParamsPath & " yet"
    return
  try:
    let params = readFile(ParamsPath).fromJson(ShaderParams)
    waterParams = params.water
    skyParams = params.sky
    panel.status = "Loaded " & ParamsPath
  except CatchableError as e:
    panel.status = "Load failed: " & e.msg

template slider(id: string, value: var float32, low, high: float32, caption: string) =
  ## A captioned scrubber showing its value.
  text(caption & " " & formatFloat(value, ffDecimal, 2))
  scrubber(id, value, low, high)

proc draw*(panel: var DevPanel, window: Window, paused: bool): bool =
  ## Draws the panel over the frame. Returns true when Stop / Resume was pressed.
  if window.buttonPressed[KeyF1]: panel.show = not panel.show
  if not panel.show: return
  let sk = panel.sk
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
  sk.beginUi(window, window.size)
  subWindow("Paintbot dev (F1)", panel.show, PanelOrigin, PanelSize):
    button(if paused: "Resume game" else: "Stop game"):
      result = true

    group "params row":
      box 300, 32
      layout LeftToRight
      itemSpacing 6
      button("Save"): panel.saveParams()
      button("Load"): panel.loadParams()
      button("Reset"):
        waterParams = DefaultWaterParams
        skyParams = DefaultSkyParams
        panel.status = "Reset to defaults"
    if panel.status.len > 0: text(panel.status)

    h1text("Sky")
    slider("cloudSpeed", skyParams.cloudSpeed, -3, 3, "Cloud speed (0 = still)")
    slider("sunRotation", skyParams.sunRotation, -180, 180, "Sun layer rotation (deg)")
    checkBox("Sun follows shadows", skyParams.sunFromShadows)
    let sunBefore = (skyParams.sunAzimuth, skyParams.sunElevation)
    slider("sunAzimuth", skyParams.sunAzimuth, -180, 180, "Sun azimuth")
    slider("sunElevation", skyParams.sunElevation, -10, 90, "Sun elevation")
    # Placing the sun by hand stops it following the shadows.
    if (skyParams.sunAzimuth, skyParams.sunElevation) != sunBefore:
      skyParams.sunFromShadows = false
    slider("sunSize", skyParams.sunSize, 0.2, 10, "Sun size (deg)")
    slider("sunBrightness", skyParams.sunBrightness, 0, 60, "Sun brightness")
    slider("glowStrength", skyParams.glowStrength, 0, 3, "Glow strength")
    slider("glowSharpness", skyParams.glowSharpness, 1, 200, "Glow sharpness")
    slider("gradientPower", skyParams.gradientPower, 0.1, 4, "Gradient power")
    slider("skyExposure", skyParams.exposure, 0, 4, "Sky exposure")

    h1text("Water")
    slider("waterR", waterParams.color.x, 0, 1, "Colour red")
    slider("waterG", waterParams.color.y, 0, 1, "Colour green")
    slider("waterB", waterParams.color.z, 0, 1, "Colour blue")
    slider("murk", waterParams.murkDensity, 0, 20, "Murk per metre")
    slider("waterHeight", waterParams.height, RiverSurface - 2, RiverSurface + 2,
      "Height (m)")
    slider("reflectiveness", waterParams.reflectiveness, 0, 1, "Reflectiveness")
    slider("fresnelStrength", waterParams.fresnelStrength, 0, 1, "Fresnel strength")
    slider("fresnelPower", waterParams.fresnelPower, 1, 10, "Fresnel power")
    slider("sheenStrength", waterParams.sheenStrength, 0, 10, "Sun sheen strength")
    slider("sheenSharpness", waterParams.sheenSharpness, 1, 64, "Sun sheen sharpness")

    h1text("Ripples")
    slider("waveHeight", waterParams.waveHeight, 0, 0.3, "Wave height (m)")
    slider("waveScale", waterParams.waveScale, 0.05, 4, "Wave scale (m)")
    slider("waveSpeed", waterParams.waveSpeed, 0, 4, "Wave speed")
    slider("waveDrag", waterParams.waveDrag, 0, 1, "Wave drag")
    slider("waveCount", waterParams.waveCount, 1, MaxWaves.float32, "Wave count")
    slider("rippleFade", waterParams.rippleFade, 5, 400, "Ripple fade (m)")
    slider("distortion", waterParams.distortion, 0, 1, "Reflection distortion")
    slider("glintStrength", waterParams.glintStrength, 0, 30, "Glint strength")
    slider("glintSharpness", waterParams.glintSharpness, 16, 4000, "Glint sharpness")

    h1text("Refraction")
    slider("refraction", waterParams.refraction, 0, 0.5, "Refraction strength")
    slider("refractionDepth", waterParams.refractionDepth, 0.01, 2, "Refraction depth (m)")

    h1text("Camera")
    checkBox("Free camera", panel.freeCamera)
    let before = (panel.position, panel.rotation)
    slider("camX", panel.position.x, -120, 120, "Position x")
    slider("camY", panel.position.y, -5, 160, "Position y")
    slider("camZ", panel.position.z, -120, 120, "Position z")
    slider("camPitch", panel.rotation.x, -90, 90, "Pitch (x)")
    slider("camYaw", panel.rotation.y, -180, 180, "Yaw (y)")
    slider("camRoll", panel.rotation.z, -180, 180, "Roll (z)")
    # Moving the camera by hand takes it over from the spectator camera.
    if (panel.position, panel.rotation) != before: panel.freeCamera = true
  sk.endUi()
