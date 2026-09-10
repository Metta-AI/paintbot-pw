# Paintbot PW

Sixteen wheeled cogs fight on a symmetric Polyworld arena. Red uses even slots;
Blue uses odd slots. Capture the enemy heart in your home endzone or exhaust the
other team's lives to win. One capture wins, even if your own heart is stolen.
Each cog has three lives and three base HP. Death returns a carried heart home,
loses equipment, and respawns at a fresh endzone position after 72 ticks if lives
remain. Spawn protection lasts 36 ticks. A time-limit draw gives both teams zero.

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
