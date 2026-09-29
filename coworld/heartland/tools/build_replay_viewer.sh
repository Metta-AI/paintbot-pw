#!/usr/bin/env bash
# Heartland replays are paintbot-pw replays (FFA-kin mode): the same viewer bundle, plus the
# 50-seat crowd build in s50/ for Heartland Big (10 tribes of 5).
export PAINTBOT_CROWD_SEATS="${PAINTBOT_CROWD_SEATS:-50}"
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../paintbot/tools/build_replay_viewer.sh" "$1"
