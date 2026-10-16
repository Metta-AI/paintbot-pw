## A sunny sky shared by the camera and planar water reflections. The atmosphere
## and sun stay fixed while a separate premultiplied RGBA cloud layer drifts.
## Periodic sampling closes both tile seams exactly, including imperfect art edges.
import std/math
import opengl, pixie, shady, vmath
import polyworld/[quadterrain, shadows, toon]

const
  ShaderTarget =
    when defined(emscripten): glsl3WebGL
    else: glsl4Desktop
  CloudPng = staticRead("textures/sunny-clouds.png")

type SkyParams* = object
  sunAzimuth*, sunElevation*: float32 ## manual sun position, in degrees
  sunRotation*: float32 ## rotates only the sun layer around the vertical axis
  sunSize*, sunBrightness*: float32
  glowStrength*, glowSharpness*, gradientPower*, exposure*: float32
  cloudSpeed*: float32 ## 1 = gentle wind, 0 = still; negative reverses the wind

const DefaultSkyParams* = SkyParams(sunAzimuth: -149.1,
  sunElevation: 34.78, sunRotation: -3.13, sunSize: 1.2, sunBrightness: 4,
  glowStrength: 0.22, glowSharpness: 24, gradientPower: 0.55, exposure: 1,
  cloudSpeed: 2.5)

var
  skyParams* = DefaultSkyParams
  cloudPhase: float64
  skyProgram, skyVertexArray, skyVertexBuffer, cloudTexture: GLuint
  skyInverseViewProjection: Uniform[Mat4]
  skyEye, skySunDirection: Uniform[Vec3]
  skySunCosine, skySunBrightness, skyGlowStrength: Uniform[float32]
  skyGlowSharpness, skyGradientPower, skyExposure: Uniform[float32]
  skyCloudOffset: Uniform[Vec2]
  skyClouds: Uniform[Sampler2D]

proc skyVert(gl_Position: var Vec4, vertPos: Vec2, ndc: var Vec2) =
  gl_Position = vec4(vertPos.x, vertPos.y, 1.0, 1.0)
  ndc = vertPos

proc periodicClouds(uv: Vec2): Vec4 =
  ## At each seam the discontinuous lookup has zero weight; its half-tile
  ## neighbour is continuous. Smooth weights close the first derivative too.
  let
    p = vec2(fract(uv.x), fract(uv.y))
    q = vec2(fract(uv.x + 0.5), fract(uv.y + 0.5))
    wx = smoothstep(0.0, 0.18, p.x) * smoothstep(0.0, 0.18, 1.0 - p.x)
    wy = smoothstep(0.0, 0.18, p.y) * smoothstep(0.0, 0.18, 1.0 - p.y)
    a: Vec4 = mix(texture(skyClouds, vec2(q.x, p.y)), texture(skyClouds, p), wx)
    b: Vec4 = mix(texture(skyClouds, q), texture(skyClouds, vec2(p.x, q.y)), wx)
  result = mix(b, a, wy)

proc skyFrag(fragColor: var Vec4, ndc: Vec2) =
  ## Reconstruct from the near plane: an oblique reflection's far plane can
  ## lie behind the eye. Direction mapping has no longitude or pole seam.
  let
    nearPoint: Vec4 = skyInverseViewProjection * vec4(ndc.x, ndc.y, -1.0, 1.0)
    d: Vec3 = normalize(vec3(nearPoint.x, nearPoint.y, nearPoint.z) / nearPoint.w - skyEye)
    up = pow(clamp(d.y, 0.0, 1.0), skyGradientPower)
    down = smoothstep(0.0, 0.55, -d.y)
    toSun = dot(d, skySunDirection)
    disc = smoothstep(skySunCosine - 0.00015, skySunCosine + 0.00015, toSun)
    glow = pow(max(toSun, 0.0), skyGlowSharpness)
    horizon = vec3(0.68, 0.85, 0.96)
    zenith = vec3(0.12, 0.44, 0.82)
    ground = vec3(0.38, 0.56, 0.66)
    sunlight = vec3(1.0, 0.96, 0.84)
    cloudUv: Vec2 = vec2(d.x, d.z) * (0.28 / max(d.y + 0.15, 0.15)) + skyCloudOffset
    cloudFade = smoothstep(0.015, 0.16, d.y)
    clouds: Vec4 = periodicClouds(cloudUv) * cloudFade
  var color: Vec3 = mix(mix(horizon, zenith, up), ground, down)
  color = color + sunlight * (skySunBrightness * disc + skyGlowStrength * glow)
  # Pixie decodes to premultiplied RGBA so filtering/crossfading preserves
  # soft edges without picking up the transparent pixels' RGB.
  color = color * (1.0 - clouds.w) + vec3(clouds.x, clouds.y, clouds.z)
  color = color * skyExposure
  fragColor = vec4(color.x, color.y, color.z, 1.0)

proc compileShader(kind: GLenum, source: string): GLuint =
  result = glCreateShader(kind)
  var text = allocCStringArray([source])
  glShaderSource(result, 1, text, nil)
  deallocCStringArray(text)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok == 0:
    var log = newString(4096)
    var length: GLsizei
    glGetShaderInfoLog(result, 4096, length.addr, log.cstring)
    log.setLen(length)
    raise newException(ValueError, "sky shader: " & log)

proc initSky*() =
  ## PNG is embedded in native/web builds, independent of external art.
  let
    vertex = compileShader(GL_VERTEX_SHADER, toShader(skyVert, ShaderTarget, shaderVertex))
    fragment = compileShader(GL_FRAGMENT_SHADER, toShader(skyFrag, ShaderTarget, shaderFragment))
  skyProgram = glCreateProgram()
  glAttachShader(skyProgram, vertex)
  glAttachShader(skyProgram, fragment)
  glLinkProgram(skyProgram)
  glDeleteShader(vertex)
  glDeleteShader(fragment)
  var ok: GLint
  glGetProgramiv(skyProgram, GL_LINK_STATUS, ok.addr)
  if ok == 0:
    var log = newString(4096)
    var length: GLsizei
    glGetProgramInfoLog(skyProgram, 4096, length.addr, log.cstring)
    log.setLen(length)
    raise newException(ValueError, "sky program: " & log)
  let clouds = decodeImage(CloudPng)
  glActiveTexture(GL_TEXTURE0)
  glGenTextures(1, cloudTexture.addr)
  glBindTexture(GL_TEXTURE_2D, cloudTexture)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, clouds.width.GLsizei,
    clouds.height.GLsizei, 0, GL_RGBA, GL_UNSIGNED_BYTE, clouds.data[0].addr)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glGenerateMipmap(GL_TEXTURE_2D)
  glBindTexture(GL_TEXTURE_2D, 0)
  var triangle = [-1'f32, -1, 3, -1, -1, 3]
  glGenVertexArrays(1, skyVertexArray.addr)
  glBindVertexArray(skyVertexArray)
  glGenBuffers(1, skyVertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, skyVertexBuffer)
  glBufferData(GL_ARRAY_BUFFER, sizeof(triangle), triangle[0].addr, GL_STATIC_DRAW)
  let position = glGetAttribLocation(skyProgram, "vertPos")
  glEnableVertexAttribArray(position.GLuint)
  glVertexAttribPointer(position.GLuint, 2, cGL_FLOAT, GL_FALSE, 0, nil)
  glBindVertexArray(0)

proc advanceSky*(dt: float32) =
  ## Integrate once per displayed frame so speed edits never jump the clouds,
  ## and every camera uses the same phase. Both wind components wrap together.
  cloudPhase = cloudPhase + dt.float64 * skyParams.cloudSpeed.float64 * 0.004
  cloudPhase = cloudPhase - floor(cloudPhase / 5.0) * 5.0

proc sunToward*(): Vec3 =
  ## Unit direction toward the sun: its azimuth and elevation, turned by the rotation.
  let
    a = skyParams.sunAzimuth * PI.float32 / 180
    e = skyParams.sunElevation * PI.float32 / 180
    base = vec3(cos(e) * sin(a), sin(e), cos(e) * cos(a))
    r = skyParams.sunRotation * PI.float32 / 180
  vec3(base.x * cos(r) + base.z * sin(r), base.y,
    -base.x * sin(r) + base.z * cos(r))

var litFrom = vec3(0, 0, 0) # the sun direction the shadows and light last took

proc shadowsFollowSun*(toon: ToonContext) =
  ## Aims the shadow maps and the scene's light (characters and terrain) at the sky's
  ## sun whenever it moves; call once a frame before the shadow pass.
  let s = sunToward()
  if s == litFrom: return
  litFrom = s
  shadows.sunAzimuth = arctan2(s.x, s.z) * 180 / PI.float32
  shadows.sunElevation = arcsin(clamp(s.y, -1, 1)) * 180 / PI.float32
  updateSunMatrix()
  toon.lightDirection = -sunDirection
  setEnvironmentPalette(toon)

proc drawSky*(viewProjection: Mat4, eye: Vec3, sun = true) =
  ## Draw first in the active viewport, without writing depth. `sun = false` leaves out
  ## the sun's disc and glow: the water's reflection draws the sun from its ripples.
  var inverse = viewProjection.inverse
  let s = sunToward()
  glUseProgram(skyProgram)
  glUniformMatrix4fv(glGetUniformLocation(skyProgram, "skyInverseViewProjection"), 1,
    GL_FALSE, cast[ptr float32](inverse.addr))
  glUniform3f(glGetUniformLocation(skyProgram, "skyEye"), eye.x, eye.y, eye.z)
  glUniform3f(glGetUniformLocation(skyProgram, "skySunDirection"), s.x, s.y, s.z)
  glUniform1f(glGetUniformLocation(skyProgram, "skySunCosine"), cos(skyParams.sunSize * PI.float32 / 180))
  glUniform1f(glGetUniformLocation(skyProgram, "skySunBrightness"),
    if sun: skyParams.sunBrightness else: 0)
  glUniform1f(glGetUniformLocation(skyProgram, "skyGlowStrength"),
    if sun: skyParams.glowStrength else: 0)
  glUniform1f(glGetUniformLocation(skyProgram, "skyGlowSharpness"), skyParams.glowSharpness)
  glUniform1f(glGetUniformLocation(skyProgram, "skyGradientPower"), skyParams.gradientPower)
  glUniform1f(glGetUniformLocation(skyProgram, "skyExposure"), skyParams.exposure)
  glUniform2f(glGetUniformLocation(skyProgram, "skyCloudOffset"), cloudPhase.float32,
    (cloudPhase * 0.4).float32)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, cloudTexture)
  glUniform1i(glGetUniformLocation(skyProgram, "skyClouds"), 0)
  glDisable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glDisable(GL_BLEND)
  glDisable(GL_CULL_FACE)
  glBindVertexArray(skyVertexArray)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  glBindVertexArray(0)
  glDepthMask(GL_TRUE)
  glEnable(GL_DEPTH_TEST)
  glUseProgram(0)
