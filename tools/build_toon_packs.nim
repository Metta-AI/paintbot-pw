## Converts the SICS Games "Toon" Unity environment packs into polyworld glb
## prop kits: one glb per category, every model an independent top-level
## scene node, sharing external atlas textures.
##
## These are the first environment packs through this pipeline, and they
## differ from the character packs in three ways that shape the whole tool:
## the models ship LOD chains and collision proxies that must be dropped, a
## category draws on several atlases at once, and the vertex colours are
## packed shader data rather than colour.
##
## Usage (from the repo root):
##   nim r tools/build_toon_packs.nim                    # full build
##   nim r tools/build_toon_packs.nim --pack=toon_golden_valley
##   nim r tools/build_toon_packs.nim --self-test        # resolve only
##   nim r tools/build_toon_packs.nim --verify           # check outputs

import
  std/[algorithm, json, math, os, sequtils, sets, strformat, strutils,
       tables, cpuinfo],
  pixie, vmath,
  fbx_to_glb, glb_pack

type
  Pack = object
    key: string        ## output directory name
    directory: string  ## path under the Unity Assets folder
    prefix: string     ## model-name prefix to strip, e.g. "TGV_"
    title: string
    productId: int
    productVersion: string

const
  Packs = [
    Pack(key: "toon_golden_valley", directory: "Toon Golden Valley",
         prefix: "TGV_", title: "Toon Golden Valley",
         productId: 323151, productVersion: "1.0"),
    Pack(key: "toon_enchanted_meadow",
         directory: "Toon Series/Toon Enchanted Meadow",
         prefix: "TEM_", title: "Toon Enchanted Meadow",
         productId: 309654, productVersion: "1.0.1"),
  ]

  DefaultSource = "~/Polyworld/Assets"
  DefaultOut = "../polyworld_data/terrain"
  LayoutGap = 1.0     ## clear space between models in the browsing grid
  FoliageSize = 2048  ## cutout atlases, where the alpha edge is the shape
  PropSize = 1024     ## opaque atlases

  # Distant scenery whose diffuse ships only as a multi-hundred-megabyte PSD,
  # and cards that mean nothing without Unity's particle systems.
  SkipMarkers = ["Particle_Quad", "Tree_Billboard", "Background_Cliff"]
  SkipPrefixes = ["TGV_BG_", "TEM_BG_"]

## Source discovery

proc guidMap(packDir: string): Table[string, string] =
  ## Maps every Unity guid in the pack to the file it belongs to.
  for path in walkDirRec(packDir):
    if not path.endsWith(".meta"):
      continue
    let text = readFile(path)
    let at = text.find("guid: ")
    if at >= 0 and at + 38 <= text.len:
      result[text[at + 6 ..< at + 38]] = path[0 ..< path.len - 5]

iterator guidsIn(text: string): string =
  ## Every guid mentioned in a Unity YAML file.
  var at = text.find("guid: ")
  while at >= 0:
    if at + 38 <= text.len:
      yield text[at + 6 ..< at + 38]
    at = text.find("guid: ", at + 6)

proc skipModel(path: string): bool =
  let name = path.extractFilename
  for marker in SkipMarkers:
    if marker in name:
      return true
  for prefix in SkipPrefixes:
    if name.startsWith(prefix):
      return true
  false

proc categoryModels(
    packDir: string, guids: Table[string, string]
): OrderedTable[string, seq[string]] =
  ## Groups model files by the pack's own Prefabs/<Category> folders.
  ##
  ## The prefabs are the only place the pack states what a model is for, so
  ## the categories come from there rather than from guessing at names.
  var claimed: HashSet[string]
  var byCategory = initOrderedTable[string, HashSet[string]]()
  for prefab in walkDirRec(packDir / "Prefabs"):
    if not prefab.endsWith(".prefab"):
      continue
    let relative = prefab[(packDir / "Prefabs").len + 1 .. ^1]
    let category = relative.split(DirSep)[0].toLowerAscii
    for guid in guidsIn(readFile(prefab)):
      let target = guids.getOrDefault(guid, "")
      if target.len > 0 and target.endsWith(".fbx") and not skipModel(target):
        if category notin byCategory:
          byCategory[category] = initHashSet[string]()
        byCategory[category].incl(target)
        claimed.incl(target)

  # Anything the prefabs never mention is still a prop.
  var orphans: HashSet[string]
  for path in walkDirRec(packDir / "Models"):
    if path.endsWith(".fbx") and not skipModel(path) and path notin claimed:
      orphans.incl(path)
  if orphans.len > 0:
    if "props" notin byCategory:
      byCategory["props"] = initHashSet[string]()
    byCategory["props"] = byCategory["props"] + orphans

  byCategory.del("background")
  for category in toSeq(byCategory.keys).sorted:
    result[category] = toSeq(byCategory[category].items).sorted

proc materialTextures(
    packDir: string, guids: Table[string, string]
): Table[string, string] =
  ## Maps each material name to the source file behind its albedo slot.
  ##
  ## The packs use a custom toon shader, so the albedo is not `_MainTex`: it
  ## is `_MainTexture` on the foliage and rock shaders and `_TextureSample`
  ## on the prop atlases.
  for path in walkDirRec(packDir / "Models" / "Materials"):
    if not path.endsWith(".mat"):
      continue
    var slots = initTable[string, string]()
    var slot = ""
    for line in readFile(path).splitLines:
      let trimmed = line.strip
      if trimmed.startsWith("- _") and trimmed.endsWith(":"):
        slot = trimmed[2 ..< trimmed.len - 1]
      elif trimmed.startsWith("m_Texture:") and slot.len > 0:
        for guid in guidsIn(trimmed):
          let target = guids.getOrDefault(guid, "")
          if target.len > 0:
            slots[slot] = target
        slot = ""
    for preferred in ["_MainTexture", "_TextureSample", "_MainTex"]:
      if preferred in slots:
        result[path.extractFilename[0 ..< ^4]] = slots[preferred]
        break

proc assetKey(name: string): string =
  ## Lowercases a pack asset name, keeping its own separators.
  ##
  ## Not glb_pack's snakeKey: these names are already underscore separated
  ## and end in a variant tag like "01A", which a camelCase split would
  ## mangle into "01_a".
  var previousUnderscore = true
  for c in name:
    if c in {'A' .. 'Z'}:
      result.add(char(c.ord + 32))
      previousUnderscore = false
    elif c in {'a' .. 'z', '0' .. '9'}:
      result.add(c)
      previousUnderscore = false
    elif not previousUnderscore:
      result.add('_')
      previousUnderscore = true
  while result.len > 0 and result[^1] == '_':
    result.setLen(result.len - 1)

proc atlasName(pack: Pack, sourcePath: string): string =
  ## The output PNG name for a source texture, derived from its own name.
  var stem = sourcePath.extractFilename.changeFileExt("")
  if stem.startsWith(pack.prefix):
    stem = stem[pack.prefix.len .. ^1]
  assetKey(stem) & ".png"

proc atlasSize(sourcePath: string): int =
  if "Trees" in sourcePath or "Vegetation" in sourcePath: FoliageSize
  else: PropSize

## Merging

proc keepMesh(name: string): bool =
  ## Drops collision proxies and every LOD below the highest.
  if "Collider" in name:
    return false
  if "_LOD" in name:
    return "_LOD0" in name
  true

type Part = object
  primitive: JsonNode
  world: DMat4
  material: string

proc collectParts(source: Glb): seq[Part] =
  ## Every drawable primitive of a converted model, with its world transform.
  let doc = source.doc
  var parts: seq[Part]

  proc visit(index: int, parent: DMat4) =
    let node = doc["nodes"][index]
    let world = parent * nodeMatrix(node)
    if "mesh" in node and keepMesh(node{"name"}.getStr("")):
      let mesh = doc["meshes"][node["mesh"].getInt]
      for primitive in mesh["primitives"]:
        var material = ""
        if "material" in primitive:
          material = doc["materials"][primitive["material"].getInt]{
            "name"}.getStr("")
        parts.add(Part(primitive: primitive, world: world, material: material))
    for child in nodeChildren(node):
      visit(child, world)

  let scene = doc["scenes"][doc{"scene"}.getInt(0)]
  for index in scene["nodes"]:
    visit(index.getInt, dmat4())
  parts

proc bakedPositions(
    source: Glb, accessorIndex: int, world: DMat4
): tuple[payload: string, count: int, low, high: seq[float]] =
  ## Transforms a POSITION accessor into world space.
  ##
  ## Baking rather than keeping the node transform is what lets each model
  ## become a single flat node: the pack's props carry their scale on the
  ## model node (the apples and tomatoes are authored at 1/100 scale), and a
  ## consumer that flattens the tree would otherwise lose it.
  let floats = unpackFloats(source.accessorBytes(accessorIndex))
  let count = floats.len div 3
  var moved = newSeq[float32](floats.len)
  var low = @[Inf, Inf, Inf]
  var high = @[-Inf, -Inf, -Inf]
  for i in 0 ..< count:
    let point = world * dvec3(
      floats[i * 3 + 0].float, floats[i * 3 + 1].float, floats[i * 3 + 2].float)
    for axis in 0 .. 2:
      moved[i * 3 + axis] = point[axis].float32
      low[axis] = min(low[axis], point[axis])
      high[axis] = max(high[axis], point[axis])
  (packFloats(moved), count, low, high)

proc bakedNormals(source: Glb, accessorIndex: int, world: DMat4): string =
  ## Rotates a NORMAL accessor, using the inverse transpose so non-uniform
  ## scale does not shear the normals off the surface.
  var basis = world
  basis[3, 0] = 0
  basis[3, 1] = 0
  basis[3, 2] = 0
  let normalBasis = basis.inverse.transpose
  let floats = unpackFloats(source.accessorBytes(accessorIndex))
  var moved = newSeq[float32](floats.len)
  for i in 0 ..< floats.len div 3:
    var n = normalBasis * dvec3(
      floats[i * 3 + 0].float, floats[i * 3 + 1].float, floats[i * 3 + 2].float)
    let length = sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
    if length > 0:
      n = n / length
    for axis in 0 .. 2:
      moved[i * 3 + axis] = n[axis].float32
  packFloats(moved)

proc newPackGlb(): Glb =
  ## An empty glb ready to take flattened models.
  Glb(
    doc: %*{
      "asset": {"version": "2.0", "generator": "polyworld toon pack converter"},
      "scene": 0,
      "scenes": [{"nodes": []}],
      "nodes": [],
      "meshes": [],
      "materials": [],
      "accessors": [],
      "bufferViews": [],
      "buffers": [{"byteLength": 0}],
      "images": [],
      "samplers": [],
      "textures": [],
    },
    binary: "")

proc addAtlas(base: Glb, uri: string, hasAlpha: bool): int =
  ## Adds one external atlas; returns its texture index.
  base.doc["images"].add(%*{"uri": uri, "name": uri.changeFileExt("")})
  base.doc["samplers"].add(%*{
    "magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497})
  base.doc["textures"].add(%*{
    "source": base.doc["images"].len - 1,
    "sampler": base.doc["samplers"].len - 1})
  base.doc["textures"].len - 1

proc addMaterial(
    base: Glb, name: string, texture: int, cutout: bool
): int =
  let material = %*{
    "name": name,
    "doubleSided": cutout,
    "pbrMetallicRoughness": {
      "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
      "metallicFactor": 0.0,
      "roughnessFactor": 1.0,
    },
  }
  if texture >= 0:
    material["pbrMetallicRoughness"]["baseColorTexture"] = %*{"index": texture}
  if cutout:
    # Foliage is alpha-cutout cards; blending them would sort wrongly against
    # itself, so mask instead.
    material["alphaMode"] = %"MASK"
    material["alphaCutoff"] = %0.5
  base.doc["materials"].add(material)
  base.doc["materials"].len - 1

type Piece = object
  source: Glb
  world: DMat4

proc appendAssembly(
    base: Glb, pieces: seq[Piece], nodeName: string,
    materialIndex: Table[string, int], recentre = true
): tuple[index: int, low, high: seq[float]] =
  ## Adds one or more converted models as a single flat top-level node.
  ##
  ## A kit prop is one piece with an identity transform. An assembled house
  ## is many, each carrying the world transform its Unity prefab placed it
  ## at, merged into one mesh so the building is a single addressable node.
  ##
  ## Re-centring on x and z matches what quadterrain's collectPropModels
  ## does at load time. Height is left as authored, so a fence post still
  ## sinks below the ground and a lamp still stands on it. Without it a
  ## stray like wood_fence_pole_01a, which its FBX places 166 units out in
  ## space, would drag the whole kit's bounds with it.
  var
    baked: seq[tuple[
      part: Part, source: Glb, payload: string, count: int,
      low, high: seq[float]]]
    low = @[Inf, Inf, Inf]
    high = @[-Inf, -Inf, -Inf]
  for piece in pieces:
    for part in collectParts(piece.source):
      let attributes = part.primitive["attributes"]
      if "POSITION" notin attributes:
        continue
      let world = piece.world * part.world
      var placedPart = part
      placedPart.world = world
      let one = bakedPositions(
        piece.source, attributes["POSITION"].getInt, world)
      for axis in 0 .. 2:
        low[axis] = min(low[axis], one.low[axis])
        high[axis] = max(high[axis], one.high[axis])
      baked.add((placedPart, piece.source, one.payload, one.count,
                 one.low, one.high))

  if baked.len == 0:
    raise newException(ConversionError, nodeName & ": no drawable geometry")
  let offset =
    if recentre: [-(low[0] + high[0]) * 0.5, 0.0, -(low[2] + high[2]) * 0.5]
    else: [0.0, 0.0, 0.0]

  var primitives = newJArray()
  for entry in baked:
    var floats = unpackFloats(entry.payload)
    for i in 0 ..< entry.count:
      for axis in 0 .. 2:
        floats[i * 3 + axis] = (floats[i * 3 + axis].float + offset[axis]).float32
    var shiftedLow, shiftedHigh: seq[float]
    for axis in 0 .. 2:
      shiftedLow.add(entry.low[axis] + offset[axis])
      shiftedHigh.add(entry.high[axis] + offset[axis])
    let attributes = entry.part.primitive["attributes"]
    var primitiveJson = %*{
      "attributes": {
        "POSITION": base.addAccessor(
          packFloats(floats), 5126, "VEC3", entry.count,
          shiftedLow, shiftedHigh),
      },
    }
    if "NORMAL" in attributes:
      let normals = bakedNormals(
        entry.source, attributes["NORMAL"].getInt, entry.part.world)
      primitiveJson["attributes"]["NORMAL"] =
        %base.addAccessor(normals, 5126, "VEC3", entry.count)
    if "TEXCOORD_0" in attributes:
      primitiveJson["attributes"]["TEXCOORD_0"] =
        %base.copyAccessor(entry.source, attributes["TEXCOORD_0"].getInt)
    # COLOR_0 holds packed shader data here — a wind weight in green and a
    # zero alpha — not colour. Multiplied into base colour it renders the
    # whole pack black, so it is dropped along with the lightmap UVs.
    if "indices" in entry.part.primitive:
      primitiveJson["indices"] = %base.copyAccessor(
        entry.source, entry.part.primitive["indices"].getInt)
    if "mode" in entry.part.primitive:
      primitiveJson["mode"] = entry.part.primitive["mode"]
    if entry.part.material in materialIndex:
      primitiveJson["material"] = %materialIndex[entry.part.material]
    primitives.add(primitiveJson)

  base.doc["meshes"].add(%*{"name": nodeName, "primitives": primitives})
  base.doc["nodes"].add(%*{
    "name": nodeName, "mesh": base.doc["meshes"].len - 1})
  let index = base.doc["nodes"].len - 1
  base.doc["scenes"][0]["nodes"].add(%index)
  var centred, centredHigh: seq[float]
  for axis in 0 .. 2:
    centred.add(low[axis] + offset[axis])
    centredHigh.add(high[axis] + offset[axis])
  (index, centred, centredHigh)

proc appendModel(
    base: Glb, source: Glb, nodeName: string, materialIndex: Table[string, int]
): tuple[index: int, low, high: seq[float]] =
  base.appendAssembly(
    @[Piece(source: source, world: dmat4())], nodeName, materialIndex)

## Unity prefabs

# The packs ship assembled buildings as Unity prefab compositions — a
# transform list referencing kit pieces — with no FBX of their own. Reading
# that composition is the only way to get the finished houses out.

type
  PrefabInstance = object
    anchor: string
    sourceGuid: string
    parent: string      ## fileID of the transform it hangs under
    translation: DVec3
    rotation: DVec4
    scaling: DVec3

proc braceField(line: string, field: string): string =
  ## The value of `field: <value>` inside a `{...}` map on one line.
  let at = line.find(field & ": ")
  if at < 0:
    return ""
  var i = at + field.len + 2
  var value = ""
  while i < line.len and line[i] notin {',', '}', ' '}:
    value.add(line[i])
    inc i
  value

proc prefabInstances(path: string): seq[PrefabInstance] =
  ## Every nested prefab placed in this prefab, with its local transform.
  var
    found: seq[PrefabInstance]
    current: PrefabInstance
    inBlock = false
    pendingPath = ""
  proc flush() =
    if inBlock and current.sourceGuid.len > 0:
      found.add(current)
  for line in readFile(path).splitLines:
    if line.startsWith("--- !u!"):
      flush()
      inBlock = line.startsWith("--- !u!1001 ")
      current = PrefabInstance(
        anchor: line.rsplit('&', 1)[^1].strip(),
        parent: "0",
        rotation: dvec4(0, 0, 0, 1),
        scaling: dvec3(1, 1, 1))
      pendingPath = ""
      continue
    if not inBlock:
      continue
    let trimmed = line.strip
    if trimmed.startsWith("propertyPath: "):
      pendingPath = trimmed["propertyPath: ".len .. ^1]
    elif trimmed.startsWith("value: ") and pendingPath.len > 0:
      let raw = trimmed["value: ".len .. ^1]
      var number = 0.0
      try:
        number = raw.parseFloat
      except ValueError:
        pendingPath = ""
        continue
      let axis = pendingPath[^1]
      let slot = case axis
        of 'x': 0
        of 'y': 1
        of 'z': 2
        of 'w': 3
        else: -1
      if slot >= 0:
        if pendingPath.startsWith("m_LocalPosition."):
          current.translation[slot] = number
        elif pendingPath.startsWith("m_LocalRotation."):
          current.rotation[slot] = number
        elif pendingPath.startsWith("m_LocalScale."):
          current.scaling[slot] = number
      pendingPath = ""
    elif trimmed.startsWith("m_TransformParent:"):
      current.parent = braceField(trimmed, "fileID")
    elif trimmed.startsWith("m_SourcePrefab:"):
      current.sourceGuid = braceField(trimmed, "guid")
  flush()
  found

proc transformOwners(path: string): Table[string, string] =
  ## Stripped Transform fileID -> the prefab instance it belongs to, which
  ## is how a placed piece names its parent.
  var
    anchor = ""
    isTransform = false
  for line in readFile(path).splitLines:
    if line.startsWith("--- !u!"):
      isTransform = line.startsWith("--- !u!4 ")
      anchor = line.rsplit('&', 1)[^1].strip()
      continue
    if isTransform and line.strip.startsWith("m_PrefabInstance:"):
      result[anchor] = braceField(line.strip, "fileID")

proc instanceMatrix(instance: PrefabInstance): DMat4 =
  translate(instance.translation) * mat4(instance.rotation) *
    scale(instance.scaling)

proc flattenPrefab(
    path: string, guids: Table[string, string], world = dmat4(), depth = 0
): seq[tuple[model: string, world: DMat4]] =
  ## Resolves a prefab into the models it places and where it places them.
  if depth > 6:
    return
  let
    instances = prefabInstances(path)
    owners = transformOwners(path)
  var byAnchor = initTable[string, PrefabInstance]()
  for instance in instances:
    byAnchor[instance.anchor] = instance

  proc chain(instance: PrefabInstance, seen: int): DMat4 =
    result = instanceMatrix(instance)
    if seen > 8:
      return
    let owner = owners.getOrDefault(instance.parent, "")
    if owner.len > 0 and owner != instance.anchor and owner in byAnchor:
      result = chain(byAnchor[owner], seen + 1) * result

  for instance in instances:
    let target = guids.getOrDefault(instance.sourceGuid, "")
    let placed = world * chain(instance, 0)
    if target.endsWith(".fbx"):
      result.add((target, placed))
    elif target.endsWith(".prefab"):
      result.add(flattenPrefab(target, guids, placed, depth + 1))

proc presetFiles(packDir: string): seq[string] =
  ## The pack's assembled buildings: a Presets folder when it has one, and
  ## anything else named like a preset.
  ##
  ## Furnished interiors are skipped — they are a room's worth of furniture
  ## rather than a building, and the shell is what the kit is for.
  for path in walkDirRec(packDir / "Prefabs"):
    if not path.endsWith(".prefab"):
      continue
    if "Interior" in path.extractFilename:
      continue
    let parts = path.split(DirSep)
    if "Presets" in parts or "Preset" in path.extractFilename:
      result.add(path)
  result.sort()

## Reporting

var sourceRootValue = ""
proc sourceRootOf(pack: Pack): string =
  sourceRootValue / pack.directory

proc modelKey(pack: Pack, path: string): string =
  var stem = path.extractFilename.changeFileExt("")
  if stem.startsWith(pack.prefix):
    stem = stem[pack.prefix.len .. ^1]
  assetKey(stem)

type Resolved = object
  categories: OrderedTable[string, seq[string]]
  materials: Table[string, string]   ## material name -> source texture path
  atlases: OrderedTable[string, string]  ## output png name -> source path

proc resolve(sourceRoot: string, pack: Pack): Resolved =
  let packDir = sourceRoot / pack.directory
  if not dirExists(packDir):
    raise newException(ConversionError, "missing pack directory " & packDir)
  let guids = guidMap(packDir)
  result.categories = categoryModels(packDir, guids)
  result.materials = materialTextures(packDir, guids)
  result.atlases = initOrderedTable[string, string]()
  for _, source in result.materials:
    # PSD authoring files are the pack's sources, not its shipped textures.
    if source.toLowerAscii.endsWith(".psd"):
      continue
    result.atlases[atlasName(pack, source)] = source

proc variantKey(name: string): string =
  ## A material name reduced to what identifies its atlas.
  ##
  ## The FBX and the .mat files disagree about the same material in three
  ## small ways — "Rocks_01A" against "Rocks_1A", a Blender ".001" duplicate
  ## suffix, and a "_1N" spelling of "_1A" — so both sides are reduced to a
  ## common form before matching.
  var stem = name
  let dot = stem.rfind('.')
  if dot > 0 and stem.len - dot == 4 and
      stem[dot + 1 .. ^1].allCharsInSet({'0' .. '9'}):
    stem.setLen(dot)
  var key = assetKey(stem)
  # Drop leading zeros inside each run of digits.
  var reduced = ""
  var i = 0
  while i < key.len:
    if key[i] in {'0' .. '9'}:
      var j = i
      while j < key.len and key[j] in {'0' .. '9'}:
        inc j
      var digits = key[i ..< j]
      while digits.len > 1 and digits[0] == '0':
        digits = digits[1 .. ^1]
      reduced.add(digits)
      i = j
    else:
      reduced.add(key[i])
      inc i
  reduced

proc materialSource(resolved: Resolved, material: string): string =
  ## Finds the .mat behind an FBX material name, tolerating the pack's own
  ## naming drift, then falling back to the "A" variant and to variant 1.
  if material in resolved.materials:
    return resolved.materials[material]
  var byVariant = initTable[string, string]()
  for name, source in resolved.materials:
    byVariant[variantKey(name)] = source
  var key = variantKey(material)
  if key in byVariant:
    return byVariant[key]
  # "..._1n" is the normal-map spelling of the same atlas material.
  if key.len > 0 and key[^1] in {'b' .. 'z'}:
    let asA = key[0 ..< key.len - 1] & "a"
    if asA in byVariant:
      return byVariant[asA]
  # "flowers_3a" when the pack only ships "flowers_1a".
  var stripped = key
  while stripped.len > 0 and stripped[^1] notin {'0' .. '9'}:
    stripped.setLen(stripped.len - 1)
  while stripped.len > 0 and stripped[^1] in {'0' .. '9'}:
    stripped.setLen(stripped.len - 1)
  if stripped.len > 0:
    let first = stripped & "1a"
    if first in byVariant:
      return byVariant[first]
  ""

proc materialAtlas(pack: Pack, resolved: Resolved, material: string): string =
  ## The output atlas a material draws from, or "" when it has none.
  let source = materialSource(resolved, material)
  if source.len == 0 or source.toLowerAscii.endsWith(".psd"):
    return ""
  atlasName(pack, source)

proc selfTest(sourceRoot: string, packs: seq[Pack]): int =
  ## Resolves every category, model and atlas without running FBX2glTF.
  var problems: seq[string]
  for pack in packs:
    let resolved = resolve(sourceRoot, pack)
    var models = 0
    for _, list in resolved.categories:
      models += list.len
    echo &"\n=== {pack.title}  ({models} models, " &
      &"{resolved.categories.len} categories)"
    for category, list in resolved.categories:
      echo &"  {category & \".glb\":18s} {list.len:4d} models"
    echo &"  atlases ({resolved.atlases.len}):"
    for name, source in resolved.atlases:
      let size = atlasSize(source)
      if not fileExists(source):
        problems.add(&"{pack.key}: missing texture {source}")
      echo &"    {name:30s} {size}²  <- {source.extractFilename}"
    var unresolved: seq[string]
    for material, source in resolved.materials:
      if source.toLowerAscii.endsWith(".psd"):
        unresolved.add(material)
    if unresolved.len > 0:
      echo "  materials whose albedo is PSD-only (will render untextured): " &
        unresolved.sorted.join(", ")
  if problems.len > 0:
    echo "\nFAILURES:"
    for problem in problems:
      echo "  " & problem
    return 1
  echo "\nall categories, models and atlases resolved"
  0

type AtlasCache = ref object
  ## Atlases written so far, so each is resized once and only when used.
  alpha: Table[string, bool]
  source: Table[string, string]
  outDir: string
  force: bool

proc ensureAtlas(cache: AtlasCache, name, source: string): bool =
  ## Writes one atlas if it has not been written yet; returns whether it
  ## carries alpha, which decides cutout rendering for its materials.
  if name in cache.alpha:
    return cache.alpha[name]
  let image = readSourceImage(source)
  var hasAlpha = false
  for pixel in image.data:
    if pixel.a != 255:
      hasAlpha = true
      break
  cache.alpha[name] = hasAlpha
  cache.source[name] = source
  let mode = if hasAlpha: "rgba" else: "rgb"
  let target = cache.outDir / name
  if writeTexture(source, target, atlasSize(source), mode, cache.force):
    echo &"  texture {name:30s} {atlasSize(source)}² {mode} " &
      &"{getFileSize(target).float / 1e6:.2f} MB"
  hasAlpha

proc layOutGrid(
    base: Glb, placed: seq[tuple[index: int, low, high: seq[float]]]
) =
  ## Spreads a kit over a browsing grid instead of piling every model on the
  ## origin.
  ##
  ## The offset lives on each node's translation, never in its vertices, so a
  ## consumer reading one model still gets it centred on its own origin while
  ## a viewer opening the whole file can actually read the kit. quadterrain's
  ## collectPropModels re-centres on x and z anyway, so this costs nothing at
  ## runtime.
  var area = 0.0
  for entry in placed:
    area += (entry.high[0] - entry.low[0] + LayoutGap) *
      (entry.high[2] - entry.low[2] + LayoutGap)
  let rowLimit = max(sqrt(area) * 1.3, 1.0)
  var
    cursorX = 0.0
    cursorZ = 0.0
    rowDepth = 0.0
  for entry in placed:
    let
      width = entry.high[0] - entry.low[0]
      depth = entry.high[2] - entry.low[2]
    if cursorX > 0 and cursorX + width > rowLimit:
      cursorX = 0
      cursorZ += rowDepth + LayoutGap
      rowDepth = 0
    base.doc["nodes"][entry.index]["translation"] =
      %[cursorX + width * 0.5, 0.0, cursorZ + depth * 0.5]
    cursorX += width + LayoutGap
    rowDepth = max(rowDepth, depth)

proc buildCategory(
    pack: Pack, resolved: Resolved, category: string, models: seq[string],
    outDir: string, cache: AtlasCache, jobs: int
): JsonNode =
  ## Converts one category into a single glb; returns its manifest entry.
  let base = newPackGlb()

  var textureIndex = initTable[string, int]()
  var materialIndex = initTable[string, int]()

  # Discover the materials this category actually uses from the converted
  # files, so nothing unused is emitted.
  let temp = getTempDir() / "toon_packs" / pack.key / category
  createDir(temp)
  var conversions: seq[(string, string)]
  for model in models:
    conversions.add((model, temp / model.extractFilename.changeFileExt("")))
  let binary = fbx2gltfBinary()
  let converted = convertAll(binary, conversions, jobs)

  var sources: seq[Glb]
  var materialNames: OrderedSet[string]
  for path in converted:
    let glb = readGlb(path)
    sources.add(glb)
    for part in collectParts(glb):
      if part.material.len > 0:
        materialNames.incl(part.material)

  for material in materialNames:
    let atlas = materialAtlas(pack, resolved, material)
    if atlas.len > 0 and atlas notin textureIndex:
      let hasAlpha = cache.ensureAtlas(atlas, resolved.atlases[atlas])
      textureIndex[atlas] = base.addAtlas(atlas, hasAlpha)
  for material in materialNames:
    let atlas = materialAtlas(pack, resolved, material)
    let cutout = atlas.len > 0 and cache.alpha.getOrDefault(atlas)
    materialIndex[material] = base.addMaterial(
      material, textureIndex.getOrDefault(atlas, -1), cutout)

  var nodes = newJArray()
  var triangles = 0
  var placed: seq[tuple[index: int, low, high: seq[float]]]
  for i, model in models:
    let key = modelKey(pack, model)
    placed.add(base.appendModel(sources[i], key, materialIndex))
    let mesh = base.doc["meshes"][base.doc["meshes"].len - 1]
    var modelTriangles = 0
    for primitive in mesh["primitives"]:
      if "indices" in primitive:
        modelTriangles +=
          base.doc["accessors"][primitive["indices"].getInt]["count"].getInt div 3
    triangles += modelTriangles
    nodes.add(%*{
      "node": key,
      "source": model.extractFilename,
      "triangles": modelTriangles,
      "parts": mesh["primitives"].len,
      "size": [
        placed[i].high[0] - placed[i].low[0],
        placed[i].high[1] - placed[i].low[1],
        placed[i].high[2] - placed[i].low[2],
      ],
    })

  layOutGrid(base, placed)

  removeDir(temp)
  let target = outDir / category & ".glb"
  base.write(target)
  let (low, high) = bindPoseBounds(base)
  echo &"  {category & \".glb\":18s} {models.len:4d} models {triangles:8d} tris " &
    &"{base.doc[\"images\"].len} atlas  {getFileSize(target).float / 1e6:6.2f} MB"
  %*{
    "category": category,
    "path": pack.key & "/" & category & ".glb",
    "models": models.len,
    "triangles": triangles,
    "atlases": toSeq(textureIndex.keys).sorted,
    "bounds": {
      "low": [low.x, low.y, low.z],
      "high": [high.x, high.y, high.z],
    },
    "nodes": nodes,
  }

proc verifyPack(outDir: string, packKey: string): seq[string] =
  ## Structural checks over one pack's glbs.
  ##
  ## Deliberately not glb_pack's checkGlbFile: that one insists on a single
  ## texture, which holds for a character but not for a category of props
  ## that legitimately draws on several atlases.
  let manifestPath = outDir / "manifest.json"
  if not fileExists(manifestPath):
    return @[packKey & ": no manifest at " & manifestPath]
  let manifest = parseJson(readFile(manifestPath))
  for entry in manifest["categories"]:
    let category = entry["category"].getStr
    let path = outDir / category & ".glb"
    template check(condition: bool, message: string) =
      if not condition:
        result.add(category & ": " & message)
    if not fileExists(path):
      result.add(category & ": missing " & path)
      continue
    let glb = readGlb(path)
    let doc = glb.doc
    # The BIN chunk is padded to four bytes, so it may run slightly past the
    # buffer's declared length; anything more than that is corruption.
    let declared = doc["buffers"][0]["byteLength"].getInt
    check(glb.binary.len >= declared and glb.binary.len - declared < 4,
      &"buffer says {declared} bytes but the chunk holds {glb.binary.len}")
    let scene = doc["scenes"][doc{"scene"}.getInt(0)]
    check(scene["nodes"].len == doc["nodes"].len,
      "not every node is a top-level scene root")
    check(doc["nodes"].len == entry["models"].getInt,
      &"{doc[\"nodes\"].len} nodes, manifest says {entry[\"models\"].getInt}")
    for node in doc["nodes"]:
      check("mesh" in node, node{"name"}.getStr & " has no mesh")
      check("children" notin node, node{"name"}.getStr & " is not flat")
      let name = node{"name"}.getStr
      check(name.len > 0 and name == name.toLowerAscii,
        "node name is not snake_case: " & name)
    # A category may legitimately have no atlas at all — the waterfall's
    # materials are procedural in Unity and carry no albedo anywhere.
    if doc{"images"}.getElems.len == 0:
      for material in doc{"materials"}.getElems:
        check(material{"pbrMetallicRoughness"}{"baseColorTexture"} == nil,
          "no atlas, but a material still asks for a texture")
    for image in doc{"images"}.getElems:
      check("uri" in image and "bufferView" notin image,
        "image is not an external uri")
      if "uri" in image:
        check(fileExists(outDir / image["uri"].getStr),
          "sidecar " & image["uri"].getStr & " not next to the glb")
    for material in doc{"materials"}.getElems:
      let slot = material{"pbrMetallicRoughness"}{"baseColorTexture"}
      if slot != nil:
        check(slot{"index"}.getInt(-1) < doc{"textures"}.getElems.len,
          "material texture index out of range")
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


## Scene extraction

# A Unity scene is the same YAML as a prefab, but its hierarchy runs through
# real Transform blocks (the grouping GameObjects) rather than only the
# stripped ones a prefab uses.

type SceneTransform = object
  translation: DVec3
  rotation: DVec4
  scaling: DVec3
  father: string

proc sceneTransforms(path: string): Table[string, SceneTransform] =
  ## Real Transform blocks: their own local TRS and their parent.
  var
    anchor = ""
    inBlock = false
    stripped = false
    current: SceneTransform
  proc flush(into: var Table[string, SceneTransform]) =
    if inBlock and not stripped and anchor.len > 0:
      into[anchor] = current
  for line in readFile(path).splitLines:
    if line.startsWith("--- !u!"):
      flush(result)
      inBlock = line.startsWith("--- !u!4 ")
      stripped = false
      anchor = line.rsplit('&', 1)[^1].strip
      current = SceneTransform(
        rotation: dvec4(0, 0, 0, 1), scaling: dvec3(1, 1, 1), father: "0")
      continue
    if not inBlock:
      continue
    let trimmed = line.strip
    if trimmed.startsWith("m_PrefabInstance:"):
      stripped = true
    elif trimmed.startsWith("m_Father:"):
      current.father = braceField(trimmed, "fileID")
    elif trimmed.startsWith("m_LocalPosition:"):
      current.translation = dvec3(
        braceField(trimmed, "x").parseFloat, braceField(trimmed, "y").parseFloat,
        braceField(trimmed, "z").parseFloat)
    elif trimmed.startsWith("m_LocalRotation:"):
      current.rotation = dvec4(
        braceField(trimmed, "x").parseFloat, braceField(trimmed, "y").parseFloat,
        braceField(trimmed, "z").parseFloat, braceField(trimmed, "w").parseFloat)
    elif trimmed.startsWith("m_LocalScale:"):
      current.scaling = dvec3(
        braceField(trimmed, "x").parseFloat, braceField(trimmed, "y").parseFloat,
        braceField(trimmed, "z").parseFloat)
  flush(result)

proc flattenScene(
    path: string, guids: Table[string, string]
): seq[tuple[model: string, world: DMat4]] =
  ## Every model the scene places, with its world transform.
  let
    instances = prefabInstances(path)
    owners = transformOwners(path)
    groups = sceneTransforms(path)
  var byAnchor = initTable[string, PrefabInstance]()
  for instance in instances:
    byAnchor[instance.anchor] = instance

  proc parentMatrix(transformId: string, seen: int): DMat4 =
    ## Walks up the scene hierarchy, through grouping GameObjects and
    ## through other prefab instances alike.
    result = dmat4()
    if seen > 16 or transformId == "0":
      return
    let owner = owners.getOrDefault(transformId, "")
    if owner.len > 0 and owner in byAnchor:
      let parent = byAnchor[owner]
      return parentMatrix(parent.parent, seen + 1) * instanceMatrix(parent)
    if transformId in groups:
      let group = groups[transformId]
      return parentMatrix(group.father, seen + 1) *
        translate(group.translation) * mat4(group.rotation) *
        scale(group.scaling)

  for instance in instances:
    let target = guids.getOrDefault(instance.sourceGuid, "")
    let placed = parentMatrix(instance.parent, 0) * instanceMatrix(instance)
    if target.endsWith(".fbx"):
      result.add((target, placed))
    elif target.endsWith(".prefab"):
      for piece in flattenPrefab(target, guids, placed, 1):
        result.add(piece)

proc buildScene(
    pack: Pack, resolved: Resolved, scenePath, outPath: string,
    cache: AtlasCache, jobs: int
) =
  ## Extracts a whole demo scene, instancing rather than baking.
  ##
  ## A dressed level places the same tree or wall thousands of times, so
  ## every model becomes one mesh and every placement one node carrying its
  ## world matrix. Baking instead would multiply the geometry by its
  ## placement count and turn a 20 MB kit into hundreds.
  let guids = guidMap(sourceRootOf(pack))
  let placements = flattenScene(scenePath, guids)
  echo &"  {placements.len} placements in {scenePath.extractFilename}"

  var wanted: OrderedSet[string]
  for placement in placements:
    if not skipModel(placement.model):
      wanted.incl(placement.model)
  let temp = getTempDir() / "toon_packs" / pack.key / "scene"
  createDir(temp)
  var conversions: seq[(string, string)]
  var order: seq[string]
  for model in wanted:
    conversions.add((model, temp / model.extractFilename.changeFileExt("")))
    order.add(model)
  let converted = convertAll(fbx2gltfBinary(), conversions, jobs)

  let base = newPackGlb()
  var sources = initTable[string, Glb]()
  var materialNames: OrderedSet[string]
  for i, path in converted:
    let glb = readGlb(path)
    sources[order[i]] = glb
    for part in collectParts(glb):
      if part.material.len > 0:
        materialNames.incl(part.material)

  var textureIndex = initTable[string, int]()
  var materialIndex = initTable[string, int]()
  for material in materialNames:
    let atlas = materialAtlas(pack, resolved, material)
    if atlas.len > 0 and atlas notin textureIndex:
      let hasAlpha = cache.ensureAtlas(atlas, resolved.atlases[atlas])
      textureIndex[atlas] = base.addAtlas(atlas, hasAlpha)
  for material in materialNames:
    let atlas = materialAtlas(pack, resolved, material)
    let cutout = atlas.len > 0 and cache.alpha.getOrDefault(atlas)
    materialIndex[material] = base.addMaterial(
      material, textureIndex.getOrDefault(atlas, -1), cutout)

  # One mesh per distinct model, reused by every placement.
  var meshIndex = initTable[string, int]()
  for model in wanted:
    let source = sources[model]
    var primitives = newJArray()
    for part in collectParts(source):
      let attributes = part.primitive["attributes"]
      if "POSITION" notin attributes:
        continue
      let (payload, count, low, high) =
        bakedPositions(source, attributes["POSITION"].getInt, part.world)
      var primitiveJson = %*{
        "attributes": {
          "POSITION": base.addAccessor(payload, 5126, "VEC3", count, low, high),
        },
      }
      if "NORMAL" in attributes:
        primitiveJson["attributes"]["NORMAL"] = %base.addAccessor(
          bakedNormals(source, attributes["NORMAL"].getInt, part.world),
          5126, "VEC3", count)
      if "TEXCOORD_0" in attributes:
        primitiveJson["attributes"]["TEXCOORD_0"] =
          %base.copyAccessor(source, attributes["TEXCOORD_0"].getInt)
      if "indices" in part.primitive:
        primitiveJson["indices"] =
          %base.copyAccessor(source, part.primitive["indices"].getInt)
      if part.material in materialIndex:
        primitiveJson["material"] = %materialIndex[part.material]
      primitives.add(primitiveJson)
    if primitives.len == 0:
      continue
    base.doc["meshes"].add(%*{
      "name": modelKey(pack, model), "primitives": primitives})
    meshIndex[model] = base.doc["meshes"].len - 1

  var placed = 0
  for placement in placements:
    if placement.model notin meshIndex:
      continue
    var matrix = newJArray()
    for column in 0 .. 3:
      for row in 0 .. 3:
        matrix.add(%placement.world[column, row])
    base.doc["nodes"].add(%*{
      "name": modelKey(pack, placement.model) & "_" & $placed,
      "mesh": meshIndex[placement.model],
      "matrix": matrix,
    })
    base.doc["scenes"][0]["nodes"].add(%(base.doc["nodes"].len - 1))
    inc placed

  base.write(outPath)
  echo &"  wrote {outPath}: {meshIndex.len} meshes, {placed} placements, " &
    &"{getFileSize(outPath).float / 1e6:.1f} MB"

proc buildPresets(
    pack: Pack, resolved: Resolved, outDir: string, cache: AtlasCache,
    jobs: int, sourceRoot: string
): JsonNode =
  ## Rebuilds the pack's assembled buildings from their Unity prefabs.
  let packDir = sourceRoot / pack.directory
  let presets = presetFiles(packDir)
  if presets.len == 0:
    return nil
  let guids = guidMap(packDir)

  # Every distinct model any preset places, converted once and shared.
  var wanted: OrderedSet[string]
  var placements: seq[tuple[name: string, pieces: seq[tuple[model: string, world: DMat4]]]]
  for preset in presets:
    let pieces = flattenPrefab(preset, guids)
    # A single-piece preset is just a wrapper around one FBX, which the
    # category kits already carry — the windmill, for instance.
    if pieces.len < 2:
      continue
    for piece in pieces:
      wanted.incl(piece.model)
    placements.add((modelKey(pack, preset), pieces))
  if placements.len == 0:
    return nil

  let temp = getTempDir() / "toon_packs" / pack.key / "presets"
  createDir(temp)
  var conversions: seq[(string, string)]
  var order: seq[string]
  for model in wanted:
    conversions.add((model, temp / model.extractFilename.changeFileExt("")))
    order.add(model)
  let converted = convertAll(fbx2gltfBinary(), conversions, jobs)
  var sources = initTable[string, Glb]()
  var materialNames: OrderedSet[string]
  for i, path in converted:
    let glb = readGlb(path)
    sources[order[i]] = glb
    for part in collectParts(glb):
      if part.material.len > 0:
        materialNames.incl(part.material)

  let base = newPackGlb()
  var textureIndex = initTable[string, int]()
  var materialIndex = initTable[string, int]()
  for material in materialNames:
    let atlas = materialAtlas(pack, resolved, material)
    if atlas.len > 0 and atlas notin textureIndex:
      let hasAlpha = cache.ensureAtlas(atlas, resolved.atlases[atlas])
      textureIndex[atlas] = base.addAtlas(atlas, hasAlpha)
  for material in materialNames:
    let atlas = materialAtlas(pack, resolved, material)
    let cutout = atlas.len > 0 and cache.alpha.getOrDefault(atlas)
    materialIndex[material] = base.addMaterial(
      material, textureIndex.getOrDefault(atlas, -1), cutout)

  var nodes = newJArray()
  var triangles = 0
  var placed: seq[tuple[index: int, low, high: seq[float]]]
  for entry in placements:
    var pieces: seq[Piece]
    for piece in entry.pieces:
      if piece.model in sources:
        pieces.add(Piece(source: sources[piece.model], world: piece.world))
    if pieces.len == 0:
      continue
    placed.add(base.appendAssembly(pieces, entry.name, materialIndex))
    let mesh = base.doc["meshes"][base.doc["meshes"].len - 1]
    var presetTriangles = 0
    for primitive in mesh["primitives"]:
      if "indices" in primitive:
        presetTriangles +=
          base.doc["accessors"][primitive["indices"].getInt]["count"].getInt div 3
    triangles += presetTriangles
    nodes.add(%*{
      "node": entry.name,
      "pieces": pieces.len,
      "triangles": presetTriangles,
      "size": [
        placed[^1].high[0] - placed[^1].low[0],
        placed[^1].high[1] - placed[^1].low[1],
        placed[^1].high[2] - placed[^1].low[2],
      ],
    })

  layOutGrid(base, placed)
  removeDir(temp)
  let target = outDir / "presets.glb"
  base.write(target)
  echo &"  {\"presets.glb\":18s} {placed.len:4d} models {triangles:8d} tris " &
    &"{base.doc[\"images\"].len} atlas  {getFileSize(target).float / 1e6:6.2f} MB"
  %*{
    "category": "presets",
    "path": pack.key & "/presets.glb",
    "models": placed.len,
    "triangles": triangles,
    "atlases": toSeq(textureIndex.keys).sorted,
    "nodes": nodes,
  }

proc buildPack(
    sourceRoot, outRoot: string, pack: Pack, only: string, jobs: int,
    force: bool
): int =
  let resolved = resolve(sourceRoot, pack)
  let outDir = outRoot / pack.key
  createDir(outDir)
  echo &"\n=== {pack.title}"
  let cache = AtlasCache(outDir: outDir, force: force)

  # Ground textures for the quad terrain, shipped loose beside the kits
  # rather than referenced by any glb. The rock materials draw on the stone
  # one, so it may already be written.
  var terrain = newJArray()
  let terrainDir = sourceRoot / pack.directory / "Terrain" / "Terrain Textures"
  if dirExists(terrainDir):
    for path in walkFiles(terrainDir / "*D.png"):
      let name = atlasName(pack, path)
      discard cache.ensureAtlas(name, path)
      terrain.add(%*{"file": name, "source": path.extractFilename})

  var categories = newJArray()
  for category, models in resolved.categories:
    if only.len > 0 and category != only:
      continue
    categories.add(buildCategory(
      pack, resolved, category, models, outDir, cache, jobs))
  if only.len == 0 or only == "presets":
    let presets = buildPresets(
      pack, resolved, outDir, cache, jobs, sourceRoot)
    if presets != nil:
      categories.add(presets)

  var atlases = newJArray()
  for name in toSeq(cache.alpha.keys).sorted:
    let source = cache.source[name]
    atlases.add(%*{
      "file": name,
      "size": atlasSize(source),
      "alpha": cache.alpha[name],
      "source": source.extractFilename,
    })
  let manifest = %*{
    "pack": pack.key,
    "terrain": terrain,
    "title": pack.title,
    "source": "Unity Asset Store product " & $pack.productId &
      " version " & pack.productVersion,
    "generator": "tools/build_toon_packs.nim",
    "atlases": atlases,
    "categories": categories,
  }
  writeFile(outDir / "manifest.json", manifest.pretty & "\n")
  echo "  wrote " & outDir / "manifest.json"
  0

## Driver

proc main(): int =
  var
    sourceRoot = expandTilde(DefaultSource)
    outRoot = DefaultOut
    onlyPack = ""
    onlyCategory = ""
    jobs = countProcessors()
    force = false
    wantSelfTest = false
    wantVerify = false
    scenePath = ""
  for param in commandLineParams():
    if param.startsWith("--source="): sourceRoot = expandTilde(param[9 .. ^1])
    elif param.startsWith("--out="): outRoot = param[6 .. ^1]
    elif param.startsWith("--pack="): onlyPack = param[7 .. ^1]
    elif param.startsWith("--category="): onlyCategory = param[11 .. ^1]
    elif param.startsWith("--jobs="): jobs = param[7 .. ^1].parseInt
    elif param == "--force-textures": force = true
    elif param.startsWith("--scene="): scenePath = param[8 .. ^1]
    elif param == "--self-test": wantSelfTest = true
    elif param == "--verify": wantVerify = true
    else:
      echo "unknown flag: " & param
      return 2

  sourceRootValue = sourceRoot
  var packs: seq[Pack]
  for pack in Packs:
    if onlyPack.len == 0 or pack.key == onlyPack:
      packs.add(pack)
  if packs.len == 0:
    echo "unknown pack: " & onlyPack
    return 2

  if scenePath.len > 0:
    let pack = packs[0]
    let resolved = resolve(sourceRoot, pack)
    let outDir = outRoot / pack.key
    createDir(outDir)
    let cache = AtlasCache(outDir: outDir, force: force)
    buildScene(pack, resolved, sourceRoot / pack.directory / scenePath,
      outDir / scenePath.extractFilename.changeFileExt("").assetKey & ".glb",
      cache, max(1, jobs))
    return 0

  if wantSelfTest:
    return selfTest(sourceRoot, packs)

  if wantVerify:
    var failures: seq[string]
    for pack in packs:
      failures.add(verifyPack(outRoot / pack.key, pack.key))
    if failures.len > 0:
      echo &"FAILED {failures.len} check(s):"
      for failure in failures:
        echo "  " & failure
      return 1
    echo "all packs verified"
    return 0

  for pack in packs:
    let code = buildPack(
      sourceRoot, outRoot, pack, onlyCategory, max(1, jobs), force)
    if code != 0:
      return code
  0

when isMainModule:
  quit(main())
