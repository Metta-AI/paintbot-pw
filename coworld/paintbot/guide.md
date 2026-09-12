# Paintbot PW

Sixteen wheeled cogs fight for territory in Heartwick. Red uses even slots;
Blue uses odd slots. Ten stationary hearts divide the entire map into nearest-heart
regions. Each team starts with its base heart; eight hearts start neutral gray.
Stay within 140 units of a heart on connected terrain for three seconds (72 ticks)
to claim it. Extra cogs do not accelerate capture. Both teams in range pause
progress; if the attackers leave or only defenders remain, progress resets.
The current owner keeps earning points until capture completes. Holding all ten eliminates the entire opposing team, including remaining respawns.

The default-on territory overlay colors each region by its heart owner, including
neutral gray. Toggle it off for an unobstructed terrain view. Heart locations and
ownership are public. BASIC exposes `heartCount()`, `controlX(i)`, `controlY(i)`,
and `controlOwner(i)` (-1 neutral, 0 red, 1 blue). Capture state is also public:
`controlCaptureTeam(i)` (-1 idle), `controlCaptureTicks(i)` (0–71 of 72), and
`controlContested(i)` (0 or 1). Invalid indices return -1. WASM sprite observations include
`control heart <index> owner <owner>` and a separate
`control capture <index> team <team> ticks <ticks> contested <0|1>` sprite; the legacy enemy-flag target points to an
unowned objective so existing Paintbot WASM policies can play territory control.

Cogs have three base HP and three respawns (four lives total). Death loses equipment and respawns
after 72 ticks; spawn protection lasts 36 ticks. Initial spawns and respawns are within 350 world units
of an owned heart, sampled with softmax over the sum of distances from living teammates (excluding
self). Larger sums favor less-covered hearts. Temperature is 1,000 world units, with distances
quantized to 10 units for deterministic sampling. With no owned hearts, respawns use the endzone.
Blocked or crowded heart placements retry on the next tick. Each owned normal heart earns its team one point per second, accumulated at 24 ticks
per second. Starting at 0:30, every 30 seconds a random heart becomes big and earns
five points per second instead of one. Only one heart is big at a time; the previous
heart returns to normal. Selection includes neutral and owned hearts, and no heart
is selected twice in a game. After every heart has been selected, no more become big. Matches last five minutes. When a team is eliminated, the survivor receives
all remaining map income in bonus points, including scheduled big-heart income. Both teams keep previously earned points.
The higher total wins; equal totals draw. Simultaneous elimination gives no bonus.
There is no bombardment or overtime.
Older replays retain their original capture-the-heart rules.

## Combat and equipment

- Solid bodies block teammates and opponents. Movement while carrying is 70%.
- Vision is a 120-degree forward cone with unlimited distance and wall occlusion.
- Paintball guns lock aim during a five-tick windup, then trace a hitscan ray.
  Friendly fire is enabled. Shots released together choose targets before damage.
  Range is 5250 units. The user-selected cadence is one shot per second.
- Four grenade pickups refill after five seconds. Carry one; hold C to charge up
  to 24 ticks and release to throw. Grenades fly over walls, land after ten ticks,
  and deal two damage to every body in the blast, including allies and yourself.
- Spray cans refill after 30 seconds. A carried can replaces the gun. Fire sends
  a directional cone for five ticks, with 20 ticks of recovery. Aim locks at the
  beginning of each burst; each victim takes three damage once per burst.
- Trenches are walkable pits. Entering is full speed; movement outward is slowed
  fivefold. Gun cooldown is tripled, and 70% of outside gunfire passes overhead.
  Shots from inside the same trench and spray ignore that protection. Grenades
  deal six damage to victims in the landing trench, one to victims in other
  trenches, and two outside trenches.
- Shields add three armor HP without healing base HP. Damage consumes armor first.
  Armor, heart carrying, and trenches slow gunfire threefold without stacking.
- Med kits restore base HP; healthy cogs leave them. Shields and kits refill in
  30 seconds. All pickups and other cogs are fog-gated for policies.

The game runs at 24 deterministic ticks per second. Coordinates use integer
hundredths of a Polyworld tile on a 6400×4000 arena.

## File policies

Submit either a UTF-8 BASIC file or a WASM module implementing `paintbot_alloc`,
`paintbot_buffer`, `paintbot_step`, `paintbot_output_size`, exported memory and
optional WASI `_initialize`. WASM uses the existing Paintbot sprite protocol:
movement, aim buttons, A for gun/spray, C for grenade charge/release. Observations
include fog-gated equipment labels, grenade flights/targets/blasts, spray puffs,
armor, lives, hearts, and static trench terrain.

BASIC read-only data: `selfId`, `selfTeam`, `selfX`, `selfY`, `selfHp`, `carrying`,
`homeX`, `homeY`, `heartX`, `heartY`, `ownHeartX`, `ownHeartY`, `ownHeartStolen`,
`worldTick`, `hasGrenade`, `hasSpray`, `armorHp`, `livesLeft`, `grenadeCharge`,
`trenchId` (-1 outside).

Queries: `visible(slot)`, `playerX(slot)`, `playerY(slot)`, `playerHp(slot)`,
`playerCarrying(slot)`, `pickupCount()`, `pickupVisible(id)`, `pickupX(id)`,
`pickupY(id)`, `pickupKind(id)` (0 grenade, 1 spray, 2 medkit, 3 armor).
Hidden player and pickup coordinates are not disclosed.

Actions: `walkTo(x,y)`, `lookAt(x,y)`, `shootAt(x,y)`, `chargeGrenade(held)`.
Release by calling `chargeGrenade(0)` or not calling it on the next tick.
`shout(stringHandle)` is public communication; PRINT remains private.
Source is limited to 64 KiB, memory to 2 MiB, and each decision to 20,000
instructions / 50,000 work units. WASM instances are isolated in the game pod.

## Replays

Replays record accepted actions and per-tick state hashes. Version 6 includes
all equipment state and the approved Paint Crew cog models. The viewer supports
seeking, individual cone visibility, first-person view, event filtering, inventory,
armor/lives inspection, grenade arcs/blasts, spray effects and trench markers.
Earlier replay versions retain their original rules and hashes.

## Heartwick arena

Cottages, garden walls, carts, supply stacks and the market well are solid cover: they block movement, sight and direct fire. Grenades still lob over them. The village is symmetric under a half turn, with a market square, cross streets and side lanes. Flower patches are walkable decoration. Trenches retain their existing movement and damage rules.

### High ground accuracy

Gun spread decreases by 25% per metre above the locked aim point, capped at 50% less spread. Shooting uphill increases spread by up to 50%; level shots are unchanged. Terrain and trench depth both count. This applies to BASIC and WASM policies, starting with replay rules version 10.

### Village navigation and nearby speech

Rules 11 widen terrace ramps from 2m to 6m. The baseline assigns high-ground holders and separate flanking lanes, scans when it loses sight of enemies, and holds distance with guns while closing with spray cans.

BASIC uses `shout(strNew("Contact!"))`. Messages are limited to four 256-byte lines per tick. On the next tick, living cogs within 12.8m hear both teams through `heardCount()`, `heardSlot(i)`, `heardX(i)`, `heardY(i)`, and `heardText(i)`. Hearing is independent of the vision cone. WASM receives nearby messages as `shout <slot> <text>` labelled sprites at the speaker's position. The viewer shows speech bubbles for visible living speakers for three seconds.

The equipment baseline remembers visible supplies for ten seconds, sends scouts toward corner supplies, and sends equipped cogs into combat. Grenade charge follows target distance with a visible-friendly blast check. The WASM baseline uses increased grenade/spray detour budgets and the PW throw/spray ranges; rebuild with `tools/build_equipment_baseline.py` and a CTF checkout with its Nimby dependencies. This build used CTF commit `40d0bee8e2c5a8955ff711d96c4c1bb482a69134`.

Grenade and spray pickups are enlarged, bob, and spin. Each gun shot draws four bright paintballs for readability; this is visual only and still resolves one hit with the existing cooldown.

### Wilderness flanks (rules 12)

Heartwick now has 80m × 48m of playable terrain, 50% more area than the original 64m × 40m village. Coordinates extend from (-800,-400) to (7200,4400) cm, preserving the village, hearts, and equipment positions. Wooded rolling hills and a continuous perimeter trail connect back into the village on all sides. Two BASIC flankers per team use the upper and lower wilderness wings. `mapMinX/Y()` and `mapMaxX/Y()` expose the bounds; WASM sprites use a translated 1600×960 pixel map with the same five-cm scale. Older recordings retain their original boundaries.

Heartwick now spans 120 × 64 metres (twice the preceding wilderness map area).
The original village sits inside wooded hill country with broad saddles, outer
trails, six outlying territory hearts, and four extra medkit stations. Terrain
heights and tree/bush collision bounds are shared by native and WASM policies.

Baseline routine callouts are staggered across seats every 15 seconds.

New matches use meandering paths with varying widths and curved terrain banks.
The same deterministic land deformation drives heights, ramps, navigation,
and vegetation placement; older recordings keep their original terrain.

Heartwick now occupies an irregular island. The sandy coast slopes into water;
policies and movement respect the shoreline, while all objectives remain connected.

Spray covers a roughly 62-degree cone and deals 3 damage per target per burst; armor absorbs damage first.

### Expanded island and navigation (rules 22)

The island spans 160 × 96 metres, exactly twice the previous map area.
Bounds are (-4800, -2800) to (11200, 6800) centimetres. Six outer hearts
now sit in the expanded wooded hills. BASIC walkTo routes account for body
clearance and traversable slopes; blocked cogs sidestep instead of pushing
forever. Baselines abandon objectives after three seconds without progress.
WASM receives the same enlarged geometry through a compressed 3200 × 1920
walkability map, including clearance around obstacles.

### Deliberate heart captures (rules 24)

Heart towers show a bar in the capturing team's color. A yellow marker means
capture is contested and paused; the minimap shows the same progress and an
exclamation mark. Capturing an enemy heart takes the same three seconds as a
neutral heart. A different attacking team starts from zero. Capture progress
is recorded in deterministic state hashes and restored when seeking replays.
Rules 23 and older retain their original instant captures and replay hashes.

### Big hearts (rules 25)

Big hearts are twice as large and have a gold ring; the minimap marks them with
`5`. Capture time, capture radius, and ownership rules stay the same. A neutral
big heart earns no points until captured. BASIC `controlPoints(i)` returns 1 or 5
(-1 for an invalid index). WASM receives `control value <index> points <1|5>`
alongside the unchanged ownership and capture sprites. Choices are deterministic
for replay verification, and seeking restores both the active heart and used-heart
history. Rules 24 and older retain ordinary one-point hearts.

### Trenches and imperfect hearing (rules 26)

Trenches have dark sunken floors, exposed ochre banks, and timber duckboards.
The tactical map outlines their footprints in tan. Their cover rules are unchanged:
most outside gunfire passes overhead, but grenades landing in the same trench are
especially dangerous, and climbing out is slower.

Nearby movement, gunfire, explosions, and spray produce one-second sound cues.
Sound travels around walls but reveals only a kind, one of eight compass sectors,
and a rough distance band; it reveals no source identity, team, or exact position.
Normal movement is audible within 10 metres, gunfire within 35, explosions within
50, and spray within 18. Cues refresh rather than stack for the same kind and sector,
with at most twelve retained per listener. Dead cogs hear nothing.

BASIC exposes `soundCount()`, `soundKind(i)` (0 footsteps, 1 gunfire, 2 explosion,
3 spray), `soundDirection(i)` (0 E, 1 SE, 2 S, 3 SW, 4 W, 5 NW, 6 N, 7 NE),
`soundDistance(i)` (0 within 6m, 1 within 18m, 2 farther), and `soundAge(i)` in ticks.
Invalid indices return -1. Call `sneak(1)` each tick to move at half speed without
footstep cues; weapons remain audible. Humans hold Q while moving. WASM uses the
B+Select chord (button mask 80), while either button alone retains aim control.
WASM sound sprites are anchored at the listener, with labels
`sound kind <kind> direction <sector> distance <band> age <ticks>`. They do not place sprites at the source. The selected cog's cues
appear as coarse arcs on the minimap and as brief directional text.

The starter policy turns toward sounds when it has no visible opponent and uses
quiet approaches near objectives. Speech remains a separate existing channel.
Older recordings retain their original mechanics and replay hashes.
