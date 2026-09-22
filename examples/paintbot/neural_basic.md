# Neural BASIC packages (v1)

A neural policy is a ZIP file with exactly three root entries: `manifest.json`,
`policy.bas`, and `model.bin`. It uses the ordinary opaque file policy upload.
The manifest has schema `paintbot-neural-basic/1` or `paintbot-neural-basic/2`, a
`sha256` object mapping `policy.bas` and `model.bin` to lowercase SHA-256 digests, and
`observation_contract`/`action_contract` containing the contract SHA-256 hashes
exported in `neural_contract.nim`. The action contract may be v1
(`55922d42…`, identity aim = body position) or v2 (`51f602ef…`, lead-compensated
identity aim; see `neural_actor.md`); the actor's embedded hash must equal the manifest's
and selects the decoder the seat runs, so existing v1 bundles keep byte-identical
behaviour. Schema 2 is for bundles that may name contract v2: a host that only knows
schema 1 rejects them at staging instead of at model load. Actor metadata must match
both contracts, 448 inputs, 82 outputs, and categorical head sizes `[51,25,2,2,2]`.
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
nim c -r -d:headless tests/test_paintbot_neural_contract.nim
nim c -r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_fire_hold.nim
```

A successful local loader test is not hosted certification. Release must still
verify platform bundle acceptance, a mixed plain/neural full match, and the
normal hosted hash-verified replay before claiming deployment.
