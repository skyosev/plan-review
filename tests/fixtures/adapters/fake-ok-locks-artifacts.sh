#!/usr/bin/env bash
# Writes a normal review, then takes the round directory read-only -- the
# whole-artifact-store provocation for unit A's second contract. Appends to
# EXISTING files still work (chmod on a directory gates entry creation), so
# everything that fails after this is a fresh-file write: publication, the
# result record, the parent's synthesis, round.json's temp file.
set -uo pipefail
review="$3"; meta="$4"
cat > /dev/null
printf 's\nm\ne\nc\n' > "$meta"
echo "review" > "$review"
chmod 555 "$(dirname "$review")"
exit 0
