#!/usr/bin/env bash
# One half of the overlap check in tests/test-reviewer-runner.sh. Run two of
# these concurrently and both finish in well under a second; run them one
# after the other and the first gives up after ~10s with no review, well
# inside the test's 20s deadline. Deterministic either way: the assertion is
# on overlap, not on timing margins.
#
# The reviewer's name is recovered from the workdir -- the runner hands each
# adapter <sandbox>/<reviewer>/repo -- and the marker directory is shared
# through PR_TEST_HANDSHAKE_DIR because the sandboxes deliberately are not.
set -uo pipefail
workdir="$1"; review_out="$3"; meta_out="$4"
cat > /dev/null
me="${workdir%/*}"; me="${me##*/}"
: > "$PR_TEST_HANDSHAKE_DIR/$me"
# Forkless poll: a glob into $@ counts the markers without ls, wc or a
# subshell, which matters only in the failing (serialised) case -- there the
# loop runs its full 10s instead of a tick or two.
shopt -s nullglob
n=0
for ((i = 0; i < 200; i++)); do
  set -- "$PR_TEST_HANDSHAKE_DIR"/*
  n=$#
  (( n >= 2 )) && break
  sleep 0.05
done
(( n >= 2 )) || exit 1
{
  echo "# Review from fake-handshake ($me)"
  echo "<!-- VERDICT: MINOR -->"
  echo "<!-- FILES-INSPECTED: src/a.ts -->"
} > "$review_out"
printf '%s\n%s\n%s\n%s\n' "hs-$me" fake-model-hs "" fake-cli-9.9 > "$meta_out"
exit 0
