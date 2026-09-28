#!/usr/bin/env bash
# Heartland kinship evals (tools/kin_eval.py) on the metta Slurm cluster: CPU only, one mettabox.
# Default job: the C3 incentive gate with 400 episodes per condition (2 mixed layouts + 4 welfare
# layouts = 2400 full matches), 16 workers. Heavy batteries run here, never on a shared laptop.
#
# Filesystems are node-local, so sync to the node the job is pinned to (metta0 below), then submit
# through the metta0 scheduler. From the laptop, at the repository root:
#
#   ssh metta@metta0 'mkdir -p ~/kin-eval-workspace/logs'
#   rsync -az --delete --exclude=.git --exclude=/tmp/ --exclude=/runs/ --exclude=/logs/ \
#     ./ metta@metta0:kin-eval-workspace/
#   ssh metta@metta0 'cd ~/kin-eval-workspace && sbatch tools/slurm/kin_eval.sbatch'
#
# Other suites / policies (paths relative to the workspace; a bundle must be synced too):
#   ssh metta@metta0 'cd ~/kin-eval-workspace && sbatch \
#     --export=ALL,KIN_SUITE=hamilton+scrambled+health,KIN_EPISODES=200,KIN_POLICY=bundles/ckpt.zip \
#     tools/slurm/kin_eval.sbatch'
#   sbatch --export splits on commas, so list suites and layouts with '+'. KIN_POLICY2, KIN_LAYOUTS,
#   KIN_SEED, KIN_TICKS and KIN_EXTRA (raw extra flags) pass straight through.
#
# Watch / fetch:
#   ssh metta@metta0 'squeue -n daveey-kin-eval; tail -f ~/kin-eval-workspace/logs/kin-eval-<JOB>.log'
#   rsync -az metta@metta0:kin-eval-workspace/runs/kin-<JOB>/ tmp/kin-<JOB>/   # report.html, results.json
#
# The job builds the game's own compiler image (coworld/paintbot/Dockerfile, stage "compiler": the
# pinned Nim and the locked dependencies), compiles libpaintbot_pw.so inside it and runs the eval
# there (stdlib-only Python). The container is named after the job and removed on exit or scancel
# (scancel alone leaves docker containers running).
#SBATCH --partition=rtx4090
#SBATCH --nodelist=metta0
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=24G
#SBATCH --time=03:00:00
#SBATCH --nice=100
#SBATCH --signal=B:TERM@60
#SBATCH --job-name=daveey-kin-eval
#SBATCH --output=logs/kin-eval-%j.log
set -euo pipefail

SUITE=${KIN_SUITE:-incentive}
SUITE=${SUITE//+/,}
EPISODES=${KIN_EPISODES:-400}
CPUS=${SLURM_CPUS_PER_TASK:-16}
JOB=${SLURM_JOB_ID:-manual}
OUT=runs/kin-$JOB
args=(--suite "$SUITE" --episodes "$EPISODES" --workers "$CPUS" --seed "${KIN_SEED:-1}"
      --ticks "${KIN_TICKS:-8640}" --lib tmp/libpaintbot_pw.so --out "$OUT")
[[ -n "${KIN_POLICY:-}" ]] && args+=(--policy "$KIN_POLICY")
[[ -n "${KIN_POLICY2:-}" ]] && args+=(--policy2 "$KIN_POLICY2")
[[ -n "${KIN_LAYOUTS:-}" ]] && args+=(--layouts "${KIN_LAYOUTS//+/,}")
# shellcheck disable=SC2206
[[ -n "${KIN_EXTRA:-}" ]] && args+=($KIN_EXTRA)

export HOME=$(getent passwd "$(id -u)" | cut -d: -f6)
mkdir -p logs runs tmp
image=daveey-kin-eval:$(cat coworld/paintbot/Dockerfile coworld/dependencies.lock coworld/tools/sync_dependencies.py | sha256sum | cut -c1-12)
echo "== kin-eval job=$JOB node=$(hostname) cpus=$CPUS image=$image started=$(date -u +%FT%TZ)"
echo "== kin_eval.py ${args[*]}"
docker image inspect "$image" >/dev/null 2>&1 || \
  docker build --target compiler -f coworld/paintbot/Dockerfile -t "$image" .

container=daveey-kin-eval-$JOB
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 130' INT
printf -v quoted '%q ' "${args[@]}"
docker run --rm --name "$container" --pull=never --cpus="$CPUS" --memory=24g \
  --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/work" -w /work "$image" bash -c "
    set -e
    nim c --app:lib --mm:arc --threads:on -d:pwTraining -d:headless -d:release --hints:off \
      --nimcache:tmp/nimcache-lib -o:tmp/libpaintbot_pw.so examples/paintbot/native_env.nim
    python3 tools/kin_eval.py $quoted" &
rc=0
wait $! || rc=$?
echo "== kin-eval done job=$JOB exit=$rc out=$OUT finished=$(date -u +%FT%TZ)"
exit $rc
