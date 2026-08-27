#!/usr/bin/env bash
# Succeeds, but swaps <meta_out> for a writer-less FIFO -- what a hostile
# adapter or a swept-but-missed descendant could do. A writer-less FIFO blocks
# the reader at open(2), which no byte bound reaches: the -f guard is the only
# thing that skips it, and that is what this fixture pins (measured
# 2026-08-27).
set -euo pipefail
workdir="$1"; review_out="$3"; meta_out="$4"
cat > /dev/null
{
  echo "# Review from fake-ok-meta-fifo"
  echo "<!-- VERDICT: MINOR -->"
  echo "<!-- FILES-INSPECTED: src/a.ts -->"
} > "$review_out"
rm -f "$meta_out"
mkfifo "$meta_out"
exit 0
