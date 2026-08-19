#!/usr/bin/env bash
# Writes a usable review, then hangs. The runner records `ok` -- output is what
# it judges on -- while timed_out is still 1, which is exactly the combination
# the handle rule has to cover.
set -uo pipefail
workdir="$1"; session_in="$2"; review_out="$3"; meta_out="$4"
cat > /dev/null
printf '%s\n' "# partial review" "<!-- VERDICT: MINOR -->" > "$review_out"
printf '%s\n%s\n%s\n%s\n' "" fake-model-1 fake-effort-high fake-cli-9.9 > "$meta_out"
sleep 300
