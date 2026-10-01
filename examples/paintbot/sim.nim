import village, topography
export topography
## Integer-only Paintbot simulation; Polyworld RNG and portable state hashes.
import polyworld/[rngs, hashes, visions]
import std/[tables, math]
import kinship
export Seats, KinSeats, configureSeats, MaxSeats, LegacySeats

const
  TickRate* = 24
  MatchTicks* = 5*60*TickRate # Historical replay duration.
  HeartMeterMatchTicks* = 10*60*TickRate
  HeartMeterFillTicks* = 3*60*TickRate
  FfaMatchTicks* = 6*60*TickRate # FFA-kin: a fixed six-minute match.
  Width* = 6400
  Height* = 4000
  Radius* = 55
  MoveSpeed* = 28
  FireCooldownTicks* = TickRate
  ShotSpeed* = 100
  ShotRange* = 1800
  VisionRange* = 2000
  RespawnTicks* = 72
  CaptureTarget* = 3
  HeartCaptureTicks* = 3 * TickRate
  BigHeartInterval* = 30 * TickRate
  BigHeartPoints* = 5
  # Glory (rules 37) is the winner's score: it starts at the match length in seconds, loses
  # one per second, and grows on the events below. The loser's glory is zeroed at the end.
  # Glory is a self-imposed handicap: nothing that makes a team more likely to win pays it.
  GloryQuietSupplies* = 10
  GloryQuietSupplyTicks* = 30*TickRate
  GloryFriendlyFire* = 30 # Rules 37-38 only; rules 39 pays nothing for friendly fire.
  GloryFriendlyFireTicks* = 30*TickRate
  GloryEventLifetime* = 4*TickRate
  # Glory hearts (rules 38): small hearts appear in mirrored pairs at random open spots,
  # stay GloryHeartTicks, and pay GloryHeartAward to the team of the first cog to touch one.
  GloryHeartAward* = 20
  GloryHeartTicks* = 30*TickRate
  GloryHeartFirstTick* = 20*TickRate
  GloryHeartMinGap* = 10*TickRate
  GloryHeartMaxGap* = 20*TickRate
  GloryHeartReach* = 120
  # Rules 39: every GloryBehindLivesTicks a team earns GloryBehindLives per life it has fewer
  # than the enemy (lives left summed over its cogs); the team ahead in lives earns nothing.
  GloryBehindLives* = 1
  GloryBehindLivesTicks* = 5*TickRate
  # Rules 47: every GloryBehindCogsTicks a team also earns GloryBehindCogs per cog it has out
  # of the match (no lives left and dead) beyond the enemy's count; the team ahead earns nothing.
  GloryBehindCogs* = 1
  GloryBehindCogsTicks* = 5*TickRate
  SpawnTemperature* = 1000
  HeartSpawnRadius* = 350
  # FFA-kin great hearts (a stag hunt): GreatHeartQuorum living cogs inside GreatHeartRadius
  # for GreatHeartCaptureTicks split GreatHeartBounty (tenths of a point) equally, then the
  # heart sleeps GreatHeartDormantTicks. Progress decays one tick per tick below quorum.
  GreatHeartRadius* = 200
  GreatHeartQuorum* = 3
  GreatHeartCaptureTicks* = 5*TickRate
  GreatHeartBounty* = 600
  GreatHeartDormantTicks* = 60*TickRate
  FfaHeartIncome* = 10 # Tenths of a point per second per owned control heart.
  # FFA-kin tuning (the teams game untouched): cogs carry 10 HP instead of 3, and gun rays stop at
  # 20 m instead of GunRange, so fights last long enough to leave and to come to a relative's aid.
  FfaMaxHp* = 10
  FfaGunRange* = 2000
  ## FFA-kin territory boost: a cog standing in territory owned by seat j (the owner of the
  ## nearest control heart) moves up to this much faster and has this much less gun spread,
  ## scaled by rPercent(me, j): own 30, sibling 15, cousin 7 (7.5 floored), stranger 0.
  TerritoryBoostPercent* = 30
  ControlHeartRadius* = 140 # A cog within this (and a traversable line) touches a control heart.
  TeamsMaxHp = 3
  # Compile-time exponential table keeps native/WASM sampling integer-only.
  # Scores are quantized to 10 world units (1% of the temperature).
  SpawnWeights = block:
    var weights: array[1601, int32]
    for i in 0..1600:
      weights[i] = int32(exp(-float(i) / 100.0) * 1000000.0)
    weights

# A set of seats (up to MaxSeats) in 32-bit words. It hashes as the single uint32 bitmask the
# state hash has always carried while no seat above 31 is in it, so every recording made with
# 16 seats stays bit-identical. A plain `1'u32 shl j` is undefined for j >= 32 (and wraps
# differently on ARM and WASM), hence the words.
type SeatMask* = object
  words*: array[MaxSeats div 32, uint32]
template hasSeat*(m: SeatMask, j: int): bool = (m.words[j shr 5] and (1'u32 shl (j and 31))) != 0
template addSeat*(m: var SeatMask, j: int) =
  m.words[j shr 5] = m.words[j shr 5] or (1'u32 shl (j and 31))
proc addHashy*(h: var uint32, m: SeatMask) =
  h.addHashy(m.words[0])
  for i in 1..<m.words.len:
    if m.words[i] != 0:
      h.addHashy(i.int32)
      h.addHashy(m.words[i])

type
  Point* = object
    x*, z*: int32
  Cover* = object
    x*, z*, w*, h*: int32
  Cog* = object
    pos*, goal*: Point
    hp*, respawn*, cooldown*, shield*: int32
    carrying*: bool
    aim*: Point
    firing*: bool
    tags*, captures*: int32
  Paintball* = object
    pos*, velocity*: Point
    owner*, life*: int32
  Heart* = object
    pos*: Point
    carrier*: int32 # -1 on ground
    returnAt*: int32
  PickupKind* = enum
    grenadePickup, sprayPickup, medkitPickup, armorPickup, uniformPickup
  Pickup* = object
    pos*: Point
    kind*: PickupKind
    readyAt*: int32
  Equipment* = object
    grenade*, sprayCan*: bool
    charge*, armor*, lives*, burst*, sprayCooldown*, windup*: int32
    sprayAim*, gunAim*: Point
    sprayHits*: SeatMask
  Lob* = object
    start*, target*: Point
    owner*, releasedAt*, landsAt*: int32
  Blast* = object
    pos*: Point
    tick*, owner*, trench*: int32
  ControlHeart* = object
    pos*: Point
    owner*: int32 # -1 neutral, 0 Ember, 1 Azure
  HeartCapture* = object
    team*: int32 # -1 when idle
    ticks*: int32
    contested*: bool
  SoundCue* = object
    listener*, kind*, direction*, distance*, tick*: int32
  GloryKind* = enum
    gloryQuietSupplies, gloryFriendlyFire, gloryHeart, gloryBehindLives, gloryBehindCogs
  GloryEvent* = object
    tick*, team*, amount*: int32
    kind*: GloryKind
  GloryHeart* = object
    pos*: Point
    expiresAt*: int32
  GloryPickup* = object
    ## Rules 38: who took a glory heart, where, and when; kept for the viewer's +20.
    tick*, seat*, amount*: int32
    pos*: Point
  GreatHeart* = object
    ## FFA-kin: a stag-hunt heart. present is the living cogs in its zone this tick (viewer).
    pos*: Point
    progress*, dormantUntil*: int32
    present*: int8
  World* = object
    seed*, tick*: int32
    rng*: Rng
    cogs*: seq[Cog]
    hearts*: array[2, Heart]
    captures*: array[2, int32]
    cover*: seq[Cover]
    balls*: seq[Paintball]
    winner*: int32 # -1 before a capture victory
    equipment*: seq[Equipment]
    trenches*: seq[Cover]
    pickups*: seq[Pickup]
    grenades*: seq[Lob]
    blasts*: seq[Blast]
    controlHearts*: seq[ControlHeart]
    scoreTicks*: array[2, int32] # One point = TickRate units, no floating-point drift.
    endTick*: int32
    heartCaptures*: seq[HeartCapture]
    bigHeart*: int32 # -1 until 30 seconds, or after all hearts have been used
    bigHeartRound*: int32
    usedBigHearts*: seq[bool]
    sounds*: seq[SoundCue] # Listener-relative sectors; never exact source coordinates.
    uniforms*: seq[bool]
    glory*: array[2, int32] # Rules 37: the winner's score, in seconds; see GloryQuietSupplies and friends.
    lastSupplyTick*: array[2, int32] # The last tick each team collected a supply.
    gloryEvents*: seq[GloryEvent] # Recent awards, kept GloryEventLifetime ticks for the viewer.
    gloryHearts*: seq[GloryHeart] # Rules 38: glory hearts on the field.
    nextGloryHeart*: int32 # Rules 38: the tick the next pair appears.
    gloryPickups*: seq[GloryPickup] # Rules 38: recent pickups, kept GloryEventLifetime ticks.
    # FFA-kin only; hashed only in that mode, so rules-40 hashes are unchanged.
    seatScore*: seq[int32] # Raw score s_i in tenths: heart income plus great-heart shares.
    heartSeconds*: seq[int32] # Seconds of heart ownership paid to each seat.
    greatShare*: seq[int32] # Great-heart bounty paid to each seat, in tenths.
    greatHearts*: array[2, GreatHeart]
    spawnAnchor*: seq[Point] # Where each seat's family (or the loner) spawns.
  TerritoryWorld = object
    seed*, tick*: int32
    rng*: Rng
    cogs*: seq[Cog]
    hearts*: array[2, Heart]
    captures*: array[2, int32]
    cover*: seq[Cover]
    balls*: seq[Paintball]
    winner*: int32 # -1 before a capture victory
    equipment*: seq[Equipment]
    trenches*: seq[Cover]
    pickups*: seq[Pickup]
    grenades*: seq[Lob]
    blasts*: seq[Blast]
    controlHearts*: seq[ControlHeart]
  CombatWorld = object
    seed*, tick*: int32
    rng*: Rng
    cogs*: seq[Cog]
    hearts*: array[2, Heart]
    captures*: array[2, int32]
    cover*: seq[Cover]
    balls*: seq[Paintball]
    winner*: int32 # -1 before a capture victory
    equipment*: seq[Equipment]
    trenches*: seq[Cover]
    pickups*: seq[Pickup]
    grenades*: seq[Lob]
    blasts*: seq[Blast]
  Command* = object
    walk*, shoot*, direct*: bool
    goal*, aim*: Point
    chargeGrenade*: bool
    sneak*: bool

proc point*(x, z: int): Point = Point(x: int32(x), z: int32(z))
proc team*(slot: int): int = slot mod 2
type GameMode* = enum
  ## gmTeams is the two-team game every rules version plays. gmFfaKin (config "ffa_kin") makes
  ## all 16 seats separate players; teams behaviour (rules 40, 41) is untouched while the mode is gmTeams.
  gmTeams, gmFfaKin
# Rules 36 never existed as behaviour: version 0.3.32 stamped recordings 36 while this default
# still said 35, so a 36 header means rules 35 play. Glory and everything after start at 37.
const LiveRules* = 48
  ## The rules live games play and record (game.nim's replayRulesVersion starts here too). The
  ## training library defaults to its own NativeRules and accepts NativeRules .. LiveRules.
const FfaFogRules* = 48
  ## FFA-kin fog of war (rules 48): no agent-facing surface reveals anything about a cog the
  ## observing seat cannot see (sim.visible, the line of sight that sets BASIC's visible() and
  ## the ffa.v1 visible column). BASIC's kin, gene, seatScore and seatAlive read the unknown
  ## value for such a cog, and the ffa.v1 observation zeroes its identity row. The teams game
  ## is untouched; the privileged training reads (pw_kin, pw_scores, ...) are not agent-facing.
when defined(pwTraining):
  var visionRulesVersion* {.threadvar.}: int
  var gameMode* {.threadvar.}: GameMode
  type
    SeatStats* = object
      ## Per-seat combat telemetry for training hosts. Cumulative per match; never
      ## part of World, its hash or any decision. Layout is the native ABI's.
      damageDealtEnemy*, damageDealtTeam*, hitsEnemy*, hitsTaken*: int32
      kills*, deaths*, captures*, firstFriendlyFireTick*: int32
      # Spray-can damage only (pw_seat_spray_stats): health removed from enemies and
      # teammates by this seat's spray, and the kills it made on each.
      sprayDamageEnemy*, sprayDamageTeam*, sprayKillsEnemy*, sprayKillsTeam*: int32
      # Per-weapon enemy kills and enemy-hit locations (pw_seat_weapon_stats): kills by
      # gun, grenade and spray; hits dealt from / to water, high ground and trenches, by
      # the shooter's / victim's position at the damage event (classes may overlap).
      gunKills*, grenadeKills*, weaponSprayKills*: int32
      hitsFromWater*, hitsFromHigh*, hitsFromTrench*: int32
      hitsToWater*, hitsToHigh*, hitsToTrench*: int32
      # Grenades (pw_seat_grenade_stats): throws released, and the hits and health removed
      # by this seat's grenade blasts on enemies and on teammates (kills: grenadeKills).
      grenadeThrows*, grenadeHitsEnemy*, grenadeDamageEnemy*, grenadeHitsTeam*, grenadeDamageTeam*: int32
      # Equipment and disguise (pw_seat_equip_stats): pickups taken by kind, health the
      # seat's armor soaked, ticks it ended disguised, and enemy kills plus heart captures it
      # made while disguised.
      armorPickups*, uniformPickups*, medkitPickups*, grenadePickups*, sprayPickups*: int32
      armorAbsorbed*, disguisedTicks*, disguisedKillsCaptures*: int32
      # Damage taken (pw_seat_damage_taken_stats): hits and health lost by this seat as the
      # victim, by source: enemy gun, enemy grenade, enemy spray, and everything else (its own
      # or a teammate's weapon, the map).
      takenHits*, takenHealth*: array[4, int32]
    CombatTelemetry* = array[MaxSeats, SeatStats] # one entry per seat the training library plays
  const HighGroundHeight* = 216 # pw_seat_weapon_stats' "high": terrainHeight >= this
  type DamageWeapon* = enum
    dwNone, dwGun, dwGrenade, dwSpray
  # The host points this at its telemetry for the duration of one step; nil means
  # nobody is listening and damage pays only for the nil test.
  var combatTelemetry* {.threadvar.}: ptr CombatTelemetry
  # True only while the step deals spray-can damage (mechanics.nim), so the telemetry can
  # attribute it by weapon. Written and read only for telemetry; never part of World.
  var sprayDamagePhase* {.threadvar.}: bool
  # The weapon whose damage the step is dealing (gun rays, a grenade blast, spray bursts),
  # for pw_seat_weapon_stats. Telemetry only; never part of World.
  var damageWeapon* {.threadvar.}: DamageWeapon
  # Per-attacker damage scale in permille, pointed at by the host for one step; nil or
  # 1000 leaves damage exactly as the rules deal it. A training curriculum knob only.
  var damageScale* {.threadvar.}: ptr array[MaxSeats, int32]
  # Training-only handicaps (native pw_set_seat_max_hp, pw_set_seat_lives,
  # pw_set_seat_damage_taken, pw_set_team_capture_ticks, pw_set_seat_respawn_ticks),
  # pointed at by the host for one reset or step; nil, 0 (and damageTaken 1000) leave the
  # rules' values exactly. remOut / remIn carry the fractional damage of a scale between
  # hits (per attacker / per victim, match-scoped). A training curriculum knob only.
  type Handicap* = object
    maxHp*, lives*, respawnTicks*, damageTaken*: array[MaxSeats, int32]
    captureTicks*: array[2, int32]
    remOut*, remIn*: array[MaxSeats, int32]
  var handicap* {.threadvar.}: ptr Handicap
  # FFA-kin pair counters (native pw_pair_stats): the host points this at a proc for one
  # step and damage() reports every damage event past the shield and life checks, with the
  # health it removed. Telemetry only; never part of World, its hash or any decision.
  type DamageObserver* = proc(w: World, victim, attacker: int, removed: int32,
    killed: bool) {.nimcall, gcsafe.}
  var damageObserver* {.threadvar.}: DamageObserver
else:
  var visionRulesVersion* = LiveRules
  var gameMode* = gmTeams
proc ffa*(): bool = gameMode == gmFfaKin
proc ffaFog*(): bool =
  ## Whether the FFA-kin fog of war applies (FFA-kin at rules >= FfaFogRules).
  ffa() and visionRulesVersion >= FfaFogRules
proc wadesToWetGoals*(): bool =
  ## Whether a cog on dry land whose goal lies in the lake may route into the water (see
  ## waypoint): FFA-kin from rules 44, every mode from rules 45. Teams games at rules 44 and
  ## older, and FFA at 43 and older, keep the rules-38 dry anchors.
  visionRulesVersion >= 45 or (ffa() and visionRulesVersion >= 44)
proc maxHp*(): int32 =
  ## Base HP a cog spawns with and a medkit restores: FfaMaxHp in FFA-kin, 3 otherwise.
  if ffa(): FfaMaxHp.int32 else: TeamsMaxHp.int32
proc seatMaxHp*(slot: int): int32 =
  ## The HP this seat spawns with and a medkit restores: maxHp(), or a training handicap.
  when defined(pwTraining):
    if handicap != nil and handicap.maxHp[slot] > 0: return handicap.maxHp[slot]
  maxHp()
proc seatRespawnTicks*(slot: int): int32 =
  ## Ticks a dead seat waits to respawn: RespawnTicks, or a training handicap.
  when defined(pwTraining):
    if handicap != nil and handicap.respawnTicks[slot] > 0: return handicap.respawnTicks[slot]
  RespawnTicks.int32
proc seatStartingLives*(slot: int, rulesLives: int32): int32 =
  ## The lives a seat starts a match with: the rules', or a training handicap.
  when defined(pwTraining):
    if handicap != nil and handicap.lives[slot] > 0: return handicap.lives[slot]
  rulesLives
proc teamCaptureTicks*(side: int): int32 =
  ## Ticks a team holds a control heart alone to capture it: HeartCaptureTicks, or a
  ## training handicap.
  when defined(pwTraining):
    if handicap != nil and side in 0..1 and handicap.captureTicks[side] > 0: return handicap.captureTicks[side]
  HeartCaptureTicks.int32
proc apparentTeam*(w: World, slot: int): int =
  ## Uniforms change appearance only; ownership always uses team(slot).
  if visionRulesVersion >= 27 and w.uniforms[slot]: 1-team(slot) else: team(slot)
proc observedTeam*(w: World, observer, slot: int): int =
  if observer == slot: team(slot) else: w.apparentTeam(slot)
proc observedSeat*(w: World, observer, slot: int): int =
  if observer != slot and visionRulesVersion >= 27 and w.uniforms[slot]:
    result = slot xor 1
    # A disguise must never overwrite the observer's own body.
    if result == observer: result = (result+2) mod Seats
  else: result = slot
proc home*(side: int): Point =
  if activeMap() >= 0:
    let h = currentMap().home
    return if side == 0: point(h.x, h.z) else: point(Width-h.x, Height-h.z)
  point(if side == 0: Width*15 div 100 else: Width*85 div 100, Height div 2)
proc distance2*(a, b: Point): int64 =
  let x = int64(a.x)-b.x; let z = int64(a.z)-b.z
  x*x+z*z
proc isqrt(n: int64): int64 =
  var x = n; var y = (x+1) div 2
  while y < x: x = y; y = (x+n div x) div 2
  x
proc direction*(a, b: Point, speed: int): Point =
  let d = isqrt(distance2(a, b))
  if d == 0: return
  result.x = int32((int64(b.x)-a.x)*speed.int64 div d)
  result.z = int32((int64(b.z)-a.z)*speed.int64 div d)
# A map carries its own bounds (the rules-22 span for the shipped size, wider for big-*
# maps), always centred on the half turn about (Width/2, Height/2).
proc minX*():int =
  if activeMap() >= 0: return currentMap().x0
  (if visionRulesVersion>=22: -4800 elif visionRulesVersion>=14: -2800 elif visionRulesVersion>=12: -800 else: 0)
proc minZ*():int =
  if activeMap() >= 0: return currentMap().z0
  (if visionRulesVersion>=22: -2800 elif visionRulesVersion>=14: -1200 elif visionRulesVersion>=12: -400 else: 0)
proc maxX*():int = Width-minX()
proc maxZ*():int = Height-minZ()
proc elevation*(w: World, p: Point): int =
  if visionRulesVersion < 9: return 0
  result = terrainHeight(p.x.int, p.z.int)
  for t in w.trenches:
    if p.x >= t.x and p.x < t.x+t.w and p.z >= t.z and p.z < t.z+t.h:
      result -= 60
      break
proc traversable*(w: World, a, b: Point): bool =
  if visionRulesVersion < 9: return true
  let steps = max(abs(b.x-a.x), abs(b.z-a.z)).int div 20+1
  var last = terrainHeight(a.x.int, a.z.int)
  for i in 1..steps:
    let x = a.x.int+(b.x-a.x).int*i div steps
    let z = a.z.int+(b.z-a.z).int*i div steps
    let h = terrainHeight(x, z)
    if abs(h-last) > 25: return false
    last = h
  true
proc coverBlocks(c: Cover, p: Point, radius: int): bool {.inline.} =
  if c.h == 0:
    let r = c.w div 2
    return distance2(p, point(c.x.int+r.int, c.z.int+r.int)) < (r+radius).int64*(r+radius)
  p.x > c.x-radius and p.x < c.x+c.w+radius and p.z > c.z-radius and p.z < c.z+c.h+radius
proc boundsBlocked(p: Point, radius: int, bounds: array[4,int]): bool {.inline.} =
  if p.x < bounds[0]+radius or p.z < bounds[1]+radius or p.x > bounds[2]-radius or p.z >
      bounds[3]-radius: return true
  islandTerrain and islandMargin(p.x.int,p.z.int)<radius div 3+40
proc boundsBlocked(p: Point, radius: int): bool {.inline.} =
  boundsBlocked(p, radius, [minX(),minZ(),maxX(),maxZ()])
# Every build indexes cover on a coarse grid so point and segment tests visit only nearby
# obstacles instead of all of them (224 on the island, thousands on a large generated map).
# The index belongs to the thread and is keyed by the cover it was built from: a world whose
# cover payload address or length differs is compared by content and the index rebuilt if it
# differs. Every candidate set is a superset of the obstacles that can satisfy the predicate,
# so the answers are identical to the full scans below, which -d:pwFullScanGeometry restores
# for comparison. Training builds always index.
const IndexedGeometry* = defined(pwTraining) or not defined(pwFullScanGeometry)
template parkForMap(current, parked, slot: untyped) =
  ## Training builds: make `current`, a thread's geometry cache, the one for the thread's
  ## active map. The old map's cache is parked in parked[slot] and the new map's taken from
  ## parked[1 + activeMap()]; what goes back in its place is the empty value, so every parked
  ## entry is either a map's own cache or empty.
  let wanted = activeMap()+1
  if slot != wanted:
    swap(current, parked[slot])
    swap(current, parked[wanted])
    slot = wanted
when IndexedGeometry:
  const
    CoverCell = 200
    CoverReach = 90 # Largest radius any caller passes to blocked; larger falls back.
  const RayMemoBits = 16
  type
    RayKey = object
      a, b: Point
    CoverIndex = object
      payload: pointer
      length: int
      bounds: array[4, int]
      cover: seq[Cover]
      originX, originZ, nx, nz: int
      cellStart, items: seq[int32]
      seen: seq[int32]
      stamp: int32
      # lineClear is a function of its endpoints and the static geometry (cover,
      # trenches, terrain, rules), so rays repeat exactly while cogs stand still.
      rayTrenches: seq[Cover]
      rayRules: int
      rayKeys: seq[RayKey]
      rayState: seq[uint8] # 0 empty, 1 blocked, 2 clear
  var coverIndex {.threadvar.}: CoverIndex
  when defined(pwTraining):
    # A training thread may step worlds on different maps (native_env's per-handle map), and
    # the index describes one map's geometry: each map keeps its own, parked here while the
    # thread is on another. Switching maps swaps rather than rebuilds, and one map's index is
    # never taken for another's cover (two maps may share a cover count, and a freed world's
    # cover address may be reused).
    var coverIndexParked {.threadvar.}: array[MapNames.len+1, CoverIndex]
    var coverIndexMap {.threadvar.}: int # 1 + the map coverIndex belongs to (0 = the island)
  proc coverSpan(c: Cover): tuple[x0, x1, z0, z1: int] =
    let depth = if c.h == 0: c.w else: c.h
    (c.x.int-CoverReach-1, c.x.int+c.w.int+CoverReach+1, c.z.int-CoverReach-1, c.z.int+depth.int+CoverReach+1)
  proc buildCoverIndex(w: World) =
    let g = addr coverIndex
    g.cover = w.cover
    g.bounds = [minX(), minZ(), maxX(), maxZ()]
    g.originX = minX()-2*CoverCell
    g.originZ = minZ()-2*CoverCell
    g.nx = (maxX()-minX()) div CoverCell+5
    g.nz = (maxZ()-minZ()) div CoverCell+5
    g.cellStart = newSeq[int32](g.nx*g.nz+1)
    g.seen = newSeq[int32](w.cover.len)
    g.stamp = 0
    g.rayKeys = newSeq[RayKey](1 shl RayMemoBits)
    g.rayState = newSeq[uint8](1 shl RayMemoBits)
    g.rayRules = -1
    template cells(c: Cover, body: untyped) =
      let span = coverSpan(c)
      let cx0 = clamp((span.x0-g.originX) div CoverCell, 0, g.nx-1)
      let cx1 = clamp((span.x1-g.originX) div CoverCell, 0, g.nx-1)
      let cz0 = clamp((span.z0-g.originZ) div CoverCell, 0, g.nz-1)
      let cz1 = clamp((span.z1-g.originZ) div CoverCell, 0, g.nz-1)
      if span.x1 >= g.originX and span.z1 >= g.originZ:
        for cz in cz0..cz1:
          for cx in cx0..cx1:
            let cell {.inject.} = cz*g.nx+cx
            body
    for c in w.cover:
      cells(c): inc g.cellStart[cell+1]
    for i in 1..g.nx*g.nz: g.cellStart[i] += g.cellStart[i-1]
    g.items = newSeq[int32](g.cellStart[^1])
    var fill = g.cellStart
    for index, c in w.cover:
      cells(c):
        g.items[fill[cell]] = index.int32
        inc fill[cell]
  proc coverIndexFor(w: World): ptr CoverIndex =
    when defined(pwTraining): parkForMap(coverIndex, coverIndexParked, coverIndexMap)
    result = addr coverIndex
    let payload = if w.cover.len > 0: cast[pointer](unsafeAddr w.cover[0]) else: nil
    if result.payload == payload and result.length == w.cover.len and
        result.bounds == [minX(), minZ(), maxX(), maxZ()]: return
    if result.length != w.cover.len or result.bounds != [minX(), minZ(), maxX(), maxZ()] or
        result.cover != w.cover:
      buildCoverIndex(w)
    result.payload = payload
    result.length = w.cover.len
  proc raySlot(a, b: Point): int {.inline.} =
    var h = uint64(uint32(a.x))*0x9E3779B97F4A7C15'u64
    h = (h xor uint64(uint32(a.z)))*0xC2B2AE3D27D4EB4F'u64
    h = (h xor uint64(uint32(b.x)))*0x165667B19E3779F9'u64
    h = (h xor uint64(uint32(b.z)))*0x9E3779B97F4A7C15'u64
    int((h shr 40) and uint64((1 shl RayMemoBits)-1))
  template cellAt(g: ptr CoverIndex, x, z: int): int =
    ## -1 when the point lies outside the indexed span.
    let cx = x-g.originX
    let cz = z-g.originZ
    if cx < 0 or cz < 0 or cx >= g.nx*CoverCell or cz >= g.nz*CoverCell: -1
    else: (cz div CoverCell)*g.nx+cx div CoverCell
  proc coverBlockedIndexed(g: ptr CoverIndex, w: World, p: Point, radius: int): bool =
    if radius > CoverReach:
      for c in w.cover:
        if c.coverBlocks(p, radius): return true
      return false
    let cell = cellAt(g, p.x.int, p.z.int)
    if cell < 0:
      for c in w.cover:
        if c.coverBlocks(p, radius): return true
      return false
    for k in g.cellStart[cell]..<g.cellStart[cell+1]:
      if w.cover[g.items[k]].coverBlocks(p, radius): return true
    false
  iterator segmentCover(w: World, a, b: Point): int =
    ## Indices of cover that may lie within CoverReach of segment ab, each once, or every
    ## index when the segment leaves the indexed span. Rebuilding is impossible mid-loop.
    let g = coverIndexFor(w)
    let c0 = cellAt(g, min(a.x, b.x).int, min(a.z, b.z).int)
    let c1 = cellAt(g, max(a.x, b.x).int, max(a.z, b.z).int)
    if c0 < 0 or c1 < 0:
      for index in 0..<w.cover.len: yield index
    else:
      inc g.stamp
      if g.stamp == high(int32):
        for s in g.seen.mitems: s = 0
        g.stamp = 1
      let stamp = g.stamp
      for cz in c0 div g.nx..c1 div g.nx:
        for cx in c0 mod g.nx..c1 mod g.nx:
          let cell = cz*g.nx+cx
          for k in g.cellStart[cell]..<g.cellStart[cell+1]:
            let index = g.items[k]
            if g.seen[index] == stamp: continue
            g.seen[index] = stamp
            yield index.int
proc blocked*(w: World, p: Point, radius = Radius): bool =
  if boundsBlocked(p, radius): return true
  when IndexedGeometry:
    coverBlockedIndexed(coverIndexFor(w), w, p, radius)
  else:
    for c in w.cover:
      if c.coverBlocks(p, radius): return true
const RayCoverLimit = 512
proc lineClearRay(w: World, a, b: Point): bool =
  # Only obstacles overlapping the ray bounds can block its sampled points, so the
  # sampled predicate is evaluated against that subset (from the cover index, or under
  # -d:pwFullScanGeometry indexed on the stack; too many for the stack means the full set,
  # which gives the same answer). Keep the exact sample positions and collision
  # predicates for replay parity. No world copy, no allocation.
  when not IndexedGeometry:
    var rayCover: array[RayCoverLimit, int32]
    var rayCount = 0
    for index, c in w.cover:
      let depth = if c.h == 0: c.w else: c.h
      if c.x <= max(a.x,b.x) and c.x+c.w >= min(a.x,b.x) and
          c.z <= max(a.z,b.z) and c.z+depth >= min(a.z,b.z):
        if rayCount < RayCoverLimit: rayCover[rayCount] = index.int32
        inc rayCount
    let filtered = rayCount <= RayCoverLimit
  else:
    let g = coverIndexFor(w)
  let bounds = [minX(),minZ(),maxX(),maxZ()]
  let elevated = visionRulesVersion >= 9
  let startHeight = if elevated: w.elevation(a) else: 0
  let endHeight = if elevated: w.elevation(b) else: 0
  let steps = max(abs(b.x-a.x), abs(b.z-a.z)) div 25 + 1
  when defined(pwTraining):
    # The same samples and predicates, cheaper: a sample whose terrain block's bounds (its
    # lowest coast margin, its highest ground) cannot block it skips the cell; otherwise one
    # cell fetch serves both the coast and the eye-line tests. Only trenches overlapping the
    # ray's bounds are scanned (all of them when there are too many to list).
    let island = islandTerrain
    const RayTrenchLimit = 16
    var rayTrenches: array[RayTrenchLimit, int32]
    var trenchCount = 0
    if elevated:
      for index, t in w.trenches:
        if t.x <= max(a.x,b.x) and t.x+t.w > min(a.x,b.x) and t.z <= max(a.z,b.z) and t.z+t.h > min(a.z,b.z):
          if trenchCount < RayTrenchLimit: rayTrenches[trenchCount] = index.int32
          inc trenchCount
    let listed = trenchCount <= RayTrenchLimit
    for i in 1..steps:
      let p = Point(x: a.x+(b.x-a.x)*i div steps, z: a.z+(b.z-a.z)*i div steps)
      if p.x < bounds[0] or p.z < bounds[1] or p.x > bounds[2] or p.z > bounds[3]: return false
      let eye = if elevated: startHeight+120+(endHeight-startHeight)*i.int div steps.int else: 0
      let blk = terrainBlockAt(p.x.int, p.z.int)
      if blk == nil:
        # Not tabled (a generated map, or outside the span): the direct lookups, as before.
        if island and islandMargin(p.x.int, p.z.int) < 40: return false
        if elevated and w.elevation(p) > eye: return false
      elif (island and blk.minMargin.int < 40) or (elevated and blk.maxHeight.int > eye):
        let cell = blk.cellIn(p.x.int, p.z.int)
        if island and cell.margin.int < 40: return false
        if elevated:
          # A trench only lowers the ground, so a cell at or below the eye line stays clear.
          var height = cell.height.int
          if height > eye:
            if listed:
              for k in 0..<trenchCount:
                let t = w.trenches[rayTrenches[k]]
                if p.x >= t.x and p.x < t.x+t.w and p.z >= t.z and p.z < t.z+t.h:
                  height -= 60
                  break
            else:
              for t in w.trenches:
                if p.x >= t.x and p.x < t.x+t.w and p.z >= t.z and p.z < t.z+t.h:
                  height -= 60
                  break
            if height > eye: return false
      if coverBlockedIndexed(g, w, p, 0): return false
    return true
  else:
    for i in 1..steps:
      let p = Point(x: a.x+(b.x-a.x)*i div steps, z: a.z+(b.z-a.z)*i div steps)
      if boundsBlocked(p, 0, bounds): return false
      when IndexedGeometry:
        if coverBlockedIndexed(g, w, p, 0): return false
      else:
        if filtered:
          for k in 0..<rayCount:
            if w.cover[rayCover[k]].coverBlocks(p, 0): return false
        else:
          for c in w.cover:
            if c.coverBlocks(p, 0): return false
      if elevated:
        let eye = startHeight+120+(endHeight-startHeight)*i.int div steps.int
        if w.elevation(p) > eye: return false
    true
proc lineClear*(w: World, a, b: Point): bool =
  when IndexedGeometry:
    # Remembered per thread for the geometry the cover index was built from; the
    # trenches and rules are checked on every call and any change empties the memo.
    let g = coverIndexFor(w)
    if g.rayRules != visionRulesVersion or g.rayTrenches != w.trenches:
      g.rayRules = visionRulesVersion
      g.rayTrenches = w.trenches
      for state in g.rayState.mitems: state = 0
    let slot = raySlot(a, b)
    if g.rayState[slot] != 0 and g.rayKeys[slot].a == a and g.rayKeys[slot].b == b:
      return g.rayState[slot] == 2
    result = lineClearRay(w, a, b)
    g.rayKeys[slot] = RayKey(a: a, b: b)
    g.rayState[slot] = if result: 2 else: 1
  else:
    lineClearRay(w, a, b)
# Team vision (rules 42, opt-in per match with the "vision": "team" config): a team sees
# whatever any living teammate sees, out to VisionRange in every direction, on a grid of
# 1.25 m cells computed once whenever a cog changes cell (Gods of the Arena's revealVision).
# Cover blocks sight through its cells; terrain occludes in 40 cm steps, so the kernel's
# three-step eye and target heights are the 120 cm eye line lineClear uses. Visibility is
# then a table lookup, and a large game no longer traces one sight line per pair of cogs.
const
  SightCell* = 125
  SightRadiusCells = VisionRange div SightCell # 16, the kernel's largest radius
  SightHeightUnit = 40
  SightEyeSteps = 3'i16
  SightCoverSteps = 250'i16 # 100 m: cover blocks every sight line that crosses it
type SightGrid = object
  payload: pointer
  length: int
  bounds: array[4, int]
  map, rules: int
  cover: seq[Cover]
  originX, originZ, nx, nz: int
  terrain, blockers: seq[int16]
  key: seq[int32]
  seen: array[2, seq[uint8]]
when defined(pwTraining):
  var teamVision* {.threadvar.}: bool
  var sightGrid {.threadvar.}: SightGrid
else:
  var teamVision* = false ## rules 42: set by configureVision, never directly
  var sightGrid: SightGrid
proc configureVision*(mode: string) =
  ## Rules 42: "" keeps per-cog sight lines; "team" shares a team-wide sight grid. Like
  ## configureMap, it binds the calling thread; set it before newWorld.
  if mode notin ["", "team"]: raise newException(ValueError, "Unknown Paintbot vision mode: " & mode)
  teamVision = mode == "team"
proc visionMode*(): string = (if teamVision: "team" else: "")
# Vision range (opt-in per match with the "vision_range" config, any rules, both modes): per-cog
# sight lines reach at most this far, which spares the sight-line trace to every cog and
# pickup beyond it. Absent (0) keeps the rules' own reach: unlimited from rules 5.
const MaxVisionRangeMetres* = 200
when defined(pwTraining):
  var visionRangeCm {.threadvar.}: int
else:
  var visionRangeCm = 0 ## set by configureVisionRange, never directly; 0 = unlimited
proc configureVisionRange*(metres: int) =
  ## 0 = unlimited (the default), else 1..MaxVisionRangeMetres metres of per-cog sight. Like
  ## configureVision, it binds the calling thread; set it before newWorld.
  if metres notin 0..MaxVisionRangeMetres:
    raise newException(ValueError, "Paintbot vision_range must be 1.." & $MaxVisionRangeMetres & " metres")
  visionRangeCm = metres*100
proc visionRangeMetres*(): int = visionRangeCm div 100
type GloryConfig* = object
  ## Rules 43: the glory awards a match pays, from the Coworld config's "glory" (see
  ## parseGloryConfig in match_config.nim). Periods are whole seconds; teams recordings carry
  ## it. behindCogs and behindCogsSeconds are rules 47's (recordings from rules 47 on).
  quietSupplies*, quietSupplySeconds*, behindLives*, behindLivesSeconds*, heart*: int32
  behindCogs*, behindCogsSeconds*: int32
const DefaultGloryConfig* = GloryConfig(quietSupplies: GloryQuietSupplies,
  quietSupplySeconds: GloryQuietSupplyTicks div TickRate, behindLives: GloryBehindLives,
  behindLivesSeconds: GloryBehindLivesTicks div TickRate, heart: GloryHeartAward,
  behindCogs: GloryBehindCogs, behindCogsSeconds: GloryBehindCogsTicks div TickRate)
when defined(pwTraining):
  var gloryConfigured {.threadvar.}: bool
  var gloryOverride {.threadvar.}: GloryConfig
else:
  var gloryConfigured = false
  var gloryOverride: GloryConfig
proc configureGlory*(g: GloryConfig) =
  ## Like configureVision, it binds the calling thread; set it before newWorld.
  gloryOverride = g; gloryConfigured = true
proc gloryRules*(): GloryConfig =
  ## The awards in force: the configured ones, or the rules' defaults.
  if gloryConfigured: gloryOverride else: DefaultGloryConfig
proc sightCell(g: ptr SightGrid, p: Point): int =
  let x = clamp((p.x.int-g.originX) div SightCell, 0, g.nx-1)
  let z = clamp((p.z.int-g.originZ) div SightCell, 0, g.nz-1)
  z*g.nx+x
proc buildSightGrid(g: ptr SightGrid, w: World) =
  g.cover = w.cover; g.bounds = [minX(), minZ(), maxX(), maxZ()]; g.map = activeMap()
  g.rules = visionRulesVersion
  g.originX = minX(); g.originZ = minZ()
  g.nx = (maxX()-minX()) div SightCell+1; g.nz = (maxZ()-minZ()) div SightCell+1
  g.terrain = newSeq[int16](g.nx*g.nz); g.blockers = newSeq[int16](g.nx*g.nz)
  for z in 0..<g.nz:
    for x in 0..<g.nx:
      let h = terrainHeight(g.originX+x*SightCell+SightCell div 2, g.originZ+z*SightCell+SightCell div 2)
      g.terrain[z*g.nx+x] = int16(clamp(floorDiv(h, SightHeightUnit), -3000, 3000))
  for c in w.cover:
    # A cell is blocked when its centre lies within the obstacle (plus a quarter cell).
    let depth = if c.h == 0: c.w else: c.h
    let x0 = max(0, (c.x.int-SightCell-g.originX) div SightCell)
    let x1 = min(g.nx-1, (c.x.int+c.w.int+SightCell-g.originX) div SightCell)
    let z0 = max(0, (c.z.int-SightCell-g.originZ) div SightCell)
    let z1 = min(g.nz-1, (c.z.int+depth.int+SightCell-g.originZ) div SightCell)
    for z in z0..z1:
      for x in x0..x1:
        let cx = g.originX+x*SightCell+SightCell div 2
        let cz = g.originZ+z*SightCell+SightCell div 2
        let inside =
          if c.h == 0:
            let r = c.w.int div 2+SightCell div 4
            let dx = cx-(c.x.int+c.w.int div 2); let dz = cz-(c.z.int+c.w.int div 2)
            dx*dx+dz*dz <= r*r
          else:
            cx >= c.x.int-SightCell div 4 and cx < c.x.int+c.w.int+SightCell div 4 and
              cz >= c.z.int-SightCell div 4 and cz < c.z.int+c.h.int+SightCell div 4
        if inside: g.blockers[z*g.nx+x] = SightCoverSteps
  g.key.setLen(0)
proc teamSight(w: World): ptr SightGrid =
  ## The shared grid for w, refreshed when the geometry or any living cog's cell changes.
  result = addr sightGrid
  let g = result
  let payload = if w.cover.len > 0: cast[pointer](unsafeAddr w.cover[0]) else: nil
  if g.payload != payload or g.length != w.cover.len or g.bounds != [minX(), minZ(), maxX(), maxZ()] or
      g.map != activeMap() or g.rules != visionRulesVersion:
    if g.terrain.len == 0 or g.cover != w.cover or g.bounds != [minX(), minZ(), maxX(), maxZ()] or
        g.map != activeMap() or g.rules != visionRulesVersion:
      buildSightGrid(g, w)
    g.payload = payload; g.length = w.cover.len
  var same = g.key.len == Seats
  if same:
    for i in 0..<Seats:
      let k = if w.cogs[i].hp > 0: sightCell(g, w.cogs[i].pos).int32 else: -1'i32
      if g.key[i] != k: same = false; break
  if same: return
  g.key.setLen(Seats)
  for i in 0..<Seats: g.key[i] = if w.cogs[i].hp > 0: sightCell(g, w.cogs[i].pos).int32 else: -1'i32
  for side in 0..1:
    var sources: seq[VisionSource]
    for i in 0..<Seats:
      if team(i) != side or g.key[i] < 0: continue
      sources.add VisionSource(x: int32(g.key[i] mod g.nx), z: int32(g.key[i] div g.nx),
        radius: SightRadiusCells.int32, eyeHeight: SightEyeSteps)
    revealVision(g.seen[side], g.nx.int32, g.nz.int32, g.terrain, g.blockers, sources)
proc teamSightGrid*(w: World): tuple[nx, nz, originX, originZ: int, terrain, blockers: seq[int16]] =
  ## Tests: the static grid behind team vision.
  let g = teamSight(w)
  (g.nx, g.nz, g.originX, g.originZ, g.terrain, g.blockers)
proc teamSees*(w: World, side: int, p: Point): bool =
  ## Rules 42 team vision: whether side's shared sight grid covers p.
  let g = teamSight(w)
  if p.x < g.originX or p.z < g.originZ: return false
  let x = (p.x.int-g.originX) div SightCell; let z = (p.z.int-g.originZ) div SightCell
  x < g.nx and z < g.nz and g.seen[side][z*g.nx+x] != 0
proc canSeePoint*(w: World, slot: int, p: Point): bool =
  if slot notin 0..<Seats or w.cogs[slot].hp <= 0: return false
  if teamVision and not ffa(): return w.teamSees(team(slot), p)
  let c = w.cogs[slot]
  let distance = distance2(c.pos, p)
  if visionRulesVersion < 5 and distance >
      VisionRange.int64*VisionRange: return false
  if visionRangeCm > 0 and distance > visionRangeCm.int64*visionRangeCm: return false
  if visionRulesVersion >= 4 and distance > 0:
    let facing = if c.aim == Point(): home(1-team(slot)) else: c.aim
    let fx = int64(facing.x)-c.pos.x
    let fz = int64(facing.z)-c.pos.z
    let dx = int64(p.x)-c.pos.x
    let dz = int64(p.z)-c.pos.z
    let dot = fx*dx+fz*dz
    if dot <= 0 or 4*dot*dot < (fx*fx+fz*fz)*distance: return false
  w.lineClear(c.pos, p)
proc visible*(w: World, slot, other: int): bool =
  if slot notin 0..<Seats or other notin 0..<Seats or w.cogs[other].hp <= 0:
    return false
  if slot == other: return true
  if visionRulesVersion < 4 and team(slot) == team(other): return true
  if teamVision and not ffa():
    # Team vision: teammates always share positions; enemies show on the team's grid.
    if w.cogs[slot].hp <= 0: return false
    if team(slot) == team(other): return true
    return w.teamSees(team(slot), w.cogs[other].pos)
  w.canSeePoint(slot, w.cogs[other].pos)
proc occupied(w: World, p: Point, slot: int): bool =
  for other in 0..<Seats:
    if other != slot and w.cogs[other].hp > 0 and
        distance2(p, w.cogs[other].pos) < (2*Radius).int64*(2*Radius):
      return true
proc movementBlocked(w: World, p: Point, slot: int, solid: bool): bool =
  w.blocked(p) or (solid and w.occupied(p, slot)) or
    (distance2(w.cogs[slot].pos, p) < 10000 and not w.traversable(w.cogs[
        slot].pos, p))
proc sampleSpawnHeart*(w: var World, slot: int): int =
  ## Softmax of summed distances to living teammates; larger sums are favored.
  var candidates: seq[int]
  var scores: seq[int64]
  var maximum = 0'i64
  for index, heart in w.controlHearts:
    if heart.owner != team(slot).int32: continue
    var score = 0'i64
    for other, cog in w.cogs:
      if other != slot and team(other) == team(slot) and cog.hp > 0:
        score += isqrt(distance2(cog.pos, heart.pos))
    candidates.add index
    scores.add score
    maximum = max(maximum, score)
  if candidates.len == 0: return -1
  var weights: seq[int32]
  var total = 0'i32
  for score in scores:
    let bucket = min(1600'i64, (maximum-score) * 100 div SpawnTemperature)
    let weight = SpawnWeights[bucket.int]
    weights.add weight
    total += weight
  var draw = w.rng.below(total)
  for i, weight in weights:
    if draw < weight: return candidates[i]
    draw -= weight
  candidates[^1]

proc spawnRadius(): int32 =
  ## The spawn disc round a heart or family anchor: HeartSpawnRadius for up to 16 seats, wider
  ## by the square root of the seat count beyond that, so a large family still fits.
  if Seats <= LegacySeats: HeartSpawnRadius.int32
  else: int32(HeartSpawnRadius.float*sqrt(Seats.float/LegacySeats.float))
proc spawnNear(w: var World, slot: int, origin: Point): bool =
  # Search only near the origin (a heart, or an FFA spawn anchor). If crowded, retry next tick.
  let radius = spawnRadius()
  for attempt in 0..<128:
    let p = point(origin.x.int+w.rng.between(-radius, radius).int,
        origin.z.int+w.rng.between(-radius, radius).int)
    if distance2(origin, p) > radius.int64*radius: continue
    if w.blocked(p) or w.occupied(p, slot) or not w.traversable(origin, p): continue
    w.cogs[slot].pos = p; w.cogs[slot].goal = p
    w.cogs[slot].hp = seatMaxHp(slot); w.cogs[slot].shield = 36
    w.cogs[slot].firing = false; w.cogs[slot].carrying = false
    return true

proc spawnAtHeart(w: var World, slot: int): bool =
  let heart = w.sampleSpawnHeart(slot)
  if heart < 0: return false
  w.spawnNear(slot, w.controlHearts[heart].pos)

proc spawn(w: var World, slot: int, solid = true) =
  var p = point(if team(slot) == 0: 350+(slot div 2 mod 2)*160 else: Width-350-(
      slot div 2 mod 2)*160,
    1100+(slot div 4)*550)
  if solid and w.movementBlocked(p, slot, true):
    let origin = p
    var found = false
    block search:
      for ring in 1..20:
        for dz in -ring..ring:
          for dx in -ring..ring:
            if abs(dx) != ring and abs(dz) != ring: continue
            let candidate = point(origin.x.int+dx*(2*Radius+2),
                origin.z.int+dz*(2*Radius+2))
            if not w.movementBlocked(candidate, slot, true):
              p = candidate
              found = true
              break search
    if not found: return # Retry next tick rather than overlap a living cog.
  w.cogs[slot].pos = p; w.cogs[slot].goal = p
  w.cogs[slot].hp = seatMaxHp(slot); w.cogs[slot].shield = 36
  w.cogs[slot].firing = false; w.cogs[slot].carrying = false
proc resetHeart*(w: var World, side: int) =
  w.hearts[side] = Heart(pos: home(side), carrier: -1)
proc initializeEquipment(w: var World)
proc placeFfaSpawns(w: var World)
proc configureRules*(version: int) =
  ## Native rollout workers call this on their own thread before accessing a world.
  visionRulesVersion = version
  wideRamps = visionRulesVersion >= 11
  wilderness = visionRulesVersion >= 12
  deepWilderness = visionRulesVersion >= 14
  organicTerrain = visionRulesVersion >= 15
  islandTerrain = visionRulesVersion >= 16
  expandedIsland = visionRulesVersion >= 22
  riverTerrain = visionRulesVersion >= 29
  curvedRiver = visionRulesVersion >= 31
  fractalRiver = visionRulesVersion >= 32
  lakeTerrain = visionRulesVersion >= 33
  symmetricTerrain = visionRulesVersion >= 35
  refreshTerrainTable()

proc configureMap*(name: string) =
  ## Rules 41: "" keeps the rules' own island; a MapNames entry replaces its terrain and
  ## layout. Like configureRules, it binds the calling thread; set it before newWorld.
  setActiveMap(mapIndex(name))
  refreshTerrainTable()

proc mapName*(): string =
  if activeMap() >= 0: MapNames[activeMap()] else: ""

proc sizeSeats*(w: var World) =
  ## Gives every per-seat list one entry per seat of the current match (Seats).
  w.cogs.setLen(Seats)
  w.equipment.setLen(Seats)
  w.uniforms.setLen(Seats)
  w.seatScore.setLen(Seats)
  w.heartSeconds.setLen(Seats)
  w.greatShare.setLen(Seats)
  w.spawnAnchor.setLen(Seats)
proc newWorld*(seed: int32, endTick: int32 = 0): World =
  ## A world for the current seat count (Seats; see configureSeats).
  configureRules(visionRulesVersion)
  result.sizeSeats()
  result.endTick = if ffa():
    (if endTick <= 0: FfaMatchTicks.int32 else: min(endTick, FfaMatchTicks.int32))
  elif visionRulesVersion >= 28:
    (if endTick <= 0: HeartMeterMatchTicks.int32 else: min(endTick, HeartMeterMatchTicks.int32))
  else: (if endTick <= 0: MatchTicks.int32 else: endTick)
  result.seed = seed; result.rng = initRng(seed); result.winner = -1
  # FFA-kin draws the match's kinship here, on its own stream; the World RNG never sees it.
  if ffa(): activeKinship = matchKinship(seed)
  if visionRulesVersion >= 37 and not ffa():
    let seconds = result.endTick div TickRate
    result.glory = [seconds, seconds]
  if visionRulesVersion >= 38 and not ffa(): result.nextGloryHeart = GloryHeartFirstTick
  if activeMap() >= 0:
    for c in currentMap().cover:
      result.cover.add Cover(x: c.x.int32, z: c.z.int32, w: c.w.int32, h: 0)
  elif visionRulesVersion >= 8:
    for lot in roundVillage():
      result.cover.add Cover(x: (lot.x-lot.radius).int32,
          z: (lot.z-lot.radius).int32, w: (lot.radius*2).int32, h: 0)
  elif visionRulesVersion >= 7:
    for lot in VillageLots:
      result.cover.add Cover(x: lot.x.int32, z: lot.z.int32,
          w: lot.w.int32, h: lot.h.int32)
      result.cover.add Cover(x: (Width-lot.x-lot.w).int32,
          z: (Height-lot.z-lot.h).int32, w: lot.w.int32, h: lot.h.int32)
    result.cover.add Cover(x: 3090, z: 1890, w: 220, h: 220)
  else:
    # Symmetric lanes and bunkers leave all homes reachable.
    for x in [1500, 2600]:
      let shift = result.rng.between(-100, 100)
      for z in [650, 1650, 2850]:
        let c = Cover(x: x.int32, z: z.int32+shift, w: 260, h: 420)
        result.cover.add c
        result.cover.add Cover(x: Width.int32-c.x-c.w, z: Height.int32-c.z-c.h,
            w: c.w, h: c.h)
  for side in 0..1: result.resetHeart(side)
  if visionRulesVersion < 24:
    for i in 0..<Seats: result.spawn(i)
  if wilderness and activeMap() < 0:
    for p in [point(-620,300),point(-620,1700),point(-620,3500),point(1200,-320),point(3100,-320),point(5400,-320)]:
      for q in [p,point(6400-p.x.int,4000-p.z.int)]:
        result.cover.add Cover(x:q.x-65,z:q.z-65,w:130,h:0)
  if deepWilderness:
    for lot in forestLots():
      result.cover.add Cover(x:(lot.x-lot.radius).int32,z:(lot.z-lot.radius).int32,w:(2*lot.radius).int32,h:0)
  if visionRulesVersion >= 6: result.initializeEquipment()
  if ffa(): result.placeFfaSpawns()
  elif visionRulesVersion >= 24:
    for i in 0..<Seats:
      discard result.spawnAtHeart(i)
  result.bigHeart = -1
  if visionRulesVersion >= 25:
    result.usedBigHearts = newSeq[bool](result.controlHearts.len)

proc heartPoints*(w: World, index: int): int32 =
  if visionRulesVersion in 25..27 and w.bigHeart == index.int32: BigHeartPoints else: 1

proc heartMeterTarget*(w: World): int32 =
  ## Half the hearts held for three minutes, measured in integer tick-points.
  w.controlHearts.len.int32 * HeartMeterFillTicks div 2

proc earnGlory*(w: var World, side: int, kind: GloryKind, amount: int32) =
  ## Rules 37: credit a team and remember why, so the viewer can say so.
  if visionRulesVersion < 37: return
  w.glory[side] += amount
  w.gloryEvents.add GloryEvent(tick: w.tick, team: side.int32, amount: amount, kind: kind)

proc teamLives*(w: World, side: int): int32 =
  ## Lives left summed over the side's cogs: the count the behind-in-lives glory award
  ## compares (updateGlory), observation contract v3's scoreboard and BASIC teamLives(t).
  for i in 0..<Seats:
    if team(i) == side: result += w.equipment[i].lives

proc teamCogsOut*(w: World, side: int): int32 =
  ## The side's cogs out of the match (dead with no lives left): the count the rules-47
  ## behind-in-cogs glory award compares (updateGlory) and BASIC teamCogsOut(t).
  for i in 0..<Seats:
    if team(i) == side and w.cogs[i].hp <= 0 and w.equipment[i].lives <= 0: inc result

proc updateGlory*(w: var World) =
  ## Rules 37, once per tick after the tick counter advances: forget old awards, count
  ## down one glory per second, pay a team that went thirty seconds without supplies, and
  ## (rules 39) pay a team behind in lives every five seconds, and (rules 47) pay a team
  ## with more cogs out of the match than the enemy.
  var recent: seq[GloryEvent]
  for event in w.gloryEvents:
    if w.tick-event.tick < GloryEventLifetime: recent.add event
  w.gloryEvents = recent
  if w.tick mod TickRate == 0:
    for side in 0..1: w.glory[side] = max(0'i32, w.glory[side]-1)
  let rules = gloryRules()
  for side in 0..1:
    if w.tick-w.lastSupplyTick[side] >= rules.quietSupplySeconds*TickRate:
      w.lastSupplyTick[side] = w.tick
      w.earnGlory(side, gloryQuietSupplies, rules.quietSupplies)
  if visionRulesVersion >= 39 and w.tick mod (rules.behindLivesSeconds*TickRate) == 0:
    let lives = [w.teamLives(0), w.teamLives(1)]
    for side in 0..1:
      let behind = lives[1-side]-lives[side]
      if behind > 0: w.earnGlory(side, gloryBehindLives, behind*rules.behindLives)
  if visionRulesVersion >= 47 and w.tick mod (rules.behindCogsSeconds*TickRate) == 0:
    let down = [w.teamCogsOut(0), w.teamCogsOut(1)]
    for side in 0..1:
      let behind = down[side]-down[1-side]
      if behind > 0: w.earnGlory(side, gloryBehindCogs, behind*rules.behindCogs)

proc gloryHeartSpot(w: var World): (bool, Point) =
  ## A random open spot on dry land whose mirror is open too; false after 32 misses.
  for attempt in 0..<32:
    let p = point(w.rng.between(int32(minX()+400), int32(maxX()-400)).int,
      w.rng.between(int32(minZ()+400), int32(maxZ()-400)).int)
    let q = point(Width-p.x.int, Height-p.z.int)
    if distance2(p, q) < 800'i64*800: continue
    var open = true
    for spot in [p, q]:
      if w.blocked(spot) or riverBlend(spot.x.int, spot.z.int) > 0: open = false
    if open: return (true, p)
  (false, Point())

proc updateGloryHearts*(w: var World) =
  ## Rules 38, once per tick before the tick counter advances: forget old pickups, let
  ## expired hearts vanish, pay the first living cog (in fair seat order) within reach of
  ## a heart, and spawn the next mirrored pair on schedule.
  if visionRulesVersion < 38: return
  var recent: seq[GloryPickup]
  for pickup in w.gloryPickups:
    if w.tick-pickup.tick < GloryEventLifetime: recent.add pickup
  w.gloryPickups = recent
  var remaining: seq[GloryHeart]
  for heart in w.gloryHearts:
    if w.tick >= heart.expiresAt: continue
    var taker = -1
    for k in 0..<Seats:
      let i = if w.tick mod 2 == 1: k xor 1 else: k
      if w.cogs[i].hp > 0 and distance2(w.cogs[i].pos, heart.pos) <= GloryHeartReach.int64*GloryHeartReach:
        taker = i
        break
    if taker < 0:
      remaining.add heart
      continue
    let award = gloryRules().heart
    w.earnGlory(team(taker), gloryHeart, award)
    w.gloryPickups.add GloryPickup(tick: w.tick, seat: taker.int32, amount: award, pos: heart.pos)
  w.gloryHearts = remaining
  if w.tick >= w.nextGloryHeart:
    # One mirrored pair per ten control hearts: a big map (mapgen --heart-area) keeps the
    # glory-heart density of the ten-heart maps, which still spawn exactly one pair.
    for pair in 0..<max(1, w.controlHearts.len div 10):
      let (found, p) = w.gloryHeartSpot()
      if found:
        for spot in [p, point(Width-p.x.int, Height-p.z.int)]:
          w.gloryHearts.add GloryHeart(pos: spot, expiresAt: w.tick+GloryHeartTicks)
    w.nextGloryHeart = w.tick+w.rng.between(GloryHeartMinGap, GloryHeartMaxGap)

proc settleGlory*(w: var World) =
  ## Only winners keep glory: the loser's drops to zero, and a draw pays nobody.
  if visionRulesVersion < 37 or w.winner == -1: return
  for side in 0..1:
    if w.winner != side.int32: w.glory[side] = 0

proc scores*(w: World): seq[float] =
  if ffa():
    # R_i = sum over j of r(i,j) * s_j, in points.
    for i in 0..<Seats:
      var total = 0.0
      for j in 0..<Seats: total += activeKinship.r(i, j) * w.seatScore[j].float
      result.add total / 10.0
    return
  for i in 0..<Seats:
    result.add (if visionRulesVersion >= 37: w.glory[team(i)].float elif visionRulesVersion >= 23: w.scoreTicks[team(i)].float / TickRate.float else: float(if visionRulesVersion >= 20 and w.winner >= 0: (if w.winner == team(i).int32: 10 else: 0) elif visionRulesVersion>=13:w.captures[team(i)].int else:int(w.winner == team(i).int32)))
type LegacyWorld = object
  seed, tick: int32
  rng: Rng
  cogs: seq[Cog]
  hearts: array[2, Heart]
  captures: array[2, int32]
  cover: seq[Cover]
  balls: seq[Paintball]
  winner: int32
proc stateHash*(w: World): uint32 =
  if visionRulesVersion >= 26:
    result = HashySeed
    for name, value in fieldPairs(w):
      when name == "uniforms":
        if visionRulesVersion >= 27: result.addHashy(value)
      elif name == "glory" or name == "lastSupplyTick" or name == "gloryEvents":
        if visionRulesVersion >= 37: result.addHashy(value)
      elif name == "gloryHearts" or name == "nextGloryHeart" or name == "gloryPickups":
        if visionRulesVersion >= 38: result.addHashy(value)
      elif name in ["seatScore", "heartSeconds", "greatShare", "greatHearts", "spawnAnchor"]:
        if ffa(): result.addHashy(value)
      else: result.addHashy(value)
    return
  if visionRulesVersion >= 13:
    result = hashy(TerritoryWorld(seed:w.seed,tick:w.tick,rng:w.rng,cogs:w.cogs,
      hearts:w.hearts,captures:w.captures,cover:w.cover,balls:w.balls,winner:w.winner,
      equipment:w.equipment,trenches:w.trenches,pickups:w.pickups,grenades:w.grenades,
      blasts:w.blasts,controlHearts:w.controlHearts))
    if visionRulesVersion >= 23:
      result.addHashy(w.scoreTicks)
      result.addHashy(w.endTick)
    if visionRulesVersion >= 24:
      result.addHashy(w.heartCaptures)
    if visionRulesVersion >= 25:
      result.addHashy(w.bigHeart)
      result.addHashy(w.bigHeartRound)
      result.addHashy(w.usedBigHearts)
    return
  if visionRulesVersion >= 6:
    return hashy(CombatWorld(seed:w.seed,tick:w.tick,rng:w.rng,cogs:w.cogs,
      hearts:w.hearts,captures:w.captures,cover:w.cover,balls:w.balls,winner:w.winner,
      equipment:w.equipment,trenches:w.trenches,pickups:w.pickups,grenades:w.grenades,blasts:w.blasts))
  hashy(LegacyWorld(seed: w.seed, tick: w.tick, rng: w.rng, cogs: w.cogs,
      hearts: w.hearts, captures: w.captures, cover: w.cover, balls: w.balls,
      winner: w.winner))
proc dropHeart(w: var World, slot: int) =
  if not w.cogs[slot].carrying: return
  let enemy = 1-team(slot)
  w.hearts[enemy] = Heart(pos: w.cogs[slot].pos, carrier: -1,
      returnAt: w.tick+240)
  w.cogs[slot].carrying = false
# Optional spectator instrumentation lives outside World and its hash.
var observeShot*: proc(tick: int32, slot: int) {.closure.}
var observeHit*: proc(tick: int32, victim, attacker: int,
    pos: Point) {.closure.}
var observeTag*: proc(tick: int32, victim, attacker: int,
    pos: Point) {.closure.}
proc hit*(w: var World, victim, attacker: int) =
  if w.cogs[victim].hp <= 0 or w.cogs[victim].shield > 0: return
  if observeHit != nil: observeHit(w.tick, victim, attacker, w.cogs[victim].pos)
  dec w.cogs[victim].hp
  if w.cogs[victim].hp == 0:
    w.dropHeart(victim); w.cogs[victim].respawn = seatRespawnTicks(victim)
    inc w.cogs[attacker].tags
    if observeTag != nil: observeTag(w.tick, victim, attacker, w.cogs[victim].pos)
proc legacyWaypoint(w: World, start, goal: Point): Point =
  ## Bounded breadth-first navigation over a 32x20 arena grid.
  if w.lineClear(start, goal) and w.traversable(start, goal): return goal
  let nx = (maxX()-minX()) div 200; let nz = (maxZ()-minZ()) div 200
  var prev: array[1920, int]
  for x in prev.mitems: x = -2
  let a = clamp((start.z.int-minZ()) div 200, 0, nz-1)*nx+clamp((start.x.int-minX()) div 200, 0, nx-1)
  let b = clamp((goal.z.int-minZ()) div 200, 0, nz-1)*nx+clamp((goal.x.int-minX()) div 200, 0, nx-1)
  var q: array[1920, int]; var head = 0; var tail = 1
  q[0] = a; prev[a] = -1
  while head < tail and prev[b] == -2:
    let n = q[head]; inc head
    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let x = n mod nx+delta[0]; let z = n div nx+delta[1]
      if x < 0 or x >= nx or z < 0 or z >= nz: continue
      let j = z*nx+x
      if prev[j] != -2 or w.blocked(point(minX()+x*200+100, minZ()+z*200+100), 90): continue
      if not w.traversable(point(minX()+n mod nx*200+100, minZ()+n div nx*200+100), point(
          minX()+x*200+100, minZ()+z*200+100)): continue
      prev[j] = n; q[tail] = j; inc tail
  if prev[b] == -2: return start
  var n = b
  while prev[n] >= 0 and prev[n] != a: n = prev[n]
  point(minX()+n mod nx*200+100, minZ()+n div nx*200+100)
# Navigation uses body clearance, never the visibility ray. Cached flow fields
# share static terrain work across cogs headed for the same objective.
type
  NavField = object
    ## Distances to one target cell, expanded only as far as callers have needed. Every cell
    ## whose distance is below `level` is final; any other value is tentative (or -1, not yet
    ## reached). A field stops early once the cells a caller reads are final and resumes where
    ## it stopped for the next caller; run to the end it equals the old full search.
    dist: seq[int32]
    buckets: array[5, seq[int]]   # rules 38 Dial buckets, by distance mod 5
    level: int32
    pending: int
  NavCache = object
    cover: seq[Cover]
    payload: pointer
    length: int
    bounds: array[4,int]
    edges: seq[seq[int]]
    fields: Table[int,NavField]  # target cell -> distances toward it
    recent: seq[int]              # targets, least recently used first
    pinned: seq[int]              # target cells of the map's hearts, pickups and homes: never evicted
    targets: Table[Point,int]     # goal -> nearest connected cell (or -1)
    water: seq[bool]              # rules 38: whether each cell's centre is in the lake
    weighted: bool                # rules 38: `fields` measure time, a lake cell costing four
when defined(pwTraining):
  var nav {.threadvar.}: NavCache
  var navCompleteFields* {.threadvar.}: bool
  # Per map, as coverIndex above: the grid, water and fields describe one map's geometry.
  var navParked {.threadvar.}: array[MapNames.len+1, NavCache]
  var navMap {.threadvar.}: int # 1 + the map nav belongs to (0 = the island)
else:
  var nav: NavCache
  var navCompleteFields* = false ## tests: expand every field to the end, as before the cache
const
  NavCell = 100
  NavFieldLimit = 64
  NavTargetLimit = 4096
proc walkCoverBlocks(c: Cover, a,b: Point, dx,dz,length: float64): bool {.inline.} =
  if c.h==0:
    let r=c.w.float64/2
    let cx=c.x.float64+r;let cz=c.z.float64+r
    let t=if length==0:0.0 else:clamp(((cx-a.x.float64)*dx+(cz-a.z.float64)*dz)/length,0.0,1.0)
    let ex=a.x.float64+t*dx-cx;let ez=a.z.float64+t*dz-cz
    if ex*ex+ez*ez<(r+Radius.float64)*(r+Radius.float64):return true
  else:
    let steps=max(abs(b.x-a.x),abs(b.z-a.z)).int div 15+1
    for i in 1..steps:
      let x=a.x.int+(b.x-a.x).int*i div steps
      let z=a.z.int+(b.z-a.z).int*i div steps
      if x>c.x-Radius and x<c.x+c.w+Radius and z>c.z-Radius and z<c.z+c.h+Radius:return true
proc walkClear*(w: World, a,b: Point):bool =
  if w.blocked(b) or not w.traversable(a,b):return false
  let dx=(b.x-a.x).float64;let dz=(b.z-a.z).float64
  let length=dx*dx+dz*dz
  when IndexedGeometry:
    for index in segmentCover(w,a,b):
      if w.cover[index].walkCoverBlocks(a,b,dx,dz,length):return false
  else:
    for c in w.cover:
      if c.walkCoverBlocks(a,b,dx,dz,length):return false
  let steps=max(abs(b.x-a.x),abs(b.z-a.z)).int div 50+1
  for i in 1..steps:
    let x=a.x.int+(b.x-a.x).int*i div steps
    let z=a.z.int+(b.z-a.z).int*i div steps
    if islandTerrain and islandMargin(x,z)<Radius div 3+40:return false
  true
proc navCellOf(p:Point,nx,nz:int):int =
  let x=(p.x.int-minX()) div NavCell;let z=(p.z.int-minZ()) div NavCell
  if x<0 or z<0 or x>=nx or z>=nz: -1 else: z*nx+x
proc navSegmentDry(a,b:Point,nx,nz:int):bool =
  ## Rules 38: no lake cell lies under the segment from a to b, a itself excluded.
  ## Integer steps at half a cell, so the answer is the same on every platform.
  let dx=b.x.int64-a.x.int64;let dz=b.z.int64-a.z.int64
  let steps=max(1'i64,int64(sqrt(float64(dx*dx+dz*dz))) div (NavCell div 2))
  for k in 1'i64..steps:
    let c=navCellOf(point(int(a.x.int64+dx*k div steps),int(a.z.int64+dz*k div steps)),nx,nz)
    if c>=0 and nav.water[c]:return false
  true
proc navigationPoint(n,nx:int):Point =
  point(minX()+(n mod nx)*NavCell+NavCell div 2,
        minZ()+(n div nx)*NavCell+NavCell div 2)
proc nearestConnectedCell(goal:Point,nx,nz:int):int =
  ## The connected cell whose centre is nearest the goal, lowest index on ties: the
  ## same answer as scanning every cell, found by rings of cells around the goal that
  ## stop once a ring cannot hold a centre as near as the best so far.
  result = -1
  var best=high(int64)
  let originX=minX(); let originZ=minZ()
  let gx=floorDiv(goal.x.int-originX,NavCell)
  let gz=floorDiv(goal.z.int-originZ,NavCell)
  for ring in 0..max(nx,nz)+max(abs(gx),abs(gz))+1:
    if ring>0:
      let nearest=int64((ring-1)*NavCell+NavCell div 2)
      if nearest*nearest>best:break
    for z in max(0,gz-ring)..min(nz-1,gz+ring):
      let edge=abs(z-gz)==ring
      var x=max(0,gx-ring)
      while x<=min(nx-1,gx+ring):
        if edge or abs(x-gx)==ring:
          let n=z*nx+x
          if nav.edges[n].len>0:
            let d=distance2(goal,point(originX+x*NavCell+NavCell div 2,originZ+z*NavCell+NavCell div 2))
            if d<best or (d==best and n<result):best=d;result=n
        if edge or x>=gx+ring:inc x
        else:x=gx+ring
proc waypoint*(w:World,start,goal:Point):Point =
  if visionRulesVersion<22:return w.legacyWaypoint(start,goal)
  # Rules 38: the route measures time, not distance. A cog in the lake moves at a quarter of
  # its speed, and the old search - a straight line whenever no wall is in the way, else an
  # unweighted grid - walked straight through it. From dry land a cog now takes a shortcut or
  # a pulled string only when it stays dry; a cog already wading keeps the old freedom, since
  # every way out of the water starts in it.
  let wetRouting=visionRulesVersion>=38
  if not wetRouting and w.walkClear(start,goal):return goal
  let nx=(maxX()-minX()) div NavCell
  let nz=(maxZ()-minZ()) div NavCell
  let bounds=[minX(),minZ(),maxX(),maxZ()]
  let payload=if w.cover.len>0:cast[pointer](unsafeAddr w.cover[0]) else:nil
  when defined(pwTraining): parkForMap(nav, navParked, navMap)
  # The grid depends only on cover and bounds. A world whose cover payload address or
  # length differs from the last is compared by content; the grid survives if it agrees.
  let same=nav.edges.len==nx*nz and nav.bounds==bounds and nav.length==w.cover.len and
    nav.weighted==wetRouting and
    ((nav.payload==payload and defined(pwTraining)) or nav.cover==w.cover)
  if not same:
    nav.cover=w.cover;nav.bounds=bounds;nav.fields.clear();nav.recent.setLen(0);nav.targets.clear()
    nav.pinned.setLen(0)
    nav.weighted=wetRouting;nav.water.setLen(0)
    nav.edges=newSeq[seq[int]](nx*nz)
    for n in 0..<nx*nz:
      let a=navigationPoint(n,nx)
      if w.blocked(a):continue
      for delta in [(1,0),(0,1)]:
        let x=n mod nx+delta[0];let z=n div nx+delta[1]
        if x>=nx or z>=nz:continue
        let j=z*nx+x
        if w.walkClear(a,navigationPoint(j,nx)):
          nav.edges[n].add j;nav.edges[j].add n
  nav.payload=payload;nav.length=w.cover.len
  if wetRouting and nav.water.len!=nx*nz:
    # The lake is fixed geometry, so it is sampled once per grid, at each cell's centre.
    nav.water=newSeq[bool](nx*nz)
    for n in 0..<nx*nz:
      let c=navigationPoint(n,nx)
      nav.water[n]=riverBlend(c.x.int,c.z.int)>0 and terrainHeight(c.x.int,c.z.int)<RiverWaterHeight
  let dryOnly=wetRouting and (let c=navCellOf(start,nx,nz); c<0 or not nav.water[c])
  if wetRouting and w.walkClear(start,goal) and (not dryOnly or navSegmentDry(start,goal,nx,nz)):
    return goal
  var target = -1
  if goal in nav.targets:target=nav.targets[goal]
  else:
    target=nearestConnectedCell(goal,nx,nz)
    if nav.targets.len>=NavTargetLimit:nav.targets.clear()
    nav.targets[goal]=target
  if target<0:return start
  # Rules 44 (FFA) and 45 (every mode): when the goal's own cell is in the lake, every route
  # to it ends in the water, so dry anchors and dry string pulls can only lead to the shore
  # cell nearest it, where the cog then stood still for as long as it kept the goal (the two
  # lake hearts and their medkits, ~300 units short of the capture ring). Such a cog takes anchors
  # and pulls as a wading cog does; the time-weighted field keeps it on dry land for as long
  # as that is faster. The straight dry shortcut above is unchanged: it never ends in water.
  let dryAnchors=dryOnly and not (wadesToWetGoals() and nav.water[target])
  if target notin nav.fields:
    var f=NavField(dist:newSeq[int32](nx*nz))
    for d in f.dist.mitems:d = -1
    f.dist[target]=0
    if wetRouting:
      f.buckets[0].add target;f.pending=1
    else:
      # Unweighted rules: the old breadth-first search, complete at once.
      var queue = @[target]
      var head=0
      while head<queue.len:
        let n=queue[head];inc head
        for j in nav.edges[n]:
          if f.dist[j]<0:
            f.dist[j]=f.dist[n]+1;queue.add j
      f.level=high(int32)
    if nav.pinned.len==0:
      # The map's fixed objectives are routed to all match long; their fields stay cached.
      var fixed: seq[Point] = @[home(0), home(1)]
      for h in w.controlHearts: fixed.add h.pos
      for pk in w.pickups: fixed.add pk.pos
      for p in fixed:
        let c=nearestConnectedCell(p,nx,nz)
        if c>=0 and c notin nav.pinned: nav.pinned.add c
      if nav.pinned.len==0: nav.pinned.add -1
    var unpinned=0
    for t in nav.recent:
      if t notin nav.pinned: inc unpinned
    if unpinned>=NavFieldLimit:
      # Bounded eviction of the least recently used unpinned field; results never depend on it.
      for i, t in nav.recent:
        if t notin nav.pinned:
          nav.fields.del(t);nav.recent.delete(i);break
    nav.fields[target]=f
    nav.recent.add target
  elif nav.recent[^1]!=target:
    nav.recent.delete(nav.recent.find(target));nav.recent.add target
  block:
    # Expand the field until every cell the anchor search below can read is final: the
    # connected cells within three of the start. Any cell the string pull then reads is
    # nearer the target than the anchor, so it is final too; a tentative neighbour is never
    # below the anchor either way, so the comparisons match a complete search exactly.
    let f=addr nav.fields[target]
    let sx0=(start.x.int-minX()) div NavCell
    let sz0=(start.z.int-minZ()) div NavCell
    proc ready(f: ptr NavField): bool =
      if navCompleteFields: return false
      for z in max(0,sz0-3)..min(nz-1,sz0+3):
        for x in max(0,sx0-3)..min(nx-1,sx0+3):
          let n=z*nx+x
          if nav.edges[n].len>0 and not (f.dist[n]>=0 and f.dist[n]<f.level):return false
      true
    while f.pending>0 and not ready(f):
      # Dial's buckets: exact for step costs of 1 and 4, and deterministic in scan order.
      let bucket=f.buckets[f.level mod 5];f.buckets[f.level mod 5].setLen(0)
      f.pending-=bucket.len
      for n in bucket:
        if f.dist[n]!=f.level:continue
        for j in nav.edges[n]:
          let nd=f.level+(if nav.water[j]:4'i32 else:1'i32)
          if f.dist[j]<0 or nd<f.dist[j]:
            f.dist[j]=nd;f.buckets[nd mod 5].add j;inc f.pending
      inc f.level
  let distances=addr nav.fields[target].dist
  result=start
  var best=high(int64)
  var anchor = -1
  let sx=(start.x.int-minX()) div NavCell
  let sz=(start.z.int-minZ()) div NavCell
  # From dry land the anchor must be reachable without wading; if that leaves nothing - a cog
  # on a shore whose every open neighbour is wet - fall back to the old rule, never stand still.
  for pass in 0..1:
    if pass==1 and (anchor>=0 or not dryAnchors):break
    let needDry=dryAnchors and pass==0
    for z in max(0,sz-3)..min(nz-1,sz+3):
      for x in max(0,sx-3)..min(nx-1,sx+3):
        let n=z*nx+x
        if distances[n]<0:continue
        let p=navigationPoint(n,nx)
        let cost=distances[n].int64*10000000+distance2(start,p)
        if cost<best and w.walkClear(start,p) and (not needDry or navSegmentDry(start,p,nx,nz)):
          best=cost;anchor=n
  if anchor<0:return
  let pullDry=dryAnchors and navSegmentDry(start,navigationPoint(anchor,nx),nx,nz)
  result=navigationPoint(anchor,nx)
  for step in 0..<8:
    var next = -1
    for j in nav.edges[anchor]:
      if distances[j]>=0 and distances[j]<distances[anchor]:next=j;break
    if next<0:break
    let p=navigationPoint(next,nx)
    if not w.walkClear(start,p):break
    if pullDry and not navSegmentDry(start,p,nx,nz):break
    result=p;anchor=next
proc territoryOwner*(w: World, p: Point): int32 =
  ## Who owns the territory at p: the owner of the nearest control heart (distance2, ties
  ## to the lower index; the viewer's territory overlay uses the same rule), -1 when that
  ## heart is neutral or there are no hearts.
  if w.controlHearts.len == 0: return -1
  var nearest = 0
  for i, h in w.controlHearts:
    if distance2(p, h.pos) < distance2(p, w.controlHearts[nearest].pos): nearest = i
  w.controlHearts[nearest].owner
proc territoryBoost*(w: World, slot: int, kin: Kinship): int =
  ## The FFA-kin territory boost for the seat where it stands, in percent:
  ## TerritoryBoostPercent * rPercent(slot, owner) div 100. 0 in the teams game, on neutral
  ## ground and on a stranger's. Movement speed is multiplied by (100 + boost) / 100 and gun
  ## spread by (100 - boost) / 100. This and spawn grouping are the only places the engine
  ## reads kinship; it reads r (ibd), never genes.
  if not ffa() or slot notin 0..<Seats: return 0
  let owner = w.territoryOwner(w.cogs[slot].pos)
  if owner notin 0'i32..<Seats.int32: return 0
  TerritoryBoostPercent * kin.rPercent(slot, owner.int).int div 100
proc territoryBoost*(w: World, slot: int): int =
  ## territoryBoost under the match's kinship (activeKinship).
  w.territoryBoost(slot, activeKinship)
proc boostedSpeed*(speed, boost: int): int =
  ## A move speed under a territory boost; exact identity at boost 0 (the teams game).
  speed * (100 + boost) div 100
proc stepEquipment(w: var World, commands: openArray[Command])
proc step*(w: var World, commands: openArray[Command],
    rulesVersion = visionRulesVersion) =
  if rulesVersion >= 6:
    w.stepEquipment(commands)
    return
  let solid = rulesVersion >= 3
  if w.winner >= 0: return
  for i in 0..<Seats:
    if w.cogs[i].hp <= 0:
      dec w.cogs[i].respawn
      if w.cogs[i].respawn <= 0: w.spawn(i, solid)
      continue
    if w.cogs[i].shield > 0: dec w.cogs[i].shield
    if w.cogs[i].cooldown > 0: dec w.cogs[i].cooldown
    let cmd = commands[i]
    if cmd.walk: w.cogs[i].goal = Point(x: clamp(cmd.goal.x, (minX()+100).int32, (maxX()-100).int32),
        z: clamp(cmd.goal.z, (minZ()+100).int32, (maxZ()-100).int32))
    w.cogs[i].firing = cmd.shoot
    if cmd.shoot or (rulesVersion >= 4 and cmd.aim != Point()):
      w.cogs[i].aim = cmd.aim
    elif rulesVersion >= 4 and cmd.walk and cmd.goal != w.cogs[i].pos:
      w.cogs[i].aim = cmd.goal
    let dest = if cmd.direct: w.cogs[i].goal else: w.waypoint(w.cogs[i].pos,
        w.cogs[i].goal)
    let speed = boostedSpeed(if w.cogs[i].carrying: MoveSpeed*7 div 10 else: MoveSpeed,
      w.territoryBoost(i))
    if distance2(w.cogs[i].pos, dest) > speed.int64*speed:
      let v = direction(w.cogs[i].pos, dest, speed)
      var p = w.cogs[i].pos; p.x+=v.x
      if not w.movementBlocked(p, i, solid): w.cogs[i].pos = p
      p = w.cogs[i].pos; p.z+=v.z
      if not w.movementBlocked(p, i, solid): w.cogs[i].pos = p
    if cmd.shoot and w.cogs[i].cooldown == 0:
      let v = direction(w.cogs[i].pos, w.cogs[i].aim, ShotSpeed)
      if v.x != 0 or v.z != 0:
        if observeShot != nil: observeShot(w.tick, i)
        w.balls.add Paintball(pos: w.cogs[i].pos, velocity: v, owner: i.int32,
            life: ShotRange div ShotSpeed)
        w.cogs[i].cooldown = (if solid: FireCooldownTicks else: 8)
  var live: seq[Paintball]
  for original in w.balls:
    var b = original
    let old = b.pos
    b.pos.x+=b.velocity.x; b.pos.z+=b.velocity.z; dec b.life
    if b.life < 0 or not w.lineClear(old, b.pos): continue
    var collided = false
    # Short swept samples prevent a fast ball crossing a cog between ticks.
    for sub in 1..4:
      let p = Point(x: old.x+b.velocity.x*sub.int32 div 4,
          z: old.z+b.velocity.z*sub.int32 div 4)
      for j in 0..<Seats:
        if team(j) != team(b.owner.int) and w.cogs[j].hp > 0 and distance2(p,
            w.cogs[j].pos) <= Radius.int64*Radius:
          w.hit(j, b.owner.int); collided = true; break
      if collided: break
    if not collided: live.add b
  w.balls = live
  for side in 0..1:
    if w.hearts[side].carrier >= 0:
      w.hearts[side].pos = w.cogs[w.hearts[side].carrier].pos
    elif w.hearts[side].returnAt > 0 and w.tick >= w.hearts[
        side].returnAt: w.resetHeart(side)
  for i in 0..<Seats:
    if w.cogs[i].hp <= 0: continue
    let side = team(i); let enemy = 1-side
    if w.hearts[side].carrier < 0 and distance2(w.cogs[i].pos, w.hearts[
        side].pos) < 140*140:
      w.resetHeart(side)
    if not w.cogs[i].carrying and w.hearts[enemy].carrier < 0 and distance2(
        w.cogs[i].pos, w.hearts[enemy].pos) < 140*140:
      w.cogs[i].carrying = true; w.hearts[enemy].carrier = i.int32
    if w.cogs[i].carrying and distance2(w.cogs[i].pos, home(side)) < 200*200 and
        w.hearts[side].carrier < 0 and w.hearts[side].pos == home(side):
      inc w.captures[side]; inc w.cogs[i].captures
      w.cogs[i].carrying = false; w.resetHeart(enemy)
      if w.captures[side] >= CaptureTarget: w.winner = side.int32
  inc w.tick

include mechanics
