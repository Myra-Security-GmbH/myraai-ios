#!/usr/bin/env bash
CONF="$(cd "$(dirname "$0")" && pwd)/nginx.conf"
openresty -c "$CONF" -s stop 2>/dev/null && echo "mock provider stopped" || echo "mock provider was not running"
