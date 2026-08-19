#!/usr/bin/env bash
# Produces a review with no sentinel — must surface as UNPARSEABLE.
set -euo pipefail
review_out="$3"; meta_out="$4"
cat > /dev/null
echo "# I forgot the sentinel entirely." > "$review_out"
printf '\n\n\n' > "$meta_out"
exit 0
