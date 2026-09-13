# Validation

Validated on 2026-09-09 with Nim 2.2.6, Wasmtime 48.0.0 and the unchanged CDX baseline.

- Seven engine checks: deterministic seed, cover collision, tagging/respawn, capture victory, visibility, stolen-heart score denial, automatic heart return.
- Four Python boundary checks: policy digest mismatch, prohibited reply packet, bad WASM initialization attributed to its seat, gun-ready observation.
- An infinite BASIC loop exhausts the instruction budget and disables its seat without stopping the match.
- Sixteen original WASM baselines completed 7,200 ticks, all seats moving and firing. Draw, replay hash `2757634530`.
- Eight BASIC vs eight original WASM baselines completed in 3,984 ticks, BASIC won 3–0. All seats moved and fired. Native replay hash `1977552757`; browser resimulation reached tick 3,984 with the same score and no hash divergence.
- BASIC vs idle captured three hearts in 1,102 ticks, hash `1672229585`.
- Daveey's existing private Focusfire WASM completed a mixed 240-tick smoke test unchanged, hash `3568720956`. That private artifact is not distributed here.
- Container and static replay viewer built successfully.
- Ruff checks pass. Vet was attempted after changes but could not run its review because Anthropic credentials were unavailable.

These checks establish the new Polyworld game's determinism and policy compatibility. They do not establish action-level equivalence with the old Paintbot simulation or identical behavior between the BASIC translation and original Nim policy.

## Viewer upgrade (0.1.1)

- Repeated backward/forward checkpoint seeks reproduce every checked input hash.
- New v2 mixed BASIC/WASM match reproduced 3,984 ticks, 3–0, hash `1977552757`.
- Sixteen BASIC public shouts and hosted player names round-trip through v2; v1 still loads.
- Browser checks: old mixed replay, exact tick stepping, restart/end, final score, spoiler protection, capture filtering, bot selection, visibility, first-person inset, and desktop/mobile layouts.
- Art uses Gods of the Arena's Polyworld terrain, characters, toon lighting, and sun-shadow components, with pinned assets and generated masonry geometry.
- `VIEWER.md` maps CTF spectator features to this implementation and identifies game mechanics absent from PW.

## Solid cogs and deliberate firing (0.1.3)

Living cogs block both teammates and opponents using their combined collision radii. Axis sliding still permits movement along obstacles, and occupied spawn points search nearby free space. Firing now has a 24-tick cooldown (one shot per second), with a two-tick muzzle flash. Replay format v3 selects these rules; v1/v2 recordings retain their original movement and eight-tick cooldown.

Validation: all ten rule tests and three replay-analysis tests passed, including opposing/allied head-on collisions, occupied respawns, and sustained shot cadence. The full 7,200-tick BASIC/WASM match replay verified with hash `3624204313`. Original v1 (3,984 ticks, hash `1977552757`) and hosted v2 (1,300 ticks, hash `1314699705`) replays reproduced exactly. Optional vet review was unavailable because its API credentials were not configured.

## Forward vision (0.1.4)

BASIC and WASM observations now use a 120-degree forward cone around aim, with the existing distance and cover checks. Other cogs, including allies, are hidden outside the cone. BASIC `lookAt(x, y)` turns without firing; walking turns toward the destination unless explicit aim is supplied. WASM aim buttons update facing without requiring the trigger. POV terrain fog uses the same visibility predicate. Spectator all-seeing mode remains available.

All twelve rule tests, three replay-analysis tests, and five Python runtime tests passed. A full mixed BASIC/WASM episode finished at 6,758 ticks (3–0), and replay verification reproduced hash `2173305639`. Previously published v2 and v3 replays retain their original hashes. Replay format v4 selects the new facing rules.

## Unlimited forward sight (0.1.5)

The 120-degree cone now extends across the entire arena without a distance cap. Walls still occlude sight. BASIC, WASM, and POV fog share this behavior. Thirteen rule tests, three replay-analysis tests, and five runtime tests passed; the v4 mixed-policy replay still reproduces hash `2173305639`. Replay format v5 retains unlimited visibility for new recordings while earlier recordings preserve their original fog rules.

## Equipment and Paint Crew (0.1.6)

The original CTF rules in `coworld-ctf/docs/RULES.md` supplied grenade charge/flight/damage, five-tick directional spray, trench movement and damage interactions, shields, med kits, lives and capture/wipe conditions. The user's one-shot-per-second cadence and unlimited forward cone remain intentional overrides. Equipment uses the existing WASM sprite labels and C-button protocol; BASIC exposes inventory, pickup queries, aiming, and charge/release. The approved B Paint Crew design replaces the humanoid models with generated wheeled cog GLBs and a generated portrait.

Nine equipment tests cover grenade flight, friendly/trench blast damage, spray locking and once-per-burst damage, cover, trench escape, finite lives and heart return, capture, shields/med kits, and simultaneous gun releases. Thirteen legacy/current movement/vision tests, three replay-analysis tests and Python boundary tests pass. A full mixed BASIC/WASM match ends by wipe after 1,152 ticks with replay hash `3815528982`. Old v1 and v4 replays retain their original hashes. Local browser inspection found and fixed missing equipment event labels and stale capture text.

## Gnomewick Village (0.1.7)

Heartleaf's Golden Valley cottage prefabs and Enchanted Meadow props replace the repeated bunkers: six cottages, mirrored garden walls, carts, supply stacks, and a central well. Visible model bounds are fitted to each solid rectangle. Roads connect a market square and side streets; low flowers are walkable and tall scenic mushrooms stay beyond the arena boundary. The authored models and atlases use the existing pinned Polyworld data revision.

Rules v7 records the new map while v6 retains its original cover and replay hashes. Two layout tests check symmetry, overlap, free spawns/equipment, clear trenches, and flood-fill access to both hearts and every pickup across four seeds. A full mixed BASIC/WASM match ran 7,200 ticks and reproduced hash `35166491`; the old v6 match still reproduces `3815528982`. Equipment, movement/vision, replay analysis, and runtime boundary tests pass. Local browser verification displays HASH VERIFIED and the village scene. Optional vet review was unavailable because its API credentials were not configured.

## Rules 22: expanded island and navigation (2026-09-11)

- Exact map area: 160m × 96m = 2 × the preceding 120m × 64m.
- All ten heart destinations reached from spawn on seed 930220186.
- Body-clearance regression rejects a visible route that clips an obstacle.
- Equipment, respawn and bombardment suites: 16 tests passed.
- Runtime boundary suite: 5 tests passed.
- 1,110 sampled terrain heights match exactly between native and WASM observations.
- Full mixed BASIC/Daveey/WASM episode, seed 2026: 2,561 ticks, all ten hearts captured,
  every replay hash reproduced; longest stationary interval 44 ticks (1.83 seconds).
  Reported hosted failure had stationary intervals of 6,541 and 6,743 ticks.
- Full BASIC episode, seed 930220186: 1,704 ticks; maximum stationary interval 3 ticks.
- Rules 21 hosted replay c3e5bdcc-801d-4fe2-9e69-e22d044c8ef1 still verifies unchanged.
- Enlarged mixed replay loaded in browser, hash verified; play control exercised.
- Vet could not run because its required Anthropic credential is not configured.

## Rules 24–25: deliberate captures, heart spawns, and big hearts

- Three-second captures pause during contests and reset when abandoned; scoring
  transfers only when capture completes. Thirteen capture regressions pass.
- Ten big-heart regressions cover 30-second timing, one-at-a-time selection,
  no repeats, five-point income, pool exhaustion, ownership, elimination credit,
  BASIC observations, and replay seeking.
- Five heart-spawn regressions and six Python policy-boundary tests pass.
- Pre-change rules-24 replay: 1,440 ticks, unchanged hash 2492433301.
- Rules-25 BASIC match: 1,797 ticks, native/browser hash 2751937968; big hearts
  change at ticks 720 and 1440. Browser visuals show enlarged hearts and gold rings.
- Package score ceiling includes every possible bonus at the maximum duration.
- Vet was unavailable because its Anthropic credentials were not configured.

## Rules 26: trench visibility and directional hearing

- All Paintbot Nim suites pass, including eight new sound regressions. Seven
  Python runtime boundary tests pass; browser input checks pass.
- Sound tests cover coarse octants, walls/range, listener privacy, bounded and
  expiring cues, quiet movement, loud weapons, and independent replay snapshots.
- Rules-25 hosted replay still verifies at 240 ticks, hash 837788888.
- Rules-26 browser replay verifies at 1,797 ticks, hash 571947544; trenches are
  visibly outlined dugouts and selected-cog sound text shows coarse bearings.
- Private BASIC compatibility matches on both sides reproduce hashes 3901678753
  and 3350044769 at 1,484 and 2,201 ticks. No competitive-strength claim is made.
- Vet was attempted after code changes but unavailable without its API credentials.

## WASM territory objective repair (2026-09-13)

R.301 E.2 (replay `683ac72e-9ce9-45e0-85d6-2ab1171ddbfb`, rules 28,
seed 890754794) exposed a baseline compatibility bug. The inherited two-team
CTF formula computes a red pedestal at map pixel (480,960), which translates
to world (-2400,2000). All four blue baseline cogs circled that obsolete goal.
The 0.3.17 packaged WASM digest was
`3b06b727440918ffdd883189035a250de3db0eb5ac64c4deef1487093e40ee5e`.
The league separately pinned the older `paintbot-pw-wasm:v1`, file digest
`135538c4a166f3f0ac370204c6c0b90ddd7ed825490e1cc161fa161a8640c2e9`.
That exact file was fetched from its original published package and also fails
both regression cases; replacing the package alone cannot update the pinned filler.

The WASM now reads public control-heart positions and ownership, navigates to
an uncaptured heart, holds inside the capture radius, and retargets when the
owner changes. Frames without territory markers retain the inherited CTF path.
The in-repository adapter and build provenance accompany the rebuilt binary.

- The shipped-WASM regression exercises both teams on the expanded map,
  departure from the obsolete goal, 90 stationary capture frames, and arrival
  at the next uncaptured heart. The old published binary fails both cases.
- All eight Python runtime boundary tests pass.
- All 2,988 original replay hashes reproduce unchanged.
- A counterfactual starting at verified tick 1700 replaces only the four blue
  baseline command streams. All four leave the old cluster within 100 ticks;
  the first new capture occurs before tick 1900, and the baseline records four
  new captures by the end. Other seats retain recorded actions. This validates
  the repair mechanism, not competitive strength against reactive opponents.

Rebuild with WASI SDK 33 and the upstream revision in
`players/baseline.build.json`:
`WASI_SDK_PATH=/path/to/wasi-sdk python coworld/paintbot/tools/build_equipment_baseline.py /path/to/cogame-paintbot-cdx`.
Run the actuator regressions with
`python coworld/paintbot/test_baseline.py` (Wasmtime 48.0.0).
