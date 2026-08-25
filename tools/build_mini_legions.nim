## Converts the "RTS Mini Legions Fantasy HP" Unity asset pack into polyworld
## glb characters: four factions of eight skinned units each, one shared
## external texture per faction, plus a manifest describing every unit's
## clips, roles and native size.
##
## The heavy lifting is tools/fbx_to_glb.nim; this file holds the pack layout,
## the clip-name vocabulary and the manifest.
##
## Run from the repo root:
##   nim r tools/build_mini_legions.nim                        # full build
##   nim r tools/build_mini_legions.nim --faction human --unit footman
##   nim r tools/build_mini_legions.nim --self-test            # names only
##   nim r tools/build_mini_legions.nim --verify               # check outputs

import
  std/[algorithm, json, math, os, osproc, parseopt, sequtils, strformat,
       strutils, tables, tempfiles],
  vmath,
  fbx_to_glb, glb_pack

let
  DefaultSource = expandTilde("~/Polyworld/Assets/RTS Mini Legions Fantasy HP")
const
  DefaultOut = "../polyworld_data/characters/mini_legion"
  DefaultTextureSize = 1024

## Pack layout

type
  UnitSpec = object
    ## A unit whose mesh or animation path disagrees with its faction's
    ## pattern; empty fields fall back to the faction's.
    unit: string
    mesh: string
    animations: string

  Faction = object
    key, name, directory: string
    mesh, animations: string  ## patterns with {unit} / {unitNoSpace}
    albedo, maskTint, mask: string
    units: seq[UnitSpec]
    props: seq[(string, string)]  ## key -> mesh path under the faction

  UnitRecord = object
    faction, display, key, alias, mesh, animations: string

proc unit(name: string): UnitSpec =
  UnitSpec(unit: name)

# {unit} is the display name as it appears in the Animations directory;
# {unitNoSpace} is the same with spaces removed, which is how Warband names
# its mesh files.
let Factions = [
  Faction(
    key: "human",
    name: "Mini Legion Human HP",
    directory: "Mini Legion Human HP",
    mesh: "Meshes/{unit}_Default.fbx",
    animations: "Animations/{unit}",
    albedo: "Textures/RegularTex.png",
    maskTint: "Textures/MaskTintTex.png",
    mask: "Textures/Mask.png",
    units: @[
      unit"Archer", unit"Footman", unit"Griffin", unit"Horseman",
      unit"Knight", unit"Mage", unit"SiegeEngine", unit"Worker",
    ],
    props: @[("arrow", "Meshes/Archer_Arrow.fbx")],
  ),
  Faction(
    key: "sentinel",
    name: "Mini Legion Sentinel HP",
    directory: "Mini Legion Sentinel HP",
    mesh: "Meshes/{unit} Default.fbx",
    animations: "Animations/{unit}",
    albedo: "Textures/RegularTexture.png",
    maskTint: "Textures/MaskTintTexture.png",
    mask: "Textures/Mask.png",
    units: @[
      unit"Battle Owl", unit"Demon Hunter", unit"Druid", unit"Dryad",
      unit"Elf Ranger", unit"Knome", unit"Rock Golem", unit"Treeant",
    ],
    props: @[("rock", "Meshes/RockMesh.fbx")],
  ),
  Faction(
    key: "undead",
    name: "Mini Legion Undead HP",
    directory: "Mini Legion Undead HP",
    mesh: "Meshes/{unit} Mesh.fbx",
    animations: "Animations/{unit}",
    albedo: "Textures/RegularTexture.png",
    maskTint: "Textures/MaskTintTexture.png",
    mask: "Textures/Mask.png",
    units: @[
      unit"Crossbowman", unit"Death Knight", unit"Death Rider",
      # The pack misspells this animation directory.
      UnitSpec(unit: "Gargoyle", animations: "Animations/Gargolye"),
      unit"Lich", unit"Siege Engine", unit"Skeleton Warrior", unit"Slave",
    ],
    props: @[("bolt", "Meshes/Bolt.fbx")],
  ),
  Faction(
    key: "warband",
    name: "Mini Legion Warband HP",
    directory: "Mini Legion Warband HP",
    mesh: "Meshes/{unitNoSpace}.fbx",
    animations: "Animations/{unit}",
    albedo: "Textures/RegularTexture.png",
    maskTint: "Textures/MaskTintTexture.png",
    mask: "Textures/Mask.png",
    units: @[
      unit"Band Wagon", unit"Berserker", unit"Drake", unit"Grunt",
      unit"Head Hunter", unit"Hog Rider", unit"Minion", unit"Warlock",
    ],
    props: @[],
  ),
]

# Reproduces the size the existing footman.glb renders at: its load site
# asks for a height of 1.15 and the source model is 2.968 units tall.
const SuggestedScale = 1.15 / 2.968

## Clip vocabulary

const Canonical = {
  "idle": "Idle",
  "walk": "Walk",
  "run": "Run",
  "move": "Move",
  "fly": "Fly",
  "attack01": "Attack01",
  "attack02": "Attack02",
  "attack01start": "Attack01Start",
  "attack01routine": "Attack01Routine",
  "attack02start": "Attack02Start",
  "attack02routine": "Attack02Routine",
  "die": "Death",
  "death": "Death",
  "gethit": "GetHit",
  "victory": "Victory",
  "defend": "Defend",
  "shieldbash": "ShieldBash",
  "channeling": "Channeling",
  "work": "Work",
  "workstart": "WorkStart",
  "workroutine": "WorkRoutine",
  "workpickup": "Pickup",
  "pickup": "Pickup",
}.toTable

# First match wins. A role with no match is omitted from the manifest rather
# than pointed at a clip that means something else.
const Roles = [
  ("idle", @["Idle"]),
  ("move", @["Run", "Move", "Fly", "Walk"]),
  ("walk", @["Walk", "Move", "Fly", "Run"]),
  ("attack", @["Attack01", "Attack01Start", "Attack01Routine", "Attack02"]),
  ("attackAlt", @["Attack02", "Attack02Routine", "Attack02Start",
                  "ShieldBash", "Channeling"]),
  ("death", @["Death"]),
  ("hit", @["GetHit"]),
  ("victory", @["Victory"]),
  ("work", @["Work", "WorkStart", "WorkRoutine", "Pickup"]),
]

const RequiredRoles = ["idle", "move", "death", "hit"]

proc stripParenSuffix(stem: string): string =
  ## Drops a trailing parenthesised note: "Idle (2)" -> "Idle".
  let trimmed = stem.strip(leading = false)
  if trimmed.endsWith(")"):
    let open = trimmed.find('(')
    if open >= 0:
      return trimmed[0 ..< open].strip(leading = false)
  stem

proc canonicalClip(fileStem, unitAlias: string, strict = true): string =
  ## Maps an animation file name onto the canonical clip vocabulary.
  ##
  ## The unit prefix is stripped only when what remains is itself canonical,
  ## so Archer_Attack01_Routine becomes Attack01Routine while a clip that
  ## legitimately starts with its unit's name is left alone.
  let name = stripParenSuffix(fileStem)
  var key = squash(name)
  if unitAlias.len > 0 and key.startsWith(unitAlias):
    let remainder = key[unitAlias.len .. ^1]
    if remainder in Canonical:
      key = remainder
  if key in Canonical:
    return Canonical[key]
  if strict:
    raise newException(
      ConversionError, fileStem & ": no canonical clip name for '" & key & "'")
  if name.len == 0: "" else: name[0].toUpperAscii & name[1 .. ^1]

proc resolveRoles(clips: seq[string]): OrderedTable[string, string] =
  ## Picks a clip for each role from the ones a unit actually has.
  for (role, preferences) in Roles:
    for clip in preferences:
      if clip in clips:
        result[role] = clip
        break

## Pack traversal

proc unitRecords(faction: Faction): seq[UnitRecord] =
  ## One resolved record per unit of a faction.
  for entry in faction.units:
    let display = entry.unit
    proc fill(pattern: string): string =
      pattern.replace("{unitNoSpace}", display.replace(" ", ""))
        .replace("{unit}", display)
    let mesh = fill(if entry.mesh.len > 0: entry.mesh else: faction.mesh)
    let animations = fill(
      if entry.animations.len > 0: entry.animations else: faction.animations)
    result.add(UnitRecord(
      faction: faction.key,
      display: display,
      key: snakeKey(display),
      alias: squash(display),
      mesh: faction.directory / mesh,
      animations: faction.directory / animations,
    ))

proc selectedFactions(names: seq[string]): seq[Faction] =
  if names.len == 0:
    return Factions.toSeq
  var known: seq[string]
  for faction in Factions:
    known.add(faction.key)
    if faction.key in names:
      result.add(faction)
  let missing = names.filterIt(it notin known).sorted
  if missing.len > 0:
    quit("unknown faction(s): " & missing.join(", "), 1)

proc selectedUnits(faction: Faction, names: seq[string]): seq[UnitRecord] =
  let records = unitRecords(faction)
  if names.len == 0:
    return records
  records.filterIt(it.key in names)

proc checkLayout(source: string, factions: seq[Faction]) =
  ## Fails fast when a mesh or animation directory is missing.
  var problems: seq[string]
  for faction in factions:
    for texture in [faction.albedo, faction.maskTint, faction.mask]:
      let path = source / faction.directory / texture
      if not fileExists(path):
        problems.add(path)
    for record in unitRecords(faction):
      if not fileExists(source / record.mesh):
        problems.add(record.mesh)
      if not dirExists(source / record.animations):
        problems.add(record.animations)
    for (_, path) in faction.props:
      let full = source / faction.directory / path
      if not fileExists(full):
        problems.add(full)
  if problems.len > 0:
    quit("missing source paths:\n  " & problems.join("\n  "), 1)

## Textures

proc buildTextures(source, outDir: string, faction: Faction, size: int, force: bool) =
  ## Writes the faction's albedo, mask-tint and team-mask PNGs.
  ##
  ## RegularTex alpha is fully opaque in every faction, so writeTexture's
  ## drop to RGB is lossless and matches the renderer's opaque upload path.
  let directory = outDir / faction.key
  for (sourceName, name, mode) in [
      (faction.albedo, faction.key & "_albedo.png", "rgb"),
      (faction.maskTint, faction.key & "_masktint.png", "rgb"),
      (faction.mask, faction.key & "_mask.png", "mask")]:
    let target = directory / name
    if writeTexture(source / faction.directory / sourceName, target, size, mode, force):
      echo &"  texture {name} {getFileSize(target).float / 1e6:.2f} MB"

## Unit build

proc buildUnit(
    source, outDir: string, record: UnitRecord, embed, allowUnknown: bool,
    binary: string, jobs: int
): JsonNode =
  ## Converts one unit; returns its manifest entry.
  let faction = record.faction
  var sources: Table[string, string]

  proc clipNameFor(fileName: string): string =
    result = canonicalClip(
      fileName.splitFile.name, record.alias, strict = not allowUnknown)
    sources[result] = fileName

  let base = buildCharacter(
    source / record.mesh, source / record.animations, clipNameFor, binary,
    parallel = jobs)

  let textureName = faction & "_albedo.png"
  if embed:
    base.injectTexture(outDir / faction / textureName)
  else:
    base.attachExternalTexture(textureName, faction & "_albedo")
  discard base.pruneUnusedTextures()

  let doc = base.doc
  let scene = doc["scenes"][doc{"scene"}.getInt(0)]
  if scene["nodes"].len != 1:
    raise newException(
      ConversionError,
      record.key & ": expected one root node, found " & $scene["nodes"].len)
  let skins = doc{"skins"}.getElems
  if skins.len != 1:
    raise newException(
      ConversionError, record.key & ": expected one skin, found " & $skins.len)
  let meshNodes = doc["nodes"].getElems.filterIt("mesh" in it)
  if meshNodes.len != 1:
    raise newException(
      ConversionError,
      record.key & ": expected one mesh node, found " & $meshNodes.len)

  let (lo, hi) = bindPoseBounds(base)
  let target = outDir / faction / (record.key & ".glb")
  createDir(target.parentDir)
  base.write(target)

  var clips: seq[JsonNode]
  for animation in doc{"animations"}.getElems:
    let name = animation["name"].getStr
    clips.add(%*{
      "name": name,
      "source": sources[name],
      "duration": round(clipDuration(base, animation), 4),
    })
  clips.sort(proc(a, b: JsonNode): int = cmp(a["name"].getStr, b["name"].getStr))
  let roles = resolveRoles(clips.mapIt(it["name"].getStr))
  let missing = RequiredRoles.filterIt(it notin roles)
  if missing.len > 0:
    raise newException(
      ConversionError,
      record.key & ": unresolved required role(s) " & $missing &
      " from clips " & $clips.mapIt(it["name"].getStr))

  %*{
    "key": record.key,
    "name": record.display,
    "path": faction & "/" & record.key & ".glb",
    "mesh": meshNodes[0]{"name"}.getStr(""),
    "nativeHeight": round(hi.y - lo.y, 4),
    "groundOffset": round(-lo.y, 4),
    "joints": skins[0]["joints"].len,
    "nodes": doc["nodes"].len,
    "bytes": getFileSize(target),
    "clips": clips,
    "roles": roles,
  }

proc buildProp(
    source, outDir, factionKey, factionDirectory, key, relative: string,
    binary: string
): JsonNode =
  ## Converts a static prop, normalized to unit height with its base at y 0.
  let tmp = createTempDir("polyworld_", "")
  let base = readGlb(convert(binary, source / factionDirectory / relative, tmp / key))
  removeDir(tmp)
  base.attachExternalTexture(factionKey & "_albedo.png", factionKey & "_albedo")
  discard base.pruneUnusedTextures()

  let (lo, hi) = bindPoseBounds(base)
  let height = max(hi.y - lo.y, 1e-6)
  let factor = 1.0 / height
  let centre = (lo + hi) / 2.0
  let doc = base.doc
  let scene = doc["scenes"][doc{"scene"}.getInt(0)]
  # Wrap the existing roots so the prop measures one unit tall, is centred
  # on x/z and rests on y 0, without touching any accessor.
  doc["nodes"].add(%*{
    "name": key,
    "children": scene["nodes"].copy(),
    "translation": [-centre.x * factor, -lo.y * factor, -centre.z * factor],
    "rotation": [0.0, 0.0, 0.0, 1.0],
    "scale": [factor, factor, factor],
  })
  scene["nodes"] = %*[doc["nodes"].len - 1]

  let target = outDir / factionKey / (key & ".glb")
  createDir(target.parentDir)
  base.write(target)
  %*{
    "key": key,
    "path": factionKey & "/" & key & ".glb",
    "sourceHeight": round(height, 4),
    "bytes": getFileSize(target),
  }

## Self-test

proc selfTest(source: string): int =
  ## Maps every animation file name in the pack with no FBX2glTF calls.
  var total = 0
  var failures: seq[string]
  echo &"{\"unit\":<24} role: clip"
  for faction in Factions:
    echo &"\n== {faction.name}"
    for record in unitRecords(faction):
      var names: seq[string]
      for fileName in animationFiles(source / record.animations):
        inc total
        try:
          names.add(canonicalClip(fileName.splitFile.name, record.alias))
        except ConversionError as error:
          failures.add(record.key & ": " & error.msg)
      let duplicates = names.filterIt(names.count(it) > 1).deduplicate.sorted
      if duplicates.len > 0:
        failures.add(record.key & ": duplicate clip names " & $duplicates)
      let roles = resolveRoles(names)
      let missing = RequiredRoles.filterIt(it notin roles)
      if missing.len > 0:
        failures.add(record.key & ": missing required role(s) " & $missing)
      var summary: seq[string]
      for role, clip in roles:
        summary.add(role & "=" & clip)
      echo &"  {record.key:<22} {summary.join(\" \")}"
  echo &"\nmapped {total} animation files"
  if failures.len > 0:
    echo "\nFAILURES:"
    for failure in failures:
      echo "  ", failure
    return 1
  echo "all clip names resolved, no duplicates, all required roles present"
  0

## Verify

proc verify(outDir: string): int =
  ## Structural checks over every glb the manifest claims.
  let manifestPath = outDir / "manifest.json"
  if not fileExists(manifestPath):
    quit("no manifest at " & manifestPath, 1)
  let manifest = parseJson(readFile(manifestPath))
  var failures: seq[string]

  proc check(condition: bool, message: string) =
    if not condition:
      failures.add(message)

  var counted = 0
  for faction in manifest["factions"]:
    for name in ["albedo", "maskTint", "teamMask"]:
      check(fileExists(outDir / faction[name].getStr),
        faction["key"].getStr & ": missing texture " & faction[name].getStr)
    let entries = faction["units"].getElems & faction{"props"}.getElems
    for unit in entries:
      inc counted
      let path = outDir / unit["path"].getStr
      let label = unit["key"].getStr
      let glb = checkGlbFile(path, failures, label)
      if glb == nil or "clips" notin unit:
        continue
      let doc = glb.doc
      let skins = doc{"skins"}.getElems
      check(skins.len == 1, label & ": expected 1 skin")
      if skins.len > 0:
        let joints = skins[0]["joints"]
        check(joints.len == unit["joints"].getInt,
          label & ": " & $joints.len & " joints, manifest says " &
          $unit["joints"].getInt)
        check(joints.getElems.allIt(it.getInt >= 0 and it.getInt < doc["nodes"].len),
          label & ": joint index out of range")
      checkAnimations(
        glb, unit["clips"].getElems.mapIt(it["name"].getStr), failures, label)
      let (lo, hi) = bindPoseBounds(glb)
      let height = hi.y - lo.y
      check(abs(height - unit["nativeHeight"].getFloat) < 0.001,
        &"{label}: height {height:.4f} != manifest {unit[\"nativeHeight\"].getFloat}")
      check(0.5 < height and height < 8.0,
        &"{label}: implausible height {height:.4f}")

  if failures.len > 0:
    echo &"FAILED {failures.len} check(s):"
    for failure in failures:
      echo "  ", failure
    return 1
  echo &"verified {counted} models, all checks passed"
  0

## Driver

proc writeManifest(
    outDir: string, factions: seq[Faction],
    byFaction, propsByFaction: Table[string, seq[JsonNode]], partial: bool
) =
  ## Writes manifest.json, merging into any existing partial build.
  let path = outDir / "manifest.json"
  var manifest = %*{
    "pack": "mini_legion",
    "source": "RTS Mini Legions Fantasy HP",
    "generator": "tools/build_mini_legions.nim",
    "suggestedScale": round(SuggestedScale, 4),
    "factions": [],
  }
  var existing: Table[string, JsonNode]
  if partial and fileExists(path):
    for faction in parseJson(readFile(path)){"factions"}.getElems:
      existing[faction["key"].getStr] = faction

  for faction in Factions:
    let key = faction.key
    let fresh = key in byFaction
    let previous = existing.getOrDefault(key, nil)
    if not fresh and previous == nil:
      continue
    var units: OrderedTable[string, JsonNode]
    var props: OrderedTable[string, JsonNode]
    if previous != nil:
      for u in previous{"units"}.getElems:
        units[u["key"].getStr] = u
      for p in previous{"props"}.getElems:
        props[p["key"].getStr] = p
    for entry in byFaction.getOrDefault(key, @[]):
      units[entry["key"].getStr] = entry
    for entry in propsByFaction.getOrDefault(key, @[]):
      props[entry["key"].getStr] = entry
    var orderedUnits, orderedProps: seq[JsonNode]
    for record in unitRecords(faction):
      if record.key in units:
        orderedUnits.add(units[record.key])
    for propKey in props.keys.toSeq.sorted:
      orderedProps.add(props[propKey])
    manifest["factions"].add(%*{
      "key": key,
      "name": faction.name,
      "albedo": key & "/" & key & "_albedo.png",
      "maskTint": key & "/" & key & "_masktint.png",
      "teamMask": key & "/" & key & "_mask.png",
      "units": orderedUnits,
      "props": orderedProps,
    })

  createDir(outDir)
  writeFile(path, manifest.pretty & "\n")
  echo "wrote ", path

proc main(): int =
  var
    source = DefaultSource
    outDir = DefaultOut
    factionNames, unitNames: seq[string]
    textureSize = DefaultTextureSize
    jobs = countProcessors()
    forceTextures, skipTextures, skipProps, embedTexture = false
    allowUnknownClips, selfTestOnly, verifyOnly = false
  var parser = initOptParser(
    commandLineParams(),
    longNoVal = @[
      "force-textures", "skip-textures", "skip-props", "embed-texture",
      "allow-unknown-clips", "self-test", "verify"])
  for kind, key, value in parser.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "source": source = expandTilde(value)
      of "out": outDir = value
      of "faction": factionNames.add(value)
      of "unit": unitNames.add(value)
      of "texture-size": textureSize = parseInt(value)
      of "jobs": jobs = parseInt(value)
      of "force-textures": forceTextures = true
      of "skip-textures": skipTextures = true
      of "skip-props": skipProps = true
      of "embed-texture": embedTexture = true
      of "allow-unknown-clips": allowUnknownClips = true
      of "self-test": selfTestOnly = true
      of "verify": verifyOnly = true
      else: quit("unknown option --" & key, 1)
    of cmdArgument: quit("unexpected argument " & key, 1)
    of cmdEnd: discard

  if selfTestOnly:
    checkLayout(source, Factions.toSeq)
    return selfTest(source)
  if verifyOnly:
    return verify(outDir)

  let factions = selectedFactions(factionNames)
  checkLayout(source, factions)
  let partial = factionNames.len > 0 or unitNames.len > 0

  var unitJobs: seq[UnitRecord]
  var propJobs: seq[(Faction, string, string)]
  for faction in factions:
    unitJobs.add(selectedUnits(faction, unitNames))
    if not skipProps and unitNames.len == 0:
      for (key, relative) in faction.props:
        propJobs.add((faction, key, relative))
  if unitJobs.len == 0:
    quit("no units selected", 1)

  if not skipTextures:
    for faction in factions:
      echo &"textures: {faction.name}"
      buildTextures(source, outDir, faction, textureSize, forceTextures)

  echo &"converting {unitJobs.len} unit(s) and {propJobs.len} prop(s), " &
    &"{jobs} FBX2glTF process(es) at a time"
  let binary = fbx2gltfBinary()
  var byFaction, propsByFaction: Table[string, seq[JsonNode]]
  for record in unitJobs:
    let entry = buildUnit(
      source, outDir, record, embedTexture, allowUnknownClips, binary, jobs)
    byFaction.mgetOrPut(record.faction, @[]).add(entry)
    echo &"  {entry[\"path\"].getStr:<38} {entry[\"joints\"].getInt:>3} joints " &
      &"{entry[\"clips\"].len:>2} clips  h={entry[\"nativeHeight\"].getFloat:.3f}  " &
      &"{entry[\"bytes\"].getInt.float / 1e3:>6.0f} KB"
  for (faction, key, relative) in propJobs:
    let entry = buildProp(
      source, outDir, faction.key, faction.directory, key, relative, binary)
    propsByFaction.mgetOrPut(faction.key, @[]).add(entry)
    echo &"  {entry[\"path\"].getStr:<38} prop  " &
      &"{entry[\"bytes\"].getInt.float / 1e3:>6.0f} KB"

  writeManifest(outDir, factions, byFaction, propsByFaction, partial)
  0

when isMainModule:
  quit(main())
