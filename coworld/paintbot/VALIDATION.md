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
