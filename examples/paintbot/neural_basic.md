# Neural BASIC packages (v1)

A neural policy is a ZIP file with exactly three root entries: `manifest.json`,
`policy.bas`, and `model.bin`. It uses the ordinary opaque file policy upload.
The manifest has schema `paintbot-neural-basic/1` or `paintbot-neural-basic/2`, a
`sha256` object mapping `policy.bas` and `model.bin` to lowercase SHA-256 digests, and
`observation_contract`/`action_contract` containing the contract SHA-256 hashes
exported in `neural_contract.nim`. The observation contract may be v1 (`ed5d1676…`, 448
inputs) or v2 (`e0d7b0b9…`, 506 inputs: v1's 448 unchanged followed by a 58-float terrain
block, water and height for the seat, the hearts and the visible identities; see
`neural_actor.md`); the actor's embedded hash must equal the manifest's, selects the
encoder the seat runs and fixes the actor's input count. The action contract may be v1
(`55922d42…`, identity aim = body position) or v2 (`51f602ef…`, lead-compensated
identity aim; see `neural_actor.md`); the actor's embedded hash must equal the manifest's
and selects the decoder the seat runs, so existing v1 bundles keep byte-identical
behaviour. Schema 2 is for bundles that may name contract v2: a host that only knows
schema 1 rejects them at staging instead of at model load. Actor metadata must match
both contracts, the observation contract's input count (448 for v1, 506 for v2), 82
outputs, and categorical head sizes `[51,25,2,2,2]`. Any combination of observation and
action contract versions is allowed, under either schema.
The actor's binary format is documented in `neural_actor.md`.

A schema-2 manifest may carry a `decoder` object of per-bundle decoder options. Every
key must be one the host knows and every value the declared type; anything else is
rejected at staging and again at model load, so a bundle asking for an option a release
lacks never plays without it. Options change nothing in the action contract: the head
candidates and the contract hashes are the same with or without them.

- `"decoder": {"fire_hold_teammates": true}` (default false = byte-identical to before):
  after the network's heads are decoded, the shoot order is dropped when a teammate the
  seat can see (fog-gated, apparent team, the gun's line-of-sight test) stands within the
  gun's hit tolerance (`Radius` = 55 units) of the segment from the seat to the aim the
  order leaves and no farther along it than the aim point (`neural_contract.holdFire`).
  The aim, movement and every other head stand: the network keeps choosing fire and the
  decoder gates it. The same rule is the native training ABI's `pw_set_seat_fire_hold`,
  so a policy trained under it is deployed under it. With the option on, the seat's
  telemetry line ends in ` fire_holds=<n>`, the orders held in the match.
- `"decoder": {"sampling": {"mode": "categorical", "temperature": 1.0, "heads": [0, 1, 2, 3, 4]}}`
  (default absent = argmax, byte-identical to before): the listed heads are drawn from
  `softmax(logits / temperature)` instead of taken by argmax, the others keep argmax.
  `mode` is required and only `"categorical"` exists; `temperature` is optional (1.0)
  within [0.01, 10]; `heads` is optional (every head) and lists distinct head indices.
  The draws come from a stream the seat owns (`neural_contract.sampleActions`: SplitMix64
  from `polyworld/rngs`, the engine's replay-portable generator), seeded from the match
  seed and the seat's slot the first time the seat sees the world, one draw per sampled
  head per decision, in head order. The world's own random stream is never touched, so
  the world hash and every other seat are unaffected by the option, and the same match
  seed replays the same draws on the same engine build. Replays themselves record the
  commands the seat gave and never re-run the network. The same generator and seeding
  are the native training ABI's `pw_set_seat_sampling` / `pw_sample_actions`, so a probe
  that feeds it the hosted actor's logits takes the hosted seat's draws. With the option
  on, the seat's telemetry line ends in
  ` sampling=categorical t=<temperature> heads=<indices> seed=0x<stream seed> draws=<n>`.
  Caveat: the actor's float32 logits are argmax-stable across CPU architectures but not
  bit-stable, so a sampled match reproduces exactly on one engine build and architecture
  (the hosted platform's), not necessarily between an arm64 laptop and an x86 host.
- `"decoder": {"forbid_objectives": [9, 10]}` (default absent = byte-identical to before):
  the listed movement-head candidate indices (distinct, 0..50, at least one left allowed)
  are never selected, argmax or sampled, as if their logits were -inf
  (`neural_contract.argmaxActions` / `sampleActions` with an `ObjectiveMask`); the rest of
  a sampled movement head is renormalised and every other head is untouched. The actor's
  logits are still checked for finiteness as before. 9 and 10 are the two river hearts,
  the pw-diag river veto. The native training ABI's `pw_set_seat_forbid_objectives` is the
  same mask (its `pw_seat_forbidden_objectives` hands a trainer the logit mask, and
  `pw_step` refuses a forbidden index from the caller). With the option on, the telemetry
  line gains ` forbid_objectives=<indices> forbid_hits=<n>`, the decisions whose unmasked
  argmax objective was forbidden.
- `"decoder": {"strafe_legs": {"range": 5250, "legs": [3, 6], "shot_legs": [6, 9], "reverse_permille": 800}}`
  (default absent = byte-identical; every field optional, the defaults shown are base.bas's
  and the pw-diag measurement's): base.bas's footwork in contact (`neural_contract.strafeActions`).
  While the seat sees an apparent enemy within `range` and is not in a trench, its movement
  head is replaced by a compass step (indices 43..50): a leg perpendicular to the nearest
  such enemy, turned 3/4 lateral plus the direction to the heart or pickup the movement
  head chose, held `legs` ticks (inclusive range), reversing across the line with
  probability `reverse_permille`/1000 at each new leg. A shoot order the gun can take this
  tick is only issued with at least `shot_legs[0]` ticks of the current leg left; when fewer
  remain a new leg of `shot_legs` ticks starts on that tick, so the seat's own movement
  over the windup is the planned step contract v2's lead subtracts. No order is dropped;
  aim, fire, grenade and sneak stand. Out of contact the leg ends. Integer geometry; the
  draws (two per new leg) come from the seat's own SplitMix64 stream seeded from the match
  seed and the slot with its own salt (`strafeRng`), so the option never shifts the
  sampling draws and never touches the world's stream: the same match seed replays the
  same legs. Order of the options in a decision: forbid and sampling select the heads,
  the strafe rewrites the movement head, the heads are decoded, the fire hold gates the
  shot. The native training ABI's `pw_set_seat_strafe` is the same rule on the same
  stream (`pw_seat_strafe_stats` reports legs, replaced decisions and the executed
  movement index). With the option on, the telemetry line gains
  ` strafe=r<range>,legs<a>-<b>,shot<c>-<d>,rev<p> strafe_legs=<n> strafe_ticks=<n>`.
- `"decoder": {"aim_snap": {"max_angle_deg": 22.5}}` (default absent = byte-identical;
  `max_angle_deg` optional, 22.5, a multiple of 0.001 within 0.001..90): pw-diag2's lever 1
  (`neural_contract.aimSnapActions`). When a decision issues a shoot order with a compass
  aim (aim index 17..24) and an enemy the seat can see (its apparent identities: fog-gated,
  apparent team, exactly what the observation shows) stands within `max_angle_deg` of that
  compass heading (mirrored for team 1 as the aim candidate is), the aim head becomes that
  enemy's identity index (1..16), so the order aims at the identity candidate (under
  contract v2 the lead-compensated point). The nearest in angle wins, then the nearer body,
  then the lower identity index. Only shoot orders: an aim without a shot also turns the
  seat's vision cone, which the option leaves to the policy. Integer geometry against the
  threshold `round(cos(angle) * 32768)`; stateless, no draws. The native training ABI's
  `pw_set_seat_aim_snap` (angle in millidegrees) is the same rule (`pw_seat_aim_snap_stats`
  reports snaps and the executed aim index). With the option on, the telemetry line gains
  ` aim_snap=<deg>deg,cos_q15=<threshold> aim_snaps=<n>`.
- `"decoder": {"steady_shot": {}}` (default absent = byte-identical; no parameters): the
  other half of pw-diag2's lever 1 (`neural_contract.steadyShotActions`). The seat stands
  still (movement index 0: the goal is its own position, so it makes no step and contract
  v2's planned own step is zero) on every decision from a shoot order the gun takes until
  the ray leaves, stated in the gun's own windup state: the order tick (the shoot head is 1
  and, on the pre-step world, the seat is alive, carries the gun rather than a spray can,
  its windup is 0 and its cooldown at most 1, which the step decrements before it tests)
  and every tick whose pre-step windup is above 0 (5..1, whatever the shoot head says; the
  ray leaves after the move of the tick whose windup is 1). Six decisions per shot and zero
  own drift over the windup, which is what base.bas does. Stateless, no draws; every other
  head stands. The fire hold is decided after the decode, so an order it drops has still
  stood its order tick. Movement index 0 is the steady stance, so a bundle that also
  forbids index 0 is rejected. The native training ABI's `pw_set_seat_steady_shot` is the
  same rule (`pw_seat_steady_stats` reports order ticks and decisions held and the executed
  movement index). With the option on, the telemetry line gains
  ` steady_shot=on steady_shots=<n> steady_ticks=<n>`.
- Order of every option within one decision: forbid and sampling (or argmax) select the
  heads; the aim snap rewrites the aim head; the strafe, then the steady shot, rewrite the
  movement head (a steadied decision overrides the strafe's leg for that tick); the heads
  are decoded under the contract; the fire hold gates the decoded shot.

The archive is bounded to 16 MiB model, 64 KiB BASIC, and 8 KiB manifest.
Duplicates, unexpected paths/files, encryption, incorrect hashes, and oversized
expanded entries are rejected. Files are never extracted by archive path.
The host stages the BASIC file with `.model.bin` and `.neural.json` sidecars.
For local native runs, pass the BASIC filename and place those sidecars beside
it. The model always validates its own dimensions, finite weights, and contracts;
the staged manifest additionally binds contract metadata. Plain BASIC needs no
sidecars and remains supported.

```basic
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
paintbot_act(neuralLogits())
```

Each seat owns observation, logit, and recurrent-state float buffers. The four
handle functions return typed capabilities scoped to that seat; integers cannot
refer to another seat's buffers. BASIC never performs FP32 arithmetic itself.
A tick permits one observation, one inference, and one action decode, in order.
Invalid handles, missing models, repeated inference, and nonfinite inference
results disable the seat through the existing policy-failure mechanism and
produce a safe empty command. All seats observe the pre-action world.

Native inference has a separate deterministic operation count and a maximum of
4,000,000 operations per seat/tick. This cannot be bypassed by repeated host
calls. Bytecode and ordinary host work retain their existing limits. `PW_BASIC_PEAKS=1`
reports `peak_neural_operations` separately from bytecode work. On the hosted platform
each seat that loaded a neural package also gets one line in its private seat log at
match end, `neural: peak_ops=238080 budget=4000000 model=w128 ticks=1200` (peak native
operations in any tick, the budget, the hidden width, ticks played); a package rejected
for exceeding the budget gets the same line with the rejected model's cost and `ticks=0`
before its `BASIC error`. Plain BASIC seats log nothing. Recurrent
state resets at initial use, match reset, death, and respawn. Training must use
the same reset convention. Output selection is deterministic headwise argmax unless
the bundle asks for `decoder.sampling` (above); training samples categorical heads and
evaluates the deployed artifact under the selection rule it will be deployed with.

The versioned neural observation includes public self cooldown and heart-meter
state as well as the documented feature layout. These are deliberate additions
to the older BASIC scalar getters; they are not privileged enemy information.
Neural entity features preserve apparent identity and fog-of-war restrictions.

Validation:

```
python3 -m unittest coworld/paintbot/test_neural_package.py
nim c -r -d:headless tests/test_paintbot_neural_host.nim
nim c -r -d:headless tests/test_paintbot_neural_contract.nim
nim c -r -d:headless tests/test_paintbot_neural_obs_v2.nim
nim c -r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_obs_v2.nim
nim c -r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_fire_hold.nim
```

A successful local loader test is not hosted certification. Release must still
verify platform bundle acceptance, a mixed plain/neural full match, and the
normal hosted hash-verified replay before claiming deployment.
