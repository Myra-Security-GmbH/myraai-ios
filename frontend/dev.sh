#!/bin/bash
# Start AI Gateway Admin dev server
# Uses playwright's bundled Node.js (v24) since system Node is too old for Vite 7

NODE=/home/sas/.vllm/lib/python3.12/site-packages/playwright/driver/node
export PATH=$(dirname $NODE):$PATH

cd "$(dirname "$0")"
exec node node_modules/.bin/vite "$@"
