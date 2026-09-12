## Shared selection and occlusion outlines for Polyworld graphical clients.

import
  opengl, shady, vmath

const
  ShaderTarget =
    when defined(emscripten):
      glsl3WebGL
    else:
      glsl4Desktop

type
  SelectionOutlineError* = object of CatchableError

  OutlineVisibility* = enum
    AlwaysOutline, OccludedOutline

  SelectionOutline* = object
    framebuffer: GLuint
    colorTexture: GLuint
    depthTexture: GLuint
    program: GLuint
    vertexArray: GLuint
    vertexBuffer: GLuint
    size: IVec2
    visibility: OutlineVisibility

var
  selectionTexture: Uniform[Sampler2d]
  selectionResolution: Uniform[Vec2]
  selectionColor: Uniform[Vec3]

const
  SelectionOutlineColor* = vec3(1.0, 0.78, 0.12)
  AttackOutlineColor* = vec3(0.92, 0.16, 0.14)
  OccludedOutlineColor* = vec3(0.55, 0.85, 1.0)
  OcclusionFragment = """
uniform sampler2D selectionTexture;
uniform highp sampler2D selectionDepth;
uniform vec2 selectionResolution;
uniform vec3 selectionColor;
in vec2 texturePosition;
out vec4 fragColor;

void main() {
  vec2 pixel = vec2(2.0) / selectionResolution;
  float center = texture(selectionTexture, texturePosition).a;
  float nearby = 0.0;
  float nearestDepth = 1.0;
  for (int y = -1; y <= 1; ++y) {
    for (int x = -1; x <= 1; ++x) {
      vec2 uv = texturePosition + vec2(float(x), float(y)) * pixel;
      float alpha = texture(selectionTexture, uv).a;
      float depth = texture(selectionDepth, uv).r;
      if (alpha > 0.5 && depth < 1.0) {
        nearby = max(nearby, alpha);
        nearestDepth = min(nearestDepth, depth);
      }
    }
  }
  float edge = clamp(nearby - center, 0.0, 1.0);
  if (edge <= 0.0) {
    discard;
  }
  // Test the silhouette's depth against scenery without changing scene depth.
  // The small bias avoids outlining surfaces at the same depth.
  gl_FragDepth = max(nearestDepth - 0.0000001, 0.0);
  fragColor = vec4(selectionColor, edge);
}
"""

proc selectionVertex(
    gl_Position: var Vec4,
    texturePosition: var Vec2,
    vertexPosition: Vec2
) =
  ## Emits one full-screen triangle vertex for the selection outline.
  texturePosition = vertexPosition * 0.5'f32 + 0.5'f32
  gl_Position = vec4(vertexPosition.x, vertexPosition.y, 0, 1)

proc selectionFragment(fragColor: var Vec4, texturePosition: Vec2) =
  ## Finds the outside edge of the selected object's exact silhouette.
  let
    pixel = vec2(1, 1) / selectionResolution
    center = texture(selectionTexture, texturePosition).a
  var nearby = 0.0'f32
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(-2, -2) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(0, -2) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(2, -2) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(-2, 0) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(2, 0) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(-2, 2) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(0, 2) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(2, 2) * pixel
    ).a
  )
  let edge = clamp(nearby - center, 0, 1)
  fragColor = vec4(selectionColor, edge)

proc compileShaderStage(
    kind: GLenum,
    source,
    label: string
): GLuint =
  ## Compiles one selection shader stage with a useful diagnostic.
  result = glCreateShader(kind)
  let sources = allocCStringArray([source])
  defer:
    deallocCStringArray(sources)
  glShaderSource(result, 1, sources, nil)
  glCompileShader(result)
  var status: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetShaderInfoLog(result, length, nil, log.cstring)
    raise newException(
      SelectionOutlineError,
      label & " shader failed:\n" & log & "\n" & source
    )

proc compileProgram(visibility: OutlineVisibility): GLuint =
  ## Compiles and links the shared selection edge shader program.
  let
    fragmentSource =
      if visibility == OccludedOutline:
        # Shady does not yet expose the fragment-depth output builtin.
        when defined(emscripten):
          "#version 300 es\nprecision highp float;\n" & OcclusionFragment
        else:
          "#version 410 core\n" & OcclusionFragment
      else:
        toShader(selectionFragment, ShaderTarget, shaderFragment)
    vertexShader = compileShaderStage(
      GL_VERTEX_SHADER,
      toShader(selectionVertex, ShaderTarget, shaderVertex),
      "selection vertex"
    )
    fragmentShader = compileShaderStage(
      GL_FRAGMENT_SHADER,
      fragmentSource,
      "selection fragment"
    )
  result = glCreateProgram()
  glAttachShader(result, vertexShader)
  glAttachShader(result, fragmentShader)
  glLinkProgram(result)
  glDeleteShader(vertexShader)
  glDeleteShader(fragmentShader)
  var status: GLint
  glGetProgramiv(result, GL_LINK_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetProgramInfoLog(result, length, nil, log.cstring)
    raise newException(
      SelectionOutlineError,
      "selection program failed:\n" & log
    )

proc initSelectionOutline*(
    visibility = AlwaysOutline
): SelectionOutline =
  ## Creates the selection edge shader and full-screen triangle.
  result.visibility = visibility
  result.program = compileProgram(visibility)
  let vertices = [
    -1.0'f32, -1.0'f32,
    3.0'f32, -1.0'f32,
    -1.0'f32, 3.0'f32
  ]
  glGenVertexArrays(1, result.vertexArray.addr)
  glBindVertexArray(result.vertexArray)
  glGenBuffers(1, result.vertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER,
    sizeof(vertices),
    unsafeAddr vertices[0],
    GL_STATIC_DRAW
  )
  let location = glGetAttribLocation(result.program, "vertexPosition")
  doAssert location >= 0
  glEnableVertexAttribArray(location.GLuint)
  glVertexAttribPointer(
    location.GLuint,
    2,
    cGL_FLOAT,
    GL_FALSE,
    (2 * sizeof(float32)).GLsizei,
    nil
  )
  glBindVertexArray(0)
  glGenFramebuffers(1, result.framebuffer.addr)
  glGenTextures(1, result.colorTexture.addr)
  glGenTextures(1, result.depthTexture.addr)

proc ensureSize(outline: var SelectionOutline, size: IVec2) =
  ## Resizes the silhouette framebuffer to match the current window.
  let safeSize = ivec2(max(size.x, 1), max(size.y, 1))
  if outline.size == safeSize:
    return
  outline.size = safeSize
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, outline.colorTexture)
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GL_RGBA8.GLint,
    safeSize.x,
    safeSize.y,
    0,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    nil
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_MIN_FILTER,
    GL_NEAREST.GLint
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_MAG_FILTER,
    GL_NEAREST.GLint
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_WRAP_S,
    GL_CLAMP_TO_EDGE.GLint
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_WRAP_T,
    GL_CLAMP_TO_EDGE.GLint
  )
  glBindTexture(GL_TEXTURE_2D, outline.depthTexture)
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GL_DEPTH_COMPONENT24.GLint,
    safeSize.x,
    safeSize.y,
    0,
    GL_DEPTH_COMPONENT,
    GL_UNSIGNED_INT,
    nil
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glBindFramebuffer(GL_FRAMEBUFFER, outline.framebuffer)
  glFramebufferTexture2D(
    GL_FRAMEBUFFER,
    GL_COLOR_ATTACHMENT0,
    GL_TEXTURE_2D,
    outline.colorTexture,
    0
  )
  glFramebufferTexture2D(
    GL_FRAMEBUFFER,
    GL_DEPTH_ATTACHMENT,
    GL_TEXTURE_2D,
    outline.depthTexture,
    0
  )
  doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) ==
    GL_FRAMEBUFFER_COMPLETE
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glBindTexture(GL_TEXTURE_2D, 0)

proc beginMask*(outline: var SelectionOutline, size: IVec2) =
  ## Clears and binds the selected-object silhouette target.
  outline.ensureSize(size)
  glBindFramebuffer(GL_FRAMEBUFFER, outline.framebuffer)
  glViewport(0, 0, outline.size.x, outline.size.y)
  glDepthMask(GL_TRUE)
  glDisable(GL_BLEND)
  glEnable(GL_DEPTH_TEST)
  glDepthFunc(GL_LEQUAL)
  glClearColor(0, 0, 0, 0)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

proc drawOutline*(
    outline: SelectionOutline,
    color = SelectionOutlineColor
) =
  ## Draws silhouette edges, optionally only behind the window's scene depth.
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glViewport(0, 0, outline.size.x, outline.size.y)
  glDepthMask(GL_FALSE)
  if outline.visibility == OccludedOutline:
    glEnable(GL_DEPTH_TEST)
    glDepthFunc(GL_GREATER)
  else:
    glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glEnable(GL_BLEND)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  glUseProgram(outline.program)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, outline.colorTexture)
  glUniform1i(
    glGetUniformLocation(outline.program, "selectionTexture"),
    0
  )
  if outline.visibility == OccludedOutline:
    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_2D, outline.depthTexture)
    glUniform1i(
      glGetUniformLocation(outline.program, "selectionDepth"),
      1
    )
  glUniform2f(
    glGetUniformLocation(outline.program, "selectionResolution"),
    outline.size.x.float32,
    outline.size.y.float32
  )
  glUniform3f(
    glGetUniformLocation(outline.program, "selectionColor"),
    color.x,
    color.y,
    color.z
  )
  glBindVertexArray(outline.vertexArray)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  glBindVertexArray(0)
  glUseProgram(0)
  glDisable(GL_BLEND)
  glDepthFunc(GL_LEQUAL)
  glDepthMask(GL_TRUE)
  glActiveTexture(GL_TEXTURE0)

proc closeSelectionOutline*(outline: var SelectionOutline) =
  ## Releases the outline's shader, mesh, and framebuffer attachments.
  glDeleteTextures(1, outline.colorTexture.addr)
  glDeleteTextures(1, outline.depthTexture.addr)
  glDeleteFramebuffers(1, outline.framebuffer.addr)
  glDeleteBuffers(1, outline.vertexBuffer.addr)
  glDeleteVertexArrays(1, outline.vertexArray.addr)
  glDeleteProgram(outline.program)
  outline = SelectionOutline()
