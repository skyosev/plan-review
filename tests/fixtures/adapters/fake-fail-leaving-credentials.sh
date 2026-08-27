#!/usr/bin/env bash
# Fails after siting a credential copy beside the workdir, exactly where
# adapters/codex.sh puts its private CODEX_HOME: $(dirname "$workdir")/codex-home
# with a copy of the operator's auth.json in it, mode 600. The smoke keeps a
# failed reviewer's directory for diagnosis, and this is what it must not keep.
set -euo pipefail
workdir="$1"
cat > /dev/null
home="$(dirname "$workdir")/codex-home"
mkdir -p "$home"
printf '{"tokens":{"access_token":"SECRET"}}\n' > "$home/auth.json"
chmod 600 "$home/auth.json"
# One file codex writes itself, so the test can tell "the token was removed"
# from "the whole private home was blown away".
printf 'trust_level = "trusted"\n' > "$home/config.toml"
exit 1
