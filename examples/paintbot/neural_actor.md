# PWNET001 actor format

This restricted actor matches PufferLib commit
`6ffa5b10dbbbe4d1e8288367c7d9d3acd3bad4a2`, default `Arch` in `src/algo.cu`.
Architecture: bias-free linear encoder, **one** MinGRU highway layer,
bias-free categorical decoder. Hidden width is 64, 128 or 256. No ReLU,
normalization layer, biases, quantization or value head is included.

Binary bytes: ASCII `PWNET001`; six little-endian uint32 values (version=1,
input count, hidden count, output count, head count, parameter count); 64 ASCII
lowercase hex bytes each for observation and action SHA256 contracts; head
sizes as little-endian uint32; little-endian FP32 row-major tensors:
encoder `[H,I]`, recurrent `[3H,H]`, decoder `[O,H]`. Exact file length is
required. Contracts bind the encoder's normalization rules; there is no separate
learned observation normalization in this architecture. Package manifest binds
SHA256 of the entire actor file.

For observation `o`, previous recurrent state `s`, let `x = E o` and split
`R x` into `c,z,p`, each width H. Then:

```
candidate = c >= 0 ? c + 0.5 : sigmoid(c)
s_next = s + sigmoid(z) * (candidate - s)
y = sigmoid(p) * s_next + (1 - sigmoid(p)) * x
logits = D y
```

State stores `s_next`, not highway output `y`. Reset zeros the entire state.
Matrices are immutable and safe to share (the current loader loads one copy per
seat); state and output buffers are seat-local.
Inference uses bounded stack scratch, does not allocate, and validates all
results before committing state or logits. No random sampling occurs here.

Puffer checkpoint source of truth is `puf_save_weights`: raw flat FP32 master
weights in encoder / decoder / recurrent registration order. Decoder has an
extra final value row that export removes. The selected hidden widths guarantee
all tensors are eight-float multiples, so FP32/BF16 allocator alignment is
identical. Training must use `build.sh --float` for the initial parity gate;
FP32 checkpoint storage does not by itself prove FP32 training execution.

PufferLib license notice (equations adapted from `mingru_gate` and CPU reference):

MIT License

Copyright (c) 2022 PufferAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

For numerical stability, sigmoid uses `z=exp(-abs(x))` and returns
`x>=0 ? 1/(1+z) : z/(1+z)`. Interpolation uses the GPU kernel's equivalent
branch `abs(gate)<0.5 ? old+gate*(candidate-old) : candidate-(candidate-old)*(1-gate)`.
This can differ by a few FP32 rounding units from upstream's scalar CPU actor.

# Native training ABI (`native_env.nim`, `-d:pwTraining`)

Version 1, declared in `native_env.h`: `pw_create/pw_reset/pw_destroy`,
`pw_observe` (all seats) and `pw_observe_seats` (chosen seats), `pw_step`,
`pw_results`, `pw_bot_actions`, `pw_state_hash`, and the telemetry call below. Every
entry is additive to v1; a host that ignores the newer ones sees the same bytes.

## Action contracts

Two action contracts share the five heads `[51,25,2,2,2]` and differ only in what an
identity aim (aim head index 1..16) resolves to. The actor file and the package
manifest carry the contract's SHA-256 (the hash of the id string), and the host decodes
each seat by the contract its actor names; a v1 bundle keeps byte-identical behaviour on
a host that also knows v2.

| version | id | SHA-256 | identity aim |
|---|---|---|---|
| v1 | `paintbot-pw.rules37.action.v1.51-25-2-2-2` | `55922d42d4065a069b3193f31e056c3a53cd34175b10fed7ff0d8c22b50a473e` | the body's current position |
| v2 | `paintbot-pw.rules37.action.v2.51-25-2-2-2` | `51f602ef167919ca825595f9d81777cb807afbb0938a20102457d0594e2b4317` | the body's lead-compensated aim point |

Decoder options are not contracts. A schema-2 bundle may ask for `decoder.fire_hold_teammates`
(`neural_basic.md`): the decoded shoot order is dropped when a visible teammate stands in
the gun's corridor to the aim point. The candidates every head resolves to and both
contract hashes are unchanged by it; the training ABI's `pw_set_seat_fire_hold` is the
same rule (`native_env.h`). It may also ask for `decoder.sampling` (`neural_basic.md`):
the listed heads are drawn from `softmax(logits / temperature)` on a seat-owned SplitMix64
stream seeded from the match seed and the slot (`neural_contract.sampleActions`,
`samplingRng`), the rest keep argmax; the candidates and hashes are again unchanged, and
the training ABI's `pw_set_seat_sampling` / `pw_sample_actions` draw from the same stream.

Movement (heart, visible pickup or `pos+200*compass`), directional aim
(`pos+5000*compass`), fire, grenade and sneak decode identically under both.

**v2 lead (`leadAimPoint` in `neural_contract.nim`).** The gun (`mechanics.nim`, rules
>= 10) processes a shoot order on tick T after that tick's movement: `gunAim = aim -
pos_T` is locked as a vector and the ray leaves `GunWindupTicks` = 5 ticks later from
`pos_(T+5)`, along the locked vector. Between the pre-step world the policy observed and
the ray, the shooter makes 6 moves, and the direction was fixed after the first. For a
shooter with per-tick velocity `v` and a target with per-tick velocity `u` observed at
`P`, the ray `pos_(T+5) + s*(aim - pos_T)` passes through `P + 6u` when

```
aim = P + (GunWindupTicks+1)*u - GunWindupTicks*v = P + 6u - 5v
```

which is base.bas's own rule ("the ray leaves six moves after the order ... aim where
they will be, minus our own drift": target velocity x 6, own drift x 5; base.bas uses
its planned leg as the drift while in contact and its last measured move otherwise).
`u` is the body's last-tick displacement as the seat itself could observe it, kept by
the host in an `AimMemory` outside the world (never hashed or serialized, recorded with
`recordAimMemory` after every decode): only when the same body was seen under the same
identity one tick ago; a first tick, a gap, a respawn or a teleport (a per-axis
displacement above `TeleportStep` = 60, more than any one-tick move) counts as zero.
`v` is not remembered but known: the move the world will make for the seat on this
tick from the goal and sneak flag decoded from the same action (`plannedStep`: the
same waypoint, speed and trench damping as `mechanics.nim`, before blocking and
yielding; zero when the seat holds still). With a still target and a still seat the v2
aim is the v1 aim. The memory follows the recurrent state in the hosted seat (cleared
at initial use, match reset, death and respawn) and is cleared by `pw_create`,
`pw_reset` and `pw_set_action_contract` in the native ABI.

Native ABI: `pw_set_action_contract(handle, 1|2)` selects the decoder for the caller's
actions (default 1, kept across resets), `pw_action_contract(handle)` reads it,
`pw_action_contract_hash(version, out, 65)` returns the hash; the Nim bot
(`pw_bot_actions`) expresses identity aims and is therefore lead-compensated under v2.
`pw_action_candidates(handle, seat, movement, sneak, int32[51*2], int32[25*2])` reports
the point each head index resolves to on the current pre-step world (INT32_MIN for a
candidate that does not exist; a v2 identity aim depends on the movement and sneak
indices given), for exact demonstration mapping. `pw_script_decide(handle)` runs the
scripted seats' decision ahead of `pw_step` and `pw_set_seat_override(handle, seat,
mask)` (bits 1 walk, 2 aim, 4 shoot, 8 grenade, 16 sneak) makes a scripted seat execute
the caller's decoded action for the masked heads: the mapping-ceiling diagnostics, exact
with mask 0. `pw_set_seat_sampling(handle, seat, temperature_permille, head_mask)` and
`pw_sample_actions(handle, seat, float[82], int32[5])` select a seat's head actions from
logits the way a sampling bundle would (the seat's stream is seeded from the match seed
and the seat on every create/reset; `pw_seat_sample_draws` counts); with sampling off
(the default) it is plain argmax, and `pw_step` is untouched either way.

`pw_seat_stats(handle, int32 out[16*8])` fills, per seat in seat order,
`{damage_dealt_enemy, damage_dealt_team, hits_enemy, hits_taken, kills, deaths,
captures, first_friendly_fire_tick}` (`pw_seat_stats_t` in the header), cumulative
since the last create/reset. Damage is health removed (armor absorbs first); a hit is a
damage event that passed the shield and life checks; kills and deaths are the
victim's health reaching zero, credited to an enemy attacker; captures are the world's
own credit for flipping a heart; `first_friendly_fire_tick` is -1 until the seat first
damages a teammate. The counters are pure telemetry held by the host handle, never
by the world: they are outside the state hash, no decision reads them, and a build
that never calls `pw_seat_stats` pays one pointer test per damage event.

BASIC seats: `pw_set_seat_script(handle, seat, source, length)` installs BASIC source
on one seat, compiled and run by the production interpreter with the hosted host
functions (`bots.nim`), limits and 20,000-instruction per-decision budget, with the
production tick order (every scripted seat decides on the pre-step world, hears what
was shouted last tick, then the world steps). The caller's actions for that seat are
ignored while the script is installed; the runtime is re-instantiated on every
`pw_reset` with cleared persistent variables, as a new hosted match loads its bots.
Compile or runtime errors disable the seat exactly as they disable a hosted seat;
`pw_seat_script_status(handle, seat, message, capacity)` reports 0 unscripted, 1
running, 2 compile failed, 3 disabled, with the error text. `pw_seat_orders(handle,
seat, int32[10])` reports the command a scripted seat issued on the last step
(`walk, goal_x, goal_z, shoot, aim_x, aim_z, charge_grenade, sneak, direct, scripted`),
for demonstration collection: it maps exactly onto the action contract only when the
goal is a heart or visible pickup position or `pos+200*compass` (clamped) and the aim
is a visible body's position or `pos+5000*compass` (clamped); other orders have no
exact head candidate and any mapping is an approximation. Worlds without scripts are
byte-identical to a build without this call.
