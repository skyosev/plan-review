#!/usr/bin/env bash
# Fails, and says why: writes one line to <reason_out>.
set -euo pipefail
reason_out="${5:-}"
cat > /dev/null
echo "simulated CLI failure" >&2
[[ -n "$reason_out" ]] && printf 'the vendor said no\nand a second line nobody should read\n' > "$reason_out"
exit 1
