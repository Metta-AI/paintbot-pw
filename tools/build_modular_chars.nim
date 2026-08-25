## Converts the Layer Lab "3D Characters - Hero Core Vol.3" Unity pack into
## one polyworld glb: a single skeleton carrying every swappable part (714
## skinned meshes: bodies in six skin tones, heads, hair, brows, eyes, mouths,
## beards, earrings, eyewear, chest/leg/foot/hand/back gear, held weapons),
## plus a manifest that names them by category so a client can toggle nodes.
##
## The pack ships no animations of its own; it is meant to be driven by any
## Unity Humanoid clip. Here that is done for real: the RPG Tiny Hero Duo
## sword-and-shield clips (a humanoid pack in the same Unity project) are
## retargeted onto the Layer Lab skeleton through both packs' avatar
## descriptions (tools/humanoid_retarget.nim). The pack's 23 preview poses are
## added as held-still clips too.
##
## Run from the repo root:
##   nim r tools/build_modular_chars.nim              # full build
##   nim r tools/build_modular_chars.nim --verify     # check the built files
##   nim r tools/build_modular_chars.nim --skip-clips # geometry only

import
  std/[algorithm, json, math, os, osproc, parseopt, sequtils, strformat,
       strutils, tables, tempfiles],
  fbx_to_glb, glb_pack, humanoid_retarget

let
  DefaultSource = expandTilde(
    "~/Polyworld/Assets/Layer Lab/3D CharactersCasual/" &
    "3D Characters - Hero Core Vol.3")
  DefaultClipSource = expandTilde(
    "~/Polyworld/Assets/RPG Tiny Hero Duo/Animation/SwordAndShield")
const
  DefaultOut = "../polyworld_data/characters/modular_chars"
  CharacterFbx = "FBX/Character/Character.fbx"
  PaletteTexture = "Textures/3D Characters Pro - Fantasy Basic Vol.3.png"
  PosePrefabs = "Prefabs/Preview/Preview_Pose_$1.prefab"
  PoseFbx = "FBX/Preview/Preview_Pose_$1.fbx"
  PoseCount = 23

## Materials, transcribed from the pack's Unity .mat files (URP Lit).
# Every material samples the same 256x256 palette; they differ only in
# smoothness, tint, emission and blending. Unity smoothness is 1 - roughness.
# _Cull 0 in the .mat means both faces render.

type MaterialSpec = object
  baseColorFactor: array[4, float]
  metallicFactor, roughnessFactor: float
  emissiveFactor: seq[float]  ## empty when the material does not glow
  alphaMode: string           ## "" means OPAQUE
  doubleSided: bool

let Materials = {
  "Color": MaterialSpec(
    baseColorFactor: [1.0, 1.0, 1.0, 1.0],
    metallicFactor: 0.0, roughnessFactor: 1.0,
    doubleSided: true,
  ),
  "MetalnessA": MaterialSpec(
    baseColorFactor: [1.0, 1.0, 1.0, 1.0],
    metallicFactor: 0.0, roughnessFactor: 1.0 - 0.365,
    doubleSided: true,
  ),
  "MetalnessB": MaterialSpec(
    baseColorFactor: [1.0, 1.0, 1.0, 1.0],
    metallicFactor: 0.042, roughnessFactor: 1.0 - 0.286,
    doubleSided: true,
  ),
  "Emission": MaterialSpec(
    baseColorFactor: [0.9056604, 0.31185475, 0.8249302, 1.0],
    metallicFactor: 0.0, roughnessFactor: 1.0 - 0.557,
    emissiveFactor: @[0.2846542, 0.96209353, 0.19514163],
    doubleSided: true,
  ),
  # FBX2glTF keeps the FBX's own spelling of this one.
  "Transperant": MaterialSpec(
    baseColorFactor: [1.0, 1.0, 1.0, 0.58431375],
    metallicFactor: 0.0, roughnessFactor: 0.5,
    alphaMode: "BLEND",
    doubleSided: false,
  ),
}.toOrderedTable

## Clips: source file stem, clip name, and how it plays. In-place variants
# are used for the locomotion clips so the character stays on its tile; the
# RootMotion folder is skipped.
#
# loop:   the clip repeats; otherwise it plays once and holds its last frame
#         until the player moves on.
# next:   for one-shots, the clip to chain into when it ends. Empty means
#         "go back to whatever looping clip was playing before".
# bounce: vertical hips travel scale (see humanoid_retarget). The source
#         pack's walks are skips with both feet off the ground; on this rig,
#         1.6x taller at the hips, the hop reaches 0.4 units and looks like
#         low gravity, so it is damped for locomotion.

type ClipSpec = object
  stem, name: string
  loop: bool
  next: string
  bounce: float

proc clip(stem, name: string, loop: bool, next = "", bounce = 1.0): ClipSpec =
  ClipSpec(stem: stem, name: name, loop: loop, next: next, bounce: bounce)

const Clips = [
  clip("Idle_Normal_SwordAndShield", "Idle", loop = true),
  clip("Idle_Battle_SwordAndShiled", "IdleBattle", loop = true),
  clip("InPlace/MoveFWD_Normal_InPlace_SwordAndShield", "Walk", loop = true, bounce = 0.4),
  clip("InPlace/MoveFWD_Battle_InPlace_SwordAndShield", "WalkBattle", loop = true, bounce = 0.4),
  clip("InPlace/MoveBWD_Battle_InPlace_SwordAndShield", "WalkBack", loop = true, bounce = 0.4),
  clip("InPlace/MoveLFT_Battle_InPlace_SwordAndShield", "StrafeLeft", loop = true, bounce = 0.4),
  clip("InPlace/MoveRGT_Battle_InPlace_SwordAndShield", "StrafeRight", loop = true, bounce = 0.4),
  clip("InPlace/SprintFWD_Battle_InPlace_SwordAndShield", "Run", loop = true, bounce = 0.6),
  clip("Attack01_SwordAndShiled", "Attack01", loop = false),
  clip("Attack02_SwordAndShiled", "Attack02", loop = false),
  clip("Attack03_SwordAndShiled", "Attack03", loop = false),
  clip("Attack04_Start_SwordAndShield", "Attack04Start", loop = false, next = "Attack04Spin"),
  clip("Attack04_Spinning_SwordAndShield", "Attack04Spin", loop = true),
  clip("Attack04_SwordAndShiled", "Attack04", loop = false),
  clip("Defend_SwordAndShield", "Defend", loop = true),
  clip("DefendHit_SwordAndShield", "DefendHit", loop = false),
  clip("GetHit01_SwordAndShield", "GetHit", loop = false),
  clip("Dizzy_SwordAndShield", "Dizzy", loop = true),
  clip("Die01_SwordAndShield", "Death", loop = false, next = "DeathStay"),
  clip("Die01_Stay_SwordAndShield", "DeathStay", loop = true),
  clip("GetUp_SwordAndShield", "GetUp", loop = false),
  clip("InPlace/JumpStart_Normal_InPlace_SwordAndShield", "JumpStart", loop = false, next = "JumpAir"),
  clip("InPlace/JumpAir_Normal_InPlace_SwordAndShield", "JumpAir", loop = true),
  clip("InPlace/JumpEnd_Normal_InPlace_SwordAndShield", "JumpEnd", loop = false),
  clip("InPlace/JumpFull_Normal_InPlace_SwordAndShield", "Jump", loop = false),
  clip("InPlace/JumpFull_Spin_InPlace_SwordAndShield", "JumpSpin", loop = false),
  clip("InPlace/JumpAir_Double_InPlace_SwordAndShield", "JumpAirDouble", loop = false, next = "JumpAir"),
  clip("InPlace/JumpAir_Spin_InPlace_SwordAndShield", "JumpAirSpin", loop = false, next = "JumpAir"),
  clip("LevelUp_Battle_SwordAndShield", "LevelUp", loop = false),
  clip("Victory_Battle_SwordAndShield", "Victory", loop = false),
]

## Part naming

# Part nodes are named Category[_Color]_Style, e.g. Hair_Black_3, Eye_2,
# Wield_Gear_Left_7. Body meshes are Body_<Skin>_<Piece>.

# Which prefab-tree folder each category lives under; PartA is the face,
# PartB is gear. Wield_Gear splits into a left and right hand.
const Categories = [
  "Hair", "Brow", "Eye", "Mouth", "Beard", "Earring", "Eyewear",
  "Head", "Chest", "Back", "Hand", "Leg", "Foot",
  "Wield_Gear_Left", "Wield_Gear_Right",
]

proc allDigits(s: string): bool =
  s.len > 0 and s.allIt(it in {'0' .. '9'})

proc allLetters(s: string): bool =
  s.len > 0 and s.allIt(it in {'a' .. 'z', 'A' .. 'Z'})

proc parsePartSuffix(suffix: string): tuple[ok: bool, color: string, style: int] =
  ## Parses "[Color_]Style": "3" -> ("", 3), "Black_3" -> ("Black", 3).
  if suffix.allDigits:
    return (true, "", parseInt(suffix))
  let split = suffix.find('_')
  if split < 0:
    return (false, "", 0)
  let (color, style) = (suffix[0 ..< split], suffix[split + 1 .. ^1])
  if color.allLetters and style.allDigits:
    return (true, color, parseInt(style))
  (false, "", 0)

proc parseBodyName(name: string): tuple[ok: bool, skin, piece: string] =
  ## Parses "Body_<Skin>_<Piece>".
  if not name.startsWith("Body_"):
    return (false, "", "")
  let rest = name["Body_".len .. ^1]
  let split = rest.find('_')
  if split < 0:
    return (false, "", "")
  let (skin, piece) = (rest[0 ..< split], rest[split + 1 .. ^1])
  if skin.allLetters and piece.len > 0:
    return (true, skin, piece)
  (false, "", "")

proc collectParts(doc: JsonNode): tuple[categories: OrderedTable[string, seq[JsonNode]], body: JsonNode] =
  ## Walks the Parts and Body subtrees into manifest records.
  ##
  ## Node names repeat across the tree (the rig guides have a "Head" too), so
  ## the walk goes by index from the Characters folder down.
  let nodes = doc["nodes"]

  proc name(index: int): string =
    nodes[index]{"name"}.getStr("")

  proc child(index: int, childName: string): int =
    for c in nodeChildren(nodes[index]):
      if name(c) == childName:
        return c
    raise newException(
      ConversionError, name(index) & ": no child named " & childName)

  proc children(index: int): seq[int] =
    nodeChildren(nodes[index])

  let root = doc["scenes"][doc{"scene"}.getInt(0)]["nodes"][0].getInt
  let characters = child(root, "Characters")
  let parts = child(characters, "Parts")

  var categories: OrderedTable[string, seq[JsonNode]]
  for key in Categories:
    categories[key] = @[]
  for folder in children(parts):  # PartA, PartB
    for category in children(folder):
      var groups = @[category]
      if name(category) == "Wield_Gear":
        groups = children(category)
      for group in groups:
        let key = name(group)
        if key notin categories:
          raise newException(ConversionError, "unexpected part category " & key)
        for index in children(group):
          let part = name(index)
          if "mesh" notin nodes[index]:
            raise newException(ConversionError, part & ": part node has no mesh")
          let parsed =
            if part.startsWith(key & "_"): parsePartSuffix(part[key.len + 1 .. ^1])
            else: (false, "", 0)
          if not parsed.ok:
            raise newException(
              ConversionError, part & ": does not parse as a " & key & " part")
          let mesh = doc["meshes"][nodes[index]["mesh"].getInt]
          let materialIndex = mesh["primitives"][0]["material"].getInt
          let material = doc["materials"][materialIndex]["name"].getStr
          categories[key].add(%*{
            "name": part,
            "color": parsed.color,
            "style": parsed.style,
            "material": material,
          })
  for key, items in categories.mpairs:
    if items.len == 0:
      raise newException(ConversionError, "category " & key & " has no parts")
    items.sort(proc(a, b: JsonNode): int =
      result = cmp(a["color"].getStr, b["color"].getStr)
      if result == 0:
        result = cmp(a["style"].getInt, b["style"].getInt))

  var skins: seq[string]
  var pieces: seq[string]
  var first = true
  for skin in children(child(characters, "Body")):  # Body_Black, ...
    let skinName = name(skin)
    skins.add(skinName["Body_".len .. ^1])
    var found: seq[string]
    for index in children(skin):
      let parsed = parseBodyName(name(index))
      if not parsed.ok or "Body_" & parsed.skin != skinName:
        raise newException(
          ConversionError, name(index) & ": does not parse as a body mesh")
      found.add(parsed.piece)
    if first:
      pieces = found
      first = false
    elif found != pieces:
      raise newException(
        ConversionError,
        skinName & ": body pieces differ from Body_" & skins[0])
  (categories, %*{"skins": skins, "pieces": pieces})

## Presets from the pack's preview prefabs

proc lineValue(text, key: string): string =
  ## The rest of the line after the first occurrence of key, stripped.
  let start = text.find(key)
  if start < 0:
    raise newException(ConversionError, "prefab block lacks " & key)
  var stop = text.find('\n', start)
  if stop < 0:
    stop = text.len
  text[start + key.len ..< stop].strip

proc prefabActiveParts(path: string): seq[string] =
  ## Names of the enabled skinned meshes in a Unity prefab.
  let text = readFile(path)
  var objects: Table[string, tuple[name: string, active: bool]]
  var renderers: seq[string]
  for part in text.split("--- !u!"):
    if part.startsWith("1 &"):
      let fileId = part.split('&')[1].split('\n')[0].strip
      objects[fileId] = (
        lineValue(part, "m_Name: "), lineValue(part, "m_IsActive: ") == "1")
    elif part.startsWith("137 &"):
      let value = lineValue(part, "m_GameObject: {fileID: ")
      renderers.add(value[0 ..< value.find('}')])
  for fileId, (name, active) in objects:
    if fileId in renderers and active:
      result.add(name)
  result.sort()

## Build

proc build(source, clipSource, outDir: string, skipClips: bool, jobs: int) =
  let binary = fbx2gltfBinary()
  createDir(outDir)
  let tmp = createTempDir("polyworld_", "")
  defer: removeDir(tmp)

  # Every FBX2glTF run up front, in parallel; the grafting is quick.
  var conversions = @[(source / CharacterFbx, tmp / "character")]
  if not skipClips:
    for spec in Clips:
      conversions.add((clipSource / (spec.stem & ".fbx"), tmp / ("clip_" & spec.name)))
    for n in 1 .. PoseCount:
      conversions.add((source / (PoseFbx % [$n]), tmp / ("pose_" & $n)))
  let converted = convertAll(binary, conversions, jobs)

  let base = readGlb(converted[0])
  let doc = base.doc

  # One palette for every material, then the per-material settings.
  base.injectTexture(source / PaletteTexture)
  let palette = doc["textures"].len - 1
  var seen: seq[string]
  for material in doc["materials"]:
    let materialName = material["name"].getStr
    if materialName notin Materials:
      raise newException(
        ConversionError, "material " & materialName & " not in the transcription")
    let settings = Materials[materialName]
    seen.add(materialName)
    let pbr = material["pbrMetallicRoughness"]
    pbr["baseColorFactor"] = %settings.baseColorFactor
    pbr["metallicFactor"] = %settings.metallicFactor
    pbr["roughnessFactor"] = %settings.roughnessFactor
    material["doubleSided"] = %settings.doubleSided
    material["alphaMode"] = %(
      if settings.alphaMode.len > 0: settings.alphaMode else: "OPAQUE")
    if "extras" in material:
      material.delete("extras")
    if settings.emissiveFactor.len > 0:
      material["emissiveFactor"] = %settings.emissiveFactor
      material["emissiveTexture"] = %*{"index": palette}
  let missing = Materials.keys.toSeq.filterIt(it notin seen).sorted
  if missing.len > 0:
    raise newException(ConversionError, "materials never used: " & $missing)
  discard base.pruneUnusedTextures()

  let (categories, body) = collectParts(doc)

  var clips: seq[JsonNode]
  if not skipClips:
    let targetAvatar = newAvatar(source / (CharacterFbx & ".meta"))
    let retargeter = newRetargeter(base, targetAvatar)
    for i, spec in Clips:
      let fbx = clipSource / (spec.stem & ".fbx")
      let clip = readGlb(converted[1 + i])
      let unmatched = retargeter.retarget(
        clip, newAvatar(fbx & ".meta"), spec.name, spec.bounce)
      for human in unmatched:
        # Fingers are the only bones the target lacks.
        if "Thumb" notin human and "Index" notin human:
          raise newException(
            ConversionError,
            spec.name & ": source animates " & human & ", which the target rig lacks")
      if spec.next.len > 0 and not Clips.anyIt(it.name == spec.next):
        raise newException(
          ConversionError, spec.name & ": next clip " & spec.next & " is not a clip")
      let duration = round(clipDuration(base, doc["animations"][^1]), 4)
      clips.add(%*{
        "name": spec.name,
        "source": fbx.extractFilename,
        "kind": "retargeted",
        "duration": duration,
        "loop": spec.loop,
        "next": spec.next,
        "bounce": spec.bounce,
      })
      echo &"  clip {spec.name:<14} {duration:.2f}s"
    for n in 1 .. PoseCount:
      let fbx = source / (PoseFbx % [$n])
      let pose = readGlb(converted[1 + Clips.len + n - 1])
      let clipName = "Pose" & align($n, 2, '0')
      discard graftStaticPose(base, pose, clipName)
      clips.add(%*{
        "name": clipName,
        "source": fbx.extractFilename,
        "kind": "pose",
        "duration": round(clipDuration(base, doc["animations"][^1]), 4),
        "loop": true,
        "next": "",
        "bounce": 1.0,
      })
    echo &"  {PoseCount} poses"

  var presets: seq[JsonNode]
  let known = doc["nodes"].getElems.mapIt(it{"name"}.getStr(""))
  for n in 1 .. PoseCount:
    let parts = prefabActiveParts(source / (PosePrefabs % [$n]))
    for part in parts:
      if part notin known:
        raise newException(
          ConversionError, "preset " & $n & ": " & part & " is not a node in the model")
    presets.add(%*{
      "name": "Preset " & $n,
      "pose": "Pose" & align($n, 2, '0'),
      "parts": parts,
    })

  let modelPath = outDir / "character.glb"
  base.write(modelPath)

  var categoryList: seq[JsonNode]
  for key, items in categories:
    categoryList.add(%*{"key": key, "items": items})
  let manifest = %*{
    "pack": "modular_chars",
    "source": "Layer Lab - 3D Characters - Hero Core Vol.3",
    "clipSource": "RPG Tiny Hero Duo (SwordAndShield), retargeted",
    "generator": "tools/build_modular_chars.nim",
    "model": "character.glb",
    "bytes": getFileSize(modelPath),
    "nodes": doc["nodes"].len,
    "meshes": doc["meshes"].len,
    "skeleton": "QuickRigCharacter2_Hips",
    "body": body,
    "categories": categoryList,
    "clips": clips,
    "presets": presets,
  }
  writeFile(outDir / "manifest.json", manifest.pretty & "\n")
  echo &"wrote {modelPath} ({manifest[\"bytes\"].getInt.float / 1e6:.1f} MB), " &
    &"{doc[\"meshes\"].len} meshes, {clips.len} clips, {presets.len} presets"

## Verify

proc verify(outDir: string) =
  var failures: seq[string]
  let manifest = parseJson(readFile(outDir / "manifest.json"))
  let glb = readGlb(outDir / manifest["model"].getStr)
  let doc = glb.doc
  let names = doc["nodes"].getElems.mapIt(it{"name"}.getStr(""))

  proc check(condition: bool, message: string) =
    if not condition:
      failures.add(message)

  for category in manifest["categories"]:
    for item in category["items"]:
      check(item["name"].getStr in names, "missing part node " & item["name"].getStr)
  for skin in manifest["body"]["skins"]:
    for piece in manifest["body"]["pieces"]:
      let name = "Body_" & skin.getStr & "_" & piece.getStr
      check(name in names, "missing " & name)
  let clipNames = doc{"animations"}.getElems.mapIt(it["name"].getStr)
  check(clipNames == manifest["clips"].getElems.mapIt(it["name"].getStr),
    "clip list disagrees with the manifest")
  check(clipNames.deduplicate.len == clipNames.len, "duplicate clip names")
  for preset in manifest["presets"]:
    let presetName = preset["name"].getStr
    check(preset["pose"].getStr in clipNames, presetName & ": pose clip missing")
    for part in preset["parts"]:
      check(part.getStr in names, presetName & ": " & part.getStr & " missing")
  check(doc{"images"}.getElems.len == 1, "expected exactly one image")
  for material in doc["materials"]:
    check(material["pbrMetallicRoughness"]["baseColorTexture"]["index"].getInt == 0,
      material["name"].getStr & ": not bound to the palette")
  if failures.len > 0:
    for failure in failures:
      echo "FAIL ", failure
    quit(1)
  echo &"ok: {names.len} nodes, {clipNames.len} clips, {manifest[\"presets\"].len} presets"

when isMainModule:
  var
    source = DefaultSource
    clipSource = DefaultClipSource
    outDir = DefaultOut
    jobs = countProcessors()
    skipClips, verifyOnly = false
  var parser = initOptParser(
    commandLineParams(), longNoVal = @["skip-clips", "verify"])
  for kind, key, value in parser.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "source": source = expandTilde(value)
      of "clip-source": clipSource = expandTilde(value)
      of "out": outDir = value
      of "jobs": jobs = parseInt(value)
      of "skip-clips": skipClips = true
      of "verify": verifyOnly = true
      else: quit("unknown option --" & key, 1)
    of cmdArgument: quit("unexpected argument " & key, 1)
    of cmdEnd: discard
  if verifyOnly:
    verify(outDir)
  else:
    build(source, clipSource, outDir, skipClips, jobs)
