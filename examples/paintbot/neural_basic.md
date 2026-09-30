# Neural BASIC packages

A neural seat perceives and acts exactly like a plain BASIC seat (docs/neural/seat-view.md).
Its observation is built only from its `SeatView` (`seat_view.nim`), the values its BASIC
builtins read on the same tick, and the network's output reaches the game only through its
`policy.bas`: the neural builtins return numbers, and the script turns them into `walkTo`,
`lookAt`, `shootAt`, `chargeGrenade`, `sneak` and `shout` like any other script.

## The package

A neural policy is a ZIP file with exactly three root entries: `manifest.json`, `policy.bas`
and `model.bin`. It uses the ordinary opaque file policy upload. The manifest has schema
`paintbot-neural-basic/1` or `paintbot-neural-basic/2`, a `sha256` object mapping `policy.bas`
and `model.bin` to lowercase SHA-256 digests, and `observation_contract` / `action_contract`
holding contract hashes (the SHA-256 of the contract id; `neural_contract.nim` exports them).
Schema 2 may also carry `decoder` and `user_inputs` (below).

| observation contract | id | inputs |
|---|---|---|
| teams.view.1 | `paintbot-pw.teams.view.1` | 512 |
| teams.view.1u<K> | `paintbot-pw.teams.view.1u<K>`, K = 1..128 | 512 + K |
| ffa.view.1 | `paintbot-pw.ffa.view.1` | per match (`ffaViewLayout`) |

| action contract | id | heads |
|---|---|---|
| teams.view.1 | `paintbot-pw.teams.view.1.action.51-25-2-2-2` | 51, 25, 2, 2, 2 |
| teams.view.1 aim-offset | `paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23` | 51, 25, 2, 2, 2, 23, 23 |
| ffa.view.1 pointer | `paintbot-pw.ffa.view.1.action.pointer` | 11 + H, 9 + C, 2, 2, 2 |

teams.view.1 (and u<K>) pairs with the teams.view.1 action contract or its aim-offset variant
and plays the teams game; ffa.view.1 pairs with ffa.view.1 pointer and plays FFA-kin (Heartland)
at any seat count. The actor's embedded hashes must equal the manifest's, its input count the
contract's width, and its heads the action contract's. Every column of both observation
contracts is documented in `neural_contract.encodeTeamsView` / `encodeFfaView` and in
`neural_actor.md`; `tests/test_paintbot_seat_view_parity.nim` re-derives each one from the
SeatView procs.

Retired for BASIC parity and refused at staging and at load, with a message naming
docs/neural/seat-view.md: observation contracts v1 (`paintbot-pw.rules37.obs.v1.float448`), v2
(`...rules37.obs.v2.float506`), v3 (`...rules43.obs.v3.float514`), v2u<K>, v3u<K>, ffa.v1
(`...rules40.obs.ffa.v1.float810`) and ffa.v2 (`...rules48.obs.ffa.v2`); action contracts v1, v2
(`...rules37.action.v1/v2.51-25-2-2-2`) and ffa.v2 pointer. Their observations carried state no
BASIC builtin reads (gun cooldown and windup, spray cooldown, shield, respawn, the current aim,
heart meters, the end tick, blocked/traversable probes), and their actions were decoded natively
(identity lead, planned own step).

The actor's binary format, PWNET001 (one fixed MinGRU) or PWNET002 (a layer stack: dense, RMS
norm, stacked MinGRU, residual, entity attention, input concat, TOKEN_MLP / TOKEN_MIX with their
LayerNorm, SEGMENT_NEAR, COND_HEAD, TOKEN_PAIR, ...), is documented in `neural_actor.md`; staging
validates a PWNET002 model's structure and operation count (`neural_package.py`), and the host
validates both formats at load.

The archive is bounded to 16 MiB model, 128 KiB BASIC and 8 KiB manifest. Duplicates,
unexpected paths or files, encryption, incorrect hashes and oversized expanded entries are
rejected; files are never extracted by archive path. The host stages the BASIC file with
`.model.bin` and `.neural.json` sidecars; for local native runs pass the BASIC filename and put
the sidecars beside it. Plain BASIC needs no sidecars.

## policy.bas

```basic
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
neuralSample()
' then turn neuralChoice(0) .. neuralChoice(4) into walkTo / lookAt / shootAt / ...
```

`players/neural_decode.bas` is the reference reading of the teams.view.1 heads (and of the
aim-offset heads), `players/neural_decode_ffa.bas` that of ffa.view.1 pointer, and
`players/neural_policy.bas` is a complete policy: the three lines above followed by
`neural_decode.bas` verbatim. The training library decodes a caller's heads with the same files,
so a policy built on them trains and plays the same way. Everything the retired native decoder
options did (fire hold, strafe legs, aim snap, steady shot, aim retarget, shot gate, spray aim,
spray gate, the identity lead) is a policy's own business now, written in BASIC from its
builtins.

The four handle functions return typed capabilities scoped to the seat; integers cannot refer
to another seat's buffers, and BASIC never performs FP32 arithmetic itself. Per tick, in order:
`paintbot_observe` once, `run_neural_net` once, then the head-level phase. Recurrent state
resets at match start, death and respawn; training must use the same convention. All seats
observe the pre-action world. Misuse (wrong order, repeated inference, an out-of-range index, a
head with every choice masked, non-finite logits) disables the seat through the ordinary policy
failure path; a disabled seat issues nothing.

Builtins (`neural_host.addNeuralFunctions`); none of them acts:

- `neuralModel() neuralObservation() neuralLogits() neuralState()`: the handles.
- `paintbot_observe(obs)`, `run_neural_net(model, obs, logits, state)`.
- `neuralObs(i)`: round(observation[i] x 1000) of this tick's observation (any column,
  user inputs included). `neuralLogit(i)`: round(logit[i] x 1000), after `run_neural_net`.
- Before selection: `neuralMask(h, bits)` excludes choice i of head h for each set bit i
  (choices 0..31), `neuralMaskFrom(h, first, bits)` the choices first..first+31 (head 0 has 51);
  later calls overwrite their window. `neuralTemperature(h, milli)` sets head h's temperature to
  milli/1000 for this tick (h = -1 every head; 0 = argmax; 1..100000). Masks add to
  `decoder.forbid_objectives` on head 0; both last one tick. `neuralMask(0, 1536)` is
  `forbid_objectives [9, 10]` and `neuralTemperature(-1, 1000)` is `sampling {"temperature":
  1.0}`, draw for draw.
- `neuralSample()`: the tick's selection, once: argmax or the seat's sampling stream, under the
  masks and temperatures, then `decoder.joint_sampling` or the model's COND_HEAD layers.
- `neuralChoice(h)` reads head h (5 and 6 are the aim-offset heads); `neuralSetChoice(h, i)`
  overrides it (the training ABI's `pw_seat_policy_choices` reports what the script acted on).
- `neuralInput(i, v)`: user input i (below).
- `neuralLayout(i)`: for i in 0..15 `pw_observation_layout`'s word i (row floats, header floats,
  cog offset, cog rows, cog width, heart offset, heart rows, heart width, great offset, great
  rows, great width, valid column, seats, control hearts; the section words need ffa.view.1),
  for i in 16..22 the size of action head i - 16 (0 for a head the contract lacks; 21 and 22 are
  23 under the aim-offset contract).
- `neuralRow(section, k)` (ffa.view.1): the entity row k shows this tick: section 0 the seat id
  of cog row k (`nearAgentId(k)` after `nearAgents(20000)`; -1 past the cogs the seat sees), 1 the
  control heart index, 2 the great heart index.

Plain BASIC has `rnd(n)` too: 0 .. n-1 from the seat's own SplitMix64 stream, seeded from the
match seed and the slot, so a script can sample without a network (`guide.md`).

## Decoder options (selection only)

A schema-2 manifest may carry a `decoder` object. Every option reshapes the selection from the
network's own distribution; none computes an order. Every key must be one the host knows and
every value the declared type, checked at staging and again at model load, so a bundle asking
for an option a release lacks never plays without it. The retired rule names
(`fire_hold_teammates`, `strafe_legs`, `aim_snap`, `steady_shot`, `aim_retarget`, `shot_gate`,
`spray_aim`, `spray_gate`) are refused by name.

- `"sampling": {"mode": "categorical", "temperature": 1.0, "heads": [0, 1, 2, 3, 4]}`
  (absent = argmax): the listed heads are drawn from `softmax(logits / temperature)`, the others
  keep argmax. `temperature` within [0.01, 10] (default 1.0); `heads` distinct head indices
  (default every head; 5 and 6 only under the aim-offset contract). The draws come from the
  seat's own stream (`neural_contract.samplingRng`: SplitMix64 seeded from the match seed and
  the slot), one draw per sampled head per decision in head order; the world's stream is never
  touched, so the world hash and every other seat are unaffected. The training ABI's
  `pw_set_seat_sampling` / `pw_sample_actions` use the same stream. Telemetry:
  ` sampling=categorical t=<temperature> heads=<indices> seed=0x<seed> draws=<n>`. Float32 logits
  are argmax-stable across CPU architectures but not bit-stable, so a sampled match reproduces
  exactly on one build and architecture.
- `"forbid_objectives": [9, 10]`: movement-head choices (distinct, 0..50, at least one left) never
  selected, argmax or sampled, as if their logits were -inf. The training ABI's
  `pw_set_seat_forbid_objectives` is the same mask. Telemetry
  ` forbid_objectives=<indices> forbid_hits=<n>`.
- `"joint_sampling": {"when": {"head": h, "value": v}, "head": g, "offsets": [...]}`: when head h
  was selected as v, head g is selected again from its logits plus `offsets` (one number per
  choice of g, each within -1000..1000) under its exclusions and temperature: argmax at
  temperature 0, else one more draw from the seat's stream. Telemetry
  ` joint_sampling=h<h>=<v>->h<g> held=<n>`. A learned version lives in the model (PWNET002's
  COND_HEAD layer, `neural_actor.md`); a bundle cannot use both.

Under ffa.view.1 pointer only `sampling` is accepted (`neuralMask` / `neuralMaskFrom` are
refused too: their bit masks cover the teams heads).

## User inputs (BASIC -> net)

A schema-2 manifest may carry `"user_inputs": {"count": K, "init": [K integers]}`, K within
1..128, each value within -1,000,000..1,000,000. The observation contract is then
`paintbot-pw.teams.view.1u<K>`: teams.view.1's 512 floats followed by K user floats. Manifest,
actor hash and input count must agree. `neuralInput(i, v)` sets input i to v clamped to
+-1,000,000; the net reads `float32(v) / 1000`. Values persist across ticks and deaths within a
match and start at `init` each match; a value set during tick t is in the observation of tick
t + 1 (the same in training).

## Budget and telemetry

Native inference has a deterministic operation count and a maximum of 4,000,000 operations per
seat/tick, scaled like BASIC's budget above 16 seats (`4,000,000 * seats / 16`). Bytecode and
ordinary host work keep their own limits. `PW_BASIC_PEAKS=1` reports `peak_neural_operations`
separately. On the hosted platform each seat that loaded a neural package gets one line in its
private seat log at match end, `neural: peak_ops=238080 budget=4000000 model=w128 ticks=1200`
(`pwnet2-l<layers>-s<state floats>` for PWNET002), followed by the telemetry of its options; a
package rejected for exceeding the budget logs its cost with `ticks=0` before its `BASIC error`.

## Training

Training runs the same policy.bas: the native ABI's `pw_set_seat_policy_script` drives a seat
with the bundle's policy.bas and manifest, the trainer passing each tick's logits to
`pw_step_logits` and reading the heads the script acted on from `pw_seat_policy_choices` (and
`pw_seat_policy_offset_choices` for heads 5 and 6). A caller-driven seat's heads (`pw_step`) are
decoded by the reference decoder script. `pw_set_seat_conditionals` gives a policy seat the
model's COND_HEAD layers. See `native_env.h`.

Validation:

```
python -m unittest discover -s coworld/paintbot -p test_neural_package.py
nim r -d:headless tests/test_paintbot_neural_host.nim
nim r -d:headless tests/test_paintbot_neural_basic_io.nim
nim r -d:headless tests/test_paintbot_neural_view_contracts.nim
nim r -d:headless tests/test_paintbot_seat_view_parity.nim
nim r tests/test_paintbot_seat_view_boundary.nim
nim r -d:headless tests/test_paintbot_neural_net2.nim
nim r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_net2.nim
nim r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_policy_script.nim
nim r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_aim_offset.nim
nim r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_neural_parity.nim
```

A successful local loader test is not hosted certification. Release must still verify platform
bundle acceptance, a mixed plain/neural full match, and the normal hosted hash-verified replay
before claiming deployment.
