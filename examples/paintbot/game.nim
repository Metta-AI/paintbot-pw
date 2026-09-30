import std/[os, strutils, json]
import jsony
import polyworld/[cli, tapes]
import sim, bots, controls, kinship, match_config
export match_config
when defined(coworld): import polyworld/coworld

type
  Frame* = object
    ## One tick: every seat's command (one per seat) and the state hash after the step.
    commands*: seq[Command]
    hash*: uint32
  Frame16 = object
    ## A frame as every recording before rules 46 stores it: exactly LegacySeats commands.
    commands: array[LegacySeats, Command]
    hash: uint32
  LegacyCommand = object
    walk, shoot, direct: bool
    goal, aim: Point
  LegacyFrame = object
    commands: array[LegacySeats, LegacyCommand]
    hash: uint32
  LegacyRecording = object
    seed*: int32
    frames*: seq[LegacyFrame]
  Communication* = object
    tick*, slot*: int
    text*: string
  PreSoundCommand = object
    walk, shoot, direct: bool
    goal, aim: Point
    chargeGrenade: bool
  PreSoundFrame = object
    commands: array[LegacySeats, PreSoundCommand]
    hash: uint32
  PriorRecording = object
    seed*: int32
    frames*: seq[PreSoundFrame]
    names*: array[LegacySeats, string]
    communications*: seq[Communication]
  PreSoundRecording = object
    seed: int32
    frames: seq[PreSoundFrame]
    names: array[LegacySeats, string]
    communications: seq[Communication]
    endTick: int32
  PreMapRecording = object
    seed: int32
    frames: seq[Frame16]
    names: array[LegacySeats, string]
    communications: seq[Communication]
    endTick: int32
  PreVisionRecording = object
    ## Teams recordings at rules 41: Recording without the vision mode.
    seed: int32
    frames: seq[Frame16]
    names: array[LegacySeats, string]
    communications: seq[Communication]
    endTick: int32
    map: string
  PreGloryRecording = object
    ## Teams recordings at rules 42: Recording without the glory awards.
    seed: int32
    frames: seq[Frame16]
    names: array[LegacySeats, string]
    communications: seq[Communication]
    endTick: int32
    map: string
    vision: string
  PreCogsGloryConfig = object
    ## GloryConfig at rules 43-46: without the rules-47 behind-in-cogs award.
    quietSupplies, quietSupplySeconds, behindLives, behindLivesSeconds, heart: int32
  Recording43 = object
    ## Teams recordings at rules 43-45: Recording with 16 seats in fixed arrays.
    seed: int32
    frames: seq[Frame16]
    names: array[LegacySeats, string]
    communications: seq[Communication]
    endTick: int32
    map: string
    vision: string
    glory: PreCogsGloryConfig
  Recording46 = object
    ## Teams recordings at rules 46: Recording with the rules 43-46 glory awards.
    seed: int32
    frames: seq[Frame]
    names: seq[string]
    communications: seq[Communication]
    endTick: int32
    map: string
    vision: string
    glory: PreCogsGloryConfig
    seats: int32
  Recording* = object
    ## A match as the engine and viewer hold it, and (from rules 46) as a teams recording
    ## stores it: one command per seat in every frame and one name per seat.
    seed*: int32
    frames*: seq[Frame]
    names*: seq[string]
    communications*: seq[Communication]
    endTick*: int32
    map*: string ## rules 41: a MapNames entry, or "" for the rules' own island
    vision*: string ## rules 42 teams games: "" per-cog sight lines, or "team" shared vision
    glory*: GloryConfig = DefaultGloryConfig ## rules 43 teams games: the glory awards the match paid
    seats*: int32 ## rules 46: the match's seat count (LegacySeats for every older recording)
  PreMapRecordingFfa = object
    ## FFA-kin recordings at gameVersion 1040: RecordingFfa41 without the map.
    seed: int32
    frames: seq[Frame16]
    names: array[LegacySeats, string]
    communications: seq[Communication]
    endTick: int32
    mode: uint8
    layout: uint8
    family: array[LegacySeats, int8]
    genes: array[LegacySeats, uint32]
    ibd: array[LegacySeats, array[LegacySeats, int8]]
  RecordingFfa41 = object
    ## FFA-kin recordings at rules 41-45: RecordingFfa with 16 seats in fixed arrays.
    seed: int32
    frames: seq[Frame16]
    names: array[LegacySeats, string]
    communications: seq[Communication]
    endTick: int32
    map: string
    mode: uint8
    layout: uint8
    family: array[LegacySeats, int8]
    genes: array[LegacySeats, uint32]
    ibd: array[LegacySeats, array[LegacySeats, int8]]
  RecordingFfa* = object
    ## FFA-kin recordings (gameVersion 1000 + rules) from rules 46: Recording's fields, then
    ## the mode and the match's kinship, so a replay plays the recorded families even under a
    ## kinship override. Every per-seat list holds `seats` entries.
    seed*: int32
    frames*: seq[Frame]
    names*: seq[string]
    communications*: seq[Communication]
    endTick*: int32
    map*: string
    seats*: int32
    mode*: uint8
    layout*: uint8
    family*: seq[int8]
    genes*: seq[uint32]
    ibd*: seq[seq[int8]]
  RecordingRanged = object
    ## Teams recordings with a vision range (gameVersion VisionRangeReplayVersionBase + rules):
    ## Recording, then the range in metres.
    recording: Recording
    visionRange: int32
  RecordingFfaRanged = object
    ## FFA-kin recordings with a vision range (gameVersion VisionRangeReplayVersionBase +
    ## FfaReplayVersionBase + rules): RecordingFfa, then the range in metres.
    ffa: RecordingFfa
    visionRange: int32
  BridgeReply = object
    ## The host's answer to one bridge line: settled advisor-oracle requests, nothing else.
    oracle: seq[OracleReply]
type LegacyMetadataRecording = object
  seed: int32
  frames: seq[LegacyFrame]
  names: array[LegacySeats, string]
  communications: seq[Communication]
proc convertFrames(frames: seq[LegacyFrame]): seq[Frame] =
  for f in frames:
    var next = Frame(hash: f.hash, commands: newSeq[Command](LegacySeats))
    for i, c in f.commands:
      next.commands[i] = Command(walk: c.walk, shoot: c.shoot, direct: c.direct,
          goal: c.goal, aim: c.aim)
    result.add next
proc convertFrames(frames: seq[PreSoundFrame]): seq[Frame] =
  for f in frames:
    var next = Frame(hash: f.hash, commands: newSeq[Command](LegacySeats))
    for i, c in f.commands:
      next.commands[i] = Command(walk: c.walk, shoot: c.shoot, direct: c.direct,
        goal: c.goal, aim: c.aim, chargeGrenade: c.chargeGrenade)
    result.add next
proc convertFrames(frames: seq[Frame16]): seq[Frame] =
  for f in frames: result.add Frame(hash: f.hash, commands: @(f.commands))
proc toFrames16(frames: seq[Frame]): seq[Frame16] =
  ## Frames for a pre-46 recording, which only 16-seat matches can make.
  for f in frames:
    if f.commands.len != LegacySeats:
      raise newException(ReplayError, "Recordings before rules 46 hold exactly 16 seats")
    var next = Frame16(hash: f.hash)
    for i, c in f.commands: next.commands[i] = c
    result.add next
proc toLegacyFrames(frames: seq[Frame]): seq[LegacyFrame] =
  for f in toFrames16(frames):
    var next = LegacyFrame(hash: f.hash)
    for i, c in f.commands:
      next.commands[i] = LegacyCommand(walk: c.walk, shoot: c.shoot, direct: c.direct, goal: c.goal, aim: c.aim)
    result.add next
proc toPreSoundFrames(frames: seq[Frame]): seq[PreSoundFrame] =
  for f in toFrames16(frames):
    var next = PreSoundFrame(hash: f.hash)
    for i, c in f.commands:
      next.commands[i] = PreSoundCommand(walk: c.walk, shoot: c.shoot, direct: c.direct,
        goal: c.goal, aim: c.aim, chargeGrenade: c.chargeGrenade)
    result.add next
proc toNames16(names: seq[string]): array[LegacySeats, string] =
  for i in 0..<min(names.len, LegacySeats): result[i] = names[i]
proc toArray16[T](values: seq[T]): array[LegacySeats, T] =
  for i in 0..<min(values.len, LegacySeats): result[i] = values[i]
proc toIbd16(ibd: seq[seq[int8]]): array[LegacySeats, array[LegacySeats, int8]] =
  for i in 0..<min(ibd.len, LegacySeats): result[i] = toArray16(ibd[i])
proc ibdSeq(ibd: array[LegacySeats, array[LegacySeats, int8]]): seq[seq[int8]] =
  for row in ibd: result.add @row
var replayRulesVersion* = LiveRules
const
  FfaReplayVersionBase* = 1000 ## FFA-kin recordings are stamped 1000 + rules (1048 today).
  FfaRulesVersions = [40, 41, 42, 43, 44, 45, 46, 47, 48]
  SeatCountRules* = 46 ## The first rules whose recordings carry their seat count.
  BehindCogsRules* = 47 ## The first rules whose recordings carry the behind-in-cogs award.
  VisionRangeReplayVersionBase* = 2000
    ## A match played with a "vision_range" (sim.visionRangeMetres) is stamped 2000 over its
    ## usual version (2048 teams, 3048 FFA-kin today) and stores the range after the usual
    ## payload. A match without one saves exactly as before. Like FFA kinship, the range is
    ## the thread's: saving reads it, loading binds it (0 for every other recording).
  VisionRangeRules* = 48 ## The first rules whose recordings may carry a vision range.
proc toPreCogs(g: GloryConfig): PreCogsGloryConfig =
  PreCogsGloryConfig(quietSupplies: g.quietSupplies, quietSupplySeconds: g.quietSupplySeconds,
    behindLives: g.behindLives, behindLivesSeconds: g.behindLivesSeconds, heart: g.heart)
proc fromPreCogs(g: PreCogsGloryConfig): GloryConfig =
  ## Rules 43-46 awards; the behind-in-cogs award keeps its default (those rules never pay it).
  GloryConfig(quietSupplies: g.quietSupplies, quietSupplySeconds: g.quietSupplySeconds,
    behindLives: g.behindLives, behindLivesSeconds: g.behindLivesSeconds, heart: g.heart,
    behindCogs: DefaultGloryConfig.behindCogs, behindCogsSeconds: DefaultGloryConfig.behindCogsSeconds)
proc replayGameVersion*(): uint16 =
  ## The header version a recording made now is saved with.
  uint16((if visionRangeMetres() > 0: VisionRangeReplayVersionBase else: 0) +
    (if ffa(): FfaReplayVersionBase else: 0) + replayRulesVersion)
proc checkRangedRules(rules: int) =
  if visionRangeMetres() > 0 and rules notin VisionRangeRules..LiveRules:
    raise newException(ReplayError, "Recordings with a vision range need rules " &
      $VisionRangeRules & ".." & $LiveRules)
proc toFfaRecording(r: Recording, k: Kinship): RecordingFfa =
  RecordingFfa(seed: r.seed, frames: r.frames, names: r.names, communications: r.communications,
    endTick: r.endTick, map: r.map, seats: r.seats, mode: gameMode.uint8, layout: k.layout.uint8,
    family: k.family, genes: k.genes, ibd: k.ibd)
proc saveRecordingAs*(path: string, version: int, r: Recording) =
  ## A teams recording in exactly the shape loadRecording reads at `version`; every version
  ## before rules 46 holds 16 seats. With a vision range, the ranged shape (rules 48 on).
  checkRangedRules(version)
  let v = version.uint16
  if version < SeatCountRules and r.frames.len > 0 and r.frames[0].commands.len != LegacySeats:
    raise newException(ReplayError, "Recordings before rules 46 hold exactly 16 seats")
  if version >= SeatCountRules:
    var r = r
    if r.seats == 0: r.seats = (if r.names.len > 0: r.names.len else: Seats).int32
    if visionRangeMetres() > 0:
      saveReplayFile(path, "paintbot_pw", uint16(VisionRangeReplayVersionBase+version),
        RecordingRanged(recording: r, visionRange: visionRangeMetres().int32))
    elif version >= BehindCogsRules: saveReplayFile(path, "paintbot_pw", v, r)
    else: saveReplayFile(path, "paintbot_pw", v, Recording46(seed: r.seed, frames: r.frames,
      names: r.names, communications: r.communications, endTick: r.endTick, map: r.map,
      vision: r.vision, glory: toPreCogs(r.glory), seats: r.seats))
  elif version >= 43:
    saveReplayFile(path, "paintbot_pw", v, Recording43(seed: r.seed, frames: toFrames16(r.frames),
      names: toNames16(r.names), communications: r.communications, endTick: r.endTick, map: r.map,
      vision: r.vision, glory: toPreCogs(r.glory)))
  elif version == 42:
    saveReplayFile(path, "paintbot_pw", v, PreGloryRecording(seed: r.seed, frames: toFrames16(r.frames),
      names: toNames16(r.names), communications: r.communications, endTick: r.endTick, map: r.map,
      vision: r.vision))
  elif version == 41:
    saveReplayFile(path, "paintbot_pw", v, PreVisionRecording(seed: r.seed, frames: toFrames16(r.frames),
      names: toNames16(r.names), communications: r.communications, endTick: r.endTick, map: r.map))
  elif version >= 26:
    saveReplayFile(path, "paintbot_pw", v, PreMapRecording(seed: r.seed, frames: toFrames16(r.frames),
      names: toNames16(r.names), communications: r.communications, endTick: r.endTick))
  elif version >= 23:
    saveReplayFile(path, "paintbot_pw", v, PreSoundRecording(seed: r.seed, frames: toPreSoundFrames(r.frames),
      names: toNames16(r.names), communications: r.communications, endTick: r.endTick))
  elif version >= 6:
    saveReplayFile(path, "paintbot_pw", v, PriorRecording(seed: r.seed, frames: toPreSoundFrames(r.frames),
      names: toNames16(r.names), communications: r.communications))
  elif version >= 2:
    saveReplayFile(path, "paintbot_pw", v, LegacyMetadataRecording(seed: r.seed,
      frames: toLegacyFrames(r.frames), names: toNames16(r.names), communications: r.communications))
  else:
    saveReplayFile(path, "paintbot_pw", v, LegacyRecording(seed: r.seed, frames: toLegacyFrames(r.frames)))
proc saveRecording*(path: string, r: Recording) =
  ## Teams games keep the rules-numbered Recording; FFA-kin adds the mode and kinship. Each
  ## version is written in the shape its loader reads; before rules 46 that is 16 fixed seats.
  var r = r
  if r.seats == 0: r.seats = Seats.int32
  if replayRulesVersion < SeatCountRules and r.seats != LegacySeats:
    raise newException(ReplayError, "Recordings before rules 46 hold exactly 16 seats")
  if ffa():
    let k = activeKinship
    checkRangedRules(replayRulesVersion)
    if visionRangeMetres() > 0:
      saveReplayFile(path, "paintbot_pw", replayGameVersion(), RecordingFfaRanged(
        ffa: r.toFfaRecording(k), visionRange: visionRangeMetres().int32))
    elif replayRulesVersion >= SeatCountRules:
      saveReplayFile(path, "paintbot_pw", replayGameVersion(), r.toFfaRecording(k))
    elif replayRulesVersion >= 41:
      saveReplayFile(path, "paintbot_pw", replayGameVersion(), RecordingFfa41(seed: r.seed,
        frames: toFrames16(r.frames), names: toNames16(r.names), communications: r.communications,
        endTick: r.endTick, map: r.map, mode: gameMode.uint8, layout: k.layout.uint8,
        family: toArray16(k.family), genes: toArray16(k.genes), ibd: toIbd16(k.ibd)))
    else:
      saveReplayFile(path, "paintbot_pw", replayGameVersion(), PreMapRecordingFfa(seed: r.seed,
        frames: toFrames16(r.frames), names: toNames16(r.names), communications: r.communications,
        endTick: r.endTick, mode: gameMode.uint8, layout: k.layout.uint8,
        family: toArray16(k.family), genes: toArray16(k.genes), ibd: toIbd16(k.ibd)))
  else: saveRecordingAs(path, replayRulesVersion, r)
proc validSeatCount(seats: int32): bool = seats.int in 2..MaxSeats
proc loadFfaRecording(path: string, version: int, ranged: bool, visionRange: var int32): Recording =
  ## version: the header's, less VisionRangeReplayVersionBase when ranged (then visionRange is
  ## the recorded range on return).
  let rules = version - FfaReplayVersionBase
  if rules notin FfaRulesVersions or (ranged and rules notin VisionRangeRules..LiveRules):
    raise newException(ReplayError, "Unsupported Paintbot FFA replay version")
  let old =
    if ranged:
      let pre = loadReplayFile(path, "paintbot_pw", uint16(VisionRangeReplayVersionBase+version),
        RecordingFfaRanged)
      visionRange = pre.visionRange
      pre.ffa
    elif rules >= SeatCountRules: loadReplayFile(path, "paintbot_pw", version.uint16, RecordingFfa)
    elif rules >= 41:
      let pre = loadReplayFile(path, "paintbot_pw", version.uint16, RecordingFfa41)
      RecordingFfa(seed: pre.seed, frames: convertFrames(pre.frames), names: @(pre.names),
        communications: pre.communications, endTick: pre.endTick, map: pre.map,
        seats: LegacySeats, mode: pre.mode, layout: pre.layout, family: @(pre.family),
        genes: @(pre.genes), ibd: ibdSeq(pre.ibd))
    else:
      let pre = loadReplayFile(path, "paintbot_pw", version.uint16, PreMapRecordingFfa)
      RecordingFfa(seed: pre.seed, frames: convertFrames(pre.frames), names: @(pre.names),
        communications: pre.communications, endTick: pre.endTick, seats: LegacySeats,
        mode: pre.mode, layout: pre.layout, family: @(pre.family), genes: @(pre.genes),
        ibd: ibdSeq(pre.ibd))
  if old.map.len > 0 and old.map notin MapNames: # an unknown map is an invalid replay
    raise newException(ReplayError, "Unknown Paintbot map in FFA replay")
  let n = old.seats.int
  if not validSeatCount(old.seats) or old.names.len != n or old.family.len != n or
      old.genes.len != n or old.ibd.len != n:
    raise newException(ReplayError, "Invalid Paintbot FFA seat count")
  if old.mode != gmFfaKin.uint8 or old.layout > KinLayout.high.uint8:
    raise newException(ReplayError, "Invalid Paintbot FFA kinship")
  var k = Kinship(layout: KinLayout(old.layout), family: old.family, genes: old.genes, ibd: old.ibd)
  for i in 0..<n:
    if k.ibd[i].len != n or k.family[i] notin -1'i8..<n.int8 or k.ibd[i][i] != Loci.int8:
      raise newException(ReplayError, "Invalid Paintbot FFA kinship")
    for j in 0..<n:
      if k.ibd[i][j] notin 0'i8..Loci.int8 or k.ibd[i][j] != k.ibd[j][i]:
        raise newException(ReplayError, "Invalid Paintbot FFA kinship")
  replayRulesVersion = rules
  visionRulesVersion = rules
  gameMode = gmFfaKin
  activeKinship = k
  kinshipOverride = some(k)
  Recording(seed: old.seed, frames: old.frames, names: old.names,
    communications: old.communications, endTick: old.endTick, map: old.map, seats: old.seats)
proc loadRecording*(path: string): Recording =
  ## Loads a recording, binds its rules, mode, map, vision, vision range, glory awards and seat
  ## count (configureSeats), and checks its shape.
  var version = loadReplayFileHeader(path).gameVersion.int
  # A vision range stamps VisionRangeReplayVersionBase over the usual version; 0 = none.
  let ranged = version >= VisionRangeReplayVersionBase
  if ranged: version -= VisionRangeReplayVersionBase
  var visionRange = 0'i32
  # A replay sets the mode it was played in; teams replays never inherit an FFA override.
  gameMode = gmTeams
  kinshipOverride = none(Kinship)
  replayRulesVersion = version
  visionRulesVersion = replayRulesVersion
  if version >= FfaReplayVersionBase:
    result = loadFfaRecording(path, version, ranged, visionRange)
  elif ranged:
    if replayRulesVersion notin VisionRangeRules..LiveRules:
      raise newException(ReplayError, "Unsupported Paintbot replay version")
    let old = loadReplayFile(path, "paintbot_pw", uint16(VisionRangeReplayVersionBase+version),
      RecordingRanged)
    result = old.recording
    visionRange = old.visionRange
    discard mapIndex(result.map) # an unknown map is an invalid replay
    if result.vision != "": raise newException(ReplayError, "A vision range needs per-cog vision")
    if not validGloryConfig(result.glory): raise newException(ReplayError, "Invalid Paintbot glory awards")
  elif replayRulesVersion == 1:
    let old = loadReplayFile(path, "paintbot_pw", 1, LegacyRecording)
    result.seed = old.seed
    result.frames = convertFrames(old.frames)
  elif replayRulesVersion in [2, 3, 4, 5]:
    let old = loadReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, LegacyMetadataRecording)
    result = Recording(seed: old.seed, frames: convertFrames(old.frames),
        names: @(old.names), communications: old.communications)
  elif replayRulesVersion in [6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22]:
    let old = loadReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, PriorRecording)
    result = Recording(seed:old.seed,frames:convertFrames(old.frames),names: @(old.names),communications:old.communications)
  elif replayRulesVersion in [23, 24, 25]:
    let old = loadReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, PreSoundRecording)
    result = Recording(seed:old.seed,frames:convertFrames(old.frames),names: @(old.names),
      communications:old.communications,endTick:old.endTick)
  elif replayRulesVersion in [26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40]:
    let old = loadReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, PreMapRecording)
    result = Recording(seed: old.seed, frames: convertFrames(old.frames), names: @(old.names),
      communications: old.communications, endTick: old.endTick)
  elif replayRulesVersion == 41:
    let old = loadReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, PreVisionRecording)
    result = Recording(seed: old.seed, frames: convertFrames(old.frames), names: @(old.names),
      communications: old.communications, endTick: old.endTick, map: old.map)
    discard mapIndex(result.map) # an unknown map is an invalid replay
  elif replayRulesVersion == 42:
    let old = loadReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, PreGloryRecording)
    result = Recording(seed: old.seed, frames: convertFrames(old.frames), names: @(old.names),
      communications: old.communications, endTick: old.endTick, map: old.map, vision: old.vision)
    discard mapIndex(result.map) # an unknown map is an invalid replay
    if result.vision notin ["", "team"]: raise newException(ReplayError, "Unknown Paintbot vision mode")
  elif replayRulesVersion in [43, 44, 45]: # 44 and 45 changed routing only; the format is 43's
    let old = loadReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, Recording43)
    result = Recording(seed: old.seed, frames: convertFrames(old.frames), names: @(old.names),
      communications: old.communications, endTick: old.endTick, map: old.map, vision: old.vision,
      glory: fromPreCogs(old.glory))
    discard mapIndex(result.map) # an unknown map is an invalid replay
    if result.vision notin ["", "team"]: raise newException(ReplayError, "Unknown Paintbot vision mode")
    if not validGloryConfig(result.glory): raise newException(ReplayError, "Invalid Paintbot glory awards")
  elif replayRulesVersion == SeatCountRules:
    let old = loadReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, Recording46)
    result = Recording(seed: old.seed, frames: old.frames, names: old.names,
      communications: old.communications, endTick: old.endTick, map: old.map, vision: old.vision,
      glory: fromPreCogs(old.glory), seats: old.seats)
    discard mapIndex(result.map) # an unknown map is an invalid replay
    if result.vision notin ["", "team"]: raise newException(ReplayError, "Unknown Paintbot vision mode")
    if not validGloryConfig(result.glory): raise newException(ReplayError, "Invalid Paintbot glory awards")
  elif replayRulesVersion in BehindCogsRules..LiveRules:
    # Rules 48 (the FFA-kin fog of war) changed no recorded field: the rules 47 shape.
    result = loadReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, Recording)
    discard mapIndex(result.map) # an unknown map is an invalid replay
    if result.vision notin ["", "team"]: raise newException(ReplayError, "Unknown Paintbot vision mode")
    if not validGloryConfig(result.glory): raise newException(ReplayError, "Invalid Paintbot glory awards")
  else:
    raise newException(ReplayError, "Unsupported Paintbot replay version")
  if replayRulesVersion < SeatCountRules: result.seats = LegacySeats
  if ranged and visionRange notin 1'i32..MaxVisionRangeMetres.int32:
    raise newException(ReplayError, "Invalid Paintbot vision range")
  if not validSeatCount(result.seats) or result.names.len notin [0, result.seats.int]:
    raise newException(ReplayError, "Invalid Paintbot seat count")
  for f in result.frames:
    if f.commands.len != result.seats.int: raise newException(ReplayError, "Invalid Paintbot seat count")
  configureSeats(result.seats.int)
  result.names.setLen(Seats)
  # Recordings before rules 43, and every FFA recording, paid the default awards.
  if replayRulesVersion < 43 or ffa(): result.glory = DefaultGloryConfig
  if replayRulesVersion < 23: result.endTick = MatchTicks
  elif result.endTick <= 0 or result.endTick > 28800:
    raise newException(ReplayError, "Invalid match duration")
  if result.frames.len > 28800 or result.communications.len > 20000:
    raise newException(ReplayError, "Replay limits exceeded")
  for i in 0..<Seats:
    if result.names[i].len == 0: result.names[i] =
      if ffa(): "Cog " & $(i + 1)
      else: (if team(i) == 0: "Ember" else: "Azure") & " " & $(i div 2 + 1)
    if result.names[i].len > 256: raise newException(ReplayError, "Invalid player name")
  for item in result.communications:
    if item.slot notin 0..<Seats or item.tick notin 0..result.frames.len or
        item.text.len > 1024:
      raise newException(ReplayError, "Invalid communication")
  # Bind the recorded map too, so replay analysis that rebuilds the world with newWorld
  # (replay_stats, the viewer's index, kin_replay_counters) plays on the recorded ground.
  configureMap(result.map)
  configureVision(result.vision)
  configureVisionRange(visionRange.int)
  configureGlory(result.glory)
var
  world*: World
  recording*: Recording
  replayMode*: bool
  options*: GameOptions
  players: seq[Bot]
  bridge: File
  mapChoice*: string ## live games: --map:<name>, or the Coworld config's "map"
  visionChoice*: string ## live teams games: --vision:team, or the Coworld config's "vision"
  visionRangeChoice*: int ## live games: --vision-range:<metres>, or the Coworld config's "vision_range"
  gloryChoice* = DefaultGloryConfig ## live teams games: --glory:<json>, or the Coworld config's "glory"
proc applyGameConfig*(text: string) =
  ## Reads the keys CoworldConfig skips. An FFA-kin match lasts at most six minutes.
  let config = parseJson(text)
  gameMode = parseGameMode(config)
  kinLayoutPin = parseKinLayout(config, gameMode)
  let glory = config{"glory"}
  if not glory.isNil and glory.kind != JNull and ffa():
    raise newException(ValueError, "Paintbot glory awards apply to the teams game only")
  gloryChoice = parseGloryConfig(glory)
  visionRangeChoice = parseVisionRange(config)
  if ffa():
    options.maximumTicks = min(options.maximumTicks, FfaMatchTicks.int32)
    options.seconds = options.maximumTicks div TickRate
proc newLiveWorld*(seed, maximumTicks: int32): World =
  ## A live match's world. It draws its kinship from its own seed, never from a replay this
  ## process loaded earlier: loadRecording leaves kinshipOverride set so replay analysis (the
  ## viewer's index, replay_stats) can rebuild the recorded world with newWorld.
  kinshipOverride = none(Kinship)
  newWorld(seed, maximumTicks)
proc setup*() =
  when defined(coworld):
    # The seat count is the game config's roster: one player token per seat.
    let configText = readLocal(getEnv("COGAME_CONFIG_URI"))
    configureSeats(parseJson(configText){"tokens"}.len)
    options = coworldOptions(Seats)
    applyGameConfig(configText)
  else:
    options = GameOptions(seed: 2026, maximumTicks: HeartMeterMatchTicks, speed: 1)
    let args = commandLineParams(); var i = 0
    while i < args.len:
      if args[i].startsWith("--map:"):
        mapChoice = args[i]["--map:".len..^1]; discard mapIndex(mapChoice); inc i; continue
      if args[i].startsWith("--mode:"):
        # Local play and recording: "--mode:ffa_kin" plays Heartland (a match lasts at most 6:00).
        gameMode = parseGameMode(%*{"mode": args[i]["--mode:".len..^1]})
        if ffa(): options.maximumTicks = min(options.maximumTicks, FfaMatchTicks.int32)
        inc i; continue
      if args[i].startsWith("--kin-layout:"):
        # With --mode:ffa_kin (earlier on the line): pin a kin layout, e.g. "--kin-layout:tribes".
        kinLayoutPin = parseKinLayout(%*{"kin_layout": args[i]["--kin-layout:".len..^1]}, gameMode)
        inc i; continue
      if args[i].startsWith("--vision:"):
        visionChoice = args[i]["--vision:".len..^1]; configureVision(visionChoice); inc i; continue
      if args[i].startsWith("--vision-range:"):
        # Metres of per-cog sight, as the Coworld config's "vision_range" (1..200).
        let text = args[i]["--vision-range:".len..^1]
        let node = (try: newJInt(parseInt(text)) except ValueError: newJString(text))
        visionRangeChoice = parseVisionRange(%*{"vision_range": node})
        inc i; continue
      if args[i].startsWith("--glory:"):
        gloryChoice = parseGloryConfig(parseJson(args[i]["--glory:".len..^1])); inc i; continue
      if not options.takeCommonFlag(args, i, args[i]): raise newException(
          ValueError, "Unknown argument: "&args[i])
      inc i
  when not defined(coworld):
    # A live local game seats every --bot plus the human player; a replay sets its own count.
    if options.replayPath.len == 0:
      configureSeats(options.botGroups.botCount + (if options.playerSlot != 0: 1 else: 0))
    options.validateGameOptions(Seats, "live games seat 2 to " & $MaxSeats & " bots")
  replayMode = options.replayPath.len > 0
  if replayMode:
    recording = loadRecording(options.replayPath)
    if recording.frames.len > 28800: raise newException(ValueError, "Replay tick limit exceeded")
    configureMap(recording.map)
    configureVision(recording.vision)
    configureGlory(recording.glory)
    world = newWorld(recording.seed, recording.endTick)
  else:
    # The recording header and live simulation must use the same rules.
    configureRules(replayRulesVersion)
    when defined(coworld): mapChoice = config.map
    configureMap(mapChoice); recording.map = mapName()
    when defined(coworld): visionChoice = config.vision
    if visionChoice.len > 0 and ffa():
      raise newException(ValueError, "Team vision applies to the teams game only")
    configureVision(visionChoice); recording.vision = visionMode()
    checkVisionRange(visionRangeChoice, visionMode())
    configureVisionRange(visionRangeChoice) # saveRecording records it
    configureGlory(gloryChoice); recording.glory = gloryChoice
    world = newLiveWorld(options.seed, options.maximumTicks); recording.seed = options.seed
    recording.seats = Seats.int32
    recording.names = newSeq[string](Seats)
    recording.endTick = world.endTick
    players = loadBots(options.botGroups, options.playerSlot)
    for i in 0..<Seats:
      recording.names[i] = if i == options.playerSlot-1: "You" else: "Bot " & $(i+1)
    when defined(coworld):
      for i in 0..<min(Seats, config.players.len): recording.names[
          i] = config.players[i].name
    if getEnv("PW_POLICY_FD").len > 0:
      if not open(bridge, FileHandle(parseInt(getEnv("PW_POLICY_FD"))),
          fmReadWrite): raise newException(IOError, "Cannot open policy bridge")
      # The host owns the advisor oracle; it tells the engine when BASIC seats may draft asks.
      oracleEnabled = getEnv("PW_ORACLE") == "1"
      oracleInterval = parseInt(getEnv("PW_ORACLE_INTERVAL", $DefaultOracleInterval))
proc advance*() =
  if replayMode or world.tick < recording.frames.len:
    if world.tick >= recording.frames.len: return
    if world.winner != -1: raise newException(ReplayError, "Replay has frames after victory")
    let f = recording.frames[world.tick]
    world.step(f.commands, replayRulesVersion)
    if world.stateHash() != f.hash: raise newException(ReplayError,
        "Replay hash mismatch at " & $world.tick)
  else:
    var commands = players.decide(world)
    flushPlayerCommands(commands, options.playerSlot.int-1)
    for slot, messages in shouts:
      for message in messages:
        if recording.communications.len < 20000:
          recording.communications.add Communication(tick: world.tick+1,
              slot: slot, text: message)
    if bridge != nil:
      # The bridge carries advisor-oracle traffic only: this tick's BASIC asks go out, and
      # the host's settled answers come back. Seats never act through the host.
      var asks = ""
      for ask in drainOracleAsks():
        asks.add (if asks.len > 0: "," else: "") & "{\"slot\":" & $ask.slot &
            ",\"id\":" & $ask.id & ",\"body\":" & ask.body & "}"
      bridge.writeLine("{\"rulesVersion\":" & $replayRulesVersion & ",\"tick\":" &
          $world.tick & ",\"oracle\":[" & asks & "]}"); bridge.flushFile()
      let reply = bridge.readLine().fromJson(BridgeReply)
      for item in reply.oracle: deliverOracleReply(item)
    deliverSpeech(world)
    world.step(commands)
    recording.frames.add Frame(commands: commands, hash: world.stateHash())
proc matchOutcome*(w: World): string =
  ## results.outcome: FFA-kin matches simply end (winner -3); the scores carry the result.
  if ffa(): "ended" elif w.winner < 0: "time_limit" else: $w.winner
proc runHeadless*() =
  setup()
  let limit = if replayMode: recording.frames.len else: options.maximumTicks.int
  while (world.tick < limit or (not replayMode and replayRulesVersion in 20..22 and limit >= 7200)) and world.winner == -1: advance()
  if replayMode and world.tick != limit: raise newException(ReplayError, "Replay has frames after victory")
  if not replayMode and options.recordPath.len > 0: saveRecording(options.recordPath, recording)
  echo "ticks=", world.tick, " captures=", world.captures, " hash=",
      world.stateHash()
  if getEnv("PW_BASIC_PEAKS") == "1":
    # Budget headroom per seat against the limits in bots.nim (instructions, work units, strings).
    echo "peak_instructions=", peakInstructions
    echo "peak_work=", peakWork
    echo "peak_strings=", peakStrings
    echo "peak_neural_operations=", peakNativeWork
  when defined(coworld):
    # Hosted seat logs are the only per-seat channel a player can read back, so each neural
    # seat's inference cost goes there before the platform's "completed" line.
    if not replayMode: players.logNeuralTelemetry(world.tick, playerLog)
    finishCoworld(NumericCoworldResults[float](scores: world.scores(), ticks: world.tick,
        seed: world.seed, outcome: world.matchOutcome()))
