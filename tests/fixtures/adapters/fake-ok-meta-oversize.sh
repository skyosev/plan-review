#!/usr/bin/env bash
# Succeeds, but writes a single 8192-byte meta line -- a regular file, so the
# -f guard passes it and the head -c 4096 bound is the only thing this pins.
# Remove the bound and this test goes red with an 8192-byte session_id; the
# symlink and FIFO fixtures cannot see that, their cases never reach the read.
set -euo pipefail
workdir="$1"; review_out="$3"; meta_out="$4"
cat > /dev/null
{
  echo "# Review from fake-ok-meta-oversize"
  echo "<!-- VERDICT: MINOR -->"
  echo "<!-- FILES-INSPECTED: src/a.ts -->"
} > "$review_out"
printf -v pad '%8192s' ''
printf '%s' "${pad// /x}" > "$meta_out"
exit 0
