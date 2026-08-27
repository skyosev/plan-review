#!/usr/bin/env bash
# Succeeds, but swaps <meta_out> for a symlink to an endless device -- what a
# hostile adapter or a swept-but-missed descendant could do. Exists to pin the
# child's meta read as guarded: unguarded, this case does not fail red, it
# eats the machine (3GB+ RSS, measured 2026-08-27).
set -euo pipefail
workdir="$1"; review_out="$3"; meta_out="$4"
cat > /dev/null
{
  echo "# Review from fake-ok-meta-symlink"
  echo "<!-- VERDICT: MINOR -->"
  echo "<!-- FILES-INSPECTED: src/a.ts -->"
} > "$review_out"
rm -f "$meta_out"
ln -s /dev/zero "$meta_out"
exit 0
