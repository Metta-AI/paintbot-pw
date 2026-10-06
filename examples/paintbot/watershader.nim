## Paintbot's own water shader, installed in place of the engine's default.
##
## The water is murky: drawMurkyWater copies the scene's depth just before the water is
## drawn, and the shader fades whatever lies behind each water pixel towards the water's
## colour the deeper it is below the surface.
##
## It is also a planar mirror: each frame the scene is rendered once more from the camera
## reflected in the water plane, into an offscreen texture, and the water samples that
## texture at its own screen position. How much it reflects follows Schlick's Fresnel
## approximation, with the reflectiveness as the reflectance looking straight down:
##
##   R(θ) = R0 + (1 − R0) · s · (1 − cos θ)^p
##
## where cos θ = dot(up, toward the camera), R0 is the reflectiveness, s the Fresnel
## strength (0 turns the effect off) and p its power (5 in Schlick's formula).
##
## The sun also lights the whole surface as a broad sheen: the view ray reflected off
## the water, compared with the direction toward the sun, weighted by that Fresnel:
##
##   sheen = sunColour · strength · R(θ) · pow(max(dot(reflect(view, up), sun), 0), sharpness)
##
## A low sharpness spreads it over the water on the sun's side, as glare does on
## slightly rough water; it is added as light, so it whitens without hiding the scene.
##
## Ripples: the surface's normal comes from a sum of travelling waves after afl_ext's
## "Very fast procedural ocean" (https://www.shadertoy.com/view/MdXyzX, MIT License,
## (c) 2017-2024 afl_ext). Each wave is exp(sin(x) - 1), sharp crests over flat troughs;
## each turns to a scattered direction, rises 1.18x in frequency and fades 20%, and its
## slope drags where the next one is sampled, so small ripples gather on larger ones.
## The normal tilts the reflection lookup (distortion), the Fresnel angle, the sheen and
## a sharp sun glint, and flattens with distance so far water does not shimmer.
##
## Refraction: drawMurkyWater copies the scene's colour with its depth, and the water
## draws that copy itself, read at a spot the ripples push sideways. The push grows with
## the water's depth up to refractionDepth, so the shoreline seam stays closed while the
## bed just inside it wobbles; a push landing on something in front of the water (a cog,
## a tower) falls back to the straight lookup, so foreground objects never smear into it.

import std/[math, times]
import opengl, shady, vmath
import chroma
import polyworld/quadterrain
import topography, sky

const
  ShaderTarget =
    when defined(emscripten):
      glsl3WebGL
    else:
      glsl4Desktop
  ReflectionUnit = 6 # drawWater uses units 0 and 1, the toon shadows 3 and 4
  SceneDepthUnit = 7
  SceneColorUnit = 5
  RiverSurface* = RiverWaterHeight.float32 / 100 # metres, where the river's mesh is baked
  MaxWaves* = 32

type WaterParams* = object
  ## The water shader's live parameters; the developer panel edits them.
  color*: Vec3
  murkDensity*: float32 ## per metre below the surface; the river is 0.38 m deep
  height*: float32 ## the river's drawn surface; the sea moves with it (visual only)
  reflectiveness*: float32 ## reflectance looking straight down: 0 murky water only, 1 a mirror
  fresnelStrength*: float32 ## 0 reflects the same at every angle, 1 is Schlick's Fresnel
  fresnelPower*: float32 ## how sharply reflection rises towards grazing angles
  sheenStrength*: float32 ## the sun's glare over the water; 0 turns it off
  sheenSharpness*: float32 ## low spreads the glare over the water, high narrows it to the sun
  waveHeight*: float32 ## metres from trough to crest of the summed ripples
  waveScale*: float32 ## metres per radian of the longest wave (its wavelength / 2π)
  waveSpeed*: float32 ## multiplies how fast the waves travel
  waveDrag*: float32 ## how much each wave's slope pulls the next; bunches ripples together
  waveCount*: float32 ## waves summed, 1 to MaxWaves; each adds shorter, fainter ripples
  rippleFade*: float32 ## metres from the camera at which ripples have flattened most
  distortion*: float32 ## how far the ripples bend the reflection, in screen fractions
  glintStrength*: float32 ## the sun's sharp sparkle on each ripple; 0 turns it off
  glintSharpness*: float32 ## higher makes glints smaller and tighter
  refraction*: float32 ## how far the ripples bend what is seen through the water, in screen fractions
  refractionDepth*: float32 ## metres of water at which the bending reaches full strength

const DefaultWaterParams* = WaterParams(color: vec3(0.02'f32, 0.12, 0.13), # dark blueish green
  murkDensity: 4.5, height: RiverSurface, reflectiveness: 0.2, fresnelStrength: 1,
  fresnelPower: 4, sheenStrength: 0.35, sheenSharpness: 10, waveHeight: 0.035,
  waveScale: 0.6, waveSpeed: 0.7, waveDrag: 0.35, waveCount: 18, rippleFade: 150,
  distortion: 0.18, glintStrength: 12, glintSharpness: 1000, refraction: 0.25,
  refractionDepth: 0.12)

var waterParams* = DefaultWaterParams

var
  mvp: Uniform[Mat4]
  reflectionTex: Uniform[Sampler2D]
  sceneDepthTex: Uniform[Sampler2D]
  sceneColorTex: Uniform[Sampler2D]
  refraction, refractionDepth: Uniform[float32]
  inverseViewProjection: Uniform[Mat4]
  depthViewport: Uniform[Vec4] # the view's x, y, width, height as fractions of the window
  waterColor: Uniform[Vec3]
  murkDensity: Uniform[float32]
  reflectiveness: Uniform[float32]
  fresnelStrength: Uniform[float32]
  fresnelPower: Uniform[float32]
  cameraPos: Uniform[Vec3] # drawWater sets it
  waterSunToward: Uniform[Vec3]
  sheenColor: Uniform[Vec3] # sun colour times sheen strength
  sheenSharpness: Uniform[float32]
  waterLift: Uniform[float32] # metres added to the baked water mesh
  rippleClock: Uniform[float32] # wall-clock seconds, so ripples move even while the match is paused
  waveHeight, waveScale, waveSpeed, waveDrag, waveCount: Uniform[float32]
  rippleFade, distortion: Uniform[float32]
  glintColor: Uniform[Vec3] # sun colour times glint strength
  glintSharpness: Uniform[float32]

proc paintbotWaterVert(gl_Position: var Vec4, vertPos: Vec3, worldPos: var Vec3,
    screenPos: var Vec4) =
  ## Lifts and projects the water mesh and hands its world and clip positions to the
  ## fragment; drawWater sets mvp.
  worldPos = vec3(vertPos.x, vertPos.y + waterLift, vertPos.z)
  gl_Position = mvp * vec4(worldPos.x, worldPos.y, worldPos.z, 1.0)
  screenPos = gl_Position

proc waveSum(position: Vec2): float32 =
  ## The ripples' height at `position` (in wave units), from 0 (trough) to 1 (crest).
  var
    p = position
    angle = 0.0
    frequency = 1.0
    timeScale = 2.0
    weight = 1.0
    total = 0.0
    weights = 0.0
  let phaseShift = length(position) * 0.1 # keeps the waves from lining up everywhere
  for i in 0 ..< MaxWaves:
    if float32(i) >= waveCount:
      break
    let
      direction = vec2(sin(angle), cos(angle))
      x = dot(direction, p) * frequency + rippleClock * waveSpeed * timeScale + phaseShift
      wave = exp(sin(x) - 1.0)
      slope = -wave * cos(x)
    p = p + direction * (slope * weight * waveDrag)
    total = total + wave * weight
    weights = weights + weight
    weight = weight * 0.8
    frequency = frequency * 1.18
    timeScale = timeScale * 1.07
    angle = angle + 1232.399963
  result = total / weights

proc sceneHeight(uv: Vec2): float32 =
  ## The world height of the scene point seen at `uv` in the copied depth.
  let
    ndc = vec2(
      (uv.x - depthViewport.x) / depthViewport.z * 2.0 - 1.0,
      (uv.y - depthViewport.y) / depthViewport.w * 2.0 - 1.0)
    point = inverseViewProjection *
      vec4(ndc.x, ndc.y, texture(sceneDepthTex, uv).x * 2.0 - 1.0, 1.0)
  result = point.y / point.w

proc paintbotWaterFrag(fragColor: var Vec4, worldPos: Vec3, screenPos: Vec4) =
  ## Murky water: shows the scene behind this pixel (bent by the ripples) and covers it
  ## with the water's colour, more the deeper it lies below the surface.
  let
    ndc = vec2(screenPos.x / screenPos.w, screenPos.y / screenPos.w)
    depthUv = vec2(
      depthViewport.x + (ndc.x * 0.5 + 0.5) * depthViewport.z,
      depthViewport.y + (ndc.y * 0.5 + 0.5) * depthViewport.w)
    straightDepth = max(worldPos.y - sceneHeight(depthUv), 0.0)
    toCamera: Vec3 = normalize(cameraPos - worldPos)
    # The ripples' normal from three height samples a few centimetres apart, flattened
    # with distance so far water does not shimmer.
    e = 0.02
    xz = vec2(worldPos.x, worldPos.z)
    h = waveSum(xz / waveScale) * waveHeight
    hx = waveSum((xz + vec2(e, 0.0)) / waveScale) * waveHeight
    hz = waveSum((xz + vec2(0.0, e)) / waveScale) * waveHeight
    flatten = clamp(length(cameraPos - worldPos) / rippleFade, 0.0, 1.0) * 0.85
    normal: Vec3 = normalize(mix(normalize(vec3(h - hx, e, h - hz)), vec3(0.0, 1.0, 0.0),
      flatten))
    # Refraction: read the scene where the ripples push the view, more in deeper water.
    bentUv = depthUv + vec2(normal.x, normal.z) *
      (refraction * clamp(straightDepth / refractionDepth, 0.0, 1.0))
    bentHeight = sceneHeight(bentUv)
  # A push onto something in front of the water keeps the straight view.
  var
    seenUv = bentUv
    depth = max(worldPos.y - bentHeight, 0.0)
  # A refracted ray outside an inset must not sample the main camera's pixels.
  if bentHeight > worldPos.y or bentUv.x < depthViewport.x or
      bentUv.y < depthViewport.y or bentUv.x >= depthViewport.x + depthViewport.z or
      bentUv.y >= depthViewport.y + depthViewport.w:
    seenUv = depthUv
    depth = straightDepth
  let
    murk = 1.0 - exp(-depth * murkDensity)
    seen = texture(sceneColorTex, seenUv).xyz
    # The reflection pass is mirrored left to right (see reflectedCamera), so u runs
    # the other way; the ripples shift where it is read.
    reflection = texture(reflectionTex, vec2(0.5 - ndc.x * 0.5, 0.5 + ndc.y * 0.5) +
      vec2(normal.x, normal.z) * distortion).xyz
    # Schlick's Fresnel on the rippled surface: the reflectiveness looking straight down,
    # rising to 1 at grazing.
    cosTheta = clamp(dot(normal, toCamera), 0.0, 1.0)
    r = reflectiveness + (1.0 - reflectiveness) * fresnelStrength *
      pow(1.0 - cosTheta, fresnelPower)
    # The view ray mirrored off the rippled surface, against the sun direction: a broad
    # sheen and a sharp glint on each ripple facing the sun.
    mirrored: Vec3 = normal * (2.0 * dot(normal, toCamera)) - toCamera
    toSun = max(dot(mirrored, waterSunToward), 0.0)
    sheen: Vec3 = sheenColor * (r * pow(toSun, sheenSharpness))
    glint: Vec3 = glintColor * (r * pow(toSun, glintSharpness))
    # reflection * r + (murky water) * (1 - r), where the murky water is the water's
    # colour over the refracted scene with opacity murk. The water draws the scene itself,
    # so it is opaque; reflection, sheen and glint can exceed 1 (the sun).
    color = (seen * (1.0 - murk) + waterColor * murk) * (1.0 - r) + reflection * r +
      sheen + glint
  fragColor = vec4(color.x, color.y, color.z, 1.0)

let startTime = epochTime()

var
  reflectionFbo, reflectionColor, reflectionDepth, blankTexture: GLuint
  reflectionSize: IVec2
  depthCopyFbo, depthCopy, colorCopy: GLuint
  depthCopySize: IVec2

proc installPaintbotWater*() =
  ## Call before initTerrain, which compiles the water program.
  waterPremultipliedAlpha = true
  waterShaderOverride = (
    toShader(paintbotWaterVert, ShaderTarget, shaderVertex),
    toShader(paintbotWaterFrag, ShaderTarget, shaderFragment))

proc initPaintbotWater*() =
  ## Call after initTerrain: points the shader at the reflection's texture unit.
  glUseProgram(waterShaderProgram())
  glUniform1i(glGetUniformLocation(waterShaderProgram(), "reflectionTex"), ReflectionUnit)
  glUniform1i(glGetUniformLocation(waterShaderProgram(), "sceneDepthTex"), SceneDepthUnit)
  glUniform1i(glGetUniformLocation(waterShaderProgram(), "sceneColorTex"), SceneColorUnit)
  glUseProgram(0)
  glGenFramebuffers(1, depthCopyFbo.addr)
  glGenTextures(1, depthCopy.addr)
  glGenTextures(1, colorCopy.addr)
  glGenFramebuffers(1, reflectionFbo.addr)
  glGenTextures(1, reflectionColor.addr)
  glGenRenderbuffers(1, reflectionDepth.addr)
  # Bound for views without their own reflection pass (the first-person inset), which
  # draw with no reflectiveness.
  var white = [255'u8, 255, 255, 255]
  glGenTextures(1, blankTexture.addr)
  glBindTexture(GL_TEXTURE_2D, blankTexture)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, white[0].addr)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)

proc reflectedCamera*(eye: Vec3, view, projection: Mat4,
    height: float32): tuple[eye: Vec3, view, projection: Mat4] =
  ## The camera mirrored in the water plane y = height. Its projection's near plane is the
  ## water itself (Lengyel's oblique clipping), so nothing below the surface is reflected,
  ## and it flips x so the mirrored triangles keep their winding for back-face culling.
  let mirror = translate(vec3(0, height, 0)) * scale(vec3(1'f32, -1, 1)) *
    translate(vec3(0, -height, 0))
  result.eye = vec3(eye.x, 2*height-eye.y, eye.z)
  result.view = view * mirror
  let plane = transpose(inverse(result.view)) * vec4(0'f32, 1, 0, -height)
  var oblique = projection
  let q = inverse(projection) * vec4(sgn(plane.x).float32, sgn(plane.y).float32, 1, 1)
  let c = plane * (2'f32 / dot(plane, q))
  for column in 0..3: oblique[column, 2] = c[column] - oblique[column, 3]
  result.projection = scale(vec3(-1'f32, 1, 1)) * oblique

proc beginWaterReflection*(size: IVec2) =
  ## Starts rendering the reflection into its texture, at the window's size; draw the
  ## sky (see sky.nim) first.
  if size != reflectionSize:
    reflectionSize = size
    glBindTexture(GL_TEXTURE_2D, reflectionColor)
    # Half floats keep the sun brighter than white; WebGL 2 cannot render to them without
    # an extension, so the browser keeps 8 bits and a dimmer sun.
    when defined(emscripten):
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, size.x, size.y, 0, GL_RGBA,
        GL_UNSIGNED_BYTE, nil)
    else:
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F.GLint, size.x, size.y, 0, GL_RGBA,
        cGL_FLOAT, nil)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    glBindTexture(GL_TEXTURE_2D, 0)
    glBindRenderbuffer(GL_RENDERBUFFER, reflectionDepth)
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, size.x, size.y)
    glBindRenderbuffer(GL_RENDERBUFFER, 0)
    glBindFramebuffer(GL_FRAMEBUFFER, reflectionFbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
      reflectionColor, 0)
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER,
      reflectionDepth)
    if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
      raise newException(ValueError, "Paintbot reflection framebuffer is incomplete")
  glBindFramebuffer(GL_FRAMEBUFFER, reflectionFbo)
  glViewport(0, 0, size.x, size.y)
  glClear(GL_DEPTH_BUFFER_BIT)

proc endWaterReflection*() =
  ## Returns to the window's framebuffer; the caller restores its viewport.
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

proc bindWaterReflection(reflected: bool) =
  ## The reflection just rendered, or plain white for a view without one.
  glActiveTexture(GLenum(GL_TEXTURE0.int + ReflectionUnit))
  glBindTexture(GL_TEXTURE_2D, if reflected: reflectionColor else: blankTexture)
  glActiveTexture(GL_TEXTURE0)

proc captureScene(size: IVec2) =
  ## Copies the window's colour and depth into colorCopy and depthCopy. The depth texture
  ## matches the window's 24-bit depth, 8-bit stencil format, which a depth blit requires.
  if size != depthCopySize:
    depthCopySize = size
    glBindTexture(GL_TEXTURE_2D, depthCopy)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8.GLint, size.x, size.y, 0,
      GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, nil)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    glBindTexture(GL_TEXTURE_2D, colorCopy)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, size.x, size.y, 0, GL_RGBA,
      GL_UNSIGNED_BYTE, nil)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    glBindTexture(GL_TEXTURE_2D, 0)
    glBindFramebuffer(GL_FRAMEBUFFER, depthCopyFbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
      colorCopy, 0)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D,
      depthCopy, 0)
    if glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
      raise newException(ValueError, "Paintbot scene-copy framebuffer is incomplete")
  glBindFramebuffer(GL_READ_FRAMEBUFFER, 0)
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, depthCopyFbo)
  glBlitFramebuffer(0, 0, size.x, size.y, 0, 0, size.x, size.y,
    GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT, GL_NEAREST.GLenum)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

proc reflecting*(): bool =
  ## Whether the water shows reflections, so the frame needs its reflection pass.
  waterParams.reflectiveness > 0 or waterParams.fresnelStrength > 0

proc drawMurkyWater*(viewProjection: Mat4, eye: Vec3, seconds: float32, windowSize: IVec2,
    sunColor: Color, viewport = ivec4(0, 0, 0, 0), reflected = false) =
  ## Draws the water over everything drawn so far; call after the opaque scene.
  ## `viewport` is the view's x, y, width, height in window pixels; zero means the window.
  ## `reflected` says this frame's reflection pass rendered this view.
  let rect = if viewport.z == 0: ivec4(0, 0, windowSize.x, windowSize.y) else: viewport
  captureScene(windowSize)
  glUseProgram(waterShaderProgram())
  var inverse = viewProjection.inverse
  glUniformMatrix4fv(glGetUniformLocation(waterShaderProgram(), "inverseViewProjection"),
    1, GL_FALSE, cast[ptr float32](inverse.addr))
  glUniform4f(glGetUniformLocation(waterShaderProgram(), "depthViewport"),
    rect.x / windowSize.x, rect.y / windowSize.y,
    rect.z / windowSize.x, rect.w / windowSize.y)
  let program = waterShaderProgram()
  glUniform3f(glGetUniformLocation(program, "waterColor"),
    waterParams.color.x, waterParams.color.y, waterParams.color.z)
  glUniform1f(glGetUniformLocation(program, "murkDensity"), waterParams.murkDensity)
  glUniform1f(glGetUniformLocation(program, "waterLift"), waterParams.height - RiverSurface)
  # A view without its reflection pass reflects nothing at any angle.
  glUniform1f(glGetUniformLocation(program, "reflectiveness"),
    if reflected: waterParams.reflectiveness else: 0)
  glUniform1f(glGetUniformLocation(program, "fresnelStrength"),
    if reflected: waterParams.fresnelStrength else: 0)
  glUniform1f(glGetUniformLocation(program, "fresnelPower"), waterParams.fresnelPower)
  let sun = sunToward()
  glUniform3f(glGetUniformLocation(program, "waterSunToward"), sun.x, sun.y, sun.z)
  let sheen = waterParams.sheenStrength
  glUniform3f(glGetUniformLocation(program, "sheenColor"),
    sunColor.r * sheen, sunColor.g * sheen, sunColor.b * sheen)
  glUniform1f(glGetUniformLocation(program, "sheenSharpness"), waterParams.sheenSharpness)
  let glint = waterParams.glintStrength
  glUniform3f(glGetUniformLocation(program, "glintColor"),
    sunColor.r * glint, sunColor.g * glint, sunColor.b * glint)
  glUniform1f(glGetUniformLocation(program, "glintSharpness"), waterParams.glintSharpness)
  for (name, value) in [("waveHeight", waterParams.waveHeight),
      ("waveScale", waterParams.waveScale), ("waveSpeed", waterParams.waveSpeed),
      ("waveDrag", waterParams.waveDrag), ("waveCount", waterParams.waveCount),
      ("rippleFade", waterParams.rippleFade), ("distortion", waterParams.distortion),
      ("refraction", waterParams.refraction),
      ("refractionDepth", max(waterParams.refractionDepth, 0.001))]:
    glUniform1f(glGetUniformLocation(program, name.cstring), value)
  # Wrapped every 10,000 s to keep float32 precision; the jump is rare and brief.
  glUniform1f(glGetUniformLocation(program, "rippleClock"),
    float32((epochTime() - startTime) mod 10_000))
  glUseProgram(0)
  bindWaterReflection(reflected)
  glActiveTexture(GLenum(GL_TEXTURE0.int + SceneDepthUnit))
  glBindTexture(GL_TEXTURE_2D, depthCopy)
  glActiveTexture(GLenum(GL_TEXTURE0.int + SceneColorUnit))
  glBindTexture(GL_TEXTURE_2D, colorCopy)
  glActiveTexture(GL_TEXTURE0)
  drawWater(viewProjection, eye, seconds)
