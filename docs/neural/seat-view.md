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

## Implementation (2026-09-30)

- Observation contracts `paintbot-pw.teams.view.1` (512 floats; `teams.view.1u<K>` appends K
  user inputs) and `paintbot-pw.ffa.view.1` (width per match; `ffa.view.1u<K>` appends K user
  inputs). User inputs are written only by the seat's policy.bas (`neuralInput`), so they add no
  information the boundary does not already give BASIC. `encodeTeamsView` /
  `encodeFfaView` take a `SeatView`; `tests/test_paintbot_seat_view_parity.nim` re-derives
  every column from the view procs.
- Action contracts `paintbot-pw.teams.view.1.action.51-25-2-2-2`, its aim-offset variant
  `...51-25-2-2-2-23-23` (heads 5 and 6, `neuralChoice(5/6)`: the reference decode adds
  `((ix - 11) * 28, (iz - 11) * 28)`, mirrored for team 1, to an identity aim; the offset is
  the network's choice, nothing native computes a lead), its movement-offset variant
  `...51-25-2-2-2-23-23-23-23` (also heads 7 and 8, `neuralChoice(7/8)`: the reference decode adds
  `(moveOffset(dx), moveOffset(dz))`, symmetric log-spaced bins from 16 u to 4000 u
  (`MoveOffsetTable`), mirrored for team 1, to the movement goal and clamps it to
  the map; the destination is the network's choice, nothing native computes a goal) and
  `paintbot-pw.ffa.view.1.action.pointer`.
- Heads become orders only in BASIC: `players/neural_decode.bas` and `neural_decode_ffa.bas`
  are the reference decode, run by `players/neural_policy.bas` and by the training library for
  every caller-driven seat (`pw_step`). `pw_set_action_contract` chooses only between
  teams.view.1 (11) and its aim-offset (13), movement-offset (14), target-conditioned aim-offset (15) and raw (16)
  variants on a teams handle. Contract 15 keeps contract 13's choices and decode (the policy.bas is the same); its
  heads 5 and 6 are drawn from the 23-logit row of the identity the aim head chose, so the network's offset can
  depend on that target. Nothing native computes a lead. Contract 16 (raw) refines those rows to 63 bins of 7 u and
  adds walk direction (256) x walk distance (8) and look direction (128) heads, which the reference decoder reads in
  place of the compass step and the compass aim: fixed grid points relative to the seat, nothing computed for the
  network.
- Observation contract teams.view.1h (203, `paintbot-pw.teams.view.1h`, and its `...1hu<K>` user-input variants) is
  teams.view.1 plus a 100-float motion-history block the engine keeps per seat (`encodeTeamsViewH`): per identity
  its t-1 and t-2 positions relative to its current one in 28 u steps, with seen flags, and the seat's own t-1 / t-2
  displacement. Positions come from `playerX` / `playerY` / `selfX` / `selfY` at those ticks, so a BASIC seat could
  keep the same record; it is engine-computed so that seats whose script does not write it (a caller-driven training
  seat, a teacher shadow) still see it.
- Observation contract teams.view.1s (204, `paintbot-pw.teams.view.1s`, and its `...1su<K>` user-input variants) is
  teams.view.1h plus a 128-float stop-clock block the engine keeps per seat (`encodeTeamsViewS`): per identity, how
  long ago the seat last watched it go from moving to still, how long that stop has lasted and whether it has moved
  since, the same age for the last earlier stop that held, the sight gap before the current run of sight (or the
  ticks since it was last visible) and the length of that run. It is built only from `visible` / `playerX` /
  `playerY` on the ticks the seat's observation is encoded (a stop takes three consecutive visible ticks; nothing is
  inferred across a sight gap), so a BASIC seat could keep the same clocks with `dim` arrays; no gun, cooldown or
  order state of another cog is read.
- Observation contract teams.view.1t (205, `paintbot-pw.teams.view.1t`, and its `...1tu<K>` user-input variants) is
  teams.view.1s plus an 11-float hunt-clock block the engine keeps per seat (`encodeTeamsViewT`): at 740, how long
  since the seat last saw a living enemy-parity identity (capped at 720 ticks); at 741 + r, how long since the seat
  itself was within 600 u of map heart r xor selfTeam (the team frame; capped at 2760 ticks; 0 past the map's heart
  count, hearts 0..9 only). The clocks start at the match start, count only the ticks the seat is encoded alive on and
  keep running across a death (the block reads zeros while dead). It is built only from `visible` / `playerHp` /
  `selfX` / `selfY` / `controlX` / `controlY` / `heartCount`: the same clocks a BASIC seat keeps in two variables
  per value (the pw-arch hunt inputs 36..42 of policy.bas are 3 x these columns, one tick later).
- The retired contracts and decoder options are refused by name at staging
  (`neural_package.py`) and at load (`neural_host.nim`, `neural_contract.retiredContract`).
- Training-only supervision: `pw_seat_privileged_labels` (21 floats: the retired world fields,
  a lead point and nine traversable probes) lives in `training_labels.nim`, compiled only with
  `-d:pwTraining` and imported only by `native_env.nim`; the boundary test enforces both. It is
  a label source for auxiliary losses, never an observation.
- The boundary test also checks that `neural_contract.nim`, `neural_actor.nim` and
  `neural_host.nim` import neither `sim` nor anything naming `World`, and that `host()` in
  `bots.nim` reads only its `SeatView`.
