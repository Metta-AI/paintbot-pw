## Shared pieces for converting Unity character packs into polyworld glb
## assets: name normalization, bind-pose measurement that agrees with the
## gltf runtime, texture resizing, and the structural checks every converted
## model has to pass.
##
## Used by tools/build_mini_legions.nim and tools/build_rpg_monsters.nim; the
## per-pack layout, clip vocabulary and manifest shape live in those.

import
  std/[algorithm, json, math, os, sequtils, strutils, times],
  pixie, pixie/fileformats/png, vmath,
  fbx_to_glb

## Names

proc squash*(name: string): string =
  ## Lowercases a name and drops every separator and punctuation mark.
  for c in name.toLowerAscii:
    if c in {'a' .. 'z', '0' .. '9'}:
      result.add(c)

proc snakeKey*(display: string): string =
  ## Turns a pack display name into a file-name key.
  ##
  ## Death Knight -> death_knight, SiegeEngine -> siege_engine.
  var spaced = ""
  for i, c in display:
    if i > 0 and c in {'A' .. 'Z'} and display[i - 1] in {'a' .. 'z', '0' .. '9'}:
      spaced.add(' ')
    spaced.add(c)
  spaced.toLowerAscii.splitWhitespace.join("_")

## Geometry

proc nodeMatrix*(node: JsonNode): DMat4 =
  ## Builds a node's local matrix from either its matrix or its TRS.
  if "matrix" in node:
    let values = node["matrix"]
    for column in 0 .. 3:
      for row in 0 .. 3:
        result[column, row] = values[column * 4 + row].getFloat
    return
  var
    translation = dvec3(0, 0, 0)
    rotation = dvec4(0, 0, 0, 1)
    scaling = dvec3(1, 1, 1)
  if "translation" in node:
    let t = node["translation"]
    translation = dvec3(t[0].getFloat, t[1].getFloat, t[2].getFloat)
  if "rotation" in node:
    let r = node["rotation"]
    rotation = dvec4(r[0].getFloat, r[1].getFloat, r[2].getFloat, r[3].getFloat)
  if "scale" in node:
    let s = node["scale"]
    scaling = dvec3(s[0].getFloat, s[1].getFloat, s[2].getFloat)
  translate(translation) * mat4(rotation) * scale(scaling)

proc bindPoseBounds*(glb: Glb): tuple[low, high: DVec3] =
  ## Returns the bind-pose AABB the gltf runtime will compute.
  ##
  ## Mirrors gltf's getAABounds: mesh POSITION extents transformed by the
  ## accumulated node chain, ignoring skinning. Every corner of each accessor
  ## box is transformed, because an ancestor rotation makes the min/max pair
  ## alone meaningless.
  let doc = glb.doc
  var
    low = dvec3(Inf, Inf, Inf)
    high = dvec3(-Inf, -Inf, -Inf)

  proc visit(index: int, parent: DMat4) =
    let node = doc["nodes"][index]
    let world = parent * nodeMatrix(node)
    if "mesh" in node:
      for primitive in doc["meshes"][node["mesh"].getInt]["primitives"]:
        let accessor = doc["accessors"][primitive["attributes"]["POSITION"].getInt]
        if "min" notin accessor or "max" notin accessor:
          continue
        let box = [accessor["min"], accessor["max"]]
        for corner in 0 .. 7:
          var point: DVec3
          for axis in 0 .. 2:
            point[axis] = box[(corner shr axis) and 1][axis].getFloat
          let moved = world * point
          for axis in 0 .. 2:
            low[axis] = min(low[axis], moved[axis])
            high[axis] = max(high[axis], moved[axis])
    for child in nodeChildren(node):
      visit(child, world)

  let scene = doc["scenes"][doc{"scene"}.getInt(0)]
  for index in scene["nodes"]:
    visit(index.getInt, dmat4())
  if low.x == Inf:
    raise newException(ConversionError, "model has no positioned geometry")
  (low, high)

proc clipDuration*(glb: Glb, animation: JsonNode): float =
  ## Returns a clip's length from its longest sampler input.
  for sampler in animation["samplers"]:
    let accessor = glb.doc["accessors"][sampler["input"].getInt]
    if "max" in accessor:
      result = max(result, accessor["max"][0].getFloat)
    else:
      for time in unpackFloats(glb.accessorBytes(sampler["input"].getInt)):
        result = max(result, time.float)

## Textures

proc lanczos3(x: float): float =
  ## The Lanczos kernel with a support of three, as PIL's LANCZOS uses.
  if x == 0:
    return 1
  if x <= -3 or x >= 3:
    return 0
  let px = PI * x
  3 * sin(px) * sin(px / 3) / (px * px)

proc lanczosWeights(inSize, outSize: int): seq[tuple[start: int, weights: seq[float]]] =
  ## Per output pixel, the first source index and normalized kernel weights,
  ## with the support widened by the shrink factor when downscaling.
  let scale = inSize / outSize
  let filterScale = max(scale, 1.0)
  let support = 3.0 * filterScale
  for i in 0 ..< outSize:
    let center = (i.float + 0.5) * scale
    let lo = max(0, int(center - support + 0.5))
    let hi = min(inSize, int(center + support + 0.5))
    var weights: seq[float]
    var total = 0.0
    for x in lo ..< hi:
      let w = lanczos3((x.float - center + 0.5) / filterScale)
      weights.add(w)
      total += w
    if total != 0:
      for w in weights.mitems:
        w /= total
    result.add((lo, weights))

proc resampleLanczos(image: Image, width, height: int): Image =
  ## Separable Lanczos-3 resample of an opaque image, the way PIL's LANCZOS
  ## does it: a horizontal pass rounded to bytes, then a vertical one.
  template clampByte(v: float): uint8 =
    uint8(clamp(round(v), 0.0, 255.0))
  let horizontal = newImage(width, image.height)
  for x, (start, weights) in lanczosWeights(image.width, width):
    for y in 0 ..< image.height:
      var r, g, b = 0.0
      for k, w in weights:
        let pixel = image.unsafe[start + k, y]
        r += pixel.r.float * w
        g += pixel.g.float * w
        b += pixel.b.float * w
      horizontal.unsafe[x, y] = rgbx(clampByte(r), clampByte(g), clampByte(b), 255)
  result = newImage(width, height)
  for y, (start, weights) in lanczosWeights(image.height, height):
    for x in 0 ..< width:
      var r, g, b = 0.0
      for k, w in weights:
        let pixel = horizontal.unsafe[x, start + k]
        r += pixel.r.float * w
        g += pixel.g.float * w
        b += pixel.b.float * w
      result.unsafe[x, y] = rgbx(clampByte(r), clampByte(g), clampByte(b), 255)

proc writeTexture*(
    sourcePath, targetPath: string, size: int, mode = "rgb", force = false
): bool =
  ## Re-encodes a pack texture at the requested size.
  ##
  ## These packs ship textures at essentially no compression, so this is the
  ## step that turns tens of megabytes into hundreds of kilobytes. Colour
  ## textures drop to RGB and resample with Lanczos; masks keep only the red
  ## channel as 8-bit grey, sampled nearest so team regions never bleed into
  ## each other.
  if not force and fileExists(targetPath) and
      getLastModificationTime(targetPath) >= getLastModificationTime(sourcePath):
    return false
  createDir(targetPath.parentDir)
  var image = readImage(sourcePath)
  var pixels: string
  var channels: int
  if mode == "mask":
    channels = 1
    pixels = newString(size * size)
    for y in 0 ..< size:
      let sy = int((y.float + 0.5) * image.height.float / size.float)
      for x in 0 ..< size:
        let sx = int((x.float + 0.5) * image.width.float / size.float)
        pixels[y * size + x] = char(image.unsafe[sx, sy].r)
  else:
    channels = 3
    # Alpha is dropped, so make every pixel opaque first: premultiplied and
    # straight colour then agree and the resample never darkens edges.
    for pixel in image.data.mitems:
      pixel.a = 255
    if image.width != size or image.height != size:
      image = resampleLanczos(image, size, size)
    pixels = newString(size * size * 3)
    for i, pixel in image.data:
      pixels[i * 3 + 0] = char(pixel.r)
      pixels[i * 3 + 1] = char(pixel.g)
      pixels[i * 3 + 2] = char(pixel.b)
  writeFile(
    targetPath, encodePng(size, size, channels, pixels[0].addr, pixels.len))
  true

## Structural checks

proc checkGlbFile*(
    path: string, failures: var seq[string], label = ""
): Glb =
  ## Generic checks that hold for every model these tools emit.
  ##
  ## Appends human-readable problems to failures and returns the parsed Glb,
  ## or nil when the file is missing.
  let label = if label.len > 0: label else: path.extractFilename

  template check(condition: bool, message: string) =
    if not condition:
      failures.add(label & ": " & message)

  if not fileExists(path):
    failures.add(label & ": missing " & path)
    return nil

  let raw = readFile(path)
  let total = int(uint32(raw[8].ord) or (uint32(raw[9].ord) shl 8) or
    (uint32(raw[10].ord) shl 16) or (uint32(raw[11].ord) shl 24))
  check(total == raw.len,
    "header length " & $total & " != file size " & $raw.len)
  let glb = readGlb(path)
  let doc = glb.doc
  check(doc["buffers"][0]["byteLength"].getInt == glb.binary.len,
    "buffer length disagrees with the binary chunk")

  let images = doc{"images"}.getElems
  check(images.len == 1, "expected 1 image, found " & $images.len)
  check(doc{"textures"}.getElems.len == 1, "expected 1 texture")
  check(doc{"samplers"}.getElems.len == 1, "expected 1 sampler")
  let image = if images.len > 0: images[0] else: newJObject()
  check("uri" in image and "bufferView" notin image,
    "image is not an external uri")
  if "uri" in image:
    check(fileExists(path.parentDir / image["uri"].getStr),
      "sidecar " & image["uri"].getStr & " not next to the glb")
  for material in doc{"materials"}.getElems:
    let slot = material{"pbrMetallicRoughness"}{"baseColorTexture"}
    check(slot != nil and slot{"index"}.getInt(-1) == 0,
      "material base color is not texture 0")

  for i, accessor in doc{"accessors"}.getElems:
    if "bufferView" notin accessor:
      continue
    let view = doc["bufferViews"][accessor["bufferView"].getInt]
    let element = elementSize(accessor)
    var stride = view{"byteStride"}.getInt
    if stride == 0:
      stride = element
    let span = accessor{"byteOffset"}.getInt +
      stride * (accessor["count"].getInt - 1) + element
    check(span <= view["byteLength"].getInt,
      "accessor " & $i & " overruns its buffer view")
  glb

proc checkAnimations*(
    glb: Glb, clips: seq[string], failures: var seq[string], label: string
) =
  ## Checks a skinned model's clips against what the manifest recorded.
  let doc = glb.doc

  template check(condition: bool, message: string) =
    if not condition:
      failures.add(label & ": " & message)

  let animations = doc{"animations"}.getElems
  var names: seq[string]
  for animation in animations:
    names.add(animation["name"].getStr)
  check(names.deduplicate.len == names.len, "duplicate animation names")
  check(names.sorted == clips.sorted,
    "animation names disagree with the manifest")
  for animation in animations:
    let animName = animation["name"].getStr
    for channel in animation["channels"]:
      let target = channel["target"]["node"].getInt
      check(target >= 0 and target < doc["nodes"].len,
        animName & ": channel target out of range")
      let sampler = channel["sampler"].getInt
      check(sampler >= 0 and sampler < animation["samplers"].len,
        animName & ": sampler out of range")
