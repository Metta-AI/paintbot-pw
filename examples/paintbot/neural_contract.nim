## Versioned policy-visible float observations and categorical action heads, built only from a
## seat's SeatView (docs/neural/seat-view.md): every column is a value the seat's BASIC
## builtins can read on the same tick. Used unchanged by BASIC deployment and native rollouts.
## The model's output reaches the engine only through the seat's policy.bas: nothing here
## writes a command.
import std/[math, algorithm]
import polyworld/rngs
import seat_view, contract_hash
from neural_actor import ActorLayout, LayoutSection

const
  ActionSizes* = [51, 25, 2, 2, 2]
  LogitSize* = 82
  ## Observation contract teams.view.1 (the teams game, 16 seats; encodeTeamsView documents
  ## every column) and its action contract (five heads; players/neural_decode.bas is the
  ## reference reading of every index).
  ObservationContractTeamsView1* = "paintbot-pw.teams.view.1"
  ActionContractTeamsView1* = "paintbot-pw.teams.view.1.action.51-25-2-2-2"
  ## Its aim-offset variant: the same five heads, then two 23-bin heads (x, z) the policy.bas
  ## reads as neuralChoice(5) / neuralChoice(6); the reference decode adds
  ## ((ix - 11) * 28, (iz - 11) * 28), mirrored for team 1, to an identity aim point. The
  ## offset is purely the network's choice: nothing native computes a lead.
  ActionContractTeamsView1Offset* = "paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23"
  AimOffsetBins* = 23
  AimOffsetCentre* = 11
  AimOffsetStep* = 28
  AimOffsetHeads* = 2
  ActionSizesOffset* = [51, 25, 2, 2, 2, AimOffsetBins, AimOffsetBins]
  LogitSizeOffset* = LogitSize + 2*AimOffsetBins
  ## Its movement-offset variant: the aim-offset contract's seven heads, then two 23-bin
  ## heads (dx, dz) the policy.bas reads as neuralChoice(7) / neuralChoice(8); the reference
  ## decode adds (moveOffset(dx), moveOffset(dz)), mirrored for team 1, to the movement head's
  ## goal and clamps it to the map. moveOffset is symmetric and log-spaced: bin 11 = 0, bin
  ## 11 ± j = ±MoveOffsetTable[j-1] (16 u .. 4000 u, ratio 250^(1/10)), so one head reaches both
  ## short corrections and far destinations. The destination offset is purely the network's
  ## choice: nothing native computes a goal.
  ActionContractTeamsView1Move* = "paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23-23-23"
  MoveOffsetBins* = 23
  MoveOffsetCentre* = 11
  MoveOffsetTable* = [16, 28, 48, 84, 146, 253, 439, 763, 1326, 2303, 4000]
  MoveOffsetHeads* = 2
  ExtraHeadsMax* = AimOffsetHeads + MoveOffsetHeads
  ActionSizesMove* = [51, 25, 2, 2, 2, AimOffsetBins, AimOffsetBins, MoveOffsetBins, MoveOffsetBins]
  LogitSizeMove* = LogitSizeOffset + 2*MoveOffsetBins
  ## Observation contract ffa.view.1 (FFA-kin at any seat count; its width follows the match,
  ## ffaViewLayout) and its action contract, whose heads are sized by the same layout and
  ## point at the observation's rows of the same tick.
  ObservationContractFfaView1* = "paintbot-pw.ffa.view.1"
  ActionContractFfaView1Pointer* = "paintbot-pw.ffa.view.1.action.pointer"
  ## Its shout variant (opt-in): the pointer contract's five heads, then one shout head (head
  ## 5, ShoutClasses wide) the policy.bas reads as neuralChoice(5): 0 says nothing, c >= 1 says
  ## ShoutVocabulary[c - 1] through BASIC shout(). The vocabulary is exactly what the FFA-kin
  ## baseline (players/ffa.bas) shouts: "hurt" (it lost health) and "at" (where it stands, in
  ## a fight). BASIC shout() takes any text; a neural seat gets that finite set, so it can say
  ## nothing a BASIC seat cannot. The reference decode (players/neural_decode_ffa.bas) makes the
  ## call; nothing native speaks.
  ActionContractFfaView1PointerShout* = "paintbot-pw.ffa.view.1.action.pointer.shout-hurt-at"
  ShoutVocabulary* = ["hurt", "at"]
  ShoutClasses* = 1 + ShoutVocabulary.len
  ShoutHeads* = 1
  ## Observation contract ffa.view.1h (opt-in): ffa.view.1's floats unchanged, then
  ## FfaHeardRows heard-speech rows (encodeFfaHeard): what heardCount / heardText / heardSlot /
  ## heardX / heardY give the seat's BASIC this tick. ffa.view.1hu<K> appends K user inputs
  ## after them, as ffa.view.1u<K> does after ffa.view.1. Native ABI version 203.
  ObservationContractFfaView1Heard* = "paintbot-pw.ffa.view.1h"
  FfaHeardRows* = 16
  FfaHeardWidth* = 8
  FfaHeardSize* = FfaHeardRows*FfaHeardWidth
  NativeObservationFfaHeard* = 203
  ## Heights (SeatView.terrainHeight, centimetres) are divided by this.
  TerrainHeightScale* = 800
  Directions* = [(1,0), (1,1), (0,1), (-1,1), (-1,0), (-1,-1), (0,-1), (1,-1)]
  TeamsSelfSize* = 25
  TeamsHeartRows* = 10
  TeamsHeartWidth* = 10
  TeamsIdentityWidth* = 10
  TeamsPickupRows* = 32
  TeamsPickupWidth* = 5
  TeamsSoundRows* = 8
  TeamsSoundWidth* = 5
  TeamsProbeRows* = 9
  TeamsProbeWidth* = 3
  TeamsHeartOffset* = TeamsSelfSize
  TeamsIdentityOffset* = TeamsHeartOffset + TeamsHeartRows*TeamsHeartWidth
  TeamsPickupOffset* = TeamsIdentityOffset + LegacySeats*TeamsIdentityWidth
  TeamsSoundOffset* = TeamsPickupOffset + TeamsPickupRows*TeamsPickupWidth
  TeamsProbeOffset* = TeamsSoundOffset + TeamsSoundRows*TeamsSoundWidth
  TeamsViewSize* = TeamsProbeOffset + TeamsProbeRows*TeamsProbeWidth
  ## worldTick is divided by this (a ten-minute match); it is the BASIC worldTick, not a countdown.
  TeamsTickScale* = 14400
  ## ffa.view.1 sections.
  FfaHeaderSize* = 24
  FfaCogWidth* = 44
  FfaHeartWidth* = 12
  FfaGreatWidth* = 12
  FfaGreatRows* = 2
  FfaValidColumn* = 0   # every section's row: column 0 is the valid flag
  FfaSeatScale* = 64
  FfaHeartScale* = 100
  ## encodeFfaView mask bit 0 (training ABI only, pw_set_obs_mask): zero every column that
  ## reads kin (cog column 37, heart column 5 of a heart another seat owns, header column 11).
  FfaObsMaskKin* = 1'u32
static:
  doAssert TeamsViewSize == 512
  doAssert FfaCogWidth == 1 + 2 + 1 + 1 + Loci + 1 + 1 + 1 + 1 + 2 + 1

type
  ObservationContractVersion* = enum
    ## Version numbers are the native ABI's (pw_create_observation).
    ocTeamsView1 = 201, ocFfaView1 = 202
  ActionContractVersion* = enum
    acTeamsView1 = 11, acFfaView1Pointer = 12, acTeamsView1Offset = 13, acTeamsView1Move = 14,
    acFfaView1PointerShout = 15

const
  ObservationContractTeamsView1Hash* = sha256Hex(ObservationContractTeamsView1)
  ObservationContractFfaView1Hash* = sha256Hex(ObservationContractFfaView1)
  ActionContractTeamsView1Hash* = sha256Hex(ActionContractTeamsView1)
  ActionContractFfaView1PointerHash* = sha256Hex(ActionContractFfaView1Pointer)
  ActionContractTeamsView1OffsetHash* = sha256Hex(ActionContractTeamsView1Offset)
  ActionContractTeamsView1MoveHash* = sha256Hex(ActionContractTeamsView1Move)
  ActionContractFfaView1PointerShoutHash* = sha256Hex(ActionContractFfaView1PointerShout)
  ObservationContractFfaView1HeardHash* = sha256Hex(ObservationContractFfaView1Heard)

const
  ## Contracts retired for BASIC parity (docs/neural/seat-view.md): their observations read
  ## state a BASIC seat cannot (cooldowns, shield, aim, heart meters, the end tick, cover
  ## probes) or their actions were decoded natively. A package naming one is refused.
  RetiredObservationContractIds* = ["paintbot-pw.rules37.obs.v1.float448",
    "paintbot-pw.rules37.obs.v2.float506", "paintbot-pw.rules43.obs.v3.float514",
    "paintbot-pw.rules40.obs.ffa.v1.float810", "paintbot-pw.rules48.obs.ffa.v2"]
  RetiredActionContractIds* = ["paintbot-pw.rules37.action.v1.51-25-2-2-2",
    "paintbot-pw.rules37.action.v2.51-25-2-2-2", "paintbot-pw.rules48.action.ffa.v2.pointer"]
  MaxUserInputs* = 256
  ## The retired v2u<K> / v3u<K> families existed only up to the cap of their day (128).
  RetiredUserInputsMax* = 128
  UserInputLimit* = 1_000_000'i32

proc userInputsContractId*(k: int, base = ocTeamsView1): string =
  ## Observation contract teams.view.1u<K> (teams.view.1's 512 floats, then K user inputs) or,
  ## with base ocFfaView1, ffa.view.1u<K> (the match's ffa.view.1 floats, then K user inputs).
  ## The user inputs are written only by the seat's policy.bas (neuralInput).
  (if base == ocTeamsView1: ObservationContractTeamsView1 else: ObservationContractFfaView1) & "u" & $k

var retiredHashes {.threadvar.}: seq[string]
var userInputHashes {.threadvar.}: array[ObservationContractVersion, seq[string]]

proc retiredContract*(hash: string): bool =
  ## Whether `hash` names a contract retired for BASIC parity (the v2u<K> / v3u<K> families
  ## included).
  if retiredHashes.len == 0:
    for id in RetiredObservationContractIds: retiredHashes.add sha256Hex(id)
    for id in RetiredActionContractIds: retiredHashes.add sha256Hex(id)
    for k in 1..RetiredUserInputsMax:
      retiredHashes.add sha256Hex("paintbot-pw.rules39.obs.v2u" & $k)
      retiredHashes.add sha256Hex("paintbot-pw.rules43.obs.v3u" & $k)
  hash in retiredHashes

const RetiredMessage* = "was retired for BASIC parity (docs/neural/seat-view.md); retrain on teams.view.1 or ffa.view.1"

proc userInputsContractHash*(k: int, base = ocTeamsView1): string =
  ## The hash of observation contract teams.view.1u<K> (or ffa.view.1u<K>, base ocFfaView1),
  ## K = 1 .. 256.
  if k notin 1..MaxUserInputs: raise newException(ValueError, "no user-input observation contract for that count")
  if userInputHashes[base].len == 0:
    for i in 1..MaxUserInputs: userInputHashes[base].add sha256Hex(userInputsContractId(i, base))
  userInputHashes[base][k-1]

proc userInputsFromHash*(hash: string, base = ocTeamsView1): int =
  ## K when `hash` names observation contract teams.view.1u<K> (or ffa.view.1u<K>, base
  ## ocFfaView1); 0 otherwise.
  for k in 1..MaxUserInputs:
    if userInputsContractHash(k, base) == hash: return k
  0

proc userInputsContract*(hash: string): (ObservationContractVersion, int) =
  ## The base contract and K when `hash` names teams.view.1u<K> or ffa.view.1u<K>; K = 0 otherwise.
  for base in ObservationContractVersion:
    let k = userInputsFromHash(hash, base)
    if k > 0: return (base, k)
  (ocTeamsView1, 0)

proc heardContractId*(k: int): string =
  ## Observation contract ffa.view.1h (k = 0) or ffa.view.1hu<K> (ffa.view.1h's floats, then K
  ## user inputs).
  if k == 0: ObservationContractFfaView1Heard else: ObservationContractFfaView1Heard & "u" & $k

var heardHashes {.threadvar.}: seq[string]

proc heardContractHash*(k: int): string =
  ## The hash of observation contract ffa.view.1h (k = 0) or ffa.view.1hu<K>, K = 1 .. 256.
  if k notin 0..MaxUserInputs: raise newException(ValueError, "no heard-speech observation contract for that count")
  if heardHashes.len == 0:
    for i in 0..MaxUserInputs: heardHashes.add sha256Hex(heardContractId(i))
  heardHashes[k]

proc heardContractFromHash*(hash: string): int =
  ## K when `hash` names ffa.view.1h (0) or ffa.view.1hu<K> (K); -1 otherwise.
  for k in 0..MaxUserInputs:
    if heardContractHash(k) == hash: return k
  -1

proc actionContractHash*(version: ActionContractVersion): string =
  case version
  of acTeamsView1: ActionContractTeamsView1Hash
  of acFfaView1Pointer: ActionContractFfaView1PointerHash
  of acTeamsView1Offset: ActionContractTeamsView1OffsetHash
  of acTeamsView1Move: ActionContractTeamsView1MoveHash
  of acFfaView1PointerShout: ActionContractFfaView1PointerShoutHash
proc actionContractId*(version: ActionContractVersion): string =
  case version
  of acTeamsView1: ActionContractTeamsView1
  of acFfaView1Pointer: ActionContractFfaView1Pointer
  of acTeamsView1Offset: ActionContractTeamsView1Offset
  of acTeamsView1Move: ActionContractTeamsView1Move
  of acFfaView1PointerShout: ActionContractFfaView1PointerShout
proc actionContractVersion*(hash: string): ActionContractVersion =
  ## The contract an actor or manifest hash names; ValueError for anything else.
  if hash == ActionContractTeamsView1Hash: acTeamsView1
  elif hash == ActionContractFfaView1PointerHash: acFfaView1Pointer
  elif hash == ActionContractTeamsView1OffsetHash: acTeamsView1Offset
  elif hash == ActionContractTeamsView1MoveHash: acTeamsView1Move
  elif hash == ActionContractFfaView1PointerShoutHash: acFfaView1PointerShout
  elif retiredContract(hash): raise newException(ValueError, "neural action contract " & RetiredMessage)
  else: raise newException(ValueError, "unknown neural action contract")

proc observationContractHash*(version: ObservationContractVersion): string =
  case version
  of ocTeamsView1: ObservationContractTeamsView1Hash
  of ocFfaView1: ObservationContractFfaView1Hash
proc observationContractId*(version: ObservationContractVersion): string =
  case version
  of ocTeamsView1: ObservationContractTeamsView1
  of ocFfaView1: ObservationContractFfaView1
proc observationSize*(version: ObservationContractVersion): int =
  ## The fixed width of a contract. ffa.view.1's width follows the match (ffaViewLayout):
  ## ValueError here, so no caller can mistake it for a constant.
  case version
  of ocTeamsView1: TeamsViewSize
  of ocFfaView1: raise newException(ValueError, "observation contract ffa.view.1 has a per-match width (ffaViewLayout)")
proc observationContractVersion*(hash: string): ObservationContractVersion =
  ## The contract an actor or manifest hash names; ValueError for anything else.
  if hash == ObservationContractTeamsView1Hash: ocTeamsView1
  elif hash == ObservationContractFfaView1Hash: ocFfaView1
  elif retiredContract(hash): raise newException(ValueError, "neural observation contract " & RetiredMessage)
  else: raise newException(ValueError, "unknown neural observation contract")
proc pairedAction*(version: ObservationContractVersion): ActionContractVersion =
  ## The observation contract's default action contract.
  if version == ocTeamsView1: acTeamsView1 else: acFfaView1Pointer
proc pairs*(observation: ObservationContractVersion, action: ActionContractVersion): bool =
  ## Whether the two contracts go together: teams.view.1 with its five-head action contract
  ## or its aim-offset / movement-offset variants, ffa.view.1 (and its u<K>, h and hu<K>
  ## variants) with its pointer contract or the pointer contract's shout variant.
  if observation == ocTeamsView1: action in {acTeamsView1, acTeamsView1Offset, acTeamsView1Move}
  else: action in {acFfaView1Pointer, acFfaView1PointerShout}
proc shoutClass*(text: string): int =
  ## The shout-head class of a BASIC shout() text: 1 + its index in ShoutVocabulary, 0 for any
  ## other text (no class says it). The behaviour-cloning label of a recorded shout.
  for i, phrase in ShoutVocabulary:
    if text == phrase: return i + 1
  0
proc shoutText*(class: int): string =
  ## What the reference decode shouts for a shout-head class: "" for 0 (nothing).
  if class in 1..ShoutVocabulary.len: ShoutVocabulary[class - 1] else: ""
proc moveOffset*(bin: int): int =
  ## The movement offset (world units, before the team-1 mirror) of a movement-offset bin 0 .. 22:
  ## 0 at the centre bin 11, else ±MoveOffsetTable[|bin - 11| - 1]. players/neural_decode.bas holds
  ## the same table.
  let j = bin - MoveOffsetCentre
  if j == 0: 0 elif j > 0: MoveOffsetTable[j-1] else: -MoveOffsetTable[-j-1]
proc extraHeads*(action: ActionContractVersion): int =
  ## The heads after the five main ones: 2 (aim offsets) under teams.view.1 aim-offset, 4 (aim
  ## then movement offsets) under movement-offset, 1 (shout) under ffa.view.1 pointer shout, 0
  ## otherwise.
  case action
  of acTeamsView1Offset: AimOffsetHeads
  of acTeamsView1Move: AimOffsetHeads + MoveOffsetHeads
  of acFfaView1PointerShout: ShoutHeads
  else: 0
proc actionHeadSizes*(action: ActionContractVersion): seq[int] =
  ## The head sizes of a fixed-size action contract (ffa.view.1 pointer: see pointerHeads).
  case action
  of acTeamsView1: @ActionSizes
  of acTeamsView1Offset: @ActionSizesOffset
  of acTeamsView1Move: @ActionSizesMove
  of acFfaView1Pointer, acFfaView1PointerShout:
    raise newException(ValueError, "action contract ffa.view.1 pointer is sized by the match (pointerHeads)")

proc mapFlip*(slot: int): int =
  ## The teams game mirrors odd seats' observations and compass heads (team 1 plays from
  ## the other side); FFA-kin has no sides, so nothing is mirrored for any seat.
  if team(slot) == 0 or ffa(): 1 else: -1

proc relative(value, side: int): float32 =
  ## 0 for none (-1), 1 for the seat's side, -1 for the other.
  if value < 0: 0'f32
  elif value == side: 1'f32
  else: -1'f32

# ---------------------------------------------------------------------------------------
# Observation contract teams.view.1.
proc encodeTeamsView*(v: SeatView, output: var openArray[float32]) =
  ## Observation contract teams.view.1 (TeamsViewSize = 512 floats), the teams game. Every
  ## column is computed from the seat's SeatView procs (the BASIC builtins of the same name)
  ## and the map constants. flip = mapFlip(slot) (1 team 0, -1 team 1); side = selfTeam;
  ## cx, cz = the map centre ((mapMinX + mapMaxX) / 2, likewise y); spanX = mapMaxX - mapMinX,
  ## spanZ likewise; dx = (x - selfX) * flip / spanX, dz = (y - selfY) * flip / spanZ; "wet" is
  ## waterAt, "dh" is (terrainHeight(point) - terrainHeight(self)) / 800.
  ##   Self (0..24): 0 (selfX - cx) * flip / spanX, 1 (selfY - cz) * flip / spanZ, 2 selfHp/3,
  ##     3 armorHp/3, 4 livesLeft/4, 5 hasGrenade, 6 hasSpray, 7 grenadeCharge/24, 8 carrying,
  ##     9 hasUniform, 10 trenchId >= 0, 11 (selfId div 2)/7, 12 worldTick/14400, 13 self wet,
  ##     14 terrainHeight(self)/800, 15 glory(side)/1000, 16 glory(1-side)/1000,
  ##     17 teamLives(side)/32, 18 teamLives(1-side)/32, 19 teamCogsOut(side)/16,
  ##     20 teamCogsOut(1-side)/16, 21 awardBehind/10, 22 awardBehindSeconds/60,
  ##     23 awardBehindCogs/10, 24 awardBehindCogsSeconds/60
  ##   Heart i (0..9) at 25 + 10i (zeros when i >= heartCount): 0 present, 1 dx, 2 dz,
  ##     3 owner (controlOwner relative to side: 0 none, 1 ours, -1 theirs), 4 capturing team
  ##     (controlCaptureTeam, relative), 5 controlCaptureTicks/72, 6 controlContested,
  ##     7 controlPoints/5, 8 wet, 9 dh
  ##   Identity j (0..15) at 125 + 10j (zeros unless visible(j)): 0 visible, 1 dx, 2 dz
  ##     (playerX/Y), 3 playerTeam relative to side, 4 playerHp/3, 5 playerCarrying, 6 j = selfId,
  ##     7 (j div 2)/7, 8 wet, 9 dh
  ##   Pickup i (0..31) at 285 + 5i (zeros unless pickupVisible(i)): 0 visible, 1 dx, 2 dz,
  ##     3 pickupKind/4, 4 i/31
  ##   Sound i (0..7) at 445 + 5i (zeros for i >= soundCount): 0 present, 1 soundKind/4,
  ##     2 ((soundDirection + (side = 0 ? 0 : 4)) mod 8)/7, 3 soundDistance/4, 4 soundAge/24
  ##   Probe k (0..8) at 485 + 3k: the point self + flip * 200 * compass k (k = 0 self, 1..8
  ##     Directions[k-1]): 0 inside the map bounds, 1 wet, 2 dh
  if output.len != TeamsViewSize: raise newException(ValueError, "invalid neural observation dimensions")
  for i in 0..<output.len: output[i] = 0
  let side = v.selfTeam.int
  let flip = mapFlip(v.slot).float32
  let spanX = float32(v.mapMaxX - v.mapMinX)
  let spanZ = float32(v.mapMaxY - v.mapMinY)
  let cx = (v.mapMinX + v.mapMaxX) div 2
  let cz = (v.mapMinY + v.mapMaxY) div 2
  let sx = v.selfX
  let sz = v.selfY
  let own = v.terrainHeight(sx.int, sz.int)
  const hs = TerrainHeightScale.float32
  template dx(x: int32): float32 = float32(x - sx) * flip / spanX
  template dz(z: int32): float32 = float32(z - sz) * flip / spanZ
  template dh(px, pz: int32): float32 = float32(v.terrainHeight(px.int, pz.int) - own) / hs
  output[0] = float32(sx - cx) * flip / spanX
  output[1] = float32(sz - cz) * flip / spanZ
  output[2] = float32(v.selfHp) / 3
  output[3] = float32(v.armorHp) / 3
  output[4] = float32(v.livesLeft) / 4
  output[5] = float32(v.hasGrenade)
  output[6] = float32(v.hasSpray)
  output[7] = float32(v.grenadeCharge) / 24
  output[8] = float32(v.carrying)
  output[9] = float32(v.hasUniform)
  output[10] = float32((v.trenchId >= 0).int)
  output[11] = float32(v.selfId div 2) / 7
  output[12] = float32(v.worldTick) / TeamsTickScale
  output[13] = float32(v.waterAt(sx.int, sz.int))
  output[14] = float32(own) / hs
  output[15] = float32(v.glory(side)) / 1000
  output[16] = float32(v.glory(1-side)) / 1000
  output[17] = float32(v.teamLives(side)) / 32
  output[18] = float32(v.teamLives(1-side)) / 32
  output[19] = float32(v.teamCogsOut(side)) / 16
  output[20] = float32(v.teamCogsOut(1-side)) / 16
  output[21] = float32(v.awardBehind) / 10
  output[22] = float32(v.awardBehindSeconds) / 60
  output[23] = float32(v.awardBehindCogs) / 10
  output[24] = float32(v.awardBehindCogsSeconds) / 60
  for i in 0..<min(TeamsHeartRows, v.heartCount.int):
    let o = TeamsHeartOffset + i*TeamsHeartWidth
    let x = v.controlX(i)
    let z = v.controlY(i)
    output[o] = 1
    output[o+1] = dx(x)
    output[o+2] = dz(z)
    output[o+3] = relative(v.controlOwner(i).int, side)
    output[o+4] = relative(v.controlCaptureTeam(i).int, side)
    output[o+5] = float32(v.controlCaptureTicks(i)) / HeartCaptureTicks
    output[o+6] = float32(v.controlContested(i))
    output[o+7] = float32(v.controlPoints(i)) / 5
    output[o+8] = float32(v.waterAt(x.int, z.int))
    output[o+9] = dh(x, z)
  for j in 0..<LegacySeats:
    if v.visible(j) == 0: continue
    let o = TeamsIdentityOffset + j*TeamsIdentityWidth
    let x = v.playerX(j)
    let z = v.playerY(j)
    output[o] = 1
    output[o+1] = dx(x)
    output[o+2] = dz(z)
    output[o+3] = relative(v.playerTeam(j).int, side)
    output[o+4] = float32(v.playerHp(j)) / 3
    output[o+5] = float32(v.playerCarrying(j))
    output[o+6] = float32((j == v.selfId.int).int)
    output[o+7] = float32(j div 2) / 7
    output[o+8] = float32(v.waterAt(x.int, z.int))
    output[o+9] = dh(x, z)
  for i in 0..<TeamsPickupRows:
    if v.pickupVisible(i) == 0: continue
    let o = TeamsPickupOffset + i*TeamsPickupWidth
    output[o] = 1
    output[o+1] = dx(v.pickupX(i))
    output[o+2] = dz(v.pickupY(i))
    output[o+3] = float32(v.pickupKind(i)) / 4
    output[o+4] = float32(i) / 31
  for i in 0..<min(TeamsSoundRows, v.soundCount.int):
    let o = TeamsSoundOffset + i*TeamsSoundWidth
    output[o] = 1
    output[o+1] = float32(v.soundKind(i)) / 4
    output[o+2] = float32((v.soundDirection(i).int + (if side == 0: 0 else: 4)) mod 8) / 7
    output[o+3] = float32(v.soundDistance(i)) / 4
    output[o+4] = float32(v.soundAge(i)) / SoundLifetime
  for k in 0..<TeamsProbeRows:
    let delta = if k == 0: (0, 0) else: Directions[k-1]
    let px = sx.int + int(flip) * delta[0] * 200
    let pz = sz.int + int(flip) * delta[1] * 200
    let o = TeamsProbeOffset + k*TeamsProbeWidth
    output[o] = float32((px >= v.mapMinX and px <= v.mapMaxX and pz >= v.mapMinY and pz <= v.mapMaxY).int)
    output[o+1] = float32(v.waterAt(px, pz))
    output[o+2] = float32(v.terrainHeight(px, pz) - own) / hs

# ---------------------------------------------------------------------------------------
# Observation contract ffa.view.1: any seat count, variable-length entity sections.
type
  FfaViewLayout* = object
    ## Where each section of an ffa.view.1 observation lies for a match with `seats` seats and
    ## `hearts` control hearts. Rows are `*Width` floats apart; column FfaValidColumn of every
    ## row is its valid flag. Cog rows: min(seats - 1, 64), nearAgents' own cap.
    seats*, hearts*: int
    cogOffset*, cogRows*: int
    heartOffset*, heartRows*: int
    greatOffset*, greatRows*: int
    size*: int
  FfaViewRows* = object
    ## One seat's row -> entity map for one tick (the view its observation and its
    ## policy.bas both read): the agents (agentsNear order), control heart and great heart
    ## each row describes.
    agents*: seq[ViewAgent]  # row -> the agent (identity and what nearAgentX/Y/Hp/Team read)
    hearts*: seq[int]        # row -> control heart index
    greats*: array[FfaGreatRows, int]  # row -> great heart index

proc ffaViewLayout*(seats, hearts: int): FfaViewLayout =
  if seats notin 2..MaxSeats or hearts < 0:
    raise newException(ValueError, "invalid ffa.view.1 layout: " & $seats & " seats, " & $hearts & " hearts")
  result.seats = seats
  result.hearts = hearts
  result.cogOffset = FfaHeaderSize
  result.cogRows = min(seats - 1, NearMaxAgents)
  result.heartOffset = result.cogOffset + result.cogRows*FfaCogWidth
  result.heartRows = hearts
  result.greatOffset = result.heartOffset + result.heartRows*FfaHeartWidth
  result.greatRows = FfaGreatRows
  result.size = result.greatOffset + result.greatRows*FfaGreatWidth
proc ffaViewLayout*(v: SeatView): FfaViewLayout =
  ## The layout of the view's match: its seats and its control hearts.
  ffaViewLayout(v.seatCount.int, v.heartCount.int)

proc actorLayout*(l: FfaViewLayout, heads: openArray[int], targets = [-1, -1, -1, -1],
    userInputs = 0, heard = false): ActorLayout =
  ## The match layout a PWNET002 model's layout words resolve against for an ffa.view.1 seat:
  ## section 0 the cog rows, 1 the control heart rows, 2 the great heart rows, 3 the control
  ## and great heart rows as one run (they are contiguous and equally wide); `heads` the
  ## action contract's head sizes and `targets` each section's pointer target (the logit
  ## offset of its row 0; -1 none). Under ffa.view.1u<K> (`userInputs` = K) the input count is
  ## l.size + K: the K user inputs are the last K columns, l.size .. l.size + K - 1 (the layout
  ## word section 2 offset + 24 names the first: the great heart rows end there). Under
  ## ffa.view.1h (`heard`) the FfaHeardSize heard-speech columns come first, l.size ..
  ## l.size + FfaHeardSize - 1 (section 2 offset + 24 names the first), then any user inputs.
  result.present = true
  result.inputs = l.size + (if heard: FfaHeardSize else: 0) + userInputs
  result.heads = @heads
  for h in heads: result.outputs += h
  result.sections[0] = LayoutSection(offset: l.cogOffset, rows: l.cogRows, width: FfaCogWidth, target: targets[0])
  result.sections[1] = LayoutSection(offset: l.heartOffset, rows: l.heartRows, width: FfaHeartWidth, target: targets[1])
  result.sections[2] = LayoutSection(offset: l.greatOffset, rows: l.greatRows, width: FfaGreatWidth, target: targets[2])
  result.sections[3] = LayoutSection(offset: l.heartOffset, rows: l.heartRows + l.greatRows, width: FfaHeartWidth,
    target: targets[3])
static: doAssert FfaHeartWidth == FfaGreatWidth

proc ffaViewRows*(v: SeatView): FfaViewRows =
  ## The row order of the seat's ffa.view.1 observation on this tick. Cog rows: exactly
  ## nearAgents(20000)'s list (the agents the seat sees, nearest first, ties by identity, at
  ## most 64). Control heart rows: every heart, nearest first by squared distance from
  ## (selfX, selfY) to (controlX, controlY), ties by index; great heart rows likewise.
  result.agents = v.agentsNear(NearMaxRadius)
  let sx = v.selfX
  let sz = v.selfY
  proc d2(px, pz: int32): int64 = distance2(Point(x: sx, z: sz), Point(x: px, z: pz))
  var hearts: seq[(int64, int)]
  for h in 0..<v.heartCount.int: hearts.add (d2(v.controlX(h), v.controlY(h)), h)
  hearts.sort()
  for key in hearts: result.hearts.add key[1]
  var greats: seq[(int64, int)]
  for g in 0..<FfaGreatRows: greats.add (d2(v.greatHeartX(g), v.greatHeartY(g)), g)
  greats.sort()
  for k, key in greats: result.greats[k] = key[1]

proc encodeFfaView*(v: SeatView, output: var openArray[float32], rows: FfaViewRows, mask = 0'u32) =
  ## Observation contract ffa.view.1 (ffaViewLayout(v).size floats), FFA-kin at any seat count.
  ## No map flip. cx, cz, spanX, spanZ as teams.view.1; "centred x" is (x - cx) / spanX; dx, dz
  ## are the entity's position minus (selfX, selfY) over the spans; "distance" is the Euclidean
  ## distance over the map diagonal sqrt(spanX^2 + spanZ^2); "wet" is waterAt and "dh"
  ## (terrainHeight(point) - terrainHeight(self)) / 800; maxHp is the rules' (10 in FFA-kin).
  ## Every column is computed from SeatView procs (the BASIC builtins of the same name).
  ##   Header (FfaHeaderSize = 24):
  ##     0 centred selfX, 1 centred selfY, 2 selfHp/maxHp, 3 armorHp/maxHp,
  ##     4 seatScore(self)/10000, 5 selfHp > 0, 6 worldTick/8640, 7 livesLeft/4,
  ##     8 seatCount/64, 9 heartCount/100, 10 hearts heartOwner = self / max(1, heartCount),
  ##     11 territoryBoost/30, 12 self wet, 13 terrainHeight(self)/800, 14 cog rows filled/64,
  ##     15 cog rows/64, 16 heart rows/100, 17 great rows/2, 18 hasGrenade, 19 hasSpray,
  ##     20 carrying, 21 trenchId >= 0, 22..23 reserved 0
  ##   Cog rows (FfaCogWidth = 44), rows.agents in order, then zero rows:
  ##     0 valid, 1 dx, 2 dz, 3 visible (1), 4 nearAgentHp/maxHp, 5..36 gene(id, 0..31) (+1 set,
  ##     -1 clear, 0 unknown), 37 kin(id)/100 (0 unknown), 38 seatScore(id)/10000 (0 unknown),
  ##     39 hearts heartOwner = id / 10, 40 distance, 41 wet, 42 dh, 43 id/255
  ##   Control heart rows (FfaHeartWidth = 12), rows.hearts in order:
  ##     0 valid (1), 1 dx, 2 dz, 3 centred x, 4 centred z, 5 owner (-1 none, 1 self, else
  ##     kin(owner)/100, 0 unknown), 6 controlCaptureTicks/72, 7 controlContested, 8 owned by self,
  ##     9 distance, 10 wet, 11 dh
  ##   Great heart rows (FfaGreatWidth = 12), rows.greats in order:
  ##     0 valid (1), 1 dx, 2 dz, 3 centred x, 4 centred z, 5 state (-1 greatHeartDormant > 0,
  ##     1 greatHeartProgress > 0, else 0), 6 greatHeartPresent/16, 7 greatHeartProgress/120,
  ##     8 greatHeartDormant/1440, 9 distance, 10 wet, 11 dh
  ## mask bit 0 (FfaObsMaskKin, training only) zeroes every column that reads kin.
  let layout = v.ffaViewLayout()
  if output.len != layout.size or rows.agents.len > layout.cogRows or rows.hearts.len != layout.heartRows:
    raise newException(ValueError, "invalid neural observation dimensions")
  for i in 0..<output.len: output[i] = 0
  let hideKin = (mask and FfaObsMaskKin) != 0
  let hpScale = float32(maxHp())
  let spanX = float32(v.mapMaxX - v.mapMinX)
  let spanZ = float32(v.mapMaxY - v.mapMinY)
  let cx = (v.mapMinX + v.mapMaxX) div 2
  let cz = (v.mapMinY + v.mapMaxY) div 2
  let diag = sqrt(float64(spanX)*float64(spanX) + float64(spanZ)*float64(spanZ))
  let sx = v.selfX
  let sz = v.selfY
  let own = v.terrainHeight(sx.int, sz.int)
  const hs = TerrainHeightScale.float32
  let heartCount = v.heartCount.int
  template dist(px, pz: int32): float32 =
    float32(sqrt(float64(distance2(Point(x: sx, z: sz), Point(x: px, z: pz)))) / diag)
  template dh(px, pz: int32): float32 = float32(v.terrainHeight(px.int, pz.int) - own) / hs
  template kinOf(j: int): float32 =
    (if hideKin or v.kin(j) < 0: 0'f32 else: float32(v.kin(j)) / 100)
  var held = newSeq[int](v.seatCount.int)
  for h in 0..<heartCount:
    let owner = v.heartOwner(h).int
    if owner in 0..<held.len: inc held[owner]
  let me = v.selfId.int
  output[0] = float32(sx - cx) / spanX
  output[1] = float32(sz - cz) / spanZ
  output[2] = float32(v.selfHp) / hpScale
  output[3] = float32(v.armorHp) / hpScale
  output[4] = float32(max(0'i32, v.seatScore(me))) / 10000
  output[5] = float32((v.selfHp > 0).int)
  output[6] = float32(v.worldTick) / FfaMatchTicks
  output[7] = float32(v.livesLeft) / 4
  output[8] = float32(v.seatCount) / FfaSeatScale
  output[9] = float32(heartCount) / FfaHeartScale
  output[10] = float32(held[me]) / float32(max(1, heartCount))
  if not hideKin: output[11] = float32(v.territoryBoost) / float32(TerritoryBoostPercent)
  output[12] = float32(v.waterAt(sx.int, sz.int))
  output[13] = float32(own) / hs
  output[14] = float32(rows.agents.len) / FfaSeatScale
  output[15] = float32(layout.cogRows) / FfaSeatScale
  output[16] = float32(layout.heartRows) / FfaHeartScale
  output[17] = float32(layout.greatRows) / 2
  output[18] = float32(v.hasGrenade)
  output[19] = float32(v.hasSpray)
  output[20] = float32(v.carrying)
  output[21] = float32((v.trenchId >= 0).int)
  for k, agent in rows.agents:
    let o = layout.cogOffset + k*FfaCogWidth
    let j = agent.identity.int
    output[o] = 1
    output[o+1] = float32(agent.x - sx) / spanX
    output[o+2] = float32(agent.z - sz) / spanZ
    output[o+3] = 1
    output[o+4] = float32(agent.hp) / hpScale
    for b in 0..<Loci:
      let g = v.gene(j, b)
      output[o+5+b] = if g < 0: 0'f32 elif g == 1: 1'f32 else: -1'f32
    output[o+37] = kinOf(j)
    output[o+38] = float32(max(0'i32, v.seatScore(j))) / 10000
    output[o+39] = (if j < held.len: float32(held[j]) / 10 else: 0'f32)
    output[o+40] = dist(agent.x, agent.z)
    output[o+41] = float32(v.waterAt(agent.x.int, agent.z.int))
    output[o+42] = dh(agent.x, agent.z)
    output[o+43] = float32(j) / float32(MaxSeats-1)
  for k in 0..<layout.heartRows:
    let o = layout.heartOffset + k*FfaHeartWidth
    let i = rows.hearts[k]
    let x = v.controlX(i)
    let z = v.controlY(i)
    let owner = v.heartOwner(i).int
    output[o] = 1
    output[o+1] = float32(x - sx) / spanX
    output[o+2] = float32(z - sz) / spanZ
    output[o+3] = float32(x - cx) / spanX
    output[o+4] = float32(z - cz) / spanZ
    output[o+5] =
      if owner < 0: -1'f32
      elif owner == me: 1'f32
      else: kinOf(owner)
    output[o+6] = float32(v.controlCaptureTicks(i)) / HeartCaptureTicks
    output[o+7] = float32(v.controlContested(i))
    output[o+8] = float32((owner == me).int)
    output[o+9] = dist(x, z)
    output[o+10] = float32(v.waterAt(x.int, z.int))
    output[o+11] = dh(x, z)
  for k in 0..<FfaGreatRows:
    let o = layout.greatOffset + k*FfaGreatWidth
    let g = rows.greats[k]
    let x = v.greatHeartX(g)
    let z = v.greatHeartY(g)
    output[o] = 1
    output[o+1] = float32(x - sx) / spanX
    output[o+2] = float32(z - sz) / spanZ
    output[o+3] = float32(x - cx) / spanX
    output[o+4] = float32(z - cz) / spanZ
    output[o+5] =
      if v.greatHeartDormant(g) > 0: -1'f32
      elif v.greatHeartProgress(g) > 0: 1'f32
      else: 0'f32
    output[o+6] = float32(v.greatHeartPresent(g)) / 16
    output[o+7] = float32(v.greatHeartProgress(g)) / GreatHeartCaptureTicks
    output[o+8] = float32(v.greatHeartDormant(g)) / GreatHeartDormantTicks
    output[o+9] = dist(x, z)
    output[o+10] = float32(v.waterAt(x.int, z.int))
    output[o+11] = dh(x, z)

proc encodeFfaHeard*(v: SeatView, output: var openArray[float32], mask = 0'u32) =
  ## The heard-speech rows of observation contract ffa.view.1h (FfaHeardSize floats, after
  ## ffa.view.1's): row i describes heard message i (heardText(i), heardSlot(i), heardX(i),
  ## heardY(i): what was shouted last tick within earshot, in the order BASIC reads it), for
  ## i < min(heardCount, FfaHeardRows); the rest are zero rows. Every column is computed from
  ## those SeatView procs, kin and the map bounds (the BASIC builtins of the same name):
  ##   0 valid (1), 1 text = "hurt", 2 text = "at" (shoutClass: one-hot over ShoutVocabulary),
  ##   3 any other text, 4 dx = (heardX - selfX) / spanX, 5 dz = (heardY - selfY) / spanZ,
  ##   6 kin(heardSlot)/100 (0 unknown, or under mask bit 0), 7 heardSlot/255
  ## mask bit 0 (FfaObsMaskKin, training only) zeroes column 6.
  if output.len != FfaHeardSize: raise newException(ValueError, "invalid neural observation dimensions")
  for i in 0..<output.len: output[i] = 0
  let hideKin = (mask and FfaObsMaskKin) != 0
  let spanX = float32(v.mapMaxX - v.mapMinX)
  let spanZ = float32(v.mapMaxY - v.mapMinY)
  let sx = v.selfX
  let sz = v.selfY
  for i in 0..<min(v.heardCount.int, FfaHeardRows):
    let o = i*FfaHeardWidth
    let class = shoutClass(v.heardText(i))
    let speaker = v.heardSlot(i).int
    output[o] = 1
    output[o + 3] = 1
    if class > 0:
      output[o + 3] = 0
      output[o + class] = 1
    output[o + 4] = float32(v.heardX(i) - sx) / spanX
    output[o + 5] = float32(v.heardY(i) - sz) / spanZ
    if not hideKin and speaker >= 0 and v.kin(speaker) >= 0: output[o + 6] = float32(v.kin(speaker)) / 100
    if speaker >= 0: output[o + 7] = float32(speaker) / float32(MaxSeats-1)
static: doAssert ShoutClasses == 3 and FfaHeardWidth == 1 + ShoutVocabulary.len + 1 + 4

proc userInputFeature*(value: int32): float32 =
  ## The float a user input value feeds the net: float32(v) / 1000 (v already clamped).
  float32(value) / 1000'f32
proc clampUserInput*(value: int32): int32 = clamp(value, -UserInputLimit, UserInputLimit)

proc encodeObservation*(v: SeatView, version: ObservationContractVersion, output: var openArray[float32],
    inputs: openArray[int32] = [], rows = FfaViewRows(), mask = 0'u32, heard = false) =
  ## The observation of the given contract: teams.view.1 (then the K user inputs of
  ## teams.view.1u<K>, K = inputs.len) or ffa.view.1 against `rows` (ffaViewRows of the view;
  ## with `heard`, ffa.view.1h: then the heard-speech rows, encodeFfaHeard; then the K user
  ## inputs of ffa.view.1u<K> / ffa.view.1hu<K>). Each block follows the one before unchanged:
  ## with no inputs and no heard rows every byte is the base contract's.
  case version
  of ocTeamsView1:
    if output.len != TeamsViewSize + inputs.len or inputs.len > MaxUserInputs:
      raise newException(ValueError, "invalid neural observation dimensions")
    encodeTeamsView(v, output.toOpenArray(0, TeamsViewSize-1))
    for i, value in inputs: output[TeamsViewSize+i] = userInputFeature(value)
  of ocFfaView1:
    let extra = if heard: FfaHeardSize else: 0
    let size = output.len - inputs.len - extra
    if size < 0 or inputs.len > MaxUserInputs: raise newException(ValueError, "invalid neural observation dimensions")
    encodeFfaView(v, output.toOpenArray(0, size-1), rows, mask)
    if heard: encodeFfaHeard(v, output.toOpenArray(size, size+extra-1), mask)
    for i, value in inputs: output[size+extra+i] = userInputFeature(value)

proc argmaxActions*(logits: openArray[float32]): array[ActionSizes.len, int32] =
  ## Deterministic headwise argmax, the deployed selection rule (first maximum wins).
  if logits.len != LogitSize: raise newException(ValueError,"invalid neural logit size")
  var offset = 0
  for head,size in ActionSizes:
    var best = 0
    for i in 0..<size:
      if classify(logits[offset+i]) in {fcNan,fcInf,fcNegInf}:
        raise newException(ValueError,"non-finite neural logits")
      if logits[offset+i] > logits[offset+best]: best = i
    result[head] = best.int32
    offset += size

# Decoder sampling (bundle option decoder.sampling, schema 2; not a contract change): the
# categorical heads are drawn from softmax(logits / temperature) instead of taken by argmax,
# from a stream the seat owns. The stream is SplitMix64 (polyworld/rngs, the engine's own
# replay-portable generator) seeded from the match seed and the seat's slot, so a replay of
# the same match reproduces the same draws on the same engine build, two seats never share
# a stream, and the world's own rng (which the state hash covers) is never touched: with the
# option absent nothing here runs and every hash is byte-identical. One draw per sampled
# head per call, in head order, so the stream position depends only on how many decisions
# the seat has taken. Probabilities are formed in float64 from the float32 logits; the draw
# is (next() shr 11) * 2^-53, the standard 53-bit uniform. Determinism holds per engine
# build: the actor's float32 logits are themselves only argmax-stable across CPU
# architectures (a one-ulp logit difference can move a sampled draw, never an argmax).
type
  SamplingOptions* = object
    enabled*: bool
    temperature*: float32      # > 0; 1.0 = the training-time distribution
    heads*: array[ActionSizes.len, bool]  # which heads are sampled; the rest take argmax
    ## The extra heads after the five main ones: the aim-offset heads 5 and 6 (action
    ## contracts teams.view.1 aim-offset and movement-offset) and the movement-offset heads 7
    ## and 8 (movement-offset only): sampled when listed in decoder.sampling.heads, or when
    ## heads is absent (every head).
    offsetHeads*: array[ExtraHeadsMax, bool]
    offsetListed*: bool  # heads named 5 or 6 explicitly
    moveListed*: bool    # heads named 7 or 8 explicitly

const
  SamplingSalt* = 0x53414d504c450000'u64  # "SAMPLE" in the high bytes, slot below it
  MinSamplingTemperature* = 0.01'f32
  MaxSamplingTemperature* = 10'f32

proc samplingRng*(matchSeed: int32, slot: int): Rng =
  ## The seat's sampling stream for a match: the match seed (the world's) salted with the
  ## slot so every seat draws differently.
  initRng(matchSeed, SamplingSalt xor (uint64(slot+1) shl 32))

proc samplingSeed*(matchSeed: int32, slot: int): uint64 =
  ## The stream's initial state, for telemetry.
  samplingRng(matchSeed, slot).state

proc uniform53(rng: var Rng): float64 =
  float64(rng.next() shr 11) * (1.0 / 9007199254740992.0)

proc sampleActions*(logits: openArray[float32], options: SamplingOptions,
    rng: var Rng): array[ActionSizes.len, int32] =
  ## Headwise categorical draw for the heads the options sample, argmax for the others;
  ## with the options disabled exactly argmaxActions (no draw). Exactly one draw per
  ## sampled head per call. Non-finite logits are rejected like argmax rejects them.
  if not options.enabled: return argmaxActions(logits)
  if logits.len != LogitSize: raise newException(ValueError,"invalid neural logit size")
  if options.temperature < MinSamplingTemperature or options.temperature > MaxSamplingTemperature:
    raise newException(ValueError,"invalid sampling temperature")
  let argmax = argmaxActions(logits)   # also the finiteness check
  var offset = 0
  for head,size in ActionSizes:
    if not options.heads[head]:
      result[head] = argmax[head]
      offset += size
      continue
    let top = float64(logits[offset+argmax[head]])
    let inverse = 1.0 / float64(options.temperature)
    var total = 0.0
    for i in 0..<size: total += exp((float64(logits[offset+i]) - top) * inverse)
    let threshold = rng.uniform53() * total
    var cumulative = 0.0
    var pick = size-1
    for i in 0..<size:
      cumulative += exp((float64(logits[offset+i]) - top) * inverse)
      if threshold < cumulative:
        pick = i
        break
    result[head] = pick.int32
    offset += size

# Decoder joint sampling (bundle option decoder.joint_sampling, schema 2; not a contract
# change): a head's selection can depend on another head's. After the tick's selection
# (forbid / BASIC masks, argmax or sampling / temperatures), when head `whenHead` was
# selected as `whenValue`, head `head` is selected again from its logits plus the
# bundle's `offsets`, under the same exclusions and temperature it was selected with:
# argmax (first maximum among the allowed) at temperature 0, else ONE more uniform53 draw
# from the seat's sampling stream (the float64 softmax sampleActions uses). Otherwise
# nothing changes and no draw is taken. With the option absent nothing here runs, so
# every hash is byte-identical. Example: `{"when": {"head": 2, "value": 1}, "head": 0,
# "offsets": [...]}` lets a shoot order change the movement distribution (e.g. stand while
# firing) without a rule that overrides the network.
type
  JointSampling* = object
    enabled*: bool
    whenHead*, whenValue*, head*: int
    offsets*: array[ActionSizes[0], float32]   # the first ActionSizes[head] entries are used
const MaxJointOffset* = 1000'f32

proc jointSelect*(logits: openArray[float32], joint: JointSampling, excluded: openArray[bool],
    temperature: float32, rng: var Rng, actions: var array[ActionSizes.len, int32]): bool =
  ## Applies decoder.joint_sampling to the tick's selection; true when the condition held
  ## (and the head was selected again). `excluded` is the head's mask (true = excluded;
  ## empty = none), `temperature` 0 = argmax.
  if not joint.enabled or actions[joint.whenHead] != joint.whenValue.int32: return false
  var offset = 0
  for h in 0..<joint.head: offset += ActionSizes[h]
  let size = ActionSizes[joint.head]
  template allowed(i: int): bool = excluded.len == 0 or not excluded[i]
  template value(i: int): float64 = float64(logits[offset+i]) + float64(joint.offsets[i])
  var best = -1
  for i in 0..<size:
    if allowed(i) and (best < 0 or value(i) > value(best)): best = i
  if best < 0: raise newException(ValueError, "every joint-sampling candidate is excluded")
  if temperature <= 0:
    actions[joint.head] = best.int32
    return true
  let top = value(best)
  let inverse = 1.0 / float64(temperature)
  var total = 0.0
  for i in 0..<size:
    if allowed(i): total += exp((value(i) - top) * inverse)
  let threshold = rng.uniform53() * total
  var cumulative = 0.0
  var pick = -1
  for i in 0..<size:
    if not allowed(i): continue
    pick = i   # the last allowed index when rounding leaves the threshold uncovered
    cumulative += exp((value(i) - top) * inverse)
    if threshold < cumulative: break
  actions[joint.head] = pick.int32
  true

# COND_HEAD selection (neural_actor.md, "COND_HEAD"): a model's learned conditional heads.
# After the tick's selection, in layer order, head `head` is selected again from its logits
# plus column `a` of the layer's weights (a = the choice already selected for `whenHead`),
# under the same exclusions and temperature it was selected with: argmax (the first maximum
# among the allowed) at temperature 0, else ONE more uniform53 draw from the seat's
# sampling stream, the float64 softmax jointSelect uses. The host skips an all-zero column
# (the selection stands, no draw). A model without COND_HEAD layers runs none of this.
proc reselectHead*(logits: openArray[float32], offset, size: int, offsets: openArray[float32],
    excluded: openArray[bool], temperature: float32, rng: var Rng): int32 =
  ## Head selection from logits[offset ..< offset+size] + offsets; `excluded` (true =
  ## excluded; empty = none), `temperature` 0 = argmax.
  template allowed(i: int): bool = excluded.len == 0 or not excluded[i]
  template value(i: int): float64 = float64(logits[offset+i]) + float64(offsets[i])
  var best = -1
  for i in 0..<size:
    if allowed(i) and (best < 0 or value(i) > value(best)): best = i
  if best < 0: raise newException(ValueError, "every conditional-head candidate is excluded")
  if temperature <= 0: return best.int32
  let top = value(best)
  let inverse = 1.0 / float64(temperature)
  var total = 0.0
  for i in 0..<size:
    if allowed(i): total += exp((value(i) - top) * inverse)
  let threshold = rng.uniform53() * total
  var cumulative = 0.0
  var pick = -1
  for i in 0..<size:
    if not allowed(i): continue
    pick = i   # the last allowed index when rounding leaves the threshold uncovered
    cumulative += exp((value(i) - top) * inverse)
    if threshold < cumulative: break
  pick.int32

# Decoder objective forbid (bundle option decoder.forbid_objectives, schema 2; not a
# contract change): the listed movement-head candidate indices are never chosen, as if
# their logits were -inf. The actor's logits are still checked for finiteness exactly as
# argmax checks them; the forbidden entries are then skipped by argmax and carry no mass
# in a sampled draw (the remaining candidates are renormalised). With nothing forbidden
# these are exactly argmaxActions / sampleActions (the same code runs), so the option
# absent is byte-identical. The pw-diag river veto forbids 9 and 10, the two river hearts.
type
  ObjectiveMask* = array[ActionSizes[0], bool]  # true = the movement-head index is forbidden

proc forbidsAny*(mask: ObjectiveMask): bool =
  for forbidden in mask:
    if forbidden: return true
  false

proc argmaxActions*(logits: openArray[float32], forbidden: ObjectiveMask): array[ActionSizes.len, int32] =
  ## argmaxActions with the forbidden movement-head indices skipped: the first maximum
  ## among the allowed ones. Nothing forbidden = argmaxActions.
  result = argmaxActions(logits)   # size and finiteness checks, every other head
  if not forbidden.forbidsAny: return
  var best = -1
  for i in 0..<ActionSizes[0]:
    if forbidden[i]: continue
    if best < 0 or logits[i] > logits[best]: best = i
  if best < 0: raise newException(ValueError, "every objective candidate is forbidden")
  result[0] = best.int32

proc sampleActions*(logits: openArray[float32], options: SamplingOptions,
    rng: var Rng, forbidden: ObjectiveMask): array[ActionSizes.len, int32] =
  ## sampleActions with the forbidden movement-head indices removed from the draw (and
  ## from argmax when the movement head is not sampled). Still exactly one draw per
  ## sampled head per call. Nothing forbidden = sampleActions; options disabled = the
  ## masked argmax with no draw.
  if not forbidden.forbidsAny: return sampleActions(logits, options, rng)
  if not options.enabled: return argmaxActions(logits, forbidden)
  if logits.len != LogitSize: raise newException(ValueError,"invalid neural logit size")
  if options.temperature < MinSamplingTemperature or options.temperature > MaxSamplingTemperature:
    raise newException(ValueError,"invalid sampling temperature")
  let argmax = argmaxActions(logits, forbidden)   # also the finiteness check
  var offset = 0
  for head,size in ActionSizes:
    if not options.heads[head]:
      result[head] = argmax[head]
      offset += size
      continue
    let top = float64(logits[offset+argmax[head]])
    let inverse = 1.0 / float64(options.temperature)
    var total = 0.0
    for i in 0..<size:
      if head == 0 and forbidden[i]: continue
      total += exp((float64(logits[offset+i]) - top) * inverse)
    let threshold = rng.uniform53() * total
    var cumulative = 0.0
    var pick = -1
    for i in 0..<size:
      if head == 0 and forbidden[i]: continue
      pick = i   # the last allowed index when rounding leaves the threshold uncovered
      cumulative += exp((float64(logits[offset+i]) - top) * inverse)
      if threshold < cumulative: break
    result[head] = pick.int32
    offset += size

# Neural BASIC I/O (PLAN-neural-basic-io): the head-level sampler BASIC drives with
# neuralMask / neuralTemperature. Per head, a mask of excluded choices and a temperature
# (0 = argmax). With the mask equal to decoder.forbid_objectives on head 0 and nothing
# else, and the temperatures equal to decoder.sampling's, it is exactly sampleActions /
# argmaxActions with that forbid mask: the same argmax (first maximum among the allowed),
# the same float64 softmax over the allowed choices, one uniform53 draw per sampled head
# in head order, and the last allowed choice when rounding leaves the threshold uncovered.
type
  HeadMasks* = array[ActionSizes.len, array[ActionSizes[0], bool]]  # true = excluded
  HeadTemperatures* = array[ActionSizes.len, float32]                # 0 = argmax
const
  MinBasicTemperatureMilli* = 1'i32
  MaxBasicTemperatureMilli* = 100000'i32

proc maskedArgmax(logits: openArray[float32], masks: HeadMasks): array[ActionSizes.len, int32] =
  result = argmaxActions(logits)   # size and finiteness checks
  var offset = 0
  for head, size in ActionSizes:
    var any = false
    for i in 0..<size:
      if masks[head][i]: any = true
    if any:
      var best = -1
      for i in 0..<size:
        if masks[head][i]: continue
        if best < 0 or logits[offset+i] > logits[offset+best]: best = i
      if best < 0: raise newException(ValueError, "every choice of head " & $head & " is masked")
      result[head] = best.int32
    offset += size

proc sampleHeads*(logits: openArray[float32], temps: HeadTemperatures, masks: HeadMasks,
    rng: var Rng, draws: var int): array[ActionSizes.len, int32] =
  ## Headwise: argmax (temperature 0) or a categorical draw from softmax(logits / T) over
  ## the choices not masked; `draws` counts the uniforms taken.
  if logits.len != LogitSize: raise newException(ValueError, "invalid neural logit size")
  let argmax = maskedArgmax(logits, masks)
  var offset = 0
  for head, size in ActionSizes:
    let t = temps[head]
    if t <= 0'f32:
      result[head] = argmax[head]
      offset += size
      continue
    let top = float64(logits[offset+argmax[head]])
    let inverse = 1.0 / float64(t)
    var total = 0.0
    for i in 0..<size:
      if masks[head][i]: continue
      total += exp((float64(logits[offset+i]) - top) * inverse)
    let threshold = rng.uniform53() * total
    inc draws
    var cumulative = 0.0
    var pick = -1
    for i in 0..<size:
      if masks[head][i]: continue
      pick = i
      cumulative += exp((float64(logits[offset+i]) - top) * inverse)
      if threshold < cumulative: break
    result[head] = pick.int32
    offset += size

# ---------------------------------------------------------------------------------------
# Action contract ffa.view.1 pointer (observation contract ffa.view.1 only). Five heads, sized
# by the match layout (seats N, control hearts H, cog rows C = min(N - 1, 64)):
#   head 0 objective, 11 + H; head 1 aim, 9 + C; heads 2, 3, 4: 2 each. What each index means
# is the seat's policy.bas's business (players/neural_decode_ffa.bas is the reference reading:
# 0 stay / keep aim, 1..8 compass, then the observation's heart rows and cog rows, read back
# with neuralRow). Its shout variant adds head 5, ShoutClasses (0 nothing, then ShoutVocabulary).
const
  PointerCompass* = 8
  PointerObjectiveFirstRow* = 1 + PointerCompass   # 9: control heart row 0
  PointerAimFirstRow* = 1 + PointerCompass         # 9: cog row 0

proc pointerHeads*(l: FfaViewLayout, contract = acFfaView1Pointer): seq[int] =
  ## The head sizes of action contract ffa.view.1 pointer for a match layout; under its shout
  ## variant (acFfaView1PointerShout) the shout head (ShoutClasses) follows the five.
  result = @[1 + PointerCompass + l.heartRows + l.greatRows, 1 + PointerCompass + l.cogRows, 2, 2, 2]
  if contract == acFfaView1PointerShout: result.add ShoutClasses

proc pointerTargets*(l: FfaViewLayout): array[4, int] =
  ## The logit offset of each observation section's row 0 (neural_actor layout words, field
  ## 3): cogs in the aim head, control and great hearts in the objective head.
  let aimHead = 1 + PointerCompass + l.heartRows + l.greatRows
  [aimHead + PointerAimFirstRow, PointerObjectiveFirstRow, PointerObjectiveFirstRow + l.heartRows,
   PointerObjectiveFirstRow]

proc pointerSelect*(logits: openArray[float32], heads: openArray[int], temperatures: openArray[float32],
    rng: var Rng, draws: var int): seq[int32] =
  ## Headwise selection for a seat whose heads are sized by the match (action contract ffa.v2
  ## pointer): argmax (the first maximum) at temperature 0, else one uniform53 draw from the
  ## float64 softmax(logits / T), sampleActions' rule and order; `draws` counts the draws.
  ## Non-finite logits are rejected.
  var total = 0
  for h in heads: total += h
  if logits.len != total or temperatures.len != heads.len:
    raise newException(ValueError, "invalid neural logit size")
  for x in logits:
    if classify(x) in {fcNan, fcInf, fcNegInf}: raise newException(ValueError, "non-finite neural logits")
  var offset = 0
  for head, size in heads:
    var best = 0
    for i in 0..<size:
      if logits[offset+i] > logits[offset+best]: best = i
    let t = temperatures[head]
    if t <= 0'f32:
      result.add best.int32
    else:
      if t < MinSamplingTemperature or t > MaxBasicTemperatureMilli.float32 / 1000'f32:
        raise newException(ValueError, "invalid sampling temperature")
      let top = float64(logits[offset+best])
      let inverse = 1.0 / float64(t)
      var sum = 0.0
      for i in 0..<size: sum += exp((float64(logits[offset+i]) - top) * inverse)
      let threshold = rng.uniform53() * sum
      inc draws
      var cumulative = 0.0
      var pick = size-1
      for i in 0..<size:
        cumulative += exp((float64(logits[offset+i]) - top) * inverse)
        if threshold < cumulative:
          pick = i
          break
      result.add pick.int32
    offset += size

proc trainingBotActions*(v: SeatView, level: int, actions: var openArray[int32]) =
  ## Deliberately simple curriculum opponent's head choices (action contract teams.view.1),
  ## never the learner; it reads only the seat's view. Level 1 idles; level 2 heads for the
  ## nearest heart its side does not own and fires at the nearest visible apparent enemy.
  if actions.len != ActionSizes.len or level notin 1..2:
    raise newException(ValueError,"invalid training bot configuration")
  for i in 0..<actions.len: actions[i] = 0
  if level == 1 or v.selfHp <= 0: return
  let me = Point(x: v.selfX, z: v.selfY)
  let side = v.selfTeam
  var best = high(int64)
  for i in 0..<min(10, v.heartCount.int):
    if v.controlOwner(i) == side: continue
    let d = distance2(me, Point(x: v.controlX(i), z: v.controlY(i)))
    if d < best:
      best = d
      actions[0] = int32(i+1)
  # Keep looking in different directions when no opponent is seen.
  actions[1] = int32(17+(v.worldTick.int div 24+v.slot div 2) mod 8)
  best = high(int64)
  for identity in 0..<LegacySeats:
    if v.visible(identity) == 0 or v.playerTeam(identity) == side: continue
    let d = distance2(me, Point(x: v.playerX(identity), z: v.playerY(identity)))
    if d < best:
      best = d
      actions[1] = int32(identity+1)
      actions[2] = 1
