## Versioned policy-visible float observations and categorical actuators.
## Used unchanged by BASIC deployment and native Puffer rollouts.
import std/math
import polyworld/rngs
import sim, kinship

const
  ObservationSize* = 448
  ActionSizes* = [51, 25, 2, 2, 2]
  LogitSize* = 82
  ObservationContract* = "paintbot-pw.rules37.obs.v1.float448"
  ActionContract* = "paintbot-pw.rules37.action.v1.51-25-2-2-2"
  ObservationContractHash* = "ed5d16768e3144a04a28420ce227ff2d6a831be9f64f3633326b133a5335b7e2"
  ActionContractHash* = "55922d42d4065a069b3193f31e056c3a53cd34175b10fed7ff0d8c22b50a473e"
  ## Action contract v2: the same five heads and sizes; an identity aim resolves to the
  ## body's lead-compensated aim point (leadAimPoint) instead of its current position.
  ## Directional aim, movement, fire, grenade and sneak decode exactly as in v1.
  ActionContractV2* = "paintbot-pw.rules37.action.v2.51-25-2-2-2"
  ActionContractV2Hash* = "51f602ef167919ca825595f9d81777cb807afbb0938a20102457d0594e2b4317"
  ## Observation contract v2: the v1 observation, unchanged in order and value, in
  ## columns 0 .. ObservationSize-1, followed by a public terrain block
  ## (TerrainBlockSize floats; encodeTerrainBlock documents every column). Selected per
  ## seat by the actor's embedded observation hash; v1 actors keep the v1 encoder.
  TerrainBlockSize* = 58
  ObservationSizeV2* = ObservationSize + TerrainBlockSize
  ObservationContractV2* = "paintbot-pw.rules37.obs.v2.float506"
  ObservationContractV2Hash* = "e0d7b0b97975725c470ef6119ca2a6caf4aaa6f34cd15bee02bd306489c029e5"
  ## Terrain heights (w.elevation: terrain plus trench, centimetres; the playable
  ## rules-37 span measures -260 .. 551) are divided by this, so every height and height
  ## delta the block carries lies within about [-1, 1] (the river bed below a level
  ## bank is -200 / 800 = -0.25).
  TerrainHeightScale* = 800
  Directions =[(1,0), (1,1), (0,1), (-1,1), (-1,0), (-1,-1), (0,-1), (1,-1)]
  # Lead compensation (contract v2), derived from the gun in mechanics.nim (rules >= 10):
  # the tick a shoot order is applied the shooter first moves, then gunAim = aim - pos is
  # locked; the ray leaves GunWindupTicks ticks later from wherever the shooter then
  # stands, along the locked vector. With one move per tick the shooter has made 6 moves
  # when the ray leaves and the direction was fixed after the first, so for a target
  # velocity u and the shooter's own per-tick step v the ray through the target's future
  # position needs aim = body + (GunWindupTicks+1)*u - GunWindupTicks*v. base.bas ("the
  # ray leaves six moves after the order... aim where they will be, minus our own drift")
  # uses the same 6 and 5, with its planned leg as v while in contact.
  LeadTargetMoves* = GunWindupTicks + 1
  LeadOwnMoves* = GunWindupTicks
  # A larger per-axis displacement than any one-tick move (MoveSpeed 28, diagonal yield
  # steps included) is a respawn or teleport, not a velocity; base.bas uses the same 60.
  TeleportStep* = 60
static: doAssert LeadTargetMoves == 6 and LeadOwnMoves == 5 and TeleportStep > 2*MoveSpeed
const
  # Decoder fire hold (a per-bundle option, off by default; not part of any action
  # contract: candidates and hashes are untouched). A shoot order is held when a teammate
  # the seat can see stands within the gun's own hit tolerance (mechanics.nim tests every
  # ray sample against Radius) of the segment from the seat to the aim the order leaves,
  # and no farther along it than the aim point itself.
  FireHoldRadius* = Radius
  # decoder.fire_hold_teammates {"radius": r}: pw-diag4 found 97-100 % of the v7
  # champion's gun friendly fire comes from teammates outside the 55-unit hold at the
  # order tick who walk into the ray during the windup; a wider radius holds those
  # orders. 1 .. MaxFireHoldRadius; the default (and the boolean form) stays Radius.
  MaxFireHoldRadius* = 2000'i32
static: doAssert FireHoldRadius == 55
const
  ## Observation contract ffa.v1 (FFA-kin; encodeFfaObservation documents every column):
  ## no map flip, 16 seat-indexed identity rows with genes and relatedness, seat-owned
  ## hearts, the two great hearts and v2's terrain block. Selected by its hash exactly as
  ## v2 is (an actor's embedded observation hash, pw_create_observation's version).
  FfaSelfSize* = 8
  FfaIdentityRowSize* = 42
  FfaHeartRows* = 10
  FfaHeartRowSize* = 6
  FfaGreatRows* = 2
  FfaGreatRowSize* = 6
  FfaIdentityOffset* = FfaSelfSize
  FfaHeartOffset* = FfaIdentityOffset + Seats*FfaIdentityRowSize
  FfaGreatOffset* = FfaHeartOffset + FfaHeartRows*FfaHeartRowSize
  FfaTerrainOffset* = FfaGreatOffset + FfaGreatRows*FfaGreatRowSize
  ObservationSizeFfaV1* = FfaTerrainOffset + TerrainBlockSize
  ObservationContractFfaV1* = "paintbot-pw.rules40.obs.ffa.v1.float810"
  ObservationContractFfaV1Hash* = "6b19dc324386542eb915d30c2ce1707a8f8e192a0425ee8b2ae9145969583fc7"
  ## encodeFfaObservation mask bit 0 (training ABI only, pw_set_obs_mask): zero every
  ## r-to-me column (and the territory-boost column, which is r to the local owner), the
  ## genes-only ablation.
  FfaObsMaskKin* = 1'u32
static:
  doAssert FfaIdentityRowSize == 2 + 1 + 1 + 1 + Loci + 1 + 1 + 1 + 2
  doAssert FfaIdentityOffset == 8 and FfaHeartOffset == 680 and FfaGreatOffset == 740
  doAssert FfaTerrainOffset == 752 and ObservationSizeFfaV1 == 810
  doAssert ObservationContractFfaV1 == "paintbot-pw.rules40.obs.ffa.v1.float" & $ObservationSizeFfaV1
  doAssert FfaMatchTicks == 8640 and GreatHeartDormantTicks == 1440
static: doAssert ObservationSizeV2 == 506 and ObservationContractV2 == "paintbot-pw.rules37.obs.v2.float" & $ObservationSizeV2
const
  ## Observation contract v3 ("scoreboard"): v2's 506 floats unchanged in columns
  ## 0 .. ObservationSizeV2-1, followed by the seat's team's public scoreboard
  ## (ScoreboardBlockSize floats; encodeScoreboardBlock documents every column). The teams
  ## game only: FFA-kin refuses it. The hash is the SHA-256 of the id, as for v1 and v2.
  ScoreboardBlockSize* = 8
  ObservationSizeV3* = ObservationSizeV2 + ScoreboardBlockSize
  ObservationContractV3* = "paintbot-pw.rules43.obs.v3.float514"
  ObservationContractV3Hash* = "06f16d62adedda6995d393696c0d2ed257aa9380b86341e73d1d6a3c7ea374f1"
static: doAssert ObservationSizeV3 == 514 and ObservationContractV3 == "paintbot-pw.rules43.obs.v3.float" & $ObservationSizeV3

type
  ObservationContractVersion* = enum
    ## Version numbers are the native ABI's (pw_create_observation): ocFfaV1 is 101.
    ocV1 = 1, ocV2 = 2, ocV3 = 3, ocFfaV1 = 101
  ActionContractVersion* = enum
    acV1 = 1, acV2 = 2
  AimMemory* = object
    ## What a seat saw one tick ago, kept by the host outside the World (never hashed,
    ## never serialized): the pre-step tick it was recorded on and, per apparent
    ## identity, the body it resolved to and that body's position. Contract v2 derives
    ## the target's velocity from it; contract v1 never reads it.
    tick*: int32 # -1 when nothing is recorded
    bodies*: array[Seats, int]
    positions*: array[Seats, Point]

proc actionContractHash*(version: ActionContractVersion): string =
  case version
  of acV1: ActionContractHash
  of acV2: ActionContractV2Hash
proc actionContractId*(version: ActionContractVersion): string =
  case version
  of acV1: ActionContract
  of acV2: ActionContractV2
proc actionContractVersion*(hash: string): ActionContractVersion =
  ## The contract an actor or manifest hash names; ValueError for anything else.
  if hash == ActionContractHash: acV1
  elif hash == ActionContractV2Hash: acV2
  else: raise newException(ValueError, "unknown neural action contract")

proc observationContractHash*(version: ObservationContractVersion): string =
  case version
  of ocV1: ObservationContractHash
  of ocV2: ObservationContractV2Hash
  of ocV3: ObservationContractV3Hash
  of ocFfaV1: ObservationContractFfaV1Hash
proc observationContractId*(version: ObservationContractVersion): string =
  case version
  of ocV1: ObservationContract
  of ocV2: ObservationContractV2
  of ocV3: ObservationContractV3
  of ocFfaV1: ObservationContractFfaV1
proc observationSize*(version: ObservationContractVersion): int =
  case version
  of ocV1: ObservationSize
  of ocV2: ObservationSizeV2
  of ocV3: ObservationSizeV3
  of ocFfaV1: ObservationSizeFfaV1
proc observationContractVersion*(hash: string): ObservationContractVersion =
  ## The contract an actor or manifest hash names; ValueError for anything else.
  if hash == ObservationContractHash: ocV1
  elif hash == ObservationContractV2Hash: ocV2
  elif hash == ObservationContractV3Hash: ocV3
  elif hash == ObservationContractFfaV1Hash: ocFfaV1
  else: raise newException(ValueError, "unknown neural observation contract")

proc observedBodies*(w: World, slot: int): array[Seats, int] =
  ## Match BASIC identity resolution, including uniforms and duplicate identities.
  ## Pure in the world: hosts that observe, decode and drive bots on one unchanged
  ## tick may compute it once per seat and pass it to the overloads below.
  for i in 0..<Seats: result[i] = -1
  result[slot] = slot
  for body in 0..<Seats:
    if body == slot or not w.visible(slot, body): continue
    let identity = w.observedSeat(slot, body)
    if identity notin 0..<Seats or identity == slot: continue
    let previous = result[identity]
    if previous < 0 or distance2(w.cogs[slot].pos, w.cogs[body].pos) <
        distance2(w.cogs[slot].pos, w.cogs[previous].pos): result[identity] = body

proc mapFlip*(slot: int): int =
  ## The teams game mirrors odd seats' observations and compass heads (team 1 plays from
  ## the other side); FFA-kin has no sides, so nothing is mirrored for any seat.
  if team(slot) == 0 or ffa(): 1 else: -1

proc relativeTeam(value, side: int): float32 =
  if value < 0: 0'f32
  elif value == side: 1'f32
  else: -1'f32

proc encodeObservation*(w: World, slot: int, output: var openArray[float32],
    bodies: array[Seats, int]) =
  if slot notin 0..<Seats or output.len != ObservationSize:
    raise newException(ValueError, "invalid neural observation dimensions or seat")
  for i in 0..<output.len: output[i] = 0
  let me = w.cogs[slot]
  let gear = w.equipment[slot]
  let side = team(slot)
  let flip = mapFlip(slot).float32
  let spanX = float32(maxX()-minX())
  let spanZ = float32(maxZ()-minZ())
  var k = 0
  template put(value: untyped) =
    output[k] = float32(value)
    inc k
  template position(p: Point) =
    put(float32(p.x-me.pos.x)*flip/spanX)
    put(float32(p.z-me.pos.z)*flip/spanZ)
  # Self features (24). Public own-state metadata; no hidden entity state.
  put(float32(me.pos.x-Width div 2)*flip/spanX)
  put(float32(me.pos.z-Height div 2)*flip/spanZ)
  put(float32(me.hp)/3)
  put(float32(gear.armor)/3)
  put(float32(gear.lives)/4)
  put(gear.grenade.int)
  put(gear.sprayCan.int)
  put(float32(gear.charge)/24)
  put(float32(me.cooldown)/72)
  put(float32(me.respawn)/72)
  put(float32(me.shield)/36)
  put(me.carrying.int)
  position(me.aim)
  put(float32(w.tick)/max(1, w.endTick).float32)
  put(float32(w.scoreTicks[side])/max(1, w.heartMeterTarget()).float32)
  put(float32(w.scoreTicks[1-side])/max(1, w.heartMeterTarget()).float32)
  put(float32(w.glory[side])/1000)
  put(float32(w.glory[1-side])/1000)
  put(float32(slot div 2)/7)
  put(w.uniforms[slot].int)
  put((w.trenchAt(me.pos)>=0).int)
  put(float32(gear.windup)/5)
  put(float32(gear.sprayCooldown)/60)
  # Public hearts (10 * 8).
  for i in 0..<10:
    if i >= w.controlHearts.len: k += 8; continue
    let heart = w.controlHearts[i]
    put(1)
    position(heart.pos)
    put(relativeTeam(heart.owner.int, side))
    if i < w.heartCaptures.len:
      let capture = w.heartCaptures[i]
      put(relativeTeam(capture.team.int, side))
      put(float32(capture.ticks)/HeartCaptureTicks)
      put(capture.contested.int)
    else: k += 3
    put(float32(w.heartPoints(i))/5)
  # Fog-gated apparent identities (16 * 8). No true-team or real-seat leakage.
  for identity in 0..<Seats:
    let body = bodies[identity]
    if body < 0: k += 8; continue
    let other = w.cogs[body]
    put(1)
    position(other.pos)
    put(relativeTeam(w.observedTeam(slot,body),side))
    put(float32(other.hp)/3)
    put(other.carrying.int)
    put((identity == slot).int)
    put(float32(identity div 2)/7)
  # Fog-gated available pickups (32 * 5), stable public pickup index.
  for i in 0..<32:
    if i >= w.pickups.len or w.pickups[i].readyAt > w.tick or
        not w.canSeePoint(slot,w.pickups[i].pos): k += 5; continue
    let pickup = w.pickups[i]
    put(1)
    position(pickup.pos)
    put(float32(pickup.kind.ord)/4)
    put(float32(i)/31)
  # Listener-relative sound bins (8 * 4). Never include exact sound origins.
  var soundCount = 0
  for sound in w.sounds:
    if soundCount >= 8: break
    if sound.listener != slot.int32 or w.tick-sound.tick notin 0..SoundLifetime: continue
    put(1)
    put(float32(sound.kind)/4)
    put(float32((sound.direction.int+(if side==0:0 else:4)) mod 8)/7)
    put(float32(sound.distance)/4)
    inc soundCount
  k += (8-soundCount)*4
  # Local public terrain: center and eight compass samples (9 * 2).
  for i in 0..<9:
    let delta = if i==0: (0,0) else: Directions[i-1]
    let p = point(me.pos.x.int+int(flip)*delta[0]*200,
                  me.pos.z.int+int(flip)*delta[1]*200)
    put((p.x.int>=minX() and p.x.int<=maxX() and p.z.int>=minZ() and
      p.z.int<=maxZ() and not w.blocked(p) and w.traversable(me.pos,p)).int)
    put(float32(w.elevation(p)-w.elevation(me.pos))/1000)
  doAssert k == 442 # Six reserved zeros preserve the fixed-width contract.
proc encodeObservation*(w: World, slot: int, output: var openArray[float32]) =
  if slot notin 0..<Seats or output.len != ObservationSize:
    raise newException(ValueError, "invalid neural observation dimensions or seat")
  w.encodeObservation(slot, output, w.observedBodies(slot))

proc inWater*(p: Point): bool =
  ## Standing in the river's water: exactly the predicate mechanics.nim uses to quarter a
  ## wading seat's speed (rules >= 30; bank ground above the waterline is dry).
  visionRulesVersion >= 30 and riverBlend(p.x.int, p.z.int) > 0 and
    terrainHeight(p.x.int, p.z.int) < RiverWaterHeight

proc encodeTerrainBlock*(w: World, slot: int, output: var openArray[float32],
    bodies: array[Seats, int]) =
  ## Observation contract v2's terrain block (TerrainBlockSize floats), written at
  ## output[0 ..< TerrainBlockSize]. Public terrain only, read at points the v1 block
  ## already reveals: the seat's own position, the ten public hearts and the bodies the
  ## seat can see under its apparent identities (fog and uniforms exactly as v1; a slot v1
  ## leaves empty stays empty here). "Wet" is inWater, "height" is w.elevation (terrain
  ## plus trench) / TerrainHeightScale.
  ##   0      self wet (0/1)
  ##   1      self height
  ##   2+2i   heart i (0..9) wet               (0 when the heart is absent)
  ##   3+2i   heart i height minus self height  (0 when the heart is absent)
  ##   22+2j  identity j (0..15) wet               (0 when v1's identity slot j is empty)
  ##   23+2j  identity j height minus self height  (0 when empty; the seat's own slot reads 0)
  ##   54     visible apparent enemies wet / 8
  ##   55     visible apparent enemies dry / 8
  ##   56     visible apparent teammates wet / 8 (the seat itself excluded)
  ##   57     visible apparent teammates dry / 8 (the seat itself excluded)
  if slot notin 0..<Seats or output.len != TerrainBlockSize:
    raise newException(ValueError, "invalid neural terrain block dimensions or seat")
  for i in 0..<output.len: output[i] = 0
  let me = w.cogs[slot]
  let side = team(slot)
  let own = w.elevation(me.pos)
  const scale = TerrainHeightScale.float32
  output[0] = inWater(me.pos).float32
  output[1] = float32(own)/scale
  for i in 0..<10:
    if i >= w.controlHearts.len: continue
    let p = w.controlHearts[i].pos
    output[2+2*i] = inWater(p).float32
    output[3+2*i] = float32(w.elevation(p)-own)/scale
  var enemyWet, enemyDry, mateWet, mateDry = 0
  for identity in 0..<Seats:
    let body = bodies[identity]
    if body < 0: continue
    let p = w.cogs[body].pos
    let wet = inWater(p)
    output[22+2*identity] = wet.float32
    output[23+2*identity] = float32(w.elevation(p)-own)/scale
    if identity == slot: continue
    let relation = relativeTeam(w.observedTeam(slot, body), side)
    if relation < 0:
      if wet: inc enemyWet else: inc enemyDry
    elif relation > 0:
      if wet: inc mateWet else: inc mateDry
  output[54] = float32(enemyWet)/8
  output[55] = float32(enemyDry)/8
  output[56] = float32(mateWet)/8
  output[57] = float32(mateDry)/8
static: doAssert 58 == TerrainBlockSize

const
  ## Scoreboard block divisors (observation contract v3). Lives: 8 seats x 4 lives.
  ScoreboardLivesScale* = 32
  ScoreboardGloryScale* = 1000
  ScoreboardBehindLivesScale* = 10
  ScoreboardBehindSecondsScale* = 60
  ScoreboardQuietSuppliesScale* = 100

proc encodeScoreboardBlock*(w: World, slot: int, output: var openArray[float32]) =
  ## Observation contract v3's scoreboard block (ScoreboardBlockSize floats), written at
  ## output[0 ..< ScoreboardBlockSize], from the seat's team's side (team(slot); no map
  ## flip is involved: nothing here is a position). Only what the match HUD already shows
  ## every viewer: each seat's lives (the header's life pips), both glory totals (the
  ## header score), the match's glory awards (the scoreboard and the score tooltip, from
  ## the rules-43 "glory" config) and the match clock. Nothing fog-gated.
  ##   0  own team's lives left (sim.teamLives, the sum the behind-in-lives award compares) / 32
  ##   1  enemy team's lives left / 32
  ##   2  own team's glory / 1000
  ##   3  enemy team's glory / 1000
  ##   4  behind-in-lives award, glory per life trailed (gloryRules().behindLives) / 10
  ##   5  its period in seconds (gloryRules().behindLivesSeconds) / 60
  ##   6  quiet-supplies award (gloryRules().quietSupplies) / 100
  ##   7  ticks remaining, max(0, endTick - tick) / max(1, endTick)
  ## The teams game only: ValueError in FFA-kin (no teams, lives or glory there).
  if slot notin 0..<Seats or output.len != ScoreboardBlockSize:
    raise newException(ValueError, "invalid neural scoreboard block dimensions or seat")
  if ffa(): raise newException(ValueError, "observation contract v3 is for the teams game only")
  let side = team(slot)
  let awards = gloryRules()
  output[0] = float32(w.teamLives(side))/ScoreboardLivesScale.float32
  output[1] = float32(w.teamLives(1-side))/ScoreboardLivesScale.float32
  output[2] = float32(w.glory[side])/ScoreboardGloryScale.float32
  output[3] = float32(w.glory[1-side])/ScoreboardGloryScale.float32
  output[4] = float32(awards.behindLives)/ScoreboardBehindLivesScale.float32
  output[5] = float32(awards.behindLivesSeconds)/ScoreboardBehindSecondsScale.float32
  output[6] = float32(awards.quietSupplies)/ScoreboardQuietSuppliesScale.float32
  output[7] = float32(max(0'i32, w.endTick-w.tick))/max(1'i32, w.endTick).float32
static: doAssert 8 == ScoreboardBlockSize

proc encodeFfaObservation*(w: World, slot: int, output: var openArray[float32],
    bodies: array[Seats, int], kin: Kinship, mask = 0'u32) =
  ## Observation contract ffa.v1 (ObservationSizeFfaV1 = 810 floats), for FFA-kin. No map
  ## flip: positions are in the absolute frame for every seat. "Centred x" is
  ## (x - Width/2) / (maxX - minX), "centred z" likewise with Height and the z span; score is
  ## the raw score s_j in points / 1000 (seatScore is tenths). Fog: a seat's position and hp
  ## need its body to be visible (bodies, as v1); hp and armor are divided by maxHp()
  ## (FfaMaxHp = 10 in FFA-kin, 3 in the teams game); alive, genes, r, score and hearts held are
  ## public. Outside FFA the kin, score and seat-ownership columns and the great-heart rows
  ## are zero (the teams game has no kinship). mask bit 0 (FfaObsMaskKin) zeroes every
  ## r-to-me column: identity column 37 (the own row too, which then reads 0, not 1), the
  ## own row's territory-boost column 40, and a heart owned by another seat reads 0. Normalisations that can exceed 1: the score
  ## columns (raw score / 1000; a strong seat passes 1000 points over a match). Every other
  ## column stays within [-1, 1] (armor is at most 3, cooldown at most 72, dx/dz within the
  ## map span).
  ##   0..7      self: centred x, centred z, hp/maxHp, armor/maxHp, cooldown/72, own score/1000,
  ##             alive, ticks left/8640
  ##   8+42j     identity row j (seat j, 0..15), columns:
  ##             0 dx/xspan, 1 dz/zspan (0 unless visible; own row 0), 2 visible (own 1),
  ##             3 alive, 4 hp/maxHp (0 unless visible), 5..36 gene bits 0..31 (+1 set, -1
  ##             clear), 37 r(me, j) (own row 1), 38 score/1000, 39 hearts held/10,
  ##             40 own row only: territory boost / TerritoryBoostPercent (1 on own
  ##             territory, 0.5 a sibling's, 7/30 a cousin's, 0 neutral or a stranger's;
  ##             computed from `kin`, zeroed by FfaObsMaskKin; other rows 0), 41 reserved 0
  ##   680+6i    control heart row i (0..9): 0 centred x, 1 centred z, 2 owner's r to me
  ##             (-1 neutral, 1 mine), 3 capture ticks/HeartCaptureTicks, 4 contested,
  ##             5 owned by me (absent heart: all 0)
  ##   740+6g    great heart row g (0..1): 0 centred x, 1 centred z, 2 state (-1 dormant,
  ##             0 awake and empty of progress, 1 charging), 3 cogs present/16,
  ##             4 progress/GreatHeartCaptureTicks, 5 dormant ticks left/1440
  ##   752..809  v2's terrain block (encodeTerrainBlock) columns 0..53, then 54 visible
  ##             other seats wet/8, 55 visible other seats dry/8, 56..57 reserved 0 (the
  ##             v2 team split means nothing without teams)
  if slot notin 0..<Seats or output.len != ObservationSizeFfaV1:
    raise newException(ValueError, "invalid neural observation dimensions or seat")
  for i in 0..<output.len: output[i] = 0
  let kinOn = ffa()
  let hideKin = (mask and FfaObsMaskKin) != 0
  let me = w.cogs[slot]
  let hpScale = float32(maxHp())
  let spanX = float32(maxX()-minX())
  let spanZ = float32(maxZ()-minZ())
  # Templates, not nested procs: a closure would copy the World.
  template cx(p: Point): float32 = float32(p.x-Width div 2)/spanX
  template cz(p: Point): float32 = float32(p.z-Height div 2)/spanZ
  template rTo(j: int): float32 =
    (if not kinOn or hideKin: 0'f32 else: float32(kin.r(slot, j)))
  template points(j: int): float32 =
    (if kinOn: float32(w.seatScore[j])/10000 else: 0'f32)
  # Self.
  output[0] = cx(me.pos)
  output[1] = cz(me.pos)
  output[2] = float32(me.hp)/hpScale
  output[3] = float32(w.equipment[slot].armor)/hpScale
  output[4] = float32(me.cooldown)/72
  output[5] = points(slot)
  output[6] = float32((me.hp > 0).int)
  output[7] = float32(max(0'i32, w.endTick-w.tick))/8640
  # Identity rows, indexed by seat.
  var held: array[Seats, int]
  if kinOn:
    for heart in w.controlHearts:
      if heart.owner in 0'i32..<Seats.int32: inc held[heart.owner]
  for j in 0..<Seats:
    let o = FfaIdentityOffset + j*FfaIdentityRowSize
    let body = bodies[j]
    if body >= 0:
      let other = w.cogs[body]
      output[o] = float32(other.pos.x-me.pos.x)/spanX
      output[o+1] = float32(other.pos.z-me.pos.z)/spanZ
      output[o+2] = 1
      output[o+4] = float32(other.hp)/hpScale
    output[o+3] = float32((w.cogs[j].hp > 0).int)
    if kinOn:
      for b in 0..<Loci:
        output[o+5+b] = if ((kin.genes[j] shr b) and 1'u32) == 1'u32: 1'f32 else: -1'f32
    output[o+37] = rTo(j)
    output[o+38] = points(j)
    output[o+39] = float32(held[j])/10
  # Own row, column 40: the territory boost where I stand, as a fraction of the maximum.
  if kinOn and not hideKin:
    output[FfaIdentityOffset + slot*FfaIdentityRowSize + 40] =
      float32(w.territoryBoost(slot, kin))/float32(TerritoryBoostPercent)
  # Control hearts.
  for i in 0..<FfaHeartRows:
    if i >= w.controlHearts.len: continue
    let o = FfaHeartOffset + i*FfaHeartRowSize
    let heart = w.controlHearts[i]
    output[o] = cx(heart.pos)
    output[o+1] = cz(heart.pos)
    output[o+2] =
      if heart.owner < 0: -1'f32
      elif not kinOn: 0'f32
      elif heart.owner == slot.int32: 1'f32
      else: rTo(heart.owner.int)
    if i < w.heartCaptures.len:
      output[o+3] = float32(w.heartCaptures[i].ticks)/HeartCaptureTicks
      output[o+4] = float32(w.heartCaptures[i].contested.int)
    output[o+5] = float32((kinOn and heart.owner == slot.int32).int)
  # Great hearts.
  if kinOn:
    for g in 0..<FfaGreatRows:
      let o = FfaGreatOffset + g*FfaGreatRowSize
      let heart = w.greatHearts[g]
      output[o] = cx(heart.pos)
      output[o+1] = cz(heart.pos)
      output[o+2] =
        if w.tick < heart.dormantUntil: -1'f32
        elif heart.progress > 0: 1'f32
        else: 0'f32
      output[o+3] = float32(heart.present)/16
      output[o+4] = float32(heart.progress)/GreatHeartCaptureTicks
      output[o+5] = float32(max(0'i32, heart.dormantUntil-w.tick))/GreatHeartDormantTicks
  # Terrain.
  w.encodeTerrainBlock(slot, output.toOpenArray(FfaTerrainOffset, ObservationSizeFfaV1-1), bodies)
  var wet, dry = 0
  for j in 0..<Seats:
    let body = bodies[j]
    if body < 0 or j == slot: continue
    if inWater(w.cogs[body].pos): inc wet else: inc dry
  output[FfaTerrainOffset+54] = float32(wet)/8
  output[FfaTerrainOffset+55] = float32(dry)/8
  output[FfaTerrainOffset+56] = 0
  output[FfaTerrainOffset+57] = 0

proc encodeObservation*(w: World, slot: int, output: var openArray[float32],
    bodies: array[Seats, int], version: ObservationContractVersion) =
  ## The observation of the given contract. v1 is the encoder above, called unchanged;
  ## v2 writes the same v1 floats in columns 0 .. ObservationSize-1 and the terrain
  ## block after them; v3 writes v2's floats and the scoreboard block after them.
  if slot notin 0..<Seats or output.len != observationSize(version):
    raise newException(ValueError, "invalid neural observation dimensions or seat")
  case version
  of ocV1: w.encodeObservation(slot, output, bodies)
  of ocV2:
    w.encodeObservation(slot, output.toOpenArray(0, ObservationSize-1), bodies)
    w.encodeTerrainBlock(slot, output.toOpenArray(ObservationSize, ObservationSizeV2-1), bodies)
  of ocV3:
    w.encodeObservation(slot, output.toOpenArray(0, ObservationSize-1), bodies)
    w.encodeTerrainBlock(slot, output.toOpenArray(ObservationSize, ObservationSizeV2-1), bodies)
    w.encodeScoreboardBlock(slot, output.toOpenArray(ObservationSizeV2, ObservationSizeV3-1))
  of ocFfaV1:
    # Hosted and default callers: the match's kinship, no mask (masks are training-only).
    w.encodeFfaObservation(slot, output, bodies, activeKinship)
proc encodeObservation*(w: World, slot: int, output: var openArray[float32],
    version: ObservationContractVersion) =
  if slot notin 0..<Seats or output.len != observationSize(version):
    raise newException(ValueError, "invalid neural observation dimensions or seat")
  w.encodeObservation(slot, output, w.observedBodies(slot), version)

proc resetAimMemory*(m: var AimMemory) =
  m.tick = -1
  for i in 0..<Seats:
    m.bodies[i] = -1
    m.positions[i] = Point()

proc recordAimMemory*(m: var AimMemory, w: World, slot: int, bodies: array[Seats, int]) =
  ## Record once per decided tick, on the same pre-step world the actions were decoded
  ## against, with the identities that decode resolved.
  m.tick = w.tick
  for identity in 0..<Seats:
    let body = bodies[identity]
    m.bodies[identity] = body
    m.positions[identity] = if body >= 0: w.cogs[body].pos else: Point()

proc oneTickStep(a, b: Point): Point =
  ## b - a when it can be one tick's movement; zero across a respawn or teleport.
  let dx = b.x - a.x
  let dz = b.z - a.z
  if abs(dx) > TeleportStep or abs(dz) > TeleportStep: Point() else: Point(x: dx, z: dz)

proc plannedStep*(w: World, slot: int, goal: Point, sneak: bool): Point =
  ## The move the world will make for the seat on the coming tick towards `goal` (the
  ## command's goal, clamped as the step clamps it): the same waypoint, speed (carrying,
  ## FFA-kin territory boost, sneaking, wading) and trench damping as mechanics.nim, before
  ## any blocking or yielding. Zero when the seat is already there.
  let me = w.cogs[slot]
  let clamped = Point(x: clamp(goal.x, (minX()+100).int32, (maxX()-100).int32),
                      z: clamp(goal.z, (minZ()+100).int32, (maxZ()-100).int32))
  let dest = w.waypointFor(slot, me.pos, clamped)
  var speed = if me.carrying: MoveSpeed*7 div 10 else: MoveSpeed
  speed = boostedSpeed(speed, w.territoryBoost(slot))
  if visionRulesVersion >= 26 and sneak: speed = speed div 2
  if visionRulesVersion >= 30 and riverBlend(me.pos.x.int, me.pos.z.int) > 0 and
      terrainHeight(me.pos.x.int, me.pos.z.int) < RiverWaterHeight:
    speed = speed div 4
  if distance2(me.pos, dest) <= speed.int64*speed: return Point()
  result = direction(me.pos, dest, speed)
  let trench = w.trenchAt(me.pos)
  if trench >= 0:
    let t = w.trenches[trench]
    if abs(me.pos.x+result.x-(t.x+t.w div 2)) > abs(me.pos.x-(t.x+t.w div 2)): result.x = result.x div 5
    if abs(me.pos.z+result.z-(t.z+t.h div 2)) > abs(me.pos.z-(t.z+t.h div 2)): result.z = result.z div 5

proc leadAimPoint*(w: World, slot, identity, body: int, m: AimMemory, ownStep: Point): Point =
  ## Contract v2 identity aim: the point a shoot order issued now must name so that the
  ## gun's ray meets `body` if the body keeps last tick's velocity and the seat keeps
  ## making `ownStep` (see LeadTargetMoves). The body's velocity is its last-tick
  ## displacement as the seat itself could observe it: only when the same body was seen
  ## under the same identity one tick ago; a first tick, a gap, a respawn or a teleport
  ## counts as zero. The seat's own step is the move its movement head orders this tick
  ## (plannedStep), which is what the world will do, not a guess from the past. With a
  ## still target and a still seat the point is the body's position, the contract v1 aim.
  let now = w.cogs[body].pos
  result = now
  if m.tick == w.tick - 1 and m.bodies[identity] == body:
    let u = oneTickStep(m.positions[identity], now)
    result.x += u.x * LeadTargetMoves.int32
    result.z += u.z * LeadTargetMoves.int32
  result.x -= ownStep.x * LeadOwnMoves.int32
  result.z -= ownStep.z * LeadOwnMoves.int32

proc goalCandidate*(w: World, slot, movement: int): (bool, Point) =
  ## Where movement head index `movement` sends the seat, and whether that candidate
  ## exists now (a missing heart or an unavailable/unseen pickup keeps the goal).
  let me = w.cogs[slot]
  let flip = mapFlip(slot)
  if movement in 1..10:
    if movement-1 < w.controlHearts.len: return (true, w.controlHearts[movement-1].pos)
  elif movement in 11..42:
    let i = movement-11
    if i < w.pickups.len and w.pickups[i].readyAt <= w.tick and
        w.canSeePoint(slot,w.pickups[i].pos): return (true, w.pickups[i].pos)
  elif movement >= 43 and movement <= 50:
    let delta = Directions[movement-43]
    return (true, point(clamp(me.pos.x.int+flip*delta[0]*200,minX(),maxX()),
                        clamp(me.pos.z.int+flip*delta[1]*200,minZ(),maxZ())))
  (false, me.pos)

proc aimCandidate*(w: World, slot, aim: int, bodies: array[Seats, int],
    version: ActionContractVersion, memory: AimMemory, ownStep: Point): (bool, Point) =
  ## Where aim head index `aim` points under `version`, and whether that candidate
  ## exists now (an identity nobody visible carries keeps the aim). `ownStep` is the
  ## seat's planned move for this tick (read under v2 only).
  let me = w.cogs[slot]
  let flip = mapFlip(slot)
  if aim in 1..16:
    let body = bodies[aim-1]
    if body >= 0:
      return (true, if version == acV2: w.leadAimPoint(slot, aim-1, body, memory, ownStep)
                    else: w.cogs[body].pos)
  elif aim >= 17 and aim <= 24:
    let delta = Directions[aim-17]
    return (true, point(clamp(me.pos.x.int+flip*delta[0]*5000,minX(),maxX()),
                        clamp(me.pos.z.int+flip*delta[1]*5000,minZ(),maxZ())))
  (false, me.aim)

proc orderedAim*(w: World, slot: int, command: Command): Point =
  ## The aim the world holds once `command` is applied, as mechanics.nim applies it: an
  ## aim order wins; else a walk towards somewhere else aims there; else the current aim.
  if command.aim != Point(): command.aim
  elif command.walk and command.goal != w.cogs[slot].pos: command.goal
  else: w.cogs[slot].aim

proc teammateInLine*(w: World, slot: int, aim: Point, radius = FireHoldRadius.int32): bool =
  ## Whether a teammate's body, as the seat itself can see it (fog-gated, apparent team,
  ## and the gun's own line-of-sight test), lies within `radius` (default FireHoldRadius,
  ## the gun's hit tolerance) of the segment from the seat to `aim` and no farther along
  ## it than `aim`. Integer geometry only.
  let origin = w.cogs[slot].pos
  let dx = int64(aim.x) - origin.x
  let dz = int64(aim.z) - origin.z
  let len2 = dx*dx + dz*dz
  if len2 == 0: return false
  for body in 0..<Seats:
    if body == slot or w.cogs[body].hp <= 0: continue
    if not w.visible(slot, body) or w.observedTeam(slot, body) != team(slot): continue
    let p = w.cogs[body].pos
    let ex = int64(p.x) - origin.x
    let ez = int64(p.z) - origin.z
    let along = ex*dx + ez*dz
    if along < 0 or along > len2: continue
    # perpendicular^2 = e2 - along^2/len2 <= R^2  <=>  e2*len2 - along^2 <= R^2*len2
    # (|e|^2, |d|^2 < 2^27 on a 6400 x 4000 map and R <= MaxFireHoldRadius < 2^11, so
    # every product fits in 63 bits).
    let e2 = ex*ex + ez*ez
    if e2*len2 - along*along > radius.int64*radius*len2: continue
    if visionRulesVersion >= 9 and not w.lineClear(origin, p): continue
    return true
  false

proc holdFire*(w: World, slot: int, command: var Command, radius = FireHoldRadius.int32): bool =
  ## The decoder fire hold: drop the shoot order when a teammate is in the line of fire
  ## (teammateInLine of the aim the order leaves, within `radius` of it). The aim,
  ## movement and every other part of the command are untouched, so the world still turns
  ## to face the target. Applies to the shoot order whichever weapon it would fire.
  ## Returns whether the order was held.
  if not command.shoot or w.cogs[slot].hp <= 0: return false
  if not w.teammateInLine(slot, w.orderedAim(slot, command), radius): return false
  command.shoot = false
  true

proc decodeActions*(w: World, slot: int, actions: openArray[int32],
    bodies: array[Seats, int], version: ActionContractVersion,
    memory: AimMemory, fireHold = false): Command =
  ## The shared decoder of every host. `version` selects the identity-aim rule; the
  ## memory is read only under contract v2 (the host records it with recordAimMemory
  ## after decoding each tick). `fireHold` applies holdFire to the decoded command (the
  ## bundle's decoder option; false decodes exactly as before).
  if slot notin 0..<Seats or actions.len != ActionSizes.len:
    raise newException(ValueError, "invalid neural action dimensions or seat")
  for i,size in ActionSizes:
    if actions[i] < 0 or actions[i] >= size.int32:
      raise newException(ValueError, "neural action index out of range")
  let me = w.cogs[slot]
  result.goal = me.pos
  result.aim = me.aim
  if me.hp <= 0: return
  result.walk = true
  let (goalFound, goal) = w.goalCandidate(slot, actions[0].int)
  if goalFound: result.goal = goal
  result.shoot = actions[2] != 0
  result.chargeGrenade = actions[3] != 0
  result.sneak = actions[4] != 0
  let ownStep = if version == acV2 and actions[1] in 1'i32..16'i32:
      w.plannedStep(slot, result.goal, result.sneak)
    else: Point()
  let (aimFound, aim) = w.aimCandidate(slot, actions[1].int, bodies, version, memory, ownStep)
  if aimFound: result.aim = aim
  if fireHold: discard w.holdFire(slot, result)
proc decodeActions*(w: World, slot: int, actions: openArray[int32],
    bodies: array[Seats, int]): Command =
  ## Contract v1: an identity aim is the body's current position.
  w.decodeActions(slot, actions, bodies, acV1, default(AimMemory))
proc decodeActions*(w: World, slot: int, actions: openArray[int32],
    version: ActionContractVersion, memory: AimMemory): Command =
  if slot notin 0..<Seats or actions.len != ActionSizes.len:
    raise newException(ValueError, "invalid neural action dimensions or seat")
  # Identity aim is the only head that resolves bodies; keep the cost to that case.
  if actions.len == ActionSizes.len and actions[1] in 1'i32..16'i32:
    return w.decodeActions(slot, actions, w.observedBodies(slot), version, memory)
  var none: array[Seats, int]
  for i in 0..<Seats: none[i] = -1
  w.decodeActions(slot, actions, none, version, memory)
proc decodeActions*(w: World, slot: int, actions: openArray[int32]): Command =
  w.decodeActions(slot, actions, acV1, default(AimMemory))

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

# Observation contract "v2 + K user inputs" (PLAN-neural-basic-io part A): v2's 506 floats
# unchanged, then K floats the seat's policy.bas sets with neuralInput(i, v) (fed as
# v / 1000, one tick late). Contract id paintbot-pw.rules39.obs.v2u<K>, K = 1 .. 64; the
# hash is the SHA-256 of the id, one per K.
const
  MaxUserInputs* = 64
  UserInputLimit* = 1_000_000'i32
  UserInputsContractHashes*: array[MaxUserInputs, string] = [
    "bd80f4d35088c1f5e673e9b91d16df826e1cfb0e590185dbf4d8bf59af0bdb04",
    "b064de43c261ada93a1167b4098635120b6bcc11c4643d1e771a1d237b4e9f06",
    "a8c43d03947e654268ea4ead56e39bb44040a1bcea39b9d19d717fbec92ee6ce",
    "43300aa2a94a47ecb229f22d4b63debfe7f762b88f448c26343718cdcc3b8884",
    "f88a394156ad5b4028d9a1269f7bb8767a08160230d60c1fc54c9965d262ea16",
    "a224301c5715b80494bb005ffc73c08b2e4f1eb89a781e90e4f49c09759db76b",
    "0482b823f6983e06a2432f8d93a5d7aafffa7bca0e1bb092d52af5dfa0757047",
    "b9d762a882962140998c84053d86c15f26fd3077411738d8b3c967039cba9ec5",
    "4d81525b758cf22154c25f5e1539cc93f085800c3fde69b467fca3bc95faef7b",
    "52ce5dacb236d11f886a0a5955d4dd26988de3d2b581adeb7439fe14ae87abaa",
    "0a94bffcff438486394ea32fa116983e75e82aa4d84a51354cb4d63d1f6b298b",
    "d462df74017a50aff2dca88a1c50a201981878feba289163650cb593dde9a504",
    "c6a4f25511a73c3ac9bb7dff8f145e1f69a2d40b2b2a983fd18e50097d8afb71",
    "da7c80c023075b34b9821eef3123495a052589c51eff12b397693c1c6cc8e8d4",
    "02609eb49e93691c7aece2cf39e360afb6663dc7d15ab9dfa6ef985b957cf946",
    "65631635da1f04338731d96c7f022faf12f0a707093297f5e5c360d0f9a79343",
    "180c696fc827fff714c659ed7cee337f335d8faa6945113fd36c7e35989e254b",
    "3c8bd14c556499e93236b8e849b92dc9b9dea5e446f9c487f0bb6b7c423896ea",
    "40a31c9ebbd76707555efd4abde6636ec94cbd49e479314eeb4f4a02bde64bd8",
    "901212508eee6ff969fa5027b42351e1554865621a99209285c91262e16d32b2",
    "a740219cfdf633d04c82f2291305992ac0db0a34970869fef0bb0794769f5066",
    "a9d75c0b2e0826eb189f5d0d483a21d1ae049a2f6e07af0ed01be79b3b36f956",
    "7033d9f93e22941a29a6f01675dfc2cd178eebf4de81e450d799dcb5221b1647",
    "7956f4c904322650d7ea5273de104ed32828cb31dcb6bcb4a930966d8366c061",
    "71ef99882d491f19ca7e41e66d14db83232bfc90e7dceb3cfcd2a44bb3ed08e7",
    "e3182cdd6f12fb0d463018003739667d09101da8980e5520d4db475cfcd272ae",
    "42caf7901dd69f97e066d1d28f140f61f6234da9eed2f2a5064873f0e1da3ef7",
    "390d35740053c8404923040fdfa06b39d843d15e5a888e68fc356acc6aa0a6f0",
    "06f6a35f115ff03b0c298a8ef144551cf94b5998be05afc6e2656a62cfa276ca",
    "642f23700636283703121ea5b7edbc23c4b472ad2dd4777c822c7295d2340b46",
    "b28ddf9ffd8b637c12c5f45b6c988de208693a86552c12fd11fcf5ce123622fa",
    "94373a1ce8a95bbcf99f8fcb1d2acc07e8fb19ab13c99591389ac2cff807e7c3",
    "06cfb7f302ea35601752ace367eca0e3287dc6e4159353b6eb0c28ca01965b5e",
    "6a02b9c79290882e46edf61326d90babbc83d0ec77d4df58d68039a5b33885f3",
    "2eb7e79e679f31f62e2ca5e817da0ff0d621ae46351c087984ead85654dbcf9e",
    "d152b200f412c295f831909618f3584df95d96fc3e17a86f3be97d0baf7d9e23",
    "bc6c6fb0bf5b5e5664e4e8ae22ae8fb9d6b28794dcfdcee9b795d1a7b3078b11",
    "1432e1aa7f28e246aaef7c0cf0963e00720cb1a44a0cbfcdca125eda20ef4a27",
    "2a31af3957ed94045573f32fd303f7e57e366363013b948f2246b66809f7ad44",
    "b7165e5c070ae3cdab349e8e7d15a110c1d1890d23284642dbe1c9ff7f3365a2",
    "586184a1599b0335412c6d7e14b1c76f69e4aacf93e424b74922113a1bc3b89d",
    "3c782fc7a182d8b81b202642142d53706ce594aee551fdc62d9497b1501a36b8",
    "07ecbced8946a1695f509e28fe2d5b695940777a5384b3a760cdacce47834a83",
    "4098089260bdd7948a2a450d6ce1e1434de581e22cd23673f95e08ebd808bf81",
    "96c3068f78a84995ff1b502748c989b7cff5303bf17c6c64d7667afaad26a691",
    "aeedab6461211ef5cafdb6286fa6758f431d6eea0750461738fc5e2d880052c2",
    "996dd6dbf91cf23439f90a288152e6cc9ab4f25f89cb7e3f9b7e5e01e9223cdd",
    "78585d56ed2391fc66815f303538461c9bf10af4e7aa1fbaa78b7128372e94a9",
    "3b0f23bb1eb4bf0106ef2efd6f64324a28e0868d83b7c2a5313bdae7774e701d",
    "c83ab5040e88a23a801a8538f6870fb4267c96993ce4110cabe72f8e6e46ba81",
    "0080ce2f02f666b573fd4fec22a9798d859a3e7089d09cfaf4996ffdf29865f5",
    "d3fc3b556d871592c207cc80aabfbc581d5c9c6eb3faa2826036d2ac0fba865b",
    "8a0412302026890f3fdfc40579f1df4651ab2670f8494b73665df61b68df65a6",
    "41782176f1e72ad9d2da6285c795c18eca184ab574c064dc1adc59a271d192d7",
    "1ea3790b04861d4f9a330b2aa3a55ef0246f03ab186f4391b3aaedcf878dc99c",
    "90936702c76afa8002417ca47cb285d13257f413aa5ba3998aef322206f68f3b",
    "a903876802cfa263845d3cea141bbdd67cc711e5e2cbdc53c8a267a2543fcfe7",
    "0818f6e6dab081ea6b0394f8f6abce0ec67c25753f7453d400365223f662e3d8",
    "6110c5dce4d96f1bfb25c480f7199aa106519730d52f5853d0b8663cbc475e11",
    "f1a2b5ba3e88f4b78ce06034496314da93c1b44c452be21b58c432e9a5e9e6ef",
    "8b8c7d85b334af6c9b2944c015ec3e1247e73bcd1b7beb9fdf3dacf6ea3110a7",
    "2251315296a6fb0133ce828aa99f52cf2074e69a650d973e336fc12cdea825f4",
    "ded9592cbbceaa39e384893ccb4346c77c42e61b544b2420b2ffcc5794c7edc8",
    "18a5141bf7d78fdf93524757bf261f367cfebe3b489fb6f2988936375bb8f4aa"
  ]
proc userInputsContractId*(k: int): string = "paintbot-pw.rules39.obs.v2u" & $k
proc userInputsFromHash*(hash: string): int =
  ## K when `hash` names observation contract v2u<K>; 0 otherwise.
  for i, h in UserInputsContractHashes:
    if h == hash: return i + 1
  0
# Observation contract "v3 + K user inputs": v3's 514 floats (v2's 506, then the scoreboard
# block) unchanged, then the K user inputs exactly as v2u<K> feeds them. Contract id
# paintbot-pw.rules43.obs.v3u<K>, K = 1 .. 64; the hash is the SHA-256 of the id, one per K.
const
  V3UserInputsContractHashes*: array[MaxUserInputs, string] = [
    "8086b6f36b9c2cf07e9e6586e97221e484f809e08669075663c5dcf9cb63ac36",
    "ca964b56d4b488655b32aae55f7d75d5d0bacbbbaf394956a8e689a61aacb455",
    "610439dc76c3fce685e386984c89ba6608047840c202e75e8471c5f836e5ac8f",
    "5d747520806f13a50c308df52fb8fbe48bf37267dc56682e15e612519741795d",
    "3733cfe85e510fdf9b702f83db1fd045603e883dd521dc381dae71dc24096b47",
    "3759d22dc27f9a636d67df7d5aa6b0fd569385ad79f00a99aa9937adee3866cc",
    "078d05d86e3d6a7c567a59e85c5052e5898a9e638d05f44a8037c4cb69ab7a11",
    "3df9e895a5534e81362bae38a245c11d7d677f660a6a9f15066f8542a15f814e",
    "942ff27110190e8f59c790b3a238bb36e3e24fe0810a01e0e62407fe39292bf0",
    "32af93f613fa6eba4f9ad34e81ecdc975b9c8b6b1a2f181eceae6be313a985f2",
    "ab7a66b3fa0f992aac3a363866ccb1a5d42ab8913dc4c078ab86392efc8dc3bd",
    "2c92b3897a89ec43f8e643af039e769efd6624d91fd09508700a005df8269b19",
    "1abf7b958c62810b8874f476423bfebc1d26d530e8305f8e8c013fbdea3ef448",
    "7ff09120660978dbf145e9a426aedd32df5c599c9b317ecbcd6cf3fdc99738ad",
    "6ccc6ee131b6713c85546fbac5ed7e22142b4b8e25bc46ede228f46099399e2e",
    "26c647d0c254edf7ce9b29bc2eb005997afa01bf5335ff00692cf6683d1df24d",
    "727cf5714151451f3d2416e75a390caff8b6c845e46fc7e81c825e548e1224de",
    "f9ca2d1f7761fcc4b95a6cde30c77252f0762bb97cb7102b504614929854345f",
    "5760383d267aaae222da3520ff15e4aa28ac40f10203a60ddffde3379ea36786",
    "899b3292526f5d554b9208ab31a72d47fab57772b8076d040cfc022571e4fee0",
    "c2ae79efbcbbbad9358aafa16d8800c9dfe448a8057a965e322df6fb4bf96ced",
    "d350354a83a439ccf969d2647b9a10192f6fdddd45d4debbed6507af20cf82aa",
    "22fc8b4438abf44f2b67fe2127612c35762a222ded6eb1af893a60e9d6f490d8",
    "501418109b1bf8a0cc873debdecd87c9a9ddc7ffaf088078924242f0e5a8970a",
    "ecbeee86bf7a959f529e17bc732bba879cdf4cad6c5c46c6164ab25b02980412",
    "66dc26a93d0b548d98e5077ae5ad832b25c1d475df0f78a78f743709385baab1",
    "6962e9609980d86b5b075ee0d5c46cea2ff83b2a32e184012875627d6cb79bf8",
    "0e42592253d6c34969473065cba39e97d080165f1d22c3c755d055d8b791e7bd",
    "e6539f1a85484ff132710cf56f0aecb5d9f803256db66987765147d1d0c67566",
    "7d4e9709131fcda3223ae2001b2d81d4fea4b3e5ad875407dd3a10a6035b9b46",
    "e2dc42dbc2357e54241749c8fc57f2ea680d82d0e1b06d6acb463a2075b8a342",
    "92c7b22891330d11753da7215bad0d300eb0990955a6caf2f8dc003917646d3d",
    "f58000ed67c49e04a60b8c9267232a1b80ebb9a911e451262ebd74f0444ef514",
    "9eccec352a94f907b86c2da3c77d70b5bc124533b9a433769ab64fd995edfb20",
    "842711c2a9472dca8d439e9a282b37dffa0c3181aa3acf30f083e4afb5526fff",
    "79b3107563784d91accf0ac782cb5abfcb557a479ed7fe36cd9ef52865b95bf7",
    "52f47f77cf7bff9c918665b4bb8ad6203ee05e0b7aa0a56c7e2eeeb74747df90",
    "45b6557b86984eb6530bea5f94805b09e754eeb40cb8f4febd71aaeaa8daf32e",
    "cff4448d357e59d79fd855fee804e93b2af374de8f7a0e3f05c25c3991490707",
    "5c84bec7f53a3f908730eace5e4b46e54fbd7b667810dd0d3ffa4a096b0c0e2b",
    "5b8875b4ad74933d12cb56485f7cae2bed4d6afe03353a51edc0e4bdf9453a85",
    "de33870fb5abaf4c9389f8b34fc6de29996a918a448102389eee584c62d5b584",
    "31261ac0c63b3895a4477b77541586189832efa70cc3b128c13928c7d86d754c",
    "e4c7b3167e32875d1021af2c43d47c1ada6fb5009168996dd6f0310ffd50ab10",
    "470eecc6ad180e003f5eadaa494cc4ff0d7081a5e3ed6d852e094657c3c88d9e",
    "3dcfb44fca9e12451c95d5dd9125873264ac8c9f5b4b70e683e1a537d85e159d",
    "883774ce00e428c29f6a5c89a093e66bac369f7ab347ddf8fb6c3ca753599d84",
    "aefffc802bf72a33161bef617bf61d4dbbe9a3d341d170f6ebfd1ed733d6b894",
    "1d3ab99e6c3382242ea34b33f4538ab67f43533b3931a7428dea2b158f69603e",
    "db29ce7ce8c2e198084c924d004ea3b53007d51fbdbf7a98c17af3a4933b4287",
    "ea55268d4a10466c2505b7f358b3b9edf18415b45b380cbcf251cd6c6f72e704",
    "844c8e69d776b025687c5e1e78532bca2cced387800970b710a21fb45e9fa428",
    "f3906987e82cb18b873a1b8148465f115d9269cb132ef6abee1b4126638a044b",
    "396a6d9c4516c5623212f43d888932b83a92a838d515db6c487e30098fbe710a",
    "240c98819e335e604a618e843afb6f833f26d4b466f47d3a3cd2e2ca389ea8d6",
    "c1eb1cdc6272aaa3cafdace231a5f6b5d8ea97f2583556d13ac0f21202fb02c3",
    "8013591018d6092ab4d4adb9c86ab62023556c11dd40b632549e4cc6006c8168",
    "166dc93a8c95c7d833ea6e3255946383b03d10b83a8b05e429c72e039095f9ee",
    "4f5c229d86ea1a0a440010ea32716e816dc0ec20cf4ec2c44542ea836df3bab1",
    "1ca0805827c8b53cb75984fdcc4eca4c72b6df9e348e970dab661079ca227089",
    "ecdc9c3c4abdfc647c0b552d9f09fd90fdba797a7ffc3083b6406da2bacc5a85",
    "a0c334d7c41043c6ad1cac81741a9cd831b9ad34d4f171e654da9e7ce5808f01",
    "736562060cb8eafb0c9568ba560ebfdc187d9dca245909f7b4fa9c1c1ae319bf",
    "1695203c740b769ff61f9bd18c4687f517db1664069b3ae47e7466060cb77dfb"
  ]
proc v3UserInputsContractId*(k: int): string = "paintbot-pw.rules43.obs.v3u" & $k
proc v3UserInputsFromHash*(hash: string): int =
  ## K when `hash` names observation contract v3u<K>; 0 otherwise.
  for i, h in V3UserInputsContractHashes:
    if h == hash: return i + 1
  0
proc userInputsContractHash*(version: ObservationContractVersion, k: int): string =
  ## The hash of observation contract v2u<K> (version ocV2) or v3u<K> (ocV3), K = 1 .. 64.
  if k notin 1..MaxUserInputs or version notin {ocV2, ocV3}:
    raise newException(ValueError, "no user-input observation contract for that version and count")
  if version == ocV3: V3UserInputsContractHashes[k-1] else: UserInputsContractHashes[k-1]
proc userInputFeature*(value: int32): float32 =
  ## The float a user input value feeds the net: float32(v) / 1000 (v already clamped).
  float32(value) / 1000'f32
proc clampUserInput*(value: int32): int32 = clamp(value, -UserInputLimit, UserInputLimit)
proc encodeObservationInputs*(w: World, slot: int, output: var openArray[float32],
    bodies: array[Seats, int], inputs: openArray[int32], version = ocV2) =
  ## Observation contract v2u<K> (version ocV2) or v3u<K> (ocV3), K = inputs.len: the
  ## version's 506 or 514 floats, then the K user inputs.
  if version notin {ocV2, ocV3}:
    raise newException(ValueError, "user inputs need observation contract v2 or v3")
  let n = observationSize(version)
  if inputs.len notin 1..MaxUserInputs or output.len != n + inputs.len:
    raise newException(ValueError, "invalid neural observation dimensions or seat")
  w.encodeObservation(slot, output.toOpenArray(0, n-1), bodies, version)
  for i, value in inputs: output[n+i] = userInputFeature(value)

# Decoder strafe legs (bundle option decoder.strafe_legs, schema 2; not a contract change):
# base.bas's footwork in contact (its planLeg), as pw-diag measured it (first-contact.md,
# lever 2). While the seat sees an apparent enemy within range and is not in a trench,
# its movement head is replaced by a compass step: a leg perpendicular to the nearest such
# enemy, turned 3/4 lateral plus the direction to the objective the movement head chose
# (a heart or pickup), held for legs[0]..legs[1] ticks, reversing across the line with
# probability reverse_permille/1000 at every new leg. A shoot order the gun can take this
# tick is only issued with at least shot_legs[0] ticks of the current leg left: when fewer
# remain a new leg of shot_legs[0]..shot_legs[1] ticks starts on that tick, so the seat's
# own movement over the windup is the planned step contract v2's lead subtracts. No order
# is dropped. Out of contact the leg ends. Integer geometry only; the random draws (two
# per new leg: reverse, then length) come from a stream the seat owns, SplitMix64 seeded
# from the match seed and the slot like the sampling stream but with its own salt, so it
# never shifts the sampling draws and the world's rng is untouched.
type
  StrafeOptions* = object
    enabled*: bool
    range*: int32                   # contact: an apparent enemy within this distance
    legTicks*: array[2, int32]      # leg length without a shot, inclusive
    shotLegTicks*: array[2, int32]  # leg length when a ready shot starts it, inclusive
    reversePermille*: int32         # chance per new leg of reversing across the line
  StrafeState* = object
    leg*: int32        # ticks left on the current leg (0 = none)
    zig*: int32        # +1 / -1: which side of the line to the threat
    direction*: int32  # compass 0..7 of the current leg (movement index 43+direction)
    legs*: int32       # legs started (telemetry)
    ticks*: int32      # decisions whose movement head the strafe replaced (telemetry)

const
  StrafeSalt* = 0x5354524146450000'u64  # "STRAFE" in the high bytes, slot below it
  DefaultStrafeRange* = 5250'i32        # base.bas's contact range (d2 <= 27562500) = GunRange
  DefaultStrafeLegs* = [3'i32, 6]
  DefaultStrafeShotLegs* = [6'i32, 9]
  DefaultStrafeReversePermille* = 800'i32
  MaxStrafeRange* = 20000'i32
  MaxStrafeLegTicks* = 72'i32
  MinStrafeShotLegTicks* = LeadOwnMoves.int32 + 1  # the order tick plus the windup's moves
  StrafeFirstCompass* = 43
static: doAssert DefaultStrafeRange == GunRange and MinStrafeShotLegTicks == 6

proc defaultStrafeOptions*(): StrafeOptions =
  StrafeOptions(enabled: true, range: DefaultStrafeRange, legTicks: DefaultStrafeLegs,
    shotLegTicks: DefaultStrafeShotLegs, reversePermille: DefaultStrafeReversePermille)

proc strafeOptionsError*(o: StrafeOptions): string =
  ## "" when the parameters are usable; otherwise why not (the host and the native ABI
  ## reject the same values).
  if o.range < 1 or o.range > MaxStrafeRange: return "range must be within 1 .. " & $MaxStrafeRange
  if o.legTicks[0] < 1 or o.legTicks[0] > o.legTicks[1] or o.legTicks[1] > MaxStrafeLegTicks:
    return "legs must be [min, max] with 1 <= min <= max <= " & $MaxStrafeLegTicks
  if o.shotLegTicks[0] < MinStrafeShotLegTicks or o.shotLegTicks[0] > o.shotLegTicks[1] or
      o.shotLegTicks[1] > MaxStrafeLegTicks:
    return "shot_legs must be [min, max] with " & $MinStrafeShotLegTicks & " <= min <= max <= " & $MaxStrafeLegTicks
  if o.reversePermille < 0 or o.reversePermille > 1000: return "reverse_permille must be within 0 .. 1000"
  ""

proc strafeRng*(matchSeed: int32, slot: int): Rng =
  ## The seat's strafe stream for a match (its own salt: independent of the sampling stream).
  initRng(matchSeed, StrafeSalt xor (uint64(slot+1) shl 32))

proc strafeSeed*(matchSeed: int32, slot: int): uint64 =
  strafeRng(matchSeed, slot).state

proc initStrafeState*(slot: int): StrafeState =
  ## No leg; the first leg side alternates by pairs of team members, as base.bas seeds zig.
  result.zig = if (slot div 2) mod 4 < 2: 1 else: -1

proc isqrt64(n: int64): int64 =
  if n <= 0: return 0
  var x = n
  var y = (x+1) div 2
  while y < x:
    x = y
    y = (x + n div x) div 2
  x

proc strafeActions*(w: World, slot: int, actions: var array[ActionSizes.len, int32],
    bodies: array[Seats, int], options: StrafeOptions, state: var StrafeState, rng: var Rng,
    forbidden: ObjectiveMask = default(ObjectiveMask)): bool =
  ## Apply the strafe to the seat's selected head indices on the pre-step world, before
  ## they are decoded: returns whether the movement head was replaced (by a compass index
  ## 43..50). `bodies` are the seat's apparent identities (observedBodies). Compass
  ## headings the forbid mask lists are never taken. Options disabled = untouched.
  if not options.enabled: return false
  let me = w.cogs[slot]
  if me.hp <= 0 or w.trenchAt(me.pos) >= 0:
    state.leg = 0
    return false
  var threat = -1
  var best = int64(options.range) * options.range
  for identity in 0..<Seats:
    let body = bodies[identity]
    if body < 0 or body == slot or w.cogs[body].hp <= 0: continue
    if w.observedTeam(slot, body) == team(slot): continue
    let d = distance2(me.pos, w.cogs[body].pos)
    if d > int64(options.range) * options.range: continue
    if threat < 0 or d < best:
      threat = body
      best = d
  if threat < 0:
    state.leg = 0
    return false
  let gear = w.equipment[slot]
  let ready = if gear.sprayCan: gear.sprayCooldown == 0 else: me.cooldown == 0 and gear.windup == 0
  let wantShot = actions[2] != 0 and ready
  if state.leg <= 0 or (wantShot and state.leg < options.shotLegTicks[0]):
    if int32(rng.next() mod 1000'u64) < options.reversePermille: state.zig = -state.zig
    let span = if wantShot: options.shotLegTicks else: options.legTicks
    state.leg = span[0] + int32(rng.next() mod uint64(span[1] - span[0] + 1))
    inc state.legs
    # Perpendicular to the line to the threat, scaled to 1000, on the zig side.
    let tx = int64(w.cogs[threat].pos.x) - me.pos.x
    let tz = int64(w.cogs[threat].pos.z) - me.pos.z
    let reach = isqrt64(tx*tx + tz*tz)
    var lx, lz = 0'i64
    if reach > 0:
      lx = -tz * 1000 * state.zig div reach
      lz = tx * 1000 * state.zig div reach
    # Keep some progress toward the objective the movement head chose (heart or pickup).
    if actions[0] in 1'i32..42'i32:
      let (found, goal) = w.goalCandidate(slot, actions[0].int)
      if found:
        let fx = int64(goal.x) - me.pos.x
        let fz = int64(goal.z) - me.pos.z
        let far = isqrt64(fx*fx + fz*fz)
        if far > 60:
          lx = lx * 3 div 4 + fx * 1000 div far
          lz = lz * 3 div 4 + fz * 1000 div far
    # The allowed compass heading nearest the leg (a diagonal's projection is scaled by
    # 1/sqrt 2 so all eight headings compete fairly); movement compass steps are mirrored
    # for team 1 exactly as goalCandidate mirrors them.
    let flip = mapFlip(slot).int64
    var bestScore = low(int64)
    var heading = -1
    for k, delta in Directions:
      if forbidden[StrafeFirstCompass + k]: continue
      let dot = flip * (delta[0].int64 * lx + delta[1].int64 * lz)
      let score = if delta[0] != 0 and delta[1] != 0: dot * 7071 else: dot * 10000
      if heading < 0 or score > bestScore:
        heading = k
        bestScore = score
    if heading < 0:
      state.leg = 0
      return false
    state.direction = heading.int32
  dec state.leg
  actions[0] = int32(StrafeFirstCompass + state.direction)
  inc state.ticks
  true

# Decoder aim snap (bundle option decoder.aim_snap, schema 2; not a contract change): the
# pw-diag2 rules-39 diagnosis (lever 1) found 63 % of the champion's rays fired with a
# compass aim (index 17..24) while an enemy was visible, a median 10 degrees off it,
# hitting about 0.06. When the decision issues a shoot order with a compass aim and an
# enemy the seat can see (its apparent identities: fog-gated, apparent team, exactly
# observedBodies) stands within max_angle of that compass heading, the aim head becomes
# that enemy's identity index (1..16), so the identity candidate (contract v2: the
# lead-compensated aim point) is what the order aims at. The heading is the compass
# direction the index names (mirrored for team 1 exactly as aimCandidate mirrors it);
# the enemy's bearing is its body's position seen from the seat's. Among the enemies
# within the angle the nearest in angle wins, then the nearer body, then the lower
# identity index. Integer geometry: the angle test compares squared cosines against a
# Q15 threshold (AimSnapCosScale) derived once from the angle in millidegrees, so the
# snap is exact and platform-independent given that threshold (the log line prints it).
# Stateless: nothing is kept between decisions and no stream is drawn.
type
  AimSnapOptions* = object
    enabled*: bool
    maxAngleMillideg*: int32  # 1 .. MaxAimSnapMillideg
    cosQ15*: int64            # round(cos(max angle) * AimSnapCosScale): the integer threshold

const
  AimSnapCosScale* = 32768'i64
  DefaultAimSnapMillideg* = 22500'i32  # the pw-diag2 counterfactual's 22.5 degrees
  MaxAimSnapMillideg* = 90000'i32
  AimFirstCompass* = 17
static: doAssert Width.int64*Width + Height.int64*Height < (1'i64 shl 26)

proc aimSnapOptionsError*(maxAngleMillideg: int32): string =
  ## "" when the angle is usable; otherwise why not (the host and the native ABI reject
  ## the same values).
  if maxAngleMillideg < 1 or maxAngleMillideg > MaxAimSnapMillideg:
    return "max_angle_deg must be a multiple of 0.001 within 0.001 .. 90"
  ""

proc aimSnapOptions*(maxAngleMillideg: int32): AimSnapOptions =
  ## The enabled option for a valid angle, with its integer threshold; ValueError otherwise.
  let problem = aimSnapOptionsError(maxAngleMillideg)
  if problem.len > 0: raise newException(ValueError, "decoder.aim_snap." & problem)
  let radians = float64(maxAngleMillideg) / 1000.0 * PI / 180.0
  AimSnapOptions(enabled: true, maxAngleMillideg: maxAngleMillideg,
    cosQ15: max(0'i64, int64(round(cos(radians) * float64(AimSnapCosScale)))))

proc aimSnapActions*(w: World, slot: int, actions: var array[ActionSizes.len, int32],
    bodies: array[Seats, int], options: AimSnapOptions): bool =
  ## Apply the aim snap to the seat's selected head indices on the pre-step world, before
  ## they are decoded: returns whether the aim head was replaced (by an identity index
  ## 1..16). Only a live seat's shoot order (head 2 = 1) with a compass aim (17..24) is
  ## considered. `bodies` are the seat's apparent identities (observedBodies). Options
  ## disabled = untouched.
  if not options.enabled or actions[2] == 0: return false
  if actions[1] notin AimFirstCompass.int32..(AimFirstCompass+Directions.len-1).int32: return false
  let me = w.cogs[slot]
  if me.hp <= 0: return false
  let flip = mapFlip(slot).int64
  let delta = Directions[actions[1] - AimFirstCompass]
  let hx = flip * delta[0]
  let hz = flip * delta[1]
  let threshold = options.cosQ15 * options.cosQ15 * (hx*hx + hz*hz)
  const scale2 = AimSnapCosScale * AimSnapCosScale
  var best = -1
  var bestDot, bestE2 = 0'i64
  for identity in 0..<Seats:
    let body = bodies[identity]
    if body < 0 or body == slot or w.cogs[body].hp <= 0: continue
    if w.observedTeam(slot, body) == team(slot): continue
    let ex = int64(w.cogs[body].pos.x) - me.pos.x
    let ez = int64(w.cogs[body].pos.z) - me.pos.z
    let e2 = ex*ex + ez*ez
    let dot = hx*ex + hz*ez
    if e2 == 0 or dot <= 0: continue
    # angle <= max  <=>  dot / (|h| |e|) >= cos(max)  <=>  dot^2 S^2 >= cosQ^2 |h|^2 |e|^2
    # (dot^2 < 2^28, |e|^2 < 2^26, |h|^2 <= 2, cosQ and S <= 2^15: every product fits in 63 bits).
    if dot*dot*scale2 < threshold*e2: continue
    # Nearer in angle = a larger dot / |e|: dot_a^2 |e_b|^2 > dot_b^2 |e_a|^2.
    let a = dot*dot*bestE2
    let b = bestDot*bestDot*e2
    if best < 0 or a > b or (a == b and e2 < bestE2):
      best = identity
      bestDot = dot
      bestE2 = e2
  if best < 0: return false
  actions[1] = int32(best + 1)
  true

# Decoder steady shot (bundle option decoder.steady_shot, schema 2; not a contract
# change): the second half of pw-diag2's lever 1. Under rules 39 the champion's sampled
# movement index changed during 85 % of its shot windups, a median 85 u of own drift that
# v2's lead never subtracted (base.bas: 0). With the option on, the seat stands still
# (movement index 0 = SteadyMovement: goal = its own position, so the world makes no step
# and v2's planned own step is zero) on every decision from a shoot order the gun takes
# until the ray leaves, stated in the gun's own windup state (mechanics.nim stepEquipment):
#   - the order tick: the decision's shoot head is 1 and the gun takes the order on this
#     step (gunTakesOrder): the seat is alive, carries the gun (no spray can, whose branch
#     replaces the gun's), equipment.windup == 0 and cogs.cooldown <= 1 on the pre-step
#     world (the step decrements the cooldown before it tests it, so 1 fires). The step
#     then sets windup = GunWindupTicks and locks gunAim after this tick's move;
#   - the windup ticks: the seat is alive, carries the gun and equipment.windup > 0 on the
#     pre-step world (GunWindupTicks .. 1), whatever the shoot head says. The ray leaves
#     after the move of the tick whose pre-step windup is 1, so these are exactly the
#     GunWindupTicks moves the lead's own-drift term (LeadOwnMoves) counts.
# Six decisions per shot, all read from the world, so the rule keeps no state and draws
# nothing; every other head stands. The fire hold (and the training ABI's fire period)
# is decided after the decode, so an order it then drops has still stood its order tick;
# no windup starts for it and the next decision is free.
type
  SteadyShotHold* = enum
    ssNone = 0, ssOrder = 1, ssWindup = 2
const SteadyMovement* = 0'i32
static: doAssert LeadOwnMoves == GunWindupTicks

proc gunTakesOrder*(w: World, slot: int): bool =
  ## Whether a shoot order decided on this pre-step world starts the gun's windup on the
  ## coming step (the gun branch of mechanics.nim stepEquipment).
  let c = w.cogs[slot]
  let e = w.equipment[slot]
  c.hp > 0 and not e.sprayCan and e.windup == 0 and c.cooldown <= 1

proc steadyShotActions*(w: World, slot: int, actions: var array[ActionSizes.len, int32],
    enabled: bool): SteadyShotHold =
  ## Apply the steady shot to the seat's selected head indices on the pre-step world,
  ## before they are decoded: on an order tick or a windup tick (see above) the movement
  ## head becomes SteadyMovement and which of the two is returned; ssNone = untouched.
  if not enabled: return ssNone
  let c = w.cogs[slot]
  let e = w.equipment[slot]
  if c.hp <= 0 or e.sprayCan: return ssNone
  if e.windup > 0: result = ssWindup
  elif actions[2] != 0 and w.gunTakesOrder(slot): result = ssOrder
  else: return ssNone
  actions[0] = SteadyMovement

# Decoder aim retarget (bundle option decoder.aim_retarget, schema 2; not a contract
# change): the pw-diag3 rules-39 diagnosis found target choice decides v4 against
# base.bas. Only 41 % of v4's rays went at the enemy base.bas's own rule picks; the
# others hit 0.15. Every live-field opponent picks by that rule 85-88 % of the time.
# With the option on, every shoot order the policy makes (shoot head 1, identity or
# compass aim; a keep aim, index 0, is left alone) takes the aim index of the visible
# apparent enemy identity with the smallest
#   cost = d^2 - (3 - hp) * hp_weight - carrying * carry_weight
# among those with d <= max_range, where d is measured from the seat's position to the
# identity's aim candidate under the seat's action contract (v2: the lead-compensated
# point, with the seat's own planned step from the movement and sneak heads as they
# stand, exactly what pw_action_candidates reports). The inputs are the seat's own
# observation identity block (present, apparent team -1, hp, carrying; observedBodies)
# and its aim candidates: no hidden state. Ties go to the lower identity. When no enemy
# qualifies the order stands (and the aim snap, which runs next, may still snap it).
# Stateless, no draws. The defaults are base.bas's rule and diag3_run.py --retarget.
type
  AimRetargetOptions* = object
    enabled*: bool
    maxRange*: int32     # 1 .. MaxRetargetRange
    hpWeight*: int32     # 0 .. MaxRetargetWeight, per missing hp point
    carryWeight*: int32  # 0 .. MaxRetargetWeight, for an enemy carrying a heart

const
  DefaultRetargetRange* = 5250'i32         # GunRange
  DefaultRetargetHpWeight* = 160000'i32    # base.bas: (3 - hp) * 160000
  DefaultRetargetCarryWeight* = 2500000'i32  # base.bas: carrier bonus
  MaxRetargetRange* = 20000'i32
  MaxRetargetWeight* = 1_000_000_000'i32
  RetargetFullHp* = 3'i64
static: doAssert DefaultRetargetRange == GunRange

proc aimRetargetOptionsError*(maxRange, hpWeight, carryWeight: int32): string =
  ## "" when the parameters are usable; otherwise why not (the host and the native ABI
  ## reject the same values).
  if maxRange < 1 or maxRange > MaxRetargetRange: return "max_range must be within 1 .. " & $MaxRetargetRange
  if hpWeight < 0 or hpWeight > MaxRetargetWeight: return "hp_weight must be within 0 .. " & $MaxRetargetWeight
  if carryWeight < 0 or carryWeight > MaxRetargetWeight: return "carry_weight must be within 0 .. " & $MaxRetargetWeight
  ""

proc aimRetargetOptions*(maxRange = DefaultRetargetRange, hpWeight = DefaultRetargetHpWeight,
    carryWeight = DefaultRetargetCarryWeight): AimRetargetOptions =
  ## The enabled option for valid parameters (the defaults are base.bas's); ValueError otherwise.
  let problem = aimRetargetOptionsError(maxRange, hpWeight, carryWeight)
  if problem.len > 0: raise newException(ValueError, "decoder.aim_retarget." & problem)
  AimRetargetOptions(enabled: true, maxRange: maxRange, hpWeight: hpWeight, carryWeight: carryWeight)

proc plannedOwnStep(w: World, slot: int, actions: array[ActionSizes.len, int32],
    version: ActionContractVersion): Point =
  ## The own step a v2 identity candidate subtracts for these heads: the planned move of
  ## the movement and sneak heads (pw_action_candidates' rule); zero under v1.
  if version != acV2: return Point()
  let (found, goal) = w.goalCandidate(slot, actions[0].int)
  w.plannedStep(slot, if found: goal else: w.cogs[slot].pos, actions[4] != 0)

proc aimRetargetActions*(w: World, slot: int, actions: var array[ActionSizes.len, int32],
    bodies: array[Seats, int], version: ActionContractVersion, memory: AimMemory,
    options: AimRetargetOptions): bool =
  ## Apply the aim retarget to the seat's selected head indices on the pre-step world,
  ## before the aim snap and the decode: returns whether the aim head was replaced (by
  ## an identity index 1..16 other than the one it held). Only a live seat's shoot order
  ## (head 2 = 1) with an identity or compass aim (1..24) is considered. `bodies` are
  ## the seat's apparent identities (observedBodies) and `memory` its aim memory, the
  ## ones the decode reads. Options disabled = untouched.
  if not options.enabled or actions[2] == 0 or actions[1] == 0: return false
  let me = w.cogs[slot]
  if me.hp <= 0: return false
  let ownStep = w.plannedOwnStep(slot, actions, version)
  let reach2 = int64(options.maxRange) * options.maxRange
  var best = -1
  var bestCost = 0'i64
  for identity in 0..<Seats:
    let body = bodies[identity]
    if body < 0 or w.observedTeam(slot, body) == team(slot): continue
    let (found, aim) = w.aimCandidate(slot, identity + 1, bodies, version, memory, ownStep)
    if not found: continue
    let d2 = distance2(me.pos, aim)
    if d2 > reach2: continue
    let other = w.cogs[body]
    let cost = d2 - (RetargetFullHp - other.hp) * options.hpWeight -
      (if other.carrying: int64(options.carryWeight) else: 0'i64)
    if best < 0 or cost < bestCost:
      best = identity
      bestCost = cost
  if best < 0 or actions[1] == int32(best + 1): return false
  actions[1] = int32(best + 1)
  true

# Decoder shot gate (bundle option decoder.shot_gate, schema 2; not a contract change):
# after retarget, 9 % of v4's rays were still compass shots at nothing within range,
# hitting 0.016; each costs a cooldown and a six-tick steady stand. With the option on,
# a live seat's shoot order, as it stands after the aim retarget and the aim snap, is
# dropped (shoot head 0) when
#   - its aim is still a compass index (17..24): no snap is configured, or the snap found
#     no visible enemy in its cone;
#   - the aim snap turned it into an enemy identity whose body lies beyond max_range;
#   - it is an identity aim (the policy's or the retarget's) whose aim candidate lies
#     beyond max_range, measured as the retarget measures it.
# A keep aim (index 0), and an identity aim within range or one no visible body carries,
# pass: exactly pw-diag3's `--shot-gate` counterfactual (diag3_run.py gate_drop), with
# the snap test read from the snap itself (observedBodies) instead of the diag state. A
# dropped order is the decision without the shot: its aim head returns to what it was
# before the snap (the snap only rewrites shoot orders), so the strafe, the steady
# shot, the decode and the fire hold all see a decision that never ordered a shot.
# Stateless, no draws.
type
  ShotGateOptions* = object
    enabled*: bool
    maxRange*: int32  # 1 .. MaxShotGateRange

const
  DefaultShotGateRange* = 5250'i32  # GunRange
  MaxShotGateRange* = 20000'i32
static: doAssert DefaultShotGateRange == GunRange

proc shotGateOptionsError*(maxRange: int32): string =
  ## "" when the range is usable; otherwise why not (host and native ABI agree).
  if maxRange < 1 or maxRange > MaxShotGateRange: return "max_range must be within 1 .. " & $MaxShotGateRange
  ""

proc shotGateOptions*(maxRange = DefaultShotGateRange): ShotGateOptions =
  ## The enabled option for a valid range; ValueError otherwise.
  let problem = shotGateOptionsError(maxRange)
  if problem.len > 0: raise newException(ValueError, "decoder.shot_gate." & problem)
  ShotGateOptions(enabled: true, maxRange: maxRange)

proc shotGateActions*(w: World, slot: int, actions: var array[ActionSizes.len, int32],
    beforeSnap: array[ActionSizes.len, int32], snapped: bool, bodies: array[Seats, int],
    version: ActionContractVersion, memory: AimMemory, options: ShotGateOptions): bool =
  ## Apply the shot gate to the heads as they stand after the aim snap (`snapped`: the
  ## snap replaced the aim; `beforeSnap`: the heads it received): returns whether the
  ## shoot order was dropped, in which case `actions` becomes `beforeSnap` with shoot
  ## head 0. Options disabled = untouched.
  if not options.enabled or actions[2] == 0: return false
  let me = w.cogs[slot]
  if me.hp <= 0: return false
  let aim = actions[1]
  let reach2 = int64(options.maxRange) * options.maxRange
  var drop = false
  if aim >= AimFirstCompass.int32:
    drop = true
  elif aim >= 1:
    if snapped:
      drop = distance2(me.pos, w.cogs[bodies[aim - 1]].pos) > reach2
    else:
      let (found, point) = w.aimCandidate(slot, aim.int, bodies, version, memory,
        w.plannedOwnStep(slot, actions, version))
      drop = found and distance2(me.pos, point) > reach2
  if not drop: return false
  actions = beforeSnap
  actions[2] = 0
  true

# Decoder spray options (bundle options decoder.spray_aim and decoder.spray_gate, schema 2;
# not a contract change; PLAN-gcrl-spray S1). A spray can replaces the gun: a shoot order
# starts a five-tick burst in a cone (reach SprayReach + Radius, half width sprayHalfWidth +
# Radius, clear line) that deals 3 to EVERY body in it, teammates included. The gun options
# above (retarget, snap, shot gate) do not model that. Both spray options act only on a
# live seat's shoot order while it holds a spray can that is ready (sprayCooldown 0: the
# order starts a burst this step; on any other tick the order does nothing, so the options
# leave it, and its aim, alone). They judge the cone the order would produce on the pre-step
# world: the aim point the decode gives the heads (orderedAim), the seat's current position,
# and the exact sprayTouches geometry (mechanics.nim) against the bodies the seat can see
# under their apparent teams (observedBodies), like every decoder option. Stateless.
type
  SprayAimOptions* = object
    enabled*: bool
    maxRange*: int32      # 1 .. SprayReach: candidate enemies within maxRange + Radius
  SprayGateOptions* = object
    enabled*: bool
    maxTeammates*: int32  # 0 .. MaxSprayTeammates teammates the cone may hold
    minEnemies*: int32    # 0 .. MaxSprayEnemies enemies the cone must hold

const
  DefaultSprayAimRange* = 850'i32   # SprayReach
  DefaultSprayMaxTeammates* = 0'i32
  DefaultSprayMinEnemies* = 1'i32
  MaxSprayTeammates* = 7'i32         # the seat's seven teammates
  MaxSprayEnemies* = 8'i32           # the eight enemies
static: doAssert DefaultSprayAimRange == SprayReach

proc sprayAimOptionsError*(maxRange: int32): string =
  ## "" when usable; otherwise why not (host and native ABI agree).
  if maxRange < 1 or maxRange > SprayReach.int32: return "max_range must be within 1 .. " & $SprayReach
  ""

proc sprayAimOptions*(maxRange = DefaultSprayAimRange): SprayAimOptions =
  let problem = sprayAimOptionsError(maxRange)
  if problem.len > 0: raise newException(ValueError, "decoder.spray_aim." & problem)
  SprayAimOptions(enabled: true, maxRange: maxRange)

proc sprayGateOptionsError*(maxTeammates, minEnemies: int32): string =
  if maxTeammates < 0 or maxTeammates > MaxSprayTeammates:
    return "max_teammates must be within 0 .. " & $MaxSprayTeammates
  if minEnemies < 0 or minEnemies > MaxSprayEnemies: return "min_enemies must be within 0 .. " & $MaxSprayEnemies
  ""

proc sprayGateOptions*(maxTeammates = DefaultSprayMaxTeammates, minEnemies = DefaultSprayMinEnemies): SprayGateOptions =
  let problem = sprayGateOptionsError(maxTeammates, minEnemies)
  if problem.len > 0: raise newException(ValueError, "decoder.spray_gate." & problem)
  SprayGateOptions(enabled: true, maxTeammates: maxTeammates, minEnemies: minEnemies)

proc sprayReady*(w: World, slot: int): bool =
  ## Whether a shoot order decided on this pre-step world starts a spray burst.
  w.cogs[slot].hp > 0 and w.equipment[slot].sprayCan and w.equipment[slot].sprayCooldown == 0

proc sprayConeHolds*(w: World, origin, aim, target: Point): bool =
  ## mechanics.nim sprayTouches' cone for a spray aimed from `origin` at `aim` (the locked
  ## vector is direction(origin, aim, SprayReach)): whether `target` lies in it with a clear
  ## line. The same integer geometry, restated for an order not yet given.
  let v = direction(origin, aim, SprayReach)
  let dx = int64(target.x)-origin.x
  let dz = int64(target.z)-origin.z
  let length = max(1'i64, isqrt64(int64(v.x)*v.x+int64(v.z)*v.z))
  let along = (dx*v.x+dz*v.z) div length
  let across = abs(dx*v.z-dz*v.x) div length
  let halfWidth = sprayHalfWidth(along)
  along > 0 and along <= SprayReach+Radius and across <= halfWidth+Radius and w.lineClear(origin, target)

proc sprayCone*(w: World, slot: int, aim: Point, bodies: array[Seats, int]): (int, int) =
  ## (apparent enemies, apparent teammates) among the seat's visible bodies that a spray
  ## aimed at `aim` from the seat's position would touch.
  let origin = w.cogs[slot].pos
  for identity in 0..<Seats:
    let body = bodies[identity]
    if body < 0 or body == slot or w.cogs[body].hp <= 0: continue
    if not w.sprayConeHolds(origin, aim, w.cogs[body].pos): continue
    if w.observedTeam(slot, body) == team(slot): inc result[1] else: inc result[0]

proc orderAim(w: World, slot: int, actions: array[ActionSizes.len, int32], bodies: array[Seats, int],
    version: ActionContractVersion, memory: AimMemory): Point =
  ## The aim the world holds once these heads are decoded and applied (orderedAim).
  w.orderedAim(slot, w.decodeActions(slot, actions, bodies, version, memory))

proc sprayAimActions*(w: World, slot: int, actions: var array[ActionSizes.len, int32],
    bodies: array[Seats, int], version: ActionContractVersion, memory: AimMemory,
    options: SprayAimOptions): bool =
  ## decoder.spray_aim: on a shoot order with a ready spray can, the aim head becomes the
  ## visible apparent enemy identity whose resulting cone (aimed at that identity's decoded
  ## aim point) holds the most apparent enemies; ties: the nearer body, then lower hp, then
  ## the lower identity. Candidates lie within maxRange + Radius with a clear line. When no
  ## candidate's cone holds an enemy the order stands. Returns whether the aim head changed.
  if not options.enabled or actions[2] == 0 or not w.sprayReady(slot): return false
  let me = w.cogs[slot]
  let reach = int64(options.maxRange) + Radius
  var best = -1
  var bestCount, bestHp = 0
  var bestD2 = 0'i64
  for identity in 0..<Seats:
    let body = bodies[identity]
    if body < 0 or body == slot or w.cogs[body].hp <= 0: continue
    if w.observedTeam(slot, body) == team(slot): continue
    let d2 = distance2(me.pos, w.cogs[body].pos)
    if d2 > reach*reach or not w.lineClear(me.pos, w.cogs[body].pos): continue
    var heads = actions
    heads[1] = int32(identity + 1)
    let count = w.sprayCone(slot, w.orderAim(slot, heads, bodies, version, memory), bodies)[0]
    if count == 0: continue
    let hp = w.cogs[body].hp.int
    if best < 0 or count > bestCount or (count == bestCount and (d2 < bestD2 or (d2 == bestD2 and hp < bestHp))):
      best = identity
      bestCount = count
      bestD2 = d2
      bestHp = hp
  if best < 0 or actions[1] == int32(best + 1): return false
  actions[1] = int32(best + 1)
  true

proc sprayGateActions*(w: World, slot: int, actions: var array[ActionSizes.len, int32],
    bodies: array[Seats, int], version: ActionContractVersion, memory: AimMemory,
    options: SprayGateOptions): bool =
  ## decoder.spray_gate: drop a shoot order with a ready spray can unless the cone it would
  ## produce holds at least minEnemies apparent enemies and at most maxTeammates apparent
  ## teammates. Only the shoot head changes. Returns whether the order was dropped.
  if not options.enabled or actions[2] == 0 or not w.sprayReady(slot): return false
  let (enemies, mates) = w.sprayCone(slot, w.orderAim(slot, actions, bodies, version, memory), bodies)
  if enemies >= options.minEnemies and mates <= options.maxTeammates: return false
  actions[2] = 0
  true

proc decodeLogits*(w: World, slot: int, logits: openArray[float32],
    bodies: array[Seats, int], version: ActionContractVersion,
    memory: AimMemory, fireHold = false): Command =
  w.decodeActions(slot, argmaxActions(logits), bodies, version, memory, fireHold)
proc decodeLogits*(w: World, slot: int, logits: openArray[float32]): Command =
  w.decodeActions(slot, argmaxActions(logits))

proc trainingBotActions*(w: World, slot, level: int,
    actions: var openArray[int32], bodies: array[Seats, int]) =
  ## Deliberately simple policy-visible curriculum opponent, never the learner.
  ## Level 1 idles; level 2 captures and fires at the nearest apparent enemy.
  if actions.len != ActionSizes.len or level notin 1..2:
    raise newException(ValueError,"invalid training bot configuration")
  for i in 0..<actions.len: actions[i] = 0
  if level == 1 or w.cogs[slot].hp <= 0: return
  let me = w.cogs[slot]
  var best = high(int64)
  for i,heart in w.controlHearts:
    if i >= 10 or heart.owner == team(slot).int32: continue
    let d = distance2(me.pos,heart.pos)
    if d < best:
      best = d
      actions[0] = int32(i+1)
  # Keep looking in different directions when no opponent is seen.
  actions[1] = int32(17+(w.tick.int div 24+slot div 2) mod 8)
  best = high(int64)
  for identity,body in bodies:
    if body < 0 or w.observedTeam(slot,body) == team(slot): continue
    let d = distance2(me.pos,w.cogs[body].pos)
    if d < best:
      best = d
      actions[1] = int32(identity+1)
      actions[2] = 1
proc trainingBotActions*(w: World, slot, level: int, actions: var openArray[int32]) =
  if actions.len != ActionSizes.len or level notin 1..2:
    raise newException(ValueError,"invalid training bot configuration")
  if level == 1 or slot notin 0..<Seats or w.cogs[slot].hp <= 0:
    for i in 0..<actions.len: actions[i] = 0
    return
  w.trainingBotActions(slot, level, actions, w.observedBodies(slot))
