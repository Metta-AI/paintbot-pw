## Floating-point contraction policy for every build that contains the Paintbot simulation
## or the neural actor. Both import this module, so a build cannot include either without it.
##
## sim.nim decides outcomes with float64 comparisons that can tie exactly (walkCoverBlocks'
## round-cover test `ex*ex+ez*ez < (r+Radius)^2`, scores()' kinship sums), and
## neural_actor.nim's contract rounds each FP32 product and each sum separately
## (neural_actor.md, Equations). A fused multiply-add rounds once instead of twice, which
## flips such ties: GCC fuses `a*b + c` by default on an FMA target, even across statements
## (-march=x86-64-v3, as Ubuntu 26.04's amd64v3 toolchain targets), and clang fuses within an
## expression (`s += a*b`; arm64 always has FMA). Turning contraction off makes every build
## round as a target without FMA does, which is what the hosted game (python:3.12-slim gcc,
## x86-64 baseline) and the pinned test values already compute.
##
## passC is global: every C file of the build, callers' float mirrors included, gets the
## same rounding. tests/test_paintbot_fp_contract.nim builds a sim-only program with and
## without FMA and with the actor imported, and fails if their match outcomes differ;
## test_paintbot_neural_layers' "FP32 rounding" suite checks the actor build.
{.used.}

when defined(gcc) or defined(clang):
  {.passC: "-ffp-contract=off".}

const fpContractOff* = defined(gcc) or defined(clang)
  ## True when this build compiles with -ffp-contract=off. Other C compilers are not given
  ## the flag.
