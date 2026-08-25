## Retargets Unity "Humanoid" animation clips from one rig onto another using
## the avatar data Unity leaves in each FBX's .meta file.
##
## Unity's humanoid pipeline maps every rig onto a shared set of human bone
## names (Hips, Spine, LeftUpperArm, ...) and stores the rig's T-pose in the
## .meta under humanDescription. That is enough to retarget without Unity:
##
##   for each human bone at time t
##     delta      = sourceWorldRot(t) * inverse(sourceTPoseWorldRot)
##     targetRot  = delta * targetTPoseWorldRot
##
## i.e. the source's world-space rotation away from its T-pose is applied to
## the target's T-pose. Hips translation is carried over scaled by the ratio of
## the two rigs' T-pose hip heights. Bones the target has but the source lacks
## (or vice versa) keep their bind pose.
##
## Coordinates: Unity is left-handed, glTF right-handed. Unity mirrors X on
## import, so avatar transforms are converted with position (-x, y, z) and
## rotation (x, -y, -z, w) before use, putting them in the same frame as the
## FBX2glTF output.
##
## Used by tools/build_modular_chars.nim; the CLI here retargets one clip for
## iterating on a rig pair. Run from the repo root:
##   nim r tools/humanoid_retarget.nim target.glb target.fbx.meta \
##       clip.fbx clip.fbx.meta out.glb

import
  std/[algorithm, json, strutils, tables],
  vmath,
  fbx_to_glb

## Quaternions (x, y, z, w) and vectors, all float64 like the accessors'
## float32 keys deserve.

proc qConj*(q: DQuat): DQuat =
  dvec4(-q.x, -q.y, -q.z, q.w)

proc qNormalize*(q: DQuat): DQuat =
  let n = length(q)
  if n == 0:
    return dvec4(0, 0, 0, 1)
  q / n

proc qSlerp*(a, b: DQuat, u: float): DQuat =
  qNormalize(slerp(a, b, u))

proc identityQuat(): DQuat =
  dvec4(0, 0, 0, 1)

proc nodeTranslation(node: JsonNode): DVec3 =
  ## A node's translation, or the origin.
  if "translation" notin node:
    return dvec3(0, 0, 0)
  let t = node["translation"]
  dvec3(t[0].getFloat, t[1].getFloat, t[2].getFloat)

proc nodeRotation(node: JsonNode): DQuat =
  ## A node's rotation, normalized, or identity.
  if "rotation" notin node:
    return identityQuat()
  let r = node["rotation"]
  qNormalize(dvec4(r[0].getFloat, r[1].getFloat, r[2].getFloat, r[3].getFloat))

## Unity avatar description

const HumanBoneOrder* = [
  "Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
  "LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
  "RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
  "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes",
  "RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes",
]

type
  TPoseEntry* = object
    parent*: string
    position*: DVec3
    rotation*: DQuat

  Avatar* = ref object
    ## A rig's humanoid description as read from its Unity .meta file.
    ##
    ## human: humanName -> boneName for the bones this rig maps.
    ## tpose: boneName -> (parentName, position, rotation) in glTF handedness.
    human*: OrderedTable[string, string]
    tpose*: Table[string, TPoseEntry]

proc parseYamlVec(text: string): seq[float] =
  ## Parses "{x: 1, y: 2, z: 3}" (or with w) into its numbers in order.
  for part in text.strip(chars = {' ', '{', '}'}).split(','):
    result.add(parseFloat(part.split(':')[1].strip))

proc newAvatar*(metaPath: string): Avatar =
  ## Reads the humanDescription block of a Unity .meta file.
  let text = readFile(metaPath)
  let start = text.find("humanDescription:")
  if start < 0:
    raise newException(
      ConversionError, metaPath & ": no humanDescription block")
  let description = text[start .. ^1]
  let humanBlock =
    description[description.find("human:") ..< description.find("skeleton:")]
  result = Avatar()
  var bone = ""
  for line in humanBlock.splitLines:
    let stripped = line.strip
    if stripped.startsWith("- boneName: "):
      bone = stripped["- boneName: ".len .. ^1].strip
    elif stripped.startsWith("boneName: "):
      bone = stripped["boneName: ".len .. ^1].strip
    elif stripped.startsWith("humanName: "):
      result.human[stripped["humanName: ".len .. ^1].strip] = bone
  let skeletonLines =
    description[description.find("skeleton:") .. ^1].splitLines
  var i = 0

  proc takeMapping(prefix: string): string =
    ## The flow mapping starting at line i, which Unity wraps over several
    ## lines when it runs long; empty when the line is not that mapping.
    if i >= skeletonLines.len or not skeletonLines[i].strip.startsWith(prefix):
      return ""
    while i < skeletonLines.len:
      result.add(skeletonLines[i].strip)
      inc i
      if result.endsWith("}"):
        break
    result = result[prefix.len .. ^1]

  while i < skeletonLines.len:
    let nameLine = skeletonLines[i].strip
    inc i
    if not nameLine.startsWith("- name: "):
      continue
    if i >= skeletonLines.len or
        not skeletonLines[i].strip.startsWith("parentName:"):
      continue
    let parent = skeletonLines[i].strip["parentName:".len .. ^1].strip
    inc i
    let position = takeMapping("position:")
    let rotation = takeMapping("rotation:")
    if position.len == 0 or rotation.len == 0:
      continue
    let name = nameLine["- name: ".len .. ^1].strip
    if name in result.tpose:
      continue  # first occurrence wins; deform bones are unique
    let
      p = parseYamlVec(position)
      r = parseYamlVec(rotation)
    result.tpose[name] = TPoseEntry(
      parent: parent,
      position: dvec3(-p[0], p[1], p[2]),
      rotation: qNormalize(dvec4(r[0], -r[1], -r[2], r[3])),
    )
  if result.tpose.len == 0:
    raise newException(
      ConversionError, metaPath & ": no skeleton T-pose entries")
  for human, bone in result.human:
    if bone notin result.tpose:
      raise newException(
        ConversionError,
        metaPath & ": human bone " & human & " maps to " & bone &
        ", which has no T-pose entry")

proc tposeWorld*(avatar: Avatar, bone: string): tuple[rot: DQuat, pos: DVec3] =
  ## World rotation and position of a bone in the T-pose.
  var
    rotation = identityQuat()
    position = dvec3(0, 0, 0)
    chain: seq[TPoseEntry]
    current = bone
  while current.len > 0:
    let entry = avatar.tpose[current]
    chain.add(entry)
    current = if entry.parent in avatar.tpose: entry.parent else: ""
  for i in countdown(chain.high, 0):
    position = position + quatRotate(rotation, chain[i].position)
    rotation = quatMultiply(rotation, chain[i].rotation)
  (qNormalize(rotation), position)

## Source clip sampling

type
  Track = object
    times: seq[float]
    vec3s: seq[DVec3]
    quats: seq[DQuat]

proc keyBounds(times: seq[float], t: float): tuple[lo, hi: int, u: float] =
  ## The key pair bracketing time t and the blend between them.
  var lo = 0
  var hi = times.high
  while hi - lo > 1:
    let mid = (lo + hi) div 2
    if times[mid] <= t:
      lo = mid
    else:
      hi = mid
  let span = times[hi] - times[lo]
  (lo, hi, if span > 0: (t - times[lo]) / span else: 0.0)

proc sampleVec3(track: Track, t: float): DVec3 =
  if t <= track.times[0]:
    return track.vec3s[0]
  if t >= track.times[^1]:
    return track.vec3s[^1]
  let (lo, hi, u) = keyBounds(track.times, t)
  mix(track.vec3s[lo], track.vec3s[hi], u)

proc sampleQuat(track: Track, t: float): DQuat =
  if t <= track.times[0]:
    return track.quats[0]
  if t >= track.times[^1]:
    return track.quats[^1]
  let (lo, hi, u) = keyBounds(track.times, t)
  qSlerp(track.quats[lo], track.quats[hi], u)

proc readScalars(glb: Glb, accessorIndex: int): seq[float] =
  for value in unpackFloats(glb.accessorBytes(accessorIndex)):
    result.add(value.float)

proc readVec3s(glb: Glb, accessorIndex: int): seq[DVec3] =
  let flat = unpackFloats(glb.accessorBytes(accessorIndex))
  for i in countup(0, flat.high, 3):
    result.add(dvec3(flat[i].float, flat[i + 1].float, flat[i + 2].float))

proc readQuats(glb: Glb, accessorIndex: int): seq[DQuat] =
  let flat = unpackFloats(glb.accessorBytes(accessorIndex))
  for i in countup(0, flat.high, 4):
    result.add(dvec4(
      flat[i].float, flat[i + 1].float, flat[i + 2].float, flat[i + 3].float))

type
  SourceClip = ref object
    ## One converted animation FBX: node tree plus per-node tracks.
    ##
    ## A file whose take never moves (FBX2glTF drops it as "zero channels") is
    ## a held pose: its node transforms are the pose, sampled as a two-key
    ## constant clip.
    nodes: seq[JsonNode]
    parent: Table[int, int]
    byName: Table[string, int]
    tracks: Table[(int, string), Track]
    times: seq[float]
    duration: float

proc newSourceClip(glb: Glb): SourceClip =
  let doc = glb.doc
  let animations = doc{"animations"}.getElems
  if animations.len > 1:
    raise newException(
      ConversionError,
      "expected at most one animation, found " & $animations.len)
  result = SourceClip(nodes: doc["nodes"].getElems)
  for i, node in result.nodes:
    for child in nodeChildren(node):
      result.parent[child] = i
  for i, node in result.nodes:
    let name = node{"name"}.getStr("")
    if name notin result.byName:
      result.byName[name] = i
  if animations.len == 0:
    result.times = @[0.0, StaticPoseSeconds]
    result.duration = StaticPoseSeconds
    return
  let animation = animations[0]
  var times: seq[float]
  for channel in animation["channels"]:
    let sampler = animation["samplers"][channel["sampler"].getInt]
    let path = channel["target"]["path"].getStr
    var track = Track(times: readScalars(glb, sampler["input"].getInt))
    if path == "rotation":
      for q in readQuats(glb, sampler["output"].getInt):
        track.quats.add(qNormalize(q))
    elif path == "translation" or path == "scale":
      track.vec3s = readVec3s(glb, sampler["output"].getInt)
    result.tracks[(channel["target"]["node"].getInt, path)] = track
    for t in track.times:
      if t notin times:
        times.add(t)
  times.sort()
  result.times = times
  result.duration = if times.len > 0: times[^1] else: 0.0

proc local(clip: SourceClip, index: int, t: float): tuple[pos: DVec3, rot: DQuat] =
  let node = clip.nodes[index]
  result = (nodeTranslation(node), nodeRotation(node))
  if (index, "translation") in clip.tracks:
    result.pos = clip.tracks[(index, "translation")].sampleVec3(t)
  if (index, "rotation") in clip.tracks:
    result.rot = clip.tracks[(index, "rotation")].sampleQuat(t)

proc world(
    clip: SourceClip, index: int, t: float,
    cache: var Table[int, tuple[rot: DQuat, pos: DVec3]]
): tuple[rot: DQuat, pos: DVec3] =
  ## World rotation and position of a node at time t (scale ignored).
  if index in cache:
    return cache[index]
  let (pos, rot) = clip.local(index, t)
  if index notin clip.parent:
    result = (rot, pos)
  else:
    let (parentRot, parentPos) = clip.world(clip.parent[index], t, cache)
    result = (
      qNormalize(quatMultiply(parentRot, rot)),
      parentPos + quatRotate(parentRot, pos),
    )
  cache[index] = result

## Retargeting

type
  Retargeter* = ref object
    ## Retargets clips onto one target rig held in a Glb.
    target: Glb
    avatar: Avatar
    nodes: seq[JsonNode]
    parent: Table[int, int]
    boneIndex: Table[string, int]  ## boneName -> node index
    humanOf: Table[int, string]    ## node index -> humanName
    skeleton: seq[int]             ## every node under the hips, parents first
    hips: int
    hipsParentWorld: tuple[rot: DQuat, pos: DVec3]
    tposeWorld: Table[int, tuple[rot: DQuat, pos: DVec3]]

proc newRetargeter*(target: Glb, targetAvatar: Avatar): Retargeter =
  result = Retargeter(
    target: target, avatar: targetAvatar, nodes: target.doc["nodes"].getElems)
  for i, node in result.nodes:
    for child in nodeChildren(node):
      result.parent[child] = i
  var byName: Table[string, int]
  for i, node in result.nodes:
    let name = node{"name"}.getStr("")
    if name notin byName:
      byName[name] = i
  for human, bone in targetAvatar.human:
    if bone notin byName:
      raise newException(
        ConversionError,
        "target rig lacks node " & bone & " for human bone " & human)
    result.boneIndex[bone] = byName[bone]
    result.humanOf[byName[bone]] = human
  let hips = result.boneIndex[targetAvatar.human["Hips"]]
  # Every node under the hips is part of the skeleton and gets keyed,
  # in parent-before-child order.
  var pending = @[hips]
  while pending.len > 0:
    let index = pending[0]
    pending.delete(0)
    result.skeleton.add(index)
    pending.add(nodeChildren(result.nodes[index]))
  result.hips = hips
  # The hips' ancestors never animate: their bind world transform is
  # the frame the whole retargeted skeleton hangs from.
  var
    rot = identityQuat()
    pos = dvec3(0, 0, 0)
    chain: seq[tuple[pos: DVec3, rot: DQuat]]
    index = hips
  while index in result.parent:
    index = result.parent[index]
    let node = result.nodes[index]
    chain.add((nodeTranslation(node), nodeRotation(node)))
  for i in countdown(chain.high, 0):
    pos = pos + quatRotate(rot, chain[i].pos)
    rot = quatMultiply(rot, chain[i].rot)
  result.hipsParentWorld = (qNormalize(rot), pos)
  for bone, index in result.boneIndex:
    result.tposeWorld[index] = targetAvatar.tposeWorld(bone)

proc retarget*(
    retargeter: Retargeter, sourceGlb: Glb, sourceAvatar: Avatar,
    clipName: string, bounce = 1.0
): seq[string] =
  ## Adds one retargeted clip to the target Glb.
  ##
  ## bounce scales the hips' vertical travel away from its T-pose height.
  ## Hop-heavy locomotion authored for a small character turns into moon
  ## gravity on a taller one (the hop grows with the hip-height ratio while
  ## the cycle time stays put); values below 1 pull it back down without
  ## touching the leg rotations. Rotations, and the sideways/forward hip
  ## motion, are unaffected.
  ##
  ## Returns the list of human bones the source animates that the target
  ## lacks, so callers can decide whether that loses anything they care
  ## about (fingers, usually).
  let source = newSourceClip(sourceGlb)
  var sourceBones: OrderedTable[string, int]  # humanName -> source node index
  for human, bone in sourceAvatar.human:
    if bone in source.byName:
      sourceBones[human] = source.byName[bone]
  var sourceTpose: Table[string, tuple[rot: DQuat, pos: DVec3]]
  for human in sourceBones.keys:
    sourceTpose[human] = sourceAvatar.tposeWorld(sourceAvatar.human[human])
  for human in sourceBones.keys:
    if human notin retargeter.avatar.human:
      result.add(human)
  result.sort()
  if "Hips" notin sourceBones:
    raise newException(ConversionError, clipName & ": source has no Hips")

  let sourceHipsHeight = sourceTpose["Hips"].pos.y
  let targetHipsHeight = retargeter.tposeWorld[retargeter.hips].pos.y
  if sourceHipsHeight <= 0:
    raise newException(
      ConversionError,
      clipName & ": source hips T-pose height is " & $sourceHipsHeight)
  let heightScale = targetHipsHeight / sourceHipsHeight

  let times = source.times
  var rotations: Table[int, seq[DQuat]]
  for index in retargeter.skeleton:
    rotations[index] = @[]
  var hipsPositions: seq[DVec3]
  for t in times:
    var cache: Table[int, tuple[rot: DQuat, pos: DVec3]]
    var world: Table[int, tuple[rot: DQuat, pos: DVec3]]
    for index in retargeter.skeleton:
      let (parentRot, parentPos) =
        if index == retargeter.hips:
          retargeter.hipsParentWorld
        else:
          world[retargeter.parent[index]]
      let node = retargeter.nodes[index]
      let bindPos = nodeTranslation(node)
      let bindRot = nodeRotation(node)
      let human = retargeter.humanOf.getOrDefault(index, "")
      var rot: DQuat
      var srcPos: DVec3
      if human in sourceBones:
        let (sourceRot, sourcePos) = source.world(sourceBones[human], t, cache)
        srcPos = sourcePos
        let delta = quatMultiply(sourceRot, qConj(sourceTpose[human].rot))
        rot = qNormalize(quatMultiply(delta, retargeter.tposeWorld[index].rot))
      else:
        rot = qNormalize(quatMultiply(parentRot, bindRot))
      var pos: DVec3
      if index == retargeter.hips:
        var offset = (srcPos - sourceTpose["Hips"].pos) * heightScale
        offset.y = offset.y * bounce
        pos = retargeter.tposeWorld[index].pos + offset
        hipsPositions.add(quatRotate(qConj(parentRot), pos - parentPos))
      else:
        pos = parentPos + quatRotate(parentRot, bindPos)
      world[index] = (rot, pos)
      rotations[index].add(qNormalize(quatMultiply(qConj(parentRot), rot)))

  # Keep quaternion keys on one hemisphere so linear playback never
  # takes the long way round.
  for keys in rotations.mvalues:
    for i in 1 ..< keys.len:
      if dot(keys[i - 1], keys[i]) < 0:
        keys[i] = -keys[i]

  let target = retargeter.target
  var timeValues: seq[float32]
  for t in times:
    timeValues.add(t.float32)
  let timeAccessor = target.addAccessor(
    packFloats(timeValues), 5126, "SCALAR", times.len,
    @[times[0]], @[times[^1]])
  var samplers = newJArray()
  var channels = newJArray()

  proc add(index: int, path: string, payload: string, kind: string, count: int) =
    samplers.add(%*{
      "input": timeAccessor,
      "output": target.addAccessor(payload, 5126, kind, count),
      "interpolation": "LINEAR",
    })
    channels.add(%*{
      "sampler": samplers.len - 1,
      "target": {"node": index, "path": path},
    })

  for index in retargeter.skeleton:
    var flat: seq[float32]
    for q in rotations[index]:
      flat.add([q.x.float32, q.y.float32, q.z.float32, q.w.float32])
    add(index, "rotation", packFloats(flat), "VEC4", rotations[index].len)
  var flat: seq[float32]
  for p in hipsPositions:
    flat.add([p.x.float32, p.y.float32, p.z.float32])
  add(retargeter.hips, "translation", packFloats(flat), "VEC3", hipsPositions.len)
  if "animations" notin target.doc:
    target.doc["animations"] = newJArray()
  target.doc["animations"].add(%*{
    "name": clipName, "samplers": samplers, "channels": channels})

when isMainModule:
  import std/[os, tempfiles]

  let args = commandLineParams()
  if args.len < 5:
    quit(
      "usage: humanoid_retarget target.glb target.fbx.meta clip.fbx " &
      "clip.fbx.meta out.glb", 1)
  let (targetPath, targetMeta, clipPath, clipMeta, outPath) =
    (args[0], args[1], args[2], args[3], args[4])
  let binary = fbx2gltfBinary()
  let target = readGlb(targetPath)
  let retargeter = newRetargeter(target, newAvatar(targetMeta))
  let tmp = createTempDir("polyworld_", "")
  let clip = readGlb(convert(binary, clipPath, tmp / "clip"))
  removeDir(tmp)
  let name = clipPath.splitFile.name
  let unmatched = retargeter.retarget(clip, newAvatar(clipMeta), name)
  target.write(outPath)
  echo "wrote ", outPath, " clip ", name, " unmatched human bones: ",
    (if unmatched.len > 0: unmatched.join(", ") else: "none")
