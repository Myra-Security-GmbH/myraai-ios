#!/usr/bin/env bash
# Start the mock provider on 127.0.0.1:19000
set -e

CONF="$(cd "$(dirname "$0")" && pwd)/nginx.conf"
PIDFILE="/tmp/mock-provider/nginx.pid"

mkdir -p /tmp/mock-provider/{logs,client_body,proxy,fastcgi,uwsgi,scgi}

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "mock provider already running (pid $(cat $PIDFILE))"
    exit 0
fi

openresty -c "$CONF"
echo "mock provider started on 127.0.0.1:19000 (pid $(cat $PIDFILE))"
