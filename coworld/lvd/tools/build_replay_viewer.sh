#!/usr/bin/env bash
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/../../tools/build_replay_viewer.sh" light_vs_dark lvd "$1"
