## Converts a Unity-style FBX character (one mesh FBX plus a folder of
## animation FBX files sharing its rig) into a single .glb with one glTF
## animation per clip, named after the file (Footman_Idle.fbx -> Idle).
##
## Conversion uses Facebook's FBX2glTF (auto-installed via npm into
## ~/.cache/polyworld on first run), which handles Unity FBX unit/axis
## conventions correctly; Blender's FBX importer mangles these rigs.
## The per-clip outputs are then merged by node name on the raw glTF JSON
## document and binary chunk, so everything FBX2glTF emitted (accessor
## min/max, extras, node order) survives untouched.
##
## This module is both a standalone CLI and the engine behind the pack
## builders (tools/build_mini_legions.nim and friends), which supply their
## own clip names.
##
## Run from the repo root:
##   nim r tools/fbx_to_glb.nim <mesh.fbx> <animations_dir> <output.glb> \
##       [texture.png] [--clip-prefix=Footman]

import
  std/[algorithm, json, os, osproc, sequtils, sets, streams, strutils, tables,
       tempfiles]

type
  ConversionError* = object of CatchableError
    ## Raised when a conversion would silently lose data.

  Glb* = ref object
    ## A .glb held as its JSON document plus its binary chunk.
    doc*: JsonNode
    binary*: string

let CacheDir* = expandTilde("~/.cache/polyworld")

## Byte helpers

proc readU32(data: string, offset: int): uint32 =
  ## Reads a little-endian uint32.
  uint32(data[offset].ord) or
    (uint32(data[offset + 1].ord) shl 8) or
    (uint32(data[offset + 2].ord) shl 16) or
    (uint32(data[offset + 3].ord) shl 24)

proc addU32(data: var string, value: uint32) =
  ## Appends a little-endian uint32.
  data.add(char(value and 0xFF))
  data.add(char((value shr 8) and 0xFF))
  data.add(char((value shr 16) and 0xFF))
  data.add(char((value shr 24) and 0xFF))

proc packFloats*(values: openArray[float32]): string =
  ## Packs float32 values little-endian, like struct.pack("<Nf").
  result = newString(values.len * 4)
  for i, value in values:
    let bits = cast[uint32](value)
    result[i * 4 + 0] = char(bits and 0xFF)
    result[i * 4 + 1] = char((bits shr 8) and 0xFF)
    result[i * 4 + 2] = char((bits shr 16) and 0xFF)
    result[i * 4 + 3] = char((bits shr 24) and 0xFF)

proc unpackFloats*(data: string): seq[float32] =
  ## Unpacks little-endian float32 values.
  result = newSeq[float32](data.len div 4)
  for i in 0 ..< result.len:
    result[i] = cast[float32](data.readU32(i * 4))

## FBX2glTF

proc fbx2gltfBinary*(): string =
  ## Path of the FBX2glTF binary, installing it on first use.
  const system =
    when defined(macosx): "Darwin"
    elif defined(linux): "Linux"
    else: "Windows_NT"
  result = CacheDir / "node_modules" / "fbx2gltf" / "bin" / system / "FBX2glTF"
  if not fileExists(result):
    echo "installing fbx2gltf into ", CacheDir
    createDir(CacheDir)
    let code = execCmd(
      "npm install --prefix " & quoteShell(CacheDir) &
      " fbx2gltf --no-fund --no-audit")
    if code != 0:
      raise newException(ConversionError, "npm install fbx2gltf failed")
    setFilePermissions(result, {
      fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc convertCommand(binary, fbxPath, outBase: string): string =
  quoteShell(binary) & " --binary --input " & quoteShell(fbxPath) &
    " --output " & quoteShell(outBase)

proc convert*(binary, fbxPath, outBase: string): string =
  ## Converts one FBX; returns the .glb path.
  let (output, code) = execCmdEx(convertCommand(binary, fbxPath, outBase))
  if code != 0:
    raise newException(
      ConversionError, "FBX2glTF failed on " & fbxPath & ":\n" & output)
  outBase & ".glb"

proc convertAll*(
    binary: string, jobs: seq[(string, string)], parallel: int
): seq[string] =
  ## Converts many (fbx, outBase) pairs at once; returns the .glb paths in
  ## the same order. FBX2glTF is where the time goes, so this is the fan-out.
  var commands: seq[string]
  for (fbxPath, outBase) in jobs:
    commands.add(convertCommand(binary, fbxPath, outBase))
    result.add(outBase & ".glb")
  var failures: seq[string]
  proc afterRun(idx: int, p: Process) =
    let output = p.outputStream.readAll()
    if p.peekExitCode() != 0:
      failures.add("FBX2glTF failed on " & jobs[idx][0] & ":\n" & output)
  discard execProcesses(
    commands, {poStdErrToStdOut}, max(1, parallel), afterRunEvent = afterRun)
  if failures.len > 0:
    raise newException(ConversionError, failures.join("\n"))

## Glb document

proc readGlb*(path: string): Glb =
  ## Splits a .glb into its JSON document and binary chunk.
  let data = readFile(path)
  let jsonLength = data.readU32(12).int
  result = Glb(doc: parseJson(data[20 ..< 20 + jsonLength]))
  let offset = 20 + jsonLength
  let chunkLength = data.readU32(offset).int
  result.binary = data[offset + 8 ..< offset + 8 + chunkLength]

proc write*(glb: Glb, path: string) =
  ## Writes the document and binary chunk back out as a .glb.
  var jsonBytes = $glb.doc
  while jsonBytes.len mod 4 != 0:
    jsonBytes.add(' ')
  while glb.binary.len mod 4 != 0:
    glb.binary.add('\0')
  var data = "glTF"
  data.addU32(2)
  data.addU32(uint32(28 + jsonBytes.len + glb.binary.len))
  data.addU32(jsonBytes.len.uint32)
  data.add("JSON")
  data.add(jsonBytes)
  data.addU32(glb.binary.len.uint32)
  data.add("BIN\0")
  data.add(glb.binary)
  writeFile(path, data)

proc componentSize*(componentType: int): int =
  case componentType
  of 5120, 5121: 1
  of 5122, 5123: 2
  of 5125, 5126: 4
  else:
    raise newException(
      ConversionError, "unknown componentType " & $componentType)

proc typeCount*(kind: string): int =
  case kind
  of "SCALAR": 1
  of "VEC2": 2
  of "VEC3": 3
  of "VEC4": 4
  of "MAT4": 16
  else:
    raise newException(ConversionError, "unknown accessor type " & kind)

proc elementSize*(accessor: JsonNode): int =
  ## Bytes per element of an accessor.
  componentSize(accessor["componentType"].getInt) *
    typeCount(accessor["type"].getStr)

proc addBufferView*(glb: Glb, payload: string): int =
  ## Appends payload to the binary chunk; returns the new view's index.
  while glb.binary.len mod 4 != 0:
    glb.binary.add('\0')
  let view = %*{
    "buffer": 0,
    "byteOffset": glb.binary.len,
    "byteLength": payload.len,
  }
  glb.binary.add(payload)
  if "bufferViews" notin glb.doc:
    glb.doc["bufferViews"] = newJArray()
  glb.doc["bufferViews"].add(view)
  glb.doc["buffers"][0]["byteLength"] = %glb.binary.len
  glb.doc["bufferViews"].len - 1

proc accessorBytes*(glb: Glb, index: int): string =
  ## The tightly packed bytes of one accessor.
  let accessor = glb.doc["accessors"][index]
  let view = glb.doc["bufferViews"][accessor["bufferView"].getInt]
  let element = elementSize(accessor)
  let start = view{"byteOffset"}.getInt + accessor{"byteOffset"}.getInt
  let count = accessor["count"].getInt
  var stride = view{"byteStride"}.getInt
  if stride == 0:
    stride = element
  if stride == element:
    return glb.binary[start ..< start + element * count]
  for i in 0 ..< count:
    result.add(glb.binary[start + i * stride ..< start + i * stride + element])

proc addAccessor*(
    glb: Glb, payload: string, componentType: int, kind: string, count: int,
    minimum: seq[float] = @[], maximum: seq[float] = @[]
): int =
  ## Adds an accessor over a fresh buffer view; returns its index.
  let accessor = %*{
    "bufferView": glb.addBufferView(payload),
    "componentType": componentType,
    "count": count,
    "type": kind,
  }
  if minimum.len > 0:
    accessor["min"] = %minimum
  if maximum.len > 0:
    accessor["max"] = %maximum
  if "accessors" notin glb.doc:
    glb.doc["accessors"] = newJArray()
  glb.doc["accessors"].add(accessor)
  glb.doc["accessors"].len - 1

proc copyAccessor*(glb: Glb, source: Glb, index: int): int =
  ## Copies one of source's accessors (and its bytes) into glb.
  let payload = source.accessorBytes(index)
  let accessor = source.doc["accessors"][index].copy()
  accessor["bufferView"] = %glb.addBufferView(payload)
  if "byteOffset" in accessor:
    accessor.delete("byteOffset")
  if "accessors" notin glb.doc:
    glb.doc["accessors"] = newJArray()
  glb.doc["accessors"].add(accessor)
  glb.doc["accessors"].len - 1

proc nodeNames*(glb: Glb): seq[string] =
  for node in glb.doc["nodes"]:
    result.add(node{"name"}.getStr(""))

proc nodeChildren*(node: JsonNode): seq[int] =
  ## A node's child indices, empty when it has none.
  for child in node{"children"}.getElems:
    result.add(child.getInt)

proc attachmentNodes*(base: Glb): HashSet[int] =
  ## Indices of unskinned mesh nodes parented into the skeleton.
  ##
  ## These are held props — a weapon in a hand bone, a shield on an arm. They
  ## have no skin of their own and ride their parent bone.
  var parented: HashSet[int]
  for node in base.doc["nodes"]:
    for child in nodeChildren(node):
      parented.incl(child)
  for i, node in base.doc["nodes"].getElems:
    if "mesh" in node and "skin" notin node and i in parented:
      result.incl(i)

proc graftAnimation*(
    base, source: Glb, clipName: string, frozen: HashSet[int] = initHashSet[int]()
): seq[string] =
  ## Copies one clip's channels into base, matching nodes by name.
  ##
  ## Returns the list of source node names that had channels but no
  ## counterpart in base. A non-empty result means the rigs disagree and the
  ## grafted clip would pose only part of the skeleton, which on screen looks
  ## like the model stuck in its bind pose.
  let animations = source.doc{"animations"}.getElems
  if animations.len != 1:
    raise newException(
      ConversionError,
      clipName & ": expected exactly one animation, found " & $animations.len)
  var baseIndex: Table[string, int]
  for i, name in base.nodeNames:
    baseIndex[name] = i
  let sourceNames = source.nodeNames

  proc drivesTheRig(index: int): bool =
    ## True when this source node has a counterpart in base beneath it.
    ##
    ## Animation files sometimes carry rig-control nodes the mesh does not
    ## have. When such a node is a dead-end branch it animates nothing and
    ## is safe to drop; when the deform skeleton hangs beneath it, dropping
    ## its channels would silently lose motion.
    var pending = @[index]
    while pending.len > 0:
      let node = source.doc["nodes"][pending.pop()]
      if node{"name"}.getStr("") in baseIndex:
        return true
      pending.add(nodeChildren(node))
    false

  let animation = animations[0]
  var samplers = newJArray()
  var channels = newJArray()
  for channel in animation["channels"]:
    let target = channel["target"]["node"].getInt
    let targetName = sourceNames[target]
    if targetName notin baseIndex:
      if drivesTheRig(target):
        result.add(targetName)
      continue
    if baseIndex[targetName] in frozen:
      continue
    let sampler = animation["samplers"][channel["sampler"].getInt]
    samplers.add(%*{
      "input": base.copyAccessor(source, sampler["input"].getInt),
      "output": base.copyAccessor(source, sampler["output"].getInt),
      "interpolation": sampler{"interpolation"}.getStr("LINEAR"),
    })
    channels.add(%*{
      "sampler": samplers.len - 1,
      "target": {
        "node": baseIndex[targetName],
        "path": channel["target"]["path"],
      },
    })
  if channels.len == 0:
    raise newException(
      ConversionError, clipName & ": no channels matched the rig")
  if "animations" notin base.doc:
    base.doc["animations"] = newJArray()
  base.doc["animations"].add(%*{
    "name": clipName, "samplers": samplers, "channels": channels})

const
  # Every material slot that can reference a texture, as (holder, key) where
  # holder is either the material itself or its pbrMetallicRoughness block.
  TextureSlots = [
    ("pbr", "baseColorTexture"),
    ("pbr", "metallicRoughnessTexture"),
    ("material", "normalTexture"),
    ("material", "occlusionTexture"),
    ("material", "emissiveTexture"),
  ]

proc textureSlots*(material: JsonNode): seq[JsonNode] =
  ## Every texture-reference object present on a material.
  let pbr = material{"pbrMetallicRoughness"}
  for (holderName, key) in TextureSlots:
    let holder = if holderName == "pbr": pbr else: material
    if holder == nil:
      continue
    let slot = holder{key}
    if slot != nil and slot.kind == JObject and "index" in slot:
      result.add(slot)

proc pointMaterialsAt*(base: Glb, textureIndex: int) =
  ## Points every material's base color at one texture, untinted.
  for material in base.doc{"materials"}.getElems:
    if "pbrMetallicRoughness" notin material:
      material["pbrMetallicRoughness"] = newJObject()
    material["pbrMetallicRoughness"]["baseColorTexture"] = %*{
      "index": textureIndex}
    material["pbrMetallicRoughness"]["baseColorFactor"] = %*[1, 1, 1, 1]

const StaticPoseSeconds* = 1.0

type TrsPath = tuple[path, kind: string, size: int, default: seq[float]]

const TrsPaths: array[3, TrsPath] = [
  ("translation", "VEC3", 3, @[0.0, 0.0, 0.0]),
  ("rotation", "VEC4", 4, @[0.0, 0.0, 0.0, 1.0]),
  ("scale", "VEC3", 3, @[1.0, 1.0, 1.0]),
]

proc graftStaticPose*(base, source: Glb, clipName: string): int =
  ## Builds a held-still clip from a source whose channels never move.
  ##
  ## Some clips are a pose rather than a motion — the chest monster sitting
  ## disguised as a closed chest, for instance. FBX2glTF drops those with
  ## "animation has zero channels", which would lose the pose entirely, so
  ## the source's node transforms are baked into a two-key constant clip.
  ## Returns the channel count.
  var baseIndex: Table[string, int]
  for i, name in base.nodeNames:
    baseIndex[name] = i
  let inputAccessor = base.addAccessor(
    packFloats([0.0'f32, StaticPoseSeconds.float32]), 5126, "SCALAR", 2,
    @[0.0], @[StaticPoseSeconds])

  var samplers = newJArray()
  var channels = newJArray()
  for node in source.doc["nodes"]:
    let name = node{"name"}.getStr("")
    if name notin baseIndex:
      continue
    let index = baseIndex[name]
    for (path, kind, size, default) in TrsPaths:
      if path notin node:
        continue
      var values: seq[float32]
      var isDefault = true
      for i, value in node[path].getElems:
        values.add(value.getFloat.float32)
        if value.getFloat != default[i]:
          isDefault = false
      if isDefault:
        continue
      samplers.add(%*{
        "input": inputAccessor,
        "output": base.addAccessor(
          packFloats(values & values), 5126, kind, 2),
        "interpolation": "LINEAR",
      })
      channels.add(%*{
        "sampler": samplers.len - 1,
        "target": {"node": index, "path": path},
      })
  if channels.len == 0:
    raise newException(
      ConversionError, clipName & ": static pose matches the bind pose exactly")
  if "animations" notin base.doc:
    base.doc["animations"] = newJArray()
  base.doc["animations"].add(%*{
    "name": clipName, "samplers": samplers, "channels": channels})
  channels.len

proc addTexture(base: Glb, image: JsonNode) =
  ## Appends an image, a sampler and a texture, then binds every material.
  for key in ["images", "samplers", "textures"]:
    if key notin base.doc:
      base.doc[key] = newJArray()
  base.doc["images"].add(image)
  base.doc["samplers"].add(%*{
    "magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497})
  base.doc["textures"].add(%*{
    "source": base.doc["images"].len - 1,
    "sampler": base.doc["samplers"].len - 1,
  })
  base.pointMaterialsAt(base.doc["textures"].len - 1)

proc injectTexture*(base: Glb, texturePath: string) =
  ## Embeds a PNG in the binary chunk and binds it as the base color.
  let png = readFile(texturePath)
  let view = base.addBufferView(png)
  base.addTexture(%*{
    "bufferView": view,
    "mimeType": "image/png",
    "name": texturePath.splitFile.name,
  })

proc attachExternalTexture*(base: Glb, uri, imageName: string) =
  ## Binds a sidecar PNG as the base color, referenced by relative uri.
  ##
  ## The uri must be a bare file name with no directory part: the gltf reader
  ## resolves it as joinPath(dirname(glb), uri), so anything else escapes the
  ## faction directory.
  if uri.splitPath.head.len > 0:
    raise newException(
      ConversionError, "external texture uri must be bare: " & uri)
  base.addTexture(%*{"uri": uri, "name": imageName})

proc pruneUnusedTextures*(base: Glb): tuple[images, textures, samplers: int] =
  ## Drops images, textures and samplers nothing references.
  ##
  ## FBX2glTF emits a 1x1 white placeholder image plus its texture and an
  ## empty sampler for every material, all orphaned once a real atlas is
  ## bound. Returns the count of each kind removed.
  let textures = base.doc{"textures"}.getElems
  let images = base.doc{"images"}.getElems
  let samplers = base.doc{"samplers"}.getElems
  if textures.len == 0:
    return (0, 0, 0)

  var liveTextures: seq[int]
  for material in base.doc{"materials"}.getElems:
    for slot in textureSlots(material):
      let index = slot["index"].getInt
      if index notin liveTextures:
        liveTextures.add(index)
  liveTextures.sort()
  var textureMap: Table[int, int]
  var keptTextures: seq[JsonNode]
  for new, old in liveTextures:
    textureMap[old] = new
    keptTextures.add(textures[old])

  var liveImages, liveSamplers: seq[int]
  for texture in keptTextures:
    if "source" in texture and texture["source"].getInt notin liveImages:
      liveImages.add(texture["source"].getInt)
    if "sampler" in texture and texture["sampler"].getInt notin liveSamplers:
      liveSamplers.add(texture["sampler"].getInt)
  liveImages.sort()
  liveSamplers.sort()
  var imageMap, samplerMap: Table[int, int]
  for new, old in liveImages:
    imageMap[old] = new
  for new, old in liveSamplers:
    samplerMap[old] = new

  for texture in keptTextures:
    if "source" in texture:
      texture["source"] = %imageMap[texture["source"].getInt]
    if "sampler" in texture:
      texture["sampler"] = %samplerMap[texture["sampler"].getInt]
  for material in base.doc{"materials"}.getElems:
    for slot in textureSlots(material):
      slot["index"] = %textureMap[slot["index"].getInt]

  result = (
    images.len - liveImages.len,
    textures.len - keptTextures.len,
    samplers.len - liveSamplers.len,
  )
  var keptImages, keptSamplers: seq[JsonNode]
  for i in liveImages:
    keptImages.add(images[i])
  for i in liveSamplers:
    keptSamplers.add(samplers[i])
  for (key, values) in [
      ("images", keptImages), ("textures", keptTextures),
      ("samplers", keptSamplers)]:
    if values.len > 0:
      base.doc[key] = %values
    elif key in base.doc:
      base.doc.delete(key)

proc animationFiles*(directory: string): seq[string] =
  ## The .fbx file names of a directory, sorted.
  for kind, path in walkDir(directory):
    if kind == pcFile and path.toLowerAscii.endsWith(".fbx"):
      result.add(path.extractFilename)
  result.sort()

proc buildCharacter*(
    meshPath, animDir: string,
    clipNameFor: proc(fileName: string): string,
    binary: string,
    freezeAttachments = false,
    parallel = countProcessors()
): Glb =
  ## Converts a mesh FBX plus its animation folder into an in-memory Glb.
  ##
  ## clipNameFor maps an animation file name to its clip name. Grafting is
  ## strict: a channel targeting a node the mesh rig lacks is an error, not a
  ## silently missing limb.
  ##
  ## freezeAttachments drops the channels that drive held props, leaving them
  ## at the grip the mesh FBX defines and riding their parent bone. Some packs
  ## animate a prop's own node with values that only make sense against that
  ## clip's own scale inheritance, which glTF cannot express, and the prop
  ## ends up floating beside its owner.
  let tmp = createTempDir("polyworld_", "")
  try:
    var seen: Table[string, string]
    var clipNames: seq[string]
    var jobs = @[(meshPath, tmp / "mesh")]
    for fileName in animationFiles(animDir):
      let clipName = clipNameFor(fileName)
      if clipName in seen:
        raise newException(
          ConversionError,
          animDir & ": " & fileName & " and " & seen[clipName] &
          " both map to clip " & clipName)
      seen[clipName] = fileName
      clipNames.add(clipName)
      jobs.add((animDir / fileName, tmp / ("anim_" & clipName)))
    let outputs = convertAll(binary, jobs, parallel)
    result = readGlb(outputs[0])
    let frozen =
      if freezeAttachments: attachmentNodes(result) else: initHashSet[int]()
    for i, clipName in clipNames:
      let clip = readGlb(outputs[i + 1])
      if clip.doc{"animations"}.getElems.len == 0:
        discard graftStaticPose(result, clip, clipName)
        continue
      let dropped = graftAnimation(result, clip, clipName, frozen)
      if dropped.len > 0:
        var unique = deduplicate(dropped)
        unique.sort()
        raise newException(
          ConversionError,
          seen[clipName] & ": " & $dropped.len &
          " channels target nodes missing from the mesh rig: " &
          $unique[0 ..< min(5, unique.len)])
  finally:
    removeDir(tmp)

when isMainModule:
  var positional: seq[string]
  var prefix = ""
  for arg in commandLineParams():
    if arg.startsWith("--clip-prefix="):
      prefix = arg["--clip-prefix=".len .. ^1]
    elif arg.startsWith("--"):
      quit("unknown flag " & arg, 1)
    else:
      positional.add(arg)
  if positional.len < 3:
    quit(
      "usage: fbx_to_glb <mesh.fbx> <animations_dir> <output.glb> " &
      "[texture.png] [--clip-prefix=Unit]", 1)
  let (meshPath, animDir, outPath) = (positional[0], positional[1], positional[2])
  let texturePath = if positional.len > 3: positional[3] else: ""

  proc clipNameFor(fileName: string): string =
    let stem = fileName.splitFile.name
    if prefix.len > 0 and stem.toLowerAscii.startsWith(prefix.toLowerAscii & "_"):
      return stem[prefix.len + 1 .. ^1]
    stem

  let base = buildCharacter(meshPath, animDir, clipNameFor, fbx2gltfBinary())
  if texturePath.len > 0:
    base.injectTexture(texturePath)
  discard base.pruneUnusedTextures()
  base.write(outPath)
  var animations: seq[string]
  for animation in base.doc{"animations"}.getElems:
    animations.add(animation["name"].getStr)
  echo "wrote ", outPath, " with animations: ", animations.join(", ")
