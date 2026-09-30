# SeatView: one perception boundary for BASIC and neural seats

Status: decided 2026-09-30. Motivation: a neural package (a `policy.bas` plus a model) could read
engine state and use native tactics that a plain BASIC seat cannot. Every item in the
"Neural Interface has features BASIC does not" report was confirmed: exact gun cooldown/windup,
spray cooldown, shield/respawn, current aim, heart-meter totals, cover/traversability probes,
lead prediction, self-motion compensation, target selection, aim snap, shot/spray gates,
friendly-fire hold (which saw both bodies sharing an identity), spray aim, strafing and
steady shot.

## Rule

A seat, BASIC or neural, perceives the world only through `SeatView`, and acts only through the
BASIC action verbs (`walkTo`, `lookAt`, `shootAt`, `chargeGrenade`, `sneak`, `shout`).

## Decisions

1. **Direction:** neural loses what BASIC cannot see. BASIC's perception surface is unchanged,
   except for the new `rnd` builtin (item 5).
2. **`SeatView`** (`examples/paintbot/seat_view.nim`) is an opaque object for one seat and one
   tick. Its `World` field is not exported. Its exported procs are exactly the BASIC
   perception surface: the `DataNames` values, `visible`/`playerTeam`/`playerX/Y/Hp/Carrying`
   (nearest body per identity), `nearAgents*`, `hasUniform`, sounds, heard speech, pickups,
   hearts/control fields, glory and scoreboard, glory hearts, FFA functions under their fog
   rules, map bounds, `terrainHeight`, trenches, `trenchAt`, `waterAt`. The one-body-per-identity
   rule and the vision cache live here, and only here.
3. **BASIC host functions** (`bots.nim` `host()`) read only a `SeatView`. `decide` builds one view
   per seat per tick, and that is the only place perception touches `World`.
4. **Neural observation encoders** take a `SeatView`, not a `World`. Every feature must be
   computable from `SeatView` procs. The old contracts (v1, v2, v3, ffa.v1, ffa.v2) are removed,
   and staging rejects them with a clear error. They are replaced by new contract names built
   only from view data. Removed columns: gun cooldown, windup, spray cooldown, shield, respawn,
   current aim, heart meter (`scoreTicks`), `endTick`-based progress and ticks remaining, and the
   blocked/traversable terrain probes (replaced by `terrainHeight` + `waterAt` samples).
5. **The model's output reaches the engine only through BASIC.** Neural functions return
   numbers (head choices, logits, observation values). There is no native path that writes a
   `Command`. Deleted: `aim_retarget`, `aim_snap`, `spray_aim`, `shot_gate`, `spray_gate`,
   `strafe_legs`, `steady_shot`, `fire_hold_teammates`, `leadAimPoint`/`AimMemory`,
   `plannedStep`, and native goal/aim decoding (`goalCandidate`, `aimCandidate`,
   `decodeActions`). Manifest decoder options naming any of them are rejected.
6. **Kept:** model-internal computation over the observation, including every layer type
   (COND_HEAD, TOKEN_PAIR, SEGMENT_NEAR, ...), argmax, sampling, temperature, masks and joint
   sampling. BASIC gains `rnd(n)`, a per-seat stream seeded from the match seed and slot, so
   plain BASIC can sample too.
7. **Enforcement:** `seat_view.nim` is the only perception module that may use `World`.
   `neural_contract.nim`, `neural_actor.nim`, `neural_host.nim` and `host()` must not import
   `sim` for World access. A CI test (`tests/test_paintbot_seat_view_boundary.nim`) fails if they
   do. A parity test asserts that every observation column equals a value derived from `SeatView`
   on the same tick. A regression test covers the fire-hold two-bodies-one-identity case: the
   helper no longer exists, and no view proc reports the farther body.
