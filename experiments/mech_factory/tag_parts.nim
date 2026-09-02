## Renders every greeble part to labeled contact sheets so the parts can be
## described and tagged visually (see parts_tags.json). One part per frame
## from a fixed 3/4 camera, read back and pasted into 5x5 sheets.
##
## Run from the repo root: nim r experiments/mech_factory/tag_parts.nim
## Sheets land in tmp/tag_shots/sheet_NN.png

import
  std/[strformat, strutils, os],
  vmath, chroma, shady, pixie,
  gltf,
  windy, opengl

const
  DataDir = "../polyworld_data"
  GreeblePath = DataDir & "/greeble/271_greebles_low_poly_model.glb"
  FontPath = DataDir & "/themes/editor/IBMPlexSans-Regular.ttf"
  OutDir = "tmp/tag_shots"
  Cell = 256
  LabelHeight = 26
  Columns = 5
  Rows = 5

## Shader: same metallic look as mech_factory, so the sheets show the parts
## the way the editor will.

var
  tagModel: Uniform[Mat4]
  tagNormalMatrix: Uniform[Mat3]
  tagView: Uniform[Mat4]
  tagProj: Uniform[Mat4]
  tagLightDirection: Uniform[Vec3]
  tagCameraPosition: Uniform[Vec3]

proc tagVert(
  vertexPosition: Vec3,
  vertexNormal: Vec3,
  gl_Position: var Vec4,
  worldPos: var Vec3,
  normal: var Vec3
) =
  worldPos = (tagModel * vec4(vertexPosition, 1.0'f)).xyz
  normal = normalize(tagNormalMatrix * vertexNormal)
  gl_Position = tagProj * tagView * vec4(worldPos, 1.0'f)

proc tagFrag(
  worldPos: Vec3,
  normal: Vec3,
  fragColor: var Vec4
) =
  var n: Vec3 = normalize(normal)
  if not gl_FrontFacing:
    n = -n
  let
    eye: Vec3 = normalize(tagCameraPosition - worldPos)
    toLight: Vec3 = normalize(-tagLightDirection)
    albedo: Vec3 = vec3(0.62'f, 0.65'f, 0.60'f)
    diffuse = max(dot(n, toLight), 0.0'f)
    halfVec: Vec3 = normalize(toLight + eye)
    specular = pow(max(dot(n, halfVec), 0.0'f), 32.0'f)
    ambient: Vec3 = vec3(0.32'f, 0.34'f, 0.38'f)
  let lit: Vec3 = albedo * (ambient + vec3(1.0'f, 0.98'f, 0.94'f) * diffuse) +
    vec3(1.0'f) * specular * 0.35'f
  fragColor = vec4(lit, 1.0'f)

const
  TagVertSrc = toShader(tagVert, glsl4Desktop, shaderVertex)
  TagFragSrc = toShader(tagFrag, glsl4Desktop, shaderFragment)

## Window

let window = newWindow("Tag Parts", ivec2(Cell, Cell), vsync = false, msaa = msaa4x)
makeContextCurrent(window)
loadExtensions()

var shader = compileShaderFiles(TagVertSrc, TagFragSrc)
let
  uModel = glGetUniformLocation(shader, "tagModel")
  uNormalMatrix = glGetUniformLocation(shader, "tagNormalMatrix")
  uView = glGetUniformLocation(shader, "tagView")
  uProj = glGetUniformLocation(shader, "tagProj")
  uLightDirection = glGetUniformLocation(shader, "tagLightDirection")
  uCameraPosition = glGetUniformLocation(shader, "tagCameraPosition")

## Parts

type PartDef = object
  name: string
  mesh: Mesh
  boundsMin, boundsMax: Vec3

var parts: seq[PartDef]

let source = readGltfFile(GreeblePath)
source.root.updateTransforms()
for node in source.root.walkNodes:
  if not node.name.startsWith("greeble"):
    continue
  var meshNode: Node
  for child in node.walkNodes:
    if child.mesh != nil:
      meshNode = child
  doAssert meshNode != nil, "no mesh under " & node.name
  var part = PartDef(name: node.name, mesh: meshNode.mesh)
  part.boundsMin = vec3(float32.high)
  part.boundsMax = vec3(float32.low)
  for primitive in part.mesh.primitives:
    for point in primitive.points:
      part.boundsMin = min(part.boundsMin, point)
      part.boundsMax = max(part.boundsMax, point)
  parts.add part
doAssert parts.len == 271, "expected 271 greebles, got " & $parts.len

## Render loop: one part per frame, pasted into sheets.

createDir(OutDir)
let font = readFont(FontPath)
font.size = 15
font.paint = "#E8E8E8"

let
  sheetWidth = Columns * Cell
  sheetHeight = Rows * (Cell + LabelHeight)
var
  sheet = newImage(sheetWidth, sheetHeight)
  sheetIndex = 0
  partIndex = 0

proc finishSheet() =
  sheet.writeFile(OutDir & &"/sheet_{sheetIndex:02}.png")
  echo "wrote sheet ", sheetIndex
  inc sheetIndex
  sheet = newImage(sheetWidth, sheetHeight)

window.onFrame = proc() =
  if partIndex >= parts.len:
    if partIndex mod (Columns * Rows) != 0:
      finishSheet()
    quit(0)

  let part = parts[partIndex]
  let
    center = (part.boundsMin + part.boundsMax) * 0.5
    size = part.boundsMax - part.boundsMin
    radius = max(size.x, max(size.y, size.z)) * 0.5
    eyeDir = normalize(vec3(1.0, 0.75, 1.0))
    eye = center + eyeDir * radius * 2.9
    view = lookAt(eye, center, vec3(0, 1, 0))
    proj = perspective(45.0'f32, 1.0'f32, 0.02'f32, 500.0'f32)
    lightDirection = normalize(vec3(0.4, -0.6, -0.8))

  glViewport(0, 0, window.size.x, window.size.y)
  glClearColor(0.13, 0.14, 0.17, 1.0)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  glEnable(GL_DEPTH_TEST)
  glEnable(GL_MULTISAMPLE)
  glDisable(GL_CULL_FACE)

  glUseProgram(shader)
  var
    modelMat = mat4()
    normalMat = mat3()
    viewMat = view
    projMat = proj
  glUniformMatrix4fv(uModel, 1, GL_FALSE, cast[ptr float32](modelMat.addr))
  glUniformMatrix3fv(
    uNormalMatrix, 1, GL_FALSE, cast[ptr float32](normalMat.addr))
  glUniformMatrix4fv(uView, 1, GL_FALSE, cast[ptr float32](viewMat.addr))
  glUniformMatrix4fv(uProj, 1, GL_FALSE, cast[ptr float32](projMat.addr))
  glUniform3f(uLightDirection, lightDirection.x, lightDirection.y, lightDirection.z)
  glUniform3f(uCameraPosition, eye.x, eye.y, eye.z)

  for primitive in part.mesh.primitives:
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
  glBindVertexArray(0)

  var shot = newImage(window.size.x, window.size.y)
  glReadPixels(
    0, 0, window.size.x, window.size.y,
    GL_RGBA, GL_UNSIGNED_BYTE, shot.data[0].addr
  )
  shot.flipVertical()
  if shot.width != Cell:
    shot = shot.resize(Cell, Cell)

  let
    slot = partIndex mod (Columns * Rows)
    cellX = (slot mod Columns) * Cell
    cellY = (slot div Columns) * (Cell + LabelHeight)
  sheet.draw(shot, translate(vec2(cellX.float32, cellY.float32)))
  sheet.fillText(
    font.typeset(&"{partIndex}  {part.name}", vec2(Cell.float32, LabelHeight.float32)),
    translate(vec2(cellX.float32 + 4, cellY.float32 + Cell.float32 + 3))
  )

  inc partIndex
  if partIndex mod (Columns * Rows) == 0:
    finishSheet()

  window.swapBuffers()

while not window.closeRequested:
  pollEvents()
