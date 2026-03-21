#! /bin/sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$SCRIPT_DIR/create_map.sh" || exit 1

mkdocs build || exit 2

python3 generate-llms.py --full || exit 3
