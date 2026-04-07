#!/usr/bin/env bash

exec 200>/tmp/ai-gateway-gen-docs.lock
flock -n 200 || { echo "gen_docs.sh is already running"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$SCRIPT_DIR/create_map.sh" || exit 1

mkdocs build || exit 2

python3 generate-llms.py --full || exit 3
