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
