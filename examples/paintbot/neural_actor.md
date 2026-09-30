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

# PWNET002 actor format (generic layer stack)

PWNET002 makes the architecture data: `model.bin` lists a stack of layers from a fixed
menu, the host runs it, and the 4,000,000 operations per seat per tick budget
(`neural_basic.md`) still binds. A new architecture built from the menu is a new bundle,
not a game change. PWNET001 (above) stays supported unchanged; the loader picks the format
by the magic. The hosted seat and the native training library (`pw_net_*`, below) run the
same Nim code (`neural_actor.nim`).

## File

All integers are little-endian uint32, all tensors little-endian FP32, row-major.

| field | value |
|---|---|
| magic | ASCII `PWNET002` |
| version | 2 |
| I | input count, 1..4096 (the observation contract's width: 448, 506, 514, or 506 + K / 514 + K for user-input contracts v2u<K> / v3u<K>; ffa.v2: the match's width, usually the layout word `0xFFFEE000`) |
| O | output count, 2..1024 (the logits; no value row; action contract ffa.v2 pointer: the match's, usually `0xFFFEE100`) |
| head count | 1..32 |
| head sizes | one uint32 per head, each 2..1024, summing to O (layout words allowed) |
| observation contract | 64 lowercase hex bytes (as PWNET001) |
| action contract | 64 lowercase hex bytes (as PWNET001) |
| L | layer count, 1..64 |
| L layer records | `type`, `param[8]`, payload (below) |

A PWNET002 actor may name any observation contract the host knows, including v2u<K>
(`neural_basic.md`, manifest `user_inputs`): its input count is then 506 + K, the K user inputs are
ordinary input columns 506.. (DENSE, CONCAT_INPUT, ENTITY_ATTN, TOKEN_MLP and SEGMENT_NEAR slices may read them), and the operation
count includes them like any other input. Staging reads the input count and contract from the PWNET002
header. The file length must be exact: no trailing bytes. The package manifest binds the SHA-256
of the whole file, as for PWNET001. Every weight must be finite; every unused `param` word
must be 0; every flag must be 0 or 1. The file is at most 16 MiB (the package bound).

The network carries one vector from layer to layer. Before layer 0 it is the observation
(width I). Each layer reads the current vector (its declared input width must equal the
current width), writes its output, and that output becomes the current vector. The last
layer's width must equal O. The recurrent state is every MINGRU layer's state,
concatenated in layer order (at most 4096 floats); a stack without MINGRU keeps no state.
Layers that read "the input" (CONCAT_INPUT, ENTITY_ATTN, TOKEN_MLP) read the raw observation, or,
when layer 0 is SEGMENT_NEAR, that layer's output (the input view, below).

| type | layer | params | payload |
|---|---|---|---|
| 1 | DENSE | `in, out, bias, act` | `W[out, in]`, then `b[out]` if bias |
| 2 | RMSNORM | `dim, eps` (FP32 bits) | `g[dim]` |
| 3 | MINGRU | `in, hidden, highway, bias` | `W[G*hidden, in]`, then `b[G*hidden]` if bias; G = 3 with highway, 2 without |
| 4 | RESIDUAL | `start` | none |
| 5 | ENTITY_ATTN | `groups, d, heads, blocks, ff, pass_offset, pass_len, eps` | group descriptors, then tensors (below) |
| 6 | CONCAT_INPUT | `offset, len` | none |
| 7 | TOKEN_MLP | `tokens, segments, valid_segment, valid_index, layers, 0, norm, eps` | segment descriptors, widths, then tensors (below) |
| 8 | TOKEN_MIX | `source, z, 0, 0, 0, 0, norm, eps` | `Ue[z, d]`, `b[z]`, `Uy[z, width]` (d = the source's token width), then `g[z]`, `s[z]` with norm |
| 9 | POINTER | `source, offset` | `v[z]`, `c` (z = the source's token width) |
| 10 | SEGMENT_NEAR | `tokens, base, stride, x, z, valid, exclude, candidate` | `scale_x, scale_z, radius` (FP32 bits), `dst, dst_stride`; no weights |
| 11 | ATTN_POOL | `source, heads, key, value` | `Wq[h*key, width]`, `bq[h*key]`, `Wk[h*key, z]`, `bk[h*key]`, `Wv[h*value, z]`, `bv[h*value]` |
| 12 | PAD | `at, len` | none |
| 13 | COND_HEAD | `when_head, head` | `W[size(head), size(when_head)]` |
| 14 | TOKEN_PAIR | `source, p, geo_base, geo_stride, x, z, self_pairs` | `A[p, d]`, `B[p, d]`, `C[p, 10]`, `b[p]` |

Limits: widths between layers 1..4096; DENSE `out` 1..4096; MINGRU `hidden` 1..1024;
`act` 0 = none, 1 = relu; `eps` finite and > 0; TOKEN_MLP tokens 1..256, segments 1..8, layers
1..4, at most 1024 gathered floats per token, TOKEN_MLP widths and TOKEN_MIX `z` 1..256;
ENTITY_ATTN at most 256 tokens over all groups; SEGMENT_NEAR only as layer 0, tokens 1..256;
ATTN_POOL heads 1..32, `key` and `value` 1..256, heads x key and heads x value at most 1024;
PAD `at` <= the current width, `len` 0..4096. (The token caps were 64 before observation
contract ffa.v2; a model within the old caps loads and costs exactly as before.)

### Layout words

Observation contract ffa.v2's width, section row counts and offsets, and action contract
ffa.v2 pointer's head sizes follow the match (seats and control hearts). A model states any
of them as a **layout word** instead of a number, and the host resolves every word against
the match layout when the seat loads (the training library: `pw_net_load_layout`), so one
`model.bin` serves Heartland (16 seats) and Heartland Big (50). A layout word is a uint32
whose high 16 bits are `0xFFFE` (no valid model had such a value in these fields before);
its low 16 bits are section `s` (bits 12..15), field `f` (bits 8..11) and an addend `a`
(bits 0..7); the value is the named quantity plus `a`:

| s | section | f = 0 | f = 1 | f = 2 | f = 3 |
|---|---|---|---|---|---|
| 0 | cog rows | rows (seats - 1) | offset of row 0 | row width (44) | logit offset of row 0's pointer target (the aim head's cog rows) |
| 1 | control heart rows | rows (hearts) | offset | 12 | its target (the objective head's heart rows) |
| 2 | great heart rows | rows (2) | offset | 12 | its target |
| 3 | control + great heart rows (contiguous, both 12 wide) | rows | offset | 12 | its target |
| 14 | the whole | observation width + a | logit width + a | the size of head a | the logit offset of head a |

Words are allowed in the header (I, O, head sizes) and in every structural integer of a
layer record (params, ENTITY_ATTN group descriptors, TOKEN_MLP segments and widths,
SEGMENT_NEAR `dst` and `dst_stride`); never in an FP32 field (RMSNORM, ENTITY_ATTN and token-layer norm `eps`,
SEGMENT_NEAR's scales and radius). A word the host cannot resolve (no match layout, an
unknown section or field, a pointer target the action contract lacks) rejects the model. The
weight counts must not depend on a word for one file to fit several layouts: build them from
token layers over the sections, fixed-width DENSE layers, and PAD to open the match-sized
runs the POINTERs write (the test model `pointerModel` in `tests/paintbot_pwnet2_fixture.nim`
is one). Staging (`neural_package.py`) validates a model with layout words up to its first
word and leaves the rest to the host, which checks everything at load.

## Equations

Sums run over their index in ascending order, starting from `+0.0`, one FP32
multiply-add per term (`sum += a*b`), with no reassociation; a bias is added after the
sum. `exp` and `sqrt` are the platform's FP32 functions (the same `exp` PWNET001's
sigmoid uses), and `sigmoid` and `interp` are PWNET001's (above).

- **DENSE**: `y[o] = act(sum_i x[i]*W[o,i] (+ b[o]))`, relu(v) = `v > 0 ? v : 0`.
- **RMSNORM**: `r = 1 / sqrt((sum_i x[i]*x[i]) / dim + eps)`, `y[i] = x[i]*r*g[i]`.
- **MINGRU**: `combined = W x (+ b)`, split into `c, z` (and `p` with highway), each width
  `hidden`. With `s` this layer's slice of the state:
  `candidate = c >= 0 ? c + 0.5 : sigmoid(c)`, `s' = interp(s, candidate, sigmoid(z))`,
  output `y = sigmoid(p)*s' + (1 - sigmoid(p))*x` with highway (which requires
  `in == hidden`), `y = s'` without. The state slice becomes `s'`. These are PWNET001's
  equations and expressions: PWNET001's actor is exactly
  `DENSE(I, H, no bias, none) -> MINGRU(H, H, highway, no bias) -> DENSE(H, O, no bias, none)`,
  bit for bit, with the same operation count.
- **RESIDUAL**: `y = x + output(start)`, where `start` names an earlier layer (0-based,
  `start < this layer's index`) whose output width equals the current width.
- **CONCAT_INPUT**: `y = [x, input[offset ..< offset+len]]`, reading the raw observation
  (`offset + len <= I`, `len` 1..4096).
- **ENTITY_ATTN**: an entity encoder over fixed slices of the raw observation. The
  current vector is not read; the output replaces it.
  - After the 8 params come `groups` descriptors (1..8), five uint32 each:
    `offset, stride, count, width, valid`. Group g has `count` tokens (1..64); token t
    reads `input[offset + t*stride ..< offset + t*stride + width]`, which must lie inside
    the input (`stride` and `width` 1..I). `valid` is the index within the token of its
    presence flag (a token is valid when that float is > 0.5), or `0xFFFFFFFF` for
    always valid. T, the total token count, is at most 64. For example, observation
    contract v1/v2's visible identities are `(104, 8, 16, 8, 0)` and its hearts
    `(24, 8, 10, 8, 0)`.
  - Tensors: for each group in order `E_g[d, width]`, `e_g[d]`; then for each of `blocks`
    (0..8) blocks in order `g1[d]`, `Wqkv[3d, d]`, `bqkv[3d]`, `Wo[d, d]`, `bo[d]`,
    `g2[d]`, `W1[ff, d]`, `b1[ff]`, `W2[d, ff]`, `b2[d]`. `d` is 1..256, `heads` divides
    `d` (head width `dh = d/heads`), `ff` 1..1024.
  - Embedding: `h_n = E_g token_n + e_g`.
  - Each block (pre-norm, both norms RMSNORM with the layer's `eps`):
    `a_n = rmsnorm(h_n, g1)`, `[q_n, k_n, v_n] = Wqkv a_n + bqkv`; for each head and
    query n, over the valid tokens m only, in token order:
    `s_m = (q_n . k_m) * (1/sqrt(dh))`, `M = max_m s_m` (first valid token first),
    `e_m = exp(s_m - M)`, `S = sum_m e_m`, `o_n = sum_m (e_m * (1/S)) v_m`
    (a query attends to no token when none is valid: `o_n = 0`);
    `h_n += Wo o_n + bo`; `h_n += W2 relu(W1 rmsnorm(h_n, g2) + b1) + b2`.
    Every token is computed; masking only removes keys. There is no attention over time:
    memory lives in MINGRU.
  - Output (width `2d + pass_len`, at most 4096): the masked mean of `h` over valid
    tokens (`sum * (1/count)`), the masked max (first valid token first), then
    `input[pass_offset ..< pass_offset+pass_len]`. With no valid token both pools are 0.

- **TOKEN_MLP** (per-token shared MLP): a shared-weight relu MLP run over `tokens` tokens
  gathered from the raw observation (the current vector is not read; the output replaces it).
  - After the 8 params come `segments` descriptors, three uint32 each: `offset, stride,
    length`. Token n's input is the concatenation, in segment order, of
    `input[offset + n*stride ..< offset + n*stride + length]`; `stride` 0 gives every token
    the same slice (e.g. the seat's own features). Every slice must lie inside the input.
    Then `layers` uint32 widths `d_1 .. d_L`, then for each layer `W_l[d_l, d_(l-1)]`,
    `b_l[d_l]` (`d_0` = the summed segment lengths), and with norm `g_l[d_l]`, `s_l[d_l]` after `b_l`.
  - Token n is valid when `input[offset_s + n*stride_s + valid_index] > 0.5` for
    `s = valid_segment`, or always when `valid_segment` is `0xFFFFFFFF` (then `valid_index`
    is 0). A valid token's row is `e_n = relu(W_L ... relu(W_1 x_n + b_1) ... + b_L)` (each a
    DENSE with bias and relu); an invalid token's row is 0 and is not computed. With norm, every
    layer is `relu(layernorm(W_l x + b_l, g_l, s_l))` (the token-layer norm, below).
  - Output (width `2*d_L`): the masked mean (`sum * (1/count)`) and the masked max (first
    valid token first) of the valid rows, exactly ENTITY_ATTN's pools; 0 with no valid token.
    The rows `e` and the valid flags stay available to later TOKEN_MIX layers for the tick.
- **TOKEN_MIX** (per-token layer after the recurrence): `source` names an earlier TOKEN_MLP (or
  ENTITY_ATTN, whose rows `h_n` are then the `e_n`).
  With the current vector x (width W): `u = Uy x` (no bias), then for each valid token
  `z_n[o] = relu((sum_i e_n[i]*Ue[o,i] + b[o]) + u[o])`; an invalid token's `z_n` is 0. With
  norm, `z_n = relu(layernorm(v_n, g, s))` where `v_n[o] = (sum_i e_n[i]*Ue[o,i] + b[o]) + u[o]`.
  Output (width `W + 2z`): `[x, masked mean of z, masked max of z]` (the same pools). The rows
  `z` stay available to later POINTER layers.
- **Token-layer norm** (TOKEN_MLP and TOKEN_MIX params 6 and 7): `norm` 0 is the layer above,
  unchanged, and `eps` must then be 0; `norm` 1 puts a LayerNorm with a learned gain and shift
  on each valid token's pre-activation row, before the relu, with `eps` (FP32 bits, finite and
  > 0). For a row `v` of width n: `mu = (sum_i v[i]) / n`, `var = (sum_i c_i*c_i) / n` with
  `c_i = v[i] - mu`, `r = 1 / sqrt(var + eps)`, `v[i] = ((c_i * r) * g[i]) + s[i]`, each product
  and sum its own FP32 operation in that order. (Param 5 of TOKEN_MLP stays 0.)
- **ENTITY_ATTN's token rows** (the final `h_n` and the valid flags) are available to a later
  TOKEN_MIX, POINTER or ATTN_POOL that names the ENTITY_ATTN layer as its `source`; the layer
  then also copies them to a token buffer (`T*d + T` more operations, counted once).
- **POINTER** (per-token scores into chosen outputs): `source` names an earlier TOKEN_MIX,
  TOKEN_MLP or ENTITY_ATTN with the same tokens. `y = x`, then for each valid token n: `y[offset + n] = x[offset + n] +
  (sum_i z_n[i]*v[i] + c)`; invalid tokens add nothing. `offset + tokens` must not exceed the
  width. E.g. the 16 identity aim logits of contract v1/v2 are outputs 52..67 (`offset` 52).
- **SEGMENT_NEAR** (the input view; parameter-free geometry over tokens already in the input):
  allowed only as layer 0. Its output (width I) is a copy of the observation with one strided
  slice overwritten by per-token 0/1 flags, and every later layer that reads the input
  (CONCAT_INPUT, ENTITY_ATTN, TOKEN_MLP) reads this output instead of the raw observation. A
  stack without it is unchanged.
  - Params: `tokens` T (1..64); token n's floats start at `t_n = base + n*stride` (`stride` >= 1,
    the whole block `base + T*stride <= I`); `x, z, valid, exclude, candidate` are column
    indices within a token (each `< stride`; `exclude` 0xFFFFFFFF = none). After the 8 params
    come five uint32: `scale_x`, `scale_z` (FP32 bits, finite and > 0), `radius` (FP32 bits,
    finite and >= 0), `dst`, `dst_stride` (>= 1 unless T = 1); every flag index
    `dst + n*dst_stride` must be < I.
  - Computed in **float64** (FP32 values widened exactly), in this operation order, so a
    float64 mirror agrees exactly. With `in` the observation:
    `valid_n = in[t_n+valid] > 0.5` and not (`exclude` set and `in[t_n+exclude] > 0.5`);
    `cand_m = valid_m and in[t_m+candidate] > 0.5`;
    `vx_n = f64(in[t_n+x]) * f64(scale_x)`, `vz_n = f64(in[t_n+z]) * f64(scale_z)`,
    `L2 = vx_n*vx_n + vz_n*vz_n`. Token n's flag is 1 when `valid_n`, `L2 > 0`, and some
    `cand_m` (m in 0..T-1 in order, m = n allowed) with `d = vx_m*vx_n + vz_m*vz_n` has
    `0 <= d <= L2` and `(vx_m*vx_m + vz_m*vz_m) - d*d/L2 <= radius*radius`; else 0.
    That is: some candidate token lies within `radius` of the segment from the origin to
    token n, measured perpendicular to it, and not behind the origin or beyond token n.
  - `y = in`, then `y[dst + n*dst_stride] = flag_n` (1.0 or 0.0). The flags are computed
    from `in` alone, so `dst` may overlap the token block.
  - Example (documentation only): over contract v2u32 (I = 538) with T = 16, base 104,
    stride 8, x 1, z 2, valid 0, exclude 6, candidate 3, scale_x 16000, scale_z 9600,
    radius 150, dst 522, dst_stride 1, user inputs 522..537 become, for each observed
    identity (the fog-gated identity block), "an observed teammate is within 150 units of
    the segment from me to this identity".

- **ATTN_POOL** (cross-attention pooling, cost linear in the tokens): `source` names an earlier
  TOKEN_MLP, TOKEN_MIX or ENTITY_ATTN (its rows `e_n`, width `z`, and valid flags). With the
  current vector x (width W): `q = Wq x + bq`; for each valid token n, `k_n = Wk e_n + bk`,
  and per head j `s_(n,j) = (q_j . k_(n,j)) * (1/sqrt(key))`; per head, over the valid tokens
  in token order, ENTITY_ATTN's softmax (`M = max s` first valid first, `e = exp(s - M)`,
  `S = sum e`, `w = e * (1/S)`); then for each valid token n in order, `v_n = Wv e_n + bv` and
  `pool_j += w_(n,j) * v_(n,j)` (from `+0.0`). Output (width `W + heads*value`): `[x, pool]`;
  the pool is 0 with no valid token. Every DENSE here is the DENSE rule above (a float32 sum
  from +0 in index order, then the bias).
- **PAD**: `y = [x[0 ..< at], 0 x len, x[at ..< W]]` (width `W + len`): opens a run of zeros
  where later POINTERs write match-sized heads.
- **TOKEN_PAIR** (a learned pairwise token layer): `source` names an earlier TOKEN_MLP, TOKEN_MIX
  or ENTITY_ATTN (its rows `e_n`, width `d`, T tokens, valid flags). Token n's position is
  `(x_n, z_n) = (input[geo_base + n*geo_stride + x], input[geo_base + n*geo_stride + z])` (the
  observation, or SEGMENT_NEAR's view; `x, z < geo_stride`, the whole block inside the input).
  For each valid token n: `a_n = A e_n`, `b_n = B e_n` (DENSE, no bias). For each valid partner
  m (m != n unless `self_pairs`), in token order, the pair features `g` (10, each product or sum
  its own FP32 operation): `x_n, z_n, x_m, z_m, x_m - x_n, z_m - z_n, x_n*x_m + z_n*z_m,
  x_n*z_m - z_n*x_m, x_n*x_n + z_n*z_n, x_m*x_m + z_m*z_m`, and
  `h_nm[o] = relu((((sum_i g_i*C[o,i]) + b[o]) + a_n[o]) + b_m[o])`. Row n (width `d + 2p`, at
  most 1024) is `[e_n, mean_m h_nm, max_m h_nm]`: the mean is `sum * (1/count)`, the max takes the
  first partner first, and both are 0 with no partner. An invalid token's row is 0. Output
  (width `W + 2(d + 2p)`): `[x, masked mean of the rows, masked max of the rows]` (the token-layer
  pools). The rows and valid flags feed a later TOKEN_MIX, POINTER or ATTN_POOL. A learned
  successor to SEGMENT_NEAR's fixed geometry: the pair features let one relu layer form the
  products of both tokens' positions that a segment test needs.
- **COND_HEAD** (a learned conditional action head): `y = x`; the layer's weights act at
  selection, not in the vector. `when_head` and `head` are distinct action-head indices, and
  `W` is `size(head) x size(when_head)` (row-major, part of the model's weights). After the
  tick's selection (forbid, BASIC masks, argmax or sampling, BASIC temperatures), in layer
  order, head `head` is selected again from `logits_head[j] + W[j, a]`, with `a` the choice
  already selected for `when_head`, under the exclusions and temperature the head was selected
  with: argmax (the first maximum among the allowed) at temperature 0, else exactly one more
  uniform53 draw from the seat's sampling stream, the float64 softmax of `decoder.joint_sampling`
  (`neural_contract.reselectHead`; the same draw as joint sampling whose offsets are that
  column). When that column is all zero the selection already has that distribution, so it
  stands and no draw is taken; a COND_HEAD whose W is zero except column `v` (= a joint
  sampling's offsets) therefore takes exactly `decoder.joint_sampling`'s draws. The head's
  distribution is `softmax((logits_head + W[:, a]) / T)`, learned end to end with the model.
  Rules: COND_HEAD layers come after every other layer; a head is re-selected by at most one
  COND_HEAD; a COND_HEAD never re-selects a head an earlier COND_HEAD read as its condition
  (chains such as 2 -> 0 then 0 -> 1 are allowed); a model with COND_HEAD layers cannot also
  ask for `decoder.joint_sampling`. The seat log line gains ` cond_heads=h<when>->h<head>,...
  draws=<n>`. The training library's policy seats have no actor, so the trainer sets the same
  weights with `pw_set_seat_conditionals` (below). A model without COND_HEAD runs none of this.

Inference validates the observation and state (finite) first, checks every layer's output
and every new state value is finite, and commits the new state and the logits only when
all are; otherwise the seat fails as PWNET001's does. Scratch for every layer output, the
new state and the largest per-layer workspace is allocated once at load; inference does
not allocate. Reset convention: exactly PWNET001's — the host zeroes the whole state at
initial use, match reset, death and respawn.

## Operation count (published formula)

The loader computes the count once, at load, from the params alone (never from which
tokens are valid, with every layout word resolved), and the host rejects a model over the
budget with the existing error and telemetry line. The budget is 4,000,000 operations per
seat per tick up to 16 seats and scales like BASIC's instruction budget above that:
`4,000,000 * seats / 16` (12,500,000 at Heartland Big's 50; `neural_host.neuralOperationBudget`;
the telemetry line's `budget=` prints it). Units: a multiply-accumulate is 2 operations; an elementwise add,
multiply, compare, max, relu or copy is 1; an `exp`, `sqrt` or division is 8; a MINGRU
unit's gates, interpolation and highway are 32 (PWNET001's `32*H`).

| layer | operations |
|---|---|
| DENSE | `2*in*out + out*bias + out*relu` |
| RMSNORM | `4*dim + 16` |
| MINGRU | `2*in*G*hidden + G*hidden*bias + 32*hidden` |
| RESIDUAL | `width` |
| CONCAT_INPUT | `len` |
| TOKEN_MLP | `T*d_0 + T*sum_l(2*d_(l-1)*d_l + 2*d_l) + pool(d_L)` |
| TOKEN_MIX | `2*W*z + W + T*(2*d*z + 3*z) + pool(z)` |
| token-layer norm | `+ T*(8*n + 32)` per normalised width n (TOKEN_MLP: each `d_l`; TOKEN_MIX: `z`) |
| POINTER | `W + T*(2*z + 2)` |
| SEGMENT_NEAR | `I + 12*T*T + 8*T` |
| ENTITY_ATTN | `embed + blocks*block + pool` (+ `T*d + T` when a later layer reads its token rows) |
| ATTN_POOL | `W + (2*W*h*k + h*k) + T*((2*z*h*k + h*k) + h*(2*k + 1) + h*(8 + 3) + (2*z*h*v + h*v) + 2*h*v) + h*(T + 8)` |
| PAD | `W + len` |
| COND_HEAD | `W + size(head)` (the copy, and the column add at selection) |
| TOKEN_PAIR | `W + T*(4*d*p + 2 + d) + T*T*(18 + 26*p) + T*(8 + p) + pool(d + 2p)` |

with, for ENTITY_ATTN (T tokens, h heads, F = ff, P = pass_len):

```
embed = sum over groups of count*(2*width*d + d)
block = 2*T*(4d + 16)                  pre-norms
      + T*(6d^2 + 3d)                  q, k, v with bias
      + T^2*(4d + 13h) + 8*h*T         scores, scale, max, exp, sum, weights, weighted values;
                                       one reciprocal per head and query
      + T*(2d^2 + d) + T*d             output projection with bias, residual
      + T*(2dF + 2F) + T*(2Fd + d)     relu MLP with biases
      + T*d                            residual
pool  = T + 2*T*d + d + 8 + P          valid flags, mean, max, reciprocal, passthrough
```

and for the token layers `pool(d) = T + 2*T*d + d + 8` (T tokens; the counts, like every
other, do not depend on which tokens are valid). Example (an entity-factored actor over
contract v2u32): TOKEN_MLP over the 16 identities with segments (104, 8, 8), (470, 2, 2),
(0, 0, 24), (448, 0, 2), (506, 1, 1), (522, 1, 1) (identity j's block, its terrain floats,
the seat's own features for every token, two user inputs of its own), widths 128, 128; then
CONCAT_INPUT(0, 538), DENSE(794, 128), MINGRU(128, 128, highway), TOKEN_MIX(0, 64),
DENSE(256, 82, bias), POINTER(4, 52) costs 1,327,278 operations per tick. SEGMENT_NEAR costs
`I + 12*T*T + 8*T` (the copy, 12 per token pair, 8 per token): the example above (I = 538,
T = 16) costs 3,738, so the same actor behind it (sources shifted by one) costs 1,331,016.

The model's count is the sum over its layers. PWNET001's `2*(I*H + 3H*H + O*H) + 32*H` is
the same formula applied to its three layers. Example: ENTITY_ATTN over contract v2's 16
identities and 10 hearts (T = 26), d = 64, 4 heads, 2 blocks, ff = 64, pass_len = 24, then
CONCAT_INPUT(232, 274), MINGRU(426, 128, no highway, bias), DENSE(128, 82, bias) costs
3,307,774 operations per tick, 692,226 under the budget (`neural: peak_ops=3307774`).

The telemetry line's model field is `w<hidden>` for PWNET001 (unchanged) and
`pwnet2-l<layers>-s<state floats>` for PWNET002.

# Native training ABI (`native_env.nim`, `-d:pwTraining`)

Version 1, declared in `native_env.h`: `pw_create/pw_reset/pw_destroy`,
`pw_observe` (all seats) and `pw_observe_seats` (chosen seats), `pw_step`,
`pw_results`, `pw_bot_actions`, `pw_state_hash`, and the telemetry call below. Every
entry is additive to v1; a host that ignores the newer ones sees the same bytes.

## Observation contracts

The observation contracts below exist. The actor file and the package manifest carry the
contract's SHA-256 (the hash of the id string); the host encodes each seat with the
contract its actor names and requires the actor's input count to be that contract's
width, so a v1 bundle keeps byte-identical behaviour on a host that also knows v2. An
unknown hash fails the seat, as before.

| version | id | SHA-256 | floats |
|---|---|---|---|
| v1 | `paintbot-pw.rules37.obs.v1.float448` | `ed5d16768e3144a04a28420ce227ff2d6a831be9f64f3633326b133a5335b7e2` | 448 |
| v2 | `paintbot-pw.rules37.obs.v2.float506` | `e0d7b0b97975725c470ef6119ca2a6caf4aaa6f34cd15bee02bd306489c029e5` | 506 |
| v3 | `paintbot-pw.rules43.obs.v3.float514` | `06f16d62adedda6995d393696c0d2ed257aa9380b86341e73d1d6a3c7ea374f1` | 514 |

v2 is v1 followed by a terrain block: columns 0..447 are the v1 observation, same order,
same values (`encodeObservation` v1 is called unchanged on that slice), and columns
448..505 are `encodeTerrainBlock` (`neural_contract.nim`). Why: the river decides
fights (a wading seat moves at a quarter speed and stands about 200 below the bank,
where it is hit two to four times as often), and v1 shows neither water nor absolute
height, only nine height samples around the seat.

"Wet" is `inWater(p)`, exactly the predicate `mechanics.nim` uses to quarter a seat's
speed (rules >= 30: inside the river and below `RiverWaterHeight` = -162). "Height" is
`w.elevation(p)` (terrain plus the trench's -60, the height the gun's spread reads)
divided by `TerrainHeightScale` = 800; the rules-37 playable span measures -260..551, so
every height and delta lies within about [-1, 1] (river bed under a level bank: -0.25).

| column | field |
|---|---|
| 448 | self wet (0/1) |
| 449 | self height |
| 450 + 2i, i = 0..9 | heart i wet (0 when the heart is absent) |
| 451 + 2i | heart i height minus self height (0 when absent; negative = below the seat) |
| 470 + 2j, j = 0..15 | apparent identity j wet (0 when v1's identity slot j is empty) |
| 471 + 2j | apparent identity j height minus self height (0 when empty; the seat's own slot is 0) |
| 502 | visible apparent enemies wet / 8 |
| 503 | visible apparent enemies dry / 8 |
| 504 | visible apparent teammates wet / 8 (the seat itself excluded) |
| 505 | visible apparent teammates dry / 8 (the seat itself excluded) |

No hidden information: the block reads terrain only at points v1 already reveals (the
seat's own position, the ten public hearts, the bodies v1 resolves under apparent
identities). Identity slots follow v1's fog and uniform resolution (`observedBodies`),
so a slot can be non-zero only when v1's visibility flag for that slot (column
104 + 8j) is 1 (a visible seat on dry ground level with the observer reads 0, 0; the
flag tells the two apart), and the counts use the apparent team v1 shows (a disguised enemy counts
as a teammate, at the identity it wears).

Native ABI: `pw_create_observation(seed, max_ticks, version)` creates a handle encoding
contract 1 or 2 (NULL otherwise; `pw_create` is contract 1); the version is kept across
`pw_reset`, and `pw_observe` / `pw_observe_seats` rows are that contract's width apart.
`pw_observation_size_for(version)` (448 / 506, -1 unknown), `pw_handle_observation_size
(handle)`, `pw_observation_contract(handle)` and `pw_observation_contract_hash(version,
out, 65)` report it; `pw_observation_size()` stays 448. The observation contract never
touches the world or its hash.

**v2u<K>: v2 + K user inputs** (PLAN-neural-basic-io part A). Id
`paintbot-pw.rules39.obs.v2u<K>`, K = 1..128, SHA-256 of the id (all 128 listed in
`neural_contract.UserInputsContractHashes`; K = 1 is `bd80f4d3…`, K = 2 `b064de43…`, K = 3
`a8c43d03…`); 506 + K floats. Columns 0..505 are v2 unchanged; column 506 + i is
`float32(v_i) / 1000` where v_i is the value the seat's policy.bas last set with
`neuralInput(i, v)` (clamped to +-1,000,000) before this tick, or the manifest's
`user_inputs.init[i]` at match start (`neural_contract.encodeObservationInputs`). The
manifest's `user_inputs.count` must be K. Training: `pw_create_observation_inputs(seed,
max_ticks, K)`; a policy seat's rows carry its inputs, every other seat's user columns are 0.

**v3: v2 + the scoreboard** (teams game only). Columns 0..505 are v2 unchanged; columns
506..513 are `encodeScoreboardBlock` (`neural_contract.nim`), from the seat's team's side:

| column | field |
|---|---|
| 506 | own team's lives left (`sim.teamLives`: the sum the behind-in-lives award compares) / 32 |
| 507 | enemy team's lives left / 32 |
| 508 | own team's glory / 1000 |
| 509 | enemy team's glory / 1000 |
| 510 | behind-in-lives award, glory per life trailed (the match's `glory.behind_lives`) / 10 |
| 511 | its period in seconds (`glory.behind_lives_seconds`) / 60 |
| 512 | quiet-supplies award (`glory.quiet_supplies`) / 100 |
| 513 | ticks remaining, max(0, end tick - tick) / max(1, end tick) |

Only what the HUD shows every viewer: each seat's lives (the header's life pips), both glory
totals (the header score), the match's glory awards (the scoreboard and the score tooltip,
rules 43) and the clock. An FFA-kin match refuses a v3 seat at load (no teams, lives or
glory there). Native: `pw_create_observation(seed, max_ticks, 3)`; `pw_set_game_mode(h, 1)`
returns -1 on a v3 handle.

**v3u<K>: v3 + K user inputs.** Id `paintbot-pw.rules43.obs.v3u<K>`, K = 1..128, SHA-256 of
the id (all 128 in `neural_contract.V3UserInputsContractHashes`; K = 1 is `8086b6f3…`);
514 + K floats: v3 unchanged, then the K user inputs exactly as v2u<K> feeds them. The
manifest's `user_inputs.count` must be K. Training: `pw_create_observation_inputs_v(seed,
max_ticks, 3, K)` (version 2 there is `pw_create_observation_inputs`);
`pw_user_inputs_contract_hash_v(3, K, out, 65)` writes the hash.

**ffa.v1: FFA-kin** (mode `ffa_kin`). Id `paintbot-pw.rules40.obs.ffa.v1.float810`, SHA-256
`6b19dc324386542eb915d30c2ce1707a8f8e192a0425ee8b2ae9145969583fc7`, 810 floats, native version
101 (`pw_create_observation(seed, max_ticks, 101)`). A separate encoder
(`neural_contract.encodeFfaObservation`, which documents every column), not a v1/v2 prefix.
There is no map flip, for observations or for the compass heads of either action contract
(in FFA mode no seat is mirrored). Layout:

| columns | block |
|---|---|
| 0..7 | self: centred x, centred z, hp/maxHp, armor/maxHp, cooldown/72, own score/1000, alive, ticks left/8640 |
| 8 + 42j, j = 0..15 | seat j: dx, dz, visible, alive, hp/maxHp, 32 gene bits (+-1), r to me, score/1000, hearts held/10, territory boost/30 (own row only; 0 elsewhere), 1 reserved |
| 680 + 6i, i = 0..9 | control heart i: centred x, centred z, owner's r to me (-1 neutral, 1 mine), capture progress, contested, owned by me |
| 740 + 6g, g = 0..1 | great heart g: centred x, centred z, state (-1 dormant, 0 awake, 1 charging), present/16, progress, dormant ticks left/1440 |
| 752..809 | v2's terrain block columns 0..53, then visible other seats wet/8 and dry/8, 2 reserved |

Positions and hp of other seats are fog-gated; before rules 48 alive, genes, r, score and hearts
held are public. From rules 48 (the FFA-kin fog of war, `sim.ffaFog`) the whole row of a seat the
observer cannot see is zero, alive included (unknown), so genes, r, score and hearts held appear
only for seats in view; the seat's own row, the hearts and the great hearts are unchanged. The
layout, id and hash stay: like team vision (rules 42), the rules decide what is in view, the
contract how it is laid out. hp and armor are divided by `maxHp()` (FfaMaxHp = 10 in FFA, 3 otherwise).
Scores are raw scores s_j in points / 1000, the only columns that can exceed 1. Under
the training-only mask bit 0 every r column reads 0, the seat's own row included, and so does
the own row's territory-boost column (it is r to the local owner). Identity rows are indexed by seat, and the
aim head's identity index 1..16 aims at that seat. Outside FFA the kin, score and
seat-ownership columns are zero.

**ffa.v2: FFA-kin at any seat count** (Heartland and Heartland Big). Id
`paintbot-pw.rules48.obs.ffa.v2`, SHA-256
`d0a10cee5ae4a3b73a13e018fc1904e40f943768483498d896b9915e6313c592`, native version 102
(`pw_create_observation(seed, max_ticks, 102)`, `pw_set_seats`). A fixed header, then three
entity sections of fixed-width rows. The row counts follow the match, so **the width is
fixed per match, not per contract**: `24 + (N-1)*44 + H*12 + 2*12` for N seats and H control
hearts (828 in Heartland: 16 seats, 10 hearts; 3,404 in Heartland Big: 50 seats, 100 hearts).
Read it from `pw_handle_observation_size` / `pw_observation_layout` (native), `neuralLayout`
(BASIC) or `neural_contract.ffaV2Layout` (Nim). Column 0 of every row is its valid flag. No
map flip. The encoder is `neural_contract.encodeFfaV2Observation`, which documents every
column; the row order is `ffaV2Rows`.

| columns | block |
|---|---|
| 0..7 | self: ffa.v1's 8 floats (centred x, centred z, hp/maxHp, armor/maxHp, cooldown/72, own score/1000, alive, ticks left/8640) |
| 8..23 | match and own state: seats/64, control hearts/100, ticks remaining/end tick, hearts owned by self/hearts, territory boost here/30, self wet, self height/800, seen cogs/64, cog rows/64, heart rows/100, great rows/2, 5 reserved |
| 24 + 44k, k < N-1 | cog row k: valid, dx, dz, visible (1), hp/maxHp, 32 gene bits (+-1), r to me, score/1000, hearts held/10, distance/diagonal, wet, height minus own/800, seat id/255 |
| after the cogs, 12 per heart | control heart row: valid (1), dx, dz, centred x, centred z, owner's r to me (-1 neutral, 1 mine), capture progress, contested, owned by me, distance, wet, height minus own |
| the last 24 | 2 great heart rows: valid (1), dx, dz, centred x, centred z, state (-1 dormant, 0 awake, 1 charging), present/16, progress, dormant ticks left/1440, distance, wet, height minus own |

- **Only the cogs the seat can see.** The cog section holds only the cogs in view (`sim.visible`,
  the line of sight that sets ffa.v1's visible column and BASIC's `visible`), packed first,
  nearest first, ties by seat id; every row after them is all zero (valid 0). Nothing about an
  unseen cog appears anywhere (position, hp, genes, r, score, hearts held, id, or any count or
  order that depends on it), whatever the rules. The header carries only the seat's own state
  and match constants (no alive count, no family or R figure).
- **Hearts** are static map entities: every control heart and both great hearts, nearest first
  (ties by index), all valid. Their owner and capture columns are ffa.v1's.
- **Row -> entity map.** Row k of each section names one seat, control heart or great heart
  for this tick; the host keeps that map from the observation to the decode (action contract
  ffa.v2 pointer). Native `pw_observation_rows`, BASIC `neuralRow(section, k)`.
- The training-only kin mask (`pw_set_obs_mask` bit 0) zeroes cog column 37, heart column 5
  of a heart another seat owns, and header column 12.
- The v1 / v2 action contracts address 16 identities, so an ffa.v2 bundle must name action
  contract ffa.v2 pointer, and that contract needs ffa.v2 (the host rejects either alone).

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

**ffa.v2 pointer** (observation contract ffa.v2 only; native version 3). Id
`paintbot-pw.rules48.action.ffa.v2.pointer`, SHA-256
`068fc9816d515cc7df281ce94c7ecb973ca83f8f268021ef06707f934d2d83a5`. The same five heads,
sized by the match (N seats, H control hearts); the objective and aim heads point at the rows
of the observation of the same tick (`neural_contract.decodePointerActions`):

| head | size | index |
|---|---|---|
| 0 objective | 11 + H | 0 stay; 1..8 compass `pos + 200*d` for d = (1,0), (1,1), (0,1), (-1,1), (-1,0), (-1,-1), (0,-1), (1,-1) in (x, z), clamped to the map; 9 + k control heart row k; 9 + H + g great heart row g |
| 1 aim | 8 + N | 0 keep the current aim; 1..8 compass `pos + 5000*compass`; 9 + k cog row k: that cog's lead-compensated aim point (contract v2's rule, memory keyed by seat id); a row past the seen cogs keeps the aim |
| 2, 3, 4 | 2 each | fire, charge grenade, sneak |

The logits are `11 + H + 8 + N + 6` floats (175 in Heartland Big, 51 in Heartland). With
layout words a model's POINTERs target the cog rows at `0xFFFE0300` (the aim head's row 0,
`20 + H`) and the heart rows at `0xFFFE3300` (9). Selection is argmax, or `decoder.sampling`
(the only decoder option this contract takes; the others read the fixed contracts' head
indices) and BASIC `neuralTemperature`; `neuralMask` is refused. Native: `pw_set_action_contract(h, 3)`
on a 102 handle, `pw_action_layout` for the heads, `pw_step` decodes the caller's heads through
the rows of the observation `pw_observe` wrote for that world (at any seat count), and
`pw_step_logits` rows are the layout's logit width.

Decoder options are not contracts. A schema-2 bundle may ask for `decoder.fire_hold_teammates`
(`neural_basic.md`): the decoded shoot order is dropped when a visible teammate stands in
the gun's corridor to the aim point. The candidates every head resolves to and both
contract hashes are unchanged by it; the training ABI's `pw_set_seat_fire_hold` (with
`pw_set_seat_fire_hold_radius` for the object form's `radius`) is the same rule
(`native_env.h`). It may also ask for `decoder.sampling` (`neural_basic.md`):
the listed heads are drawn from `softmax(logits / temperature)` on a seat-owned SplitMix64
stream seeded from the match seed and the slot (`neural_contract.sampleActions`,
`samplingRng`), the rest keep argmax; the candidates and hashes are again unchanged, and
the training ABI's `pw_set_seat_sampling` / `pw_sample_actions` draw from the same stream.
`decoder.forbid_objectives` removes movement-head candidates from selection and
`decoder.strafe_legs` replaces the movement head with base.bas's contact legs
(`neural_basic.md`); candidates and hashes are unchanged, and the training ABI's
`pw_set_seat_forbid_objectives` / `pw_set_seat_strafe` are the same rules.
`decoder.aim_snap` turns a compass shoot order toward a visible enemy's identity and
`decoder.steady_shot` stands the seat from a shoot order until the ray leaves
(`neural_basic.md`); candidates and hashes are unchanged, and the training ABI's
`pw_set_seat_aim_snap` / `pw_set_seat_steady_shot` are the same rules.
`decoder.aim_retarget` turns every shoot order toward base.bas's target (the visible enemy
minimising `d^2 - (3 - hp) * 160000 - carrying * 2500000` within 5250) and
`decoder.shot_gate` drops a shoot order that is not aimed at an enemy in range after the
retarget and the snap (`neural_basic.md`); candidates and hashes are unchanged, and the
training ABI's `pw_set_seat_aim_retarget` / `pw_set_seat_shot_gate` are the same rules.
`decoder.spray_aim` / `decoder.spray_gate` re-aim or drop a shoot order with a ready spray
can by the cone it would produce (`neural_basic.md`); the training ABI's
`pw_set_seat_spray_aim` / `pw_set_seat_spray_gate` are the same rules, and
`pw_seat_spray_stats` (training library only) counts spray damage and kills per seat.
`decoder.joint_sampling` re-selects one head when another was selected as a given value,
from its logits plus the bundle's offsets (`neural_basic.md`); candidates and hashes are
unchanged. A model's COND_HEAD layers (PWNET002) re-select a head from its logits plus a
learned column of weights chosen by another head's selection (above); the training ABI's
`pw_set_seat_conditionals(handle, seat, count, heads[2*count], weights, weight_count)` gives
a policy seat the same layers (pairs of condition head and re-selected head, their weights
concatenated; count 0 clears; they stay across `pw_reset`; -1 bad arguments or not a policy
seat, -2 against COND_HEAD's rules).

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
`pw_reset` and `pw_set_action_contract` in the native ABI, and there too on every decided
tick the seat is dead or alive after a tick it was dead, so both agree after a respawn.

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
(the default) it is plain argmax, and `pw_step` is untouched either way (a hosted seat
decides only while alive, so a probe matching its draws calls it for live seats only).
`pw_set_seat_forbid_objectives(handle, seat, int32 indices[], count)` masks movement-head
candidates out of `pw_sample_actions` and makes `pw_step` return -3 (nothing stepped) when
the caller hands a live seat a forbidden one; `pw_seat_forbidden_objectives(handle, seat,
int32 out[51])` returns the mask for a trainer's logits. `pw_set_seat_strafe(handle, seat,
range, leg_min, leg_max, shot_min, shot_max, reverse_permille)` (range 0 = off) applies
the strafe to the caller's heads inside `pw_step`; `pw_seat_strafe_stats(handle, seat,
int32 out[3])` = {legs, replaced decisions, movement index executed last step or -1}.
`pw_set_seat_aim_snap(handle, seat, max_angle_millideg)` (0 = off, 22500 = 22.5 degrees)
and `pw_set_seat_steady_shot(handle, seat, 0|1)` apply those rules to the caller's heads
inside `pw_step` (aim snap, strafe, steady shot, decode, hold); `pw_seat_aim_snap_stats(handle,
seat, int32 out[3])` = {snaps, aim index executed last step or -1, cosine threshold} and
`pw_seat_steady_stats(handle, seat, int32 out[3])` = {order ticks held, decisions held,
movement index executed last step (0) or -1}. The steady shot refuses a seat whose forbid
mask lists index 0, and the forbid call refuses index 0 while the steady shot is on.
`pw_set_seat_aim_retarget(handle, seat, enabled, max_range, hp_weight, carry_weight)`
(enabled 0 = off; 1, 5250, 160000, 2500000 = the bundle defaults) and
`pw_set_seat_shot_gate(handle, seat, max_range)` (0 = off, 5250 = the default) apply those
rules inside `pw_step` in the hosted order (aim retarget, aim snap, shot gate, strafe,
steady shot, decode, hold); `pw_seat_aim_retarget_stats(handle, seat, int32 out[3])` =
{retargets, aim index executed last step or -1, max_range} and
`pw_seat_shot_gate_stats(handle, seat, int32 out[3])` = {orders dropped, shoot head
executed last step (0) or -1, max_range}.

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
`pw_set_seat_command(handle, seat, int32[9])` takes the same nine fields the other way:
the seat executes that raw command on the next `pw_step` only, instead of its decoded
heads or its script's order. It is built as BASIC builds one (goal verbatim, aim clamped
to the map as `lookAt` clamps it), skips the seat's head decode and forbid check for that
step, applies the fire hold and fire period only if already set, and is echoed by
`pw_seat_orders`. A command-space opponent, or a recording's commands replayed seat by
seat, reproduces the recorded world hash for hash. Never calling it is byte-identical.

Neural actors (training library): `pw_net_load(data, length, error, capacity)` loads a
`model.bin` (PWNET001 or PWNET002) with the hosted loader and refuses a model over the
operation budget, as the hosted seat does; `pw_net_info` (format, inputs, outputs, state
floats, heads, layers, parameters, operations), `pw_net_head_sizes`, `pw_net_contracts`
read it; `pw_net_infer(net, observation, state, logits)` is the hosted seat's
`run_neural_net` (0, -1 bad arguments, -2 failed with state and logits untouched);
`pw_net_destroy` frees it. A trainer that zeroes a seat's state on `pw_observe`'s reset
mask reproduces the hosted seat's recurrence exactly. Never calling them changes nothing.
