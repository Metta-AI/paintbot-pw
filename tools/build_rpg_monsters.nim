## Converts the "RPGMonsterBundlePBR" Unity asset pack into polyworld glb
## characters: 30 monsters across three release waves, all sharing one
## external albedo texture, plus a manifest describing every monster's clips,
## roles and native size.
##
## Weapons need no special handling here: unlike the mini legion pack, each
## monster's mesh FBX already carries its weapon as a second mesh parented to
## the right bone, so it comes through the conversion attached and animated.
##
## Run from the repo root:
##   nim r tools/build_rpg_monsters.nim                     # full build
##   nim r tools/build_rpg_monsters.nim --monster orc
##   nim r tools/build_rpg_monsters.nim --self-test         # names only
##   nim r tools/build_rpg_monsters.nim --verify            # check outputs

import
  std/[algorithm, json, math, os, osproc, parseopt, sequtils, strformat,
       strutils, tables],
  vmath,
  fbx_to_glb, glb_pack

let
  DefaultSource = expandTilde("~/Polyworld/Assets/RPGMonsterBundlePBR")
const
  DefaultOut = "../polyworld_data/characters/rpg_monsters"
  DefaultTextureSize = 512
  AlbedoName = "monsters_albedo.png"

## Pack layout

type
  MonsterSpec = object
    ## A monster whose mesh path disagrees with its wave's pattern; an empty
    ## mesh falls back to the wave's.
    monster: string
    mesh: string

  Wave = object
    key, directory: string
    mesh, animations: string  ## patterns with {monster} / {compact}
    monsters: seq[MonsterSpec]

  MonsterRecord = object
    wave, display, key, mesh, animations: string
    aliases: seq[string]

proc monster(name: string): MonsterSpec =
  MonsterSpec(monster: name)

# The three waves are release batches, not factions: they share one texture
# set and their monster names do not collide, so everything lands in one flat
# directory. Each wave spells its own directories differently, hence the
# per-wave patterns. {monster} is the animation directory name; {compact}
# is the same with spaces removed.
let Waves = [
  Wave(
    key: "wave01",
    directory: "RPGMonsterWave01PBR",
    mesh: "Meshes/Character/{compact}Mesh.fbx",
    animations: "Animations/{monster}",
    monsters: @[
      monster"Bat", monster"Dragon", monster"EvilMage", monster"Golem",
      monster"MonsterPlant", monster"Orc", monster"Skeleton", monster"Slime",
      monster"Spider", monster"TurtleShell",
    ],
  ),
  Wave(
    key: "wave02",
    directory: "RPGMonsterWave02PBR",
    mesh: "Meshes/Character/{compact}Mesh.fbx",
    animations: "Animations/{monster}",
    monsters: @[
      monster"Beholder", monster"Black Knight", monster"Chest Monster",
      monster"Crab Monster",
      # The pack misspells this mesh file.
      MonsterSpec(
        monster: "Flying Demon", mesh: "Meshes/Character/FylingDemonMesh.fbx"),
      monster"Lizard Warrior", monster"Rat Assassin", monster"Specter",
      monster"Werewolf", monster"Worm Monster",
    ],
  ),
  Wave(
    key: "wave03",
    directory: "RPGMonsterWave03PBR",
    mesh: "Mesh/Characters/{compact}_Mesh.fbx",
    animations: "Animation/{monster}",
    monsters: @[
      monster"BattleBee", monster"BishopKnight",
      MonsterSpec(monster: "Cactus", mesh: "Mesh/Characters/CactusMesh.fbx"),
      monster"Cyclops", monster"DemonKing", monster"Fishman", monster"Mushroom",
      monster"NagaWizard",
      MonsterSpec(
        monster: "Salamander", mesh: "Mesh/Characters/SalamanderMesh.fbx"),
      monster"StingRay",
    ],
  ),
]

# All 30 monsters share this one atlas, which is why the output is flat.
const AlbedoSource = "CommonStuffs/Textures/DefaultPBR/Albedo.png"

# Some files abbreviate the monster instead of naming it: Attack01_MP_Anim
# for MonsterPlant. Only aliases of two characters or more are used, so
# single-initial monsters like Werewolf never eat a leading letter.
const ExtraAliases = {
  "MonsterPlant": @["mp"],
}.toTable

## Clip vocabulary

# The pack spells the same clip several ways across the three waves, so this
# folds synonyms together: SenseSomethingST / SenseSomethingStart are one
# clip, as are RPT / RT / Maint / Maintain / Routine.
const Synonyms = {
  "die": "death",
  "walk": "walkforward",
  "walkfwd": "walkforward",
  "walkfront": "walkforward",
  "walkback": "walkbackward",
  "walkbwd": "walkbackward",
  "walklft": "walkleft",
  "walkrgt": "walkright",
  "run": "runforward",
  "runfwd": "runforward",
  "flyfwd": "flyforward",
  "flybwd": "flybackward",
  "flylft": "flyleft",
  "flyrgt": "flyright",
  "taunt": "taunting",
  "defense": "defend",
  "idledefense": "defend",
  "defensegethit": "defendhit",
  "idledefensegethit": "defendhit",
  "sensesomethingst": "sensesomethingstart",
  "sensesomethingrpt": "sensesomethingloop",
  "sensesomethingrt": "sensesomethingloop",
  "sensesomethingmaint": "sensesomethingloop",
  "sensesomethingmaintain": "sensesomethingloop",
  "sensesomethingroutine": "sensesomethingloop",
  "sentrywalkfront": "sentrywalkforward",
}.toTable

const Canonical = {
  "idlenormal": "IdleNormal",
  "idlebattle": "IdleBattle",
  "idlechest": "IdleChest",
  "idleplant": "IdlePlant",
  "idleplanttobattle": "IdlePlantToBattle",
  "walkforward": "WalkForward",
  "walkbackward": "WalkBackward",
  "walkleft": "WalkLeft",
  "walkright": "WalkRight",
  "sentrywalkforward": "SentryWalkForward",
  "runforward": "RunForward",
  "flyforward": "FlyForward",
  "flybackward": "FlyBackward",
  "flyleft": "FlyLeft",
  "flyright": "FlyRight",
  "flyfwdfast": "FlyForwardFast",
  "attack01": "Attack01",
  "attack02": "Attack02",
  "attack03": "Attack03",
  "attack04": "Attack04",
  "attack02st": "Attack02Start",
  "attack02rpt": "Attack02Loop",
  "attack05st": "Attack05Start",
  "attack05rpt": "Attack05Loop",
  "attack05rptswing": "Attack05LoopSwing",
  "death": "Death",
  "gethit": "GetHit",
  "dizzy": "Dizzy",
  "taunting": "Taunting",
  "victory": "Victory",
  "defend": "Defend",
  "defendhit": "DefendHit",
  "sensesomethingstart": "SenseSomethingStart",
  "sensesomethingloop": "SenseSomethingLoop",
  "grounddivein": "GroundDiveIn",
  "groundbreakthrough": "GroundBreakThrough",
}.toTable

# The Mushroom and Cactus ship every clip twice, once per facial mood. The
# mood is kept as a suffix so both survive and neither shadows the other.
const Moods = ["angry", "smile"]

# First match wins. A role with no match is omitted from the manifest rather
# than pointed at a clip that means something else.
const Roles = [
  ("idle", @["IdleNormal", "IdleBattle", "IdleChest", "IdlePlant"]),
  ("idleBattle", @["IdleBattle", "IdleNormal"]),
  ("move", @["RunForward", "WalkForward", "FlyForward", "SentryWalkForward"]),
  ("walk", @["WalkForward", "FlyForward", "SentryWalkForward", "RunForward"]),
  ("walkBack", @["WalkBackward", "FlyBackward"]),
  ("walkLeft", @["WalkLeft", "FlyLeft"]),
  ("walkRight", @["WalkRight", "FlyRight"]),
  ("attack", @["Attack01", "Attack02Start", "Attack05Start"]),
  ("attackAlt", @["Attack02", "Attack02Start", "Attack03", "Attack04",
                  "Attack05Start"]),
  ("death", @["Death"]),
  ("hit", @["GetHit"]),
  ("dizzy", @["Dizzy"]),
  ("taunt", @["Taunting"]),
  ("victory", @["Victory"]),
  ("defend", @["Defend"]),
  ("alert", @["SenseSomethingStart"]),
  ("alertLoop", @["SenseSomethingLoop"]),
  ("burrow", @["GroundDiveIn"]),
  ("emerge", @["GroundBreakThrough"]),
]

# `move` is deliberately not required: the Worm Monster is stationary and
# travels by burrowing, so it has no locomotion clip at all.
const RequiredRoles = ["idle", "attack", "death", "hit"]

proc canonicalClip(fileStem: string, aliases: seq[string], strict = true): string =
  ## Maps an animation file name onto the canonical clip vocabulary.
  ##
  ## Every wave decorates the clip name with the monster differently:
  ## Attack01_Orc_Anim (wave 1), Attack01 (wave 2), Cyclops_Attack01
  ## (wave 3). Monster tokens are stripped from either end, but only when
  ## what remains is itself canonical, so a clip that legitimately contains
  ## its monster's name survives.
  var stem = fileStem
  if stem.toLowerAscii.endsWith("_anim"):
    stem = stem[0 ..< ^5]
  elif stem.toLowerAscii.endsWith("anim"):
    stem = stem[0 ..< ^4]
  var key = squash(stem)

  var mood = ""
  for candidate in Moods:
    if key.endsWith(candidate):
      mood = candidate
      key = key[0 ..< ^candidate.len]
      break

  proc resolve(text: string): string =
    Canonical.getOrDefault(Synonyms.getOrDefault(text, text), "")

  var name = resolve(key)
  if name.len == 0:
    for alias in aliases.sortedByIt(-it.len):
      if alias.len < 2:
        continue
      let trimmed = [
        if key.startsWith(alias): key[alias.len .. ^1] else: "",
        if key.endsWith(alias): key[0 ..< ^alias.len] else: "",
      ]
      for candidate in trimmed:
        if candidate.len > 0:
          name = resolve(candidate)
          if name.len > 0:
            break
      if name.len > 0:
        break

  if name.len == 0:
    if strict:
      raise newException(
        ConversionError,
        fileStem & ": no canonical clip name for '" & key & "'")
    return fileStem
  name & mood.capitalizeAscii

proc resolveRoles(clips: seq[string]): OrderedTable[string, string] =
  ## Picks a clip for each role from the ones a monster actually has.
  ##
  ## Mood-suffixed clips are considered only as a fallback, so the Mushroom's
  ## roles land on its Angry set rather than an arbitrary mix.
  var plainClips: seq[string]
  for clip in clips:
    if not Moods.anyIt(clip.endsWith(it.capitalizeAscii)):
      plainClips.add(clip)
  for (role, preferences) in Roles:
    for clip in preferences:
      # Each preference is tried plain first, then mood-suffixed,
      # before moving on — otherwise the Mushroom's idle would fall
      # through every mood clip and land on IdlePlant, its dormant
      # state, rather than IdleNormalAngry.
      if clip in plainClips:
        result[role] = clip
        break
      # Only a mood suffix counts as a match, never any clip that
      # merely shares the prefix — otherwise Attack02 would happily
      # resolve to the Beholder's Attack02Loop.
      var moody: seq[string]
      for mood in Moods:
        if clip & mood.capitalizeAscii in clips:
          moody.add(clip & mood.capitalizeAscii)
      if moody.len > 0:
        result[role] = moody[0]
        break

## Pack traversal

proc monsterRecords(wave: Wave): seq[MonsterRecord] =
  ## One resolved record per monster of a wave.
  for entry in wave.monsters:
    let display = entry.monster
    proc fill(pattern: string): string =
      pattern.replace("{compact}", display.replace(" ", ""))
        .replace("{monster}", display)
    let mesh = fill(if entry.mesh.len > 0: entry.mesh else: wave.mesh)
    result.add(MonsterRecord(
      wave: wave.key,
      display: display,
      key: snakeKey(display),
      aliases: @[squash(display)] & ExtraAliases.getOrDefault(display, @[]),
      mesh: wave.directory / mesh,
      animations: wave.directory / fill(wave.animations),
    ))

proc allRecords(): seq[MonsterRecord] =
  for wave in Waves:
    result.add(monsterRecords(wave))

proc selectedRecords(names: seq[string]): seq[MonsterRecord] =
  let records = allRecords()
  if names.len == 0:
    return records
  result = records.filterIt(it.key in names)
  let missing = names.filterIt(it notin records.mapIt(it.key)).sorted
  if missing.len > 0:
    quit("unknown monster(s): " & missing.join(", "), 1)

proc checkLayout(source: string, records: seq[MonsterRecord]) =
  ## Fails fast when a mesh or animation directory is missing.
  var problems: seq[string]
  let albedo = source / AlbedoSource
  if not fileExists(albedo):
    problems.add(albedo)
  for record in records:
    if not fileExists(source / record.mesh):
      problems.add(record.mesh)
    if not dirExists(source / record.animations):
      problems.add(record.animations)
  if problems.len > 0:
    quit("missing source paths:\n  " & problems.join("\n  "), 1)

## Monster build

proc buildMonster(
    source, outDir: string, record: MonsterRecord, embed, allowUnknown: bool,
    binary: string, jobs: int
): JsonNode =
  ## Converts one monster; returns its manifest entry.
  var sources: Table[string, string]

  proc clipNameFor(fileName: string): string =
    result = canonicalClip(
      fileName.splitFile.name, record.aliases, strict = not allowUnknown)
    sources[result] = fileName

  let base = buildCharacter(
    source / record.mesh, source / record.animations, clipNameFor, binary,
    freezeAttachments = true, parallel = jobs)

  if embed:
    base.injectTexture(outDir / AlbedoName)
  else:
    base.attachExternalTexture(AlbedoName, "monsters_albedo")
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

  let (lo, hi) = bindPoseBounds(base)
  let target = outDir / (record.key & ".glb")
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

  let skinned = doc["nodes"].getElems.filterIt("skin" in it)
  %*{
    "key": record.key,
    "name": record.display,
    "wave": record.wave,
    "path": record.key & ".glb",
    "mesh": (if skinned.len > 0: skinned[0]{"name"}.getStr("") else: ""),
    "attachments": meshNodes.filterIt("skin" notin it).mapIt(it{"name"}.getStr("")),
    "nativeHeight": round(hi.y - lo.y, 4),
    "groundOffset": round(-lo.y, 4),
    "joints": skins[0]["joints"].len,
    "nodes": doc["nodes"].len,
    "bytes": getFileSize(target),
    "clips": clips,
    "roles": roles,
  }

## Self-test

proc selfTest(source: string): int =
  ## Maps every animation file name in the pack with no FBX2glTF calls.
  var total = 0
  var failures: seq[string]
  for wave in Waves:
    echo &"\n== {wave.directory}"
    for record in monsterRecords(wave):
      var names: seq[string]
      for fileName in animationFiles(source / record.animations):
        inc total
        try:
          names.add(canonicalClip(fileName.splitFile.name, record.aliases))
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
      for (role, _) in Roles:
        if role in roles:
          summary.add(role & "=" & roles[role])
      echo &"  {record.key:<16} {names.len:>3} clips  {summary.join(\" \")}"
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

  check(fileExists(outDir / manifest["albedo"].getStr),
    "missing shared texture " & manifest["albedo"].getStr)

  for monster in manifest["monsters"]:
    let path = outDir / monster["path"].getStr
    let label = monster["key"].getStr
    let glb = checkGlbFile(path, failures, label)
    if glb == nil:
      continue
    let doc = glb.doc
    let skins = doc{"skins"}.getElems
    check(skins.len == 1, label & ": expected 1 skin")
    if skins.len > 0:
      let joints = skins[0]["joints"]
      check(joints.len == monster["joints"].getInt,
        label & ": " & $joints.len & " joints, manifest says " &
        $monster["joints"].getInt)
      check(joints.getElems.allIt(it.getInt >= 0 and it.getInt < doc["nodes"].len),
        label & ": joint index out of range")
    checkAnimations(
      glb, monster["clips"].getElems.mapIt(it["name"].getStr), failures, label)
    let (lo, hi) = bindPoseBounds(glb)
    let height = hi.y - lo.y
    check(abs(height - monster["nativeHeight"].getFloat) < 0.001,
      &"{label}: height {height:.4f} != manifest {monster[\"nativeHeight\"].getFloat}")
    check(0.2 < height and height < 20.0,
      &"{label}: implausible height {height:.4f}")

  if failures.len > 0:
    echo &"FAILED {failures.len} check(s):"
    for failure in failures:
      echo "  ", failure
    return 1
  echo &"verified {manifest[\"monsters\"].len} models, all checks passed"
  0

## Driver

proc writeManifest(outDir: string, built: seq[JsonNode], partial: bool) =
  ## Writes manifest.json, merging into any existing partial build.
  let path = outDir / "manifest.json"
  var monsters: Table[string, JsonNode]
  if partial and fileExists(path):
    for entry in parseJson(readFile(path)){"monsters"}.getElems:
      monsters[entry["key"].getStr] = entry
  for entry in built:
    monsters[entry["key"].getStr] = entry

  var ordered: seq[JsonNode]
  for record in allRecords():
    if record.key in monsters:
      ordered.add(monsters[record.key])
  let manifest = %*{
    "pack": "rpg_monsters",
    "source": "RPGMonsterBundlePBR",
    "generator": "tools/build_rpg_monsters.nim",
    "albedo": AlbedoName,
    "monsters": ordered,
  }
  createDir(outDir)
  writeFile(path, manifest.pretty & "\n")
  echo "wrote ", path

proc main(): int =
  var
    source = DefaultSource
    outDir = DefaultOut
    monsterNames: seq[string]
    textureSize = DefaultTextureSize
    jobs = countProcessors()
    forceTextures, skipTextures, embedTexture = false
    allowUnknownClips, selfTestOnly, verifyOnly = false
  var parser = initOptParser(
    commandLineParams(),
    longNoVal = @[
      "force-textures", "skip-textures", "embed-texture",
      "allow-unknown-clips", "self-test", "verify"])
  for kind, key, value in parser.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "source": source = expandTilde(value)
      of "out": outDir = value
      of "monster": monsterNames.add(value)
      of "texture-size": textureSize = parseInt(value)
      of "jobs": jobs = parseInt(value)
      of "force-textures": forceTextures = true
      of "skip-textures": skipTextures = true
      of "embed-texture": embedTexture = true
      of "allow-unknown-clips": allowUnknownClips = true
      of "self-test": selfTestOnly = true
      of "verify": verifyOnly = true
      else: quit("unknown option --" & key, 1)
    of cmdArgument: quit("unexpected argument " & key, 1)
    of cmdEnd: discard

  if selfTestOnly:
    checkLayout(source, allRecords())
    return selfTest(source)
  if verifyOnly:
    return verify(outDir)

  let records = selectedRecords(monsterNames)
  checkLayout(source, records)

  if not skipTextures:
    let target = outDir / AlbedoName
    if writeTexture(source / AlbedoSource, target, textureSize, "rgb", forceTextures):
      echo &"texture {AlbedoName} {getFileSize(target).float / 1e6:.2f} MB"

  echo &"converting {records.len} monster(s), {jobs} FBX2glTF process(es) at a time"
  let binary = fbx2gltfBinary()
  var built: seq[JsonNode]
  for record in records:
    let entry = buildMonster(
      source, outDir, record, embedTexture, allowUnknownClips, binary, jobs)
    built.add(entry)
    let attachments = entry["attachments"].getElems.mapIt(it.getStr)
    let suffix = if attachments.len > 0: "+" & attachments.join(",") else: ""
    echo &"  {entry[\"path\"].getStr:<26} {entry[\"joints\"].getInt:>3} joints " &
      &"{entry[\"clips\"].len:>2} clips  h={entry[\"nativeHeight\"].getFloat:>6.3f}  " &
      &"{entry[\"bytes\"].getInt.float / 1e3:>6.0f} KB  {suffix}"

  writeManifest(outDir, built, monsterNames.len > 0)
  0

when isMainModule:
  quit(main())
