#!/usr/bin/env bash
# Exits 143 without producing a review, having received no signal at all.
#
# 143 is 128+15, so `$?` cannot tell this apart from death by SIGTERM — which is
# the whole point: the runner must describe the code, not claim a signal was
# delivered.
set -uo pipefail
cat > /dev/null
exit 143
