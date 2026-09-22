# Neural BASIC packages (v1)

A neural policy is a ZIP file with exactly three root entries: `manifest.json`,
`policy.bas`, and `model.bin`. It uses the ordinary opaque file policy upload.
The manifest has schema `paintbot-neural-basic/1`, a `sha256` object mapping
`policy.bas` and `model.bin` to lowercase SHA-256 digests, and
`observation_contract`/`action_contract` containing the contract SHA-256 hashes
exported in `neural_contract.nim`. Actor metadata must match both contracts,
448 inputs, 82 outputs, and categorical head sizes `[51,25,2,2,2]`.
The actor's binary format is documented in `neural_actor.md`.

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
the same reset convention. Output selection is deterministic headwise argmax;
training samples categorical heads and evaluates the deployed argmax artifact.

The versioned neural observation includes public self cooldown and heart-meter
state as well as the documented feature layout. These are deliberate additions
to the older BASIC scalar getters; they are not privileged enemy information.
Neural entity features preserve apparent identity and fog-of-war restrictions.

Validation:

```
python3 -m unittest coworld/paintbot/test_neural_package.py
nim c -r -d:headless tests/test_paintbot_neural_host.nim
```

A successful local loader test is not hosted certification. Release must still
verify platform bundle acceptance, a mixed plain/neural full match, and the
normal hosted hash-verified replay before claiming deployment.
