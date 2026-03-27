#!/usr/bin/env bash
# presidio_run.sh — build and start Presidio analyzer + anonymizer as local sidecars.
#
# Analyzer  listens on 127.0.0.1:5002  (entity detection, uses spaCy)
# Anonymizer listens on 127.0.0.1:5001  (entity redaction, no ML)
#
# Usage:
#   ./presidio_run.sh            # build (if needed) and start both services
#   ./presidio_run.sh stop       # stop and remove containers
#   ./presidio_run.sh rebuild    # force rebuild of analyzer image, then start
#   ./presidio_run.sh logs       # tail logs from both containers
#   ./presidio_run.sh status     # show running status

set -euo pipefail

ANALYZER_IMAGE="aig-presidio-analyzer"
ANALYZER_CONTAINER="aig-presidio-analyzer"
ANONYMIZER_IMAGE="mcr.microsoft.com/presidio-anonymizer:latest"
ANONYMIZER_CONTAINER="aig-presidio-anonymizer"

ANALYZER_PORT="5002"
ANONYMIZER_PORT="5001"

DOCKERFILE="config/Dockerfile.presidio"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[presidio] $*"; }

container_running() {
    docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q "true"
}

container_exists() {
    docker inspect "$1" &>/dev/null
}

stop_container() {
    local name="$1"
    if container_exists "$name"; then
        log "Stopping $name..."
        docker stop "$name" 2>/dev/null || true
        docker rm   "$name" 2>/dev/null || true
    fi
}

build_analyzer() {
    log "Building analyzer image ($ANALYZER_IMAGE) — this downloads GLiNER model and spaCy tokeniser once..."
    docker build \
        -f "$DOCKERFILE" \
        -t "$ANALYZER_IMAGE" \
        .
    log "Analyzer image built."
}

start_analyzer() {
    if container_running "$ANALYZER_CONTAINER"; then
        log "Analyzer already running on :$ANALYZER_PORT"
        return
    fi
    stop_container "$ANALYZER_CONTAINER"

    # Build image if it does not exist yet
    if ! docker image inspect "$ANALYZER_IMAGE" &>/dev/null; then
        build_analyzer
    fi

    local _uid
    _uid=$(docker run --rm --entrypoint '' "$ANALYZER_IMAGE" id -u presidio 2>/dev/null)
    log "Starting analyzer on 127.0.0.1:$ANALYZER_PORT (GPU 0, uid=${_uid})..."
    docker run -d \
        --name "$ANALYZER_CONTAINER" \
        --restart unless-stopped \
        --gpus device=0 \
        --user "$_uid" \
        --cap-drop all \
        --security-opt no-new-privileges:true \
        -p "127.0.0.1:${ANALYZER_PORT}:3000" \
        -v "$(pwd)/config/presidio_entrypoint.py:/entrypoint.py:ro" \
        "$ANALYZER_IMAGE"
    log "Analyzer started."
    wait_ready "$ANALYZER_CONTAINER" "$ANALYZER_PORT"
    # HTTP-path warmup: keep calling until we see two consecutive fast responses
    # (< 1s each), absorbing any one-shot JIT/CUDA/GC overhead.
    log "Warming up analyzer..."
    for _pass in 1 2 3 4 5; do
        _t=$(curl -sf --max-time 60 -o /dev/null -w "%{time_total}" \
            -X POST "http://127.0.0.1:${ANALYZER_PORT}/analyze" \
            -H "Content-Type: application/json" \
            -d '{"text":"My name is John, email john@example.com","language":"auto"}' 2>/dev/null || echo "60")
        log "  warmup pass ${_pass}: ${_t}s"
        # Stop once we get a sub-second response (model is warm)
        if awk "BEGIN{exit !($_t < 1.0)}"; then
            break
        fi
    done
    log "Analyzer warm."
}

start_anonymizer() {
    if container_running "$ANONYMIZER_CONTAINER"; then
        log "Anonymizer already running on :$ANONYMIZER_PORT"
        return
    fi
    stop_container "$ANONYMIZER_CONTAINER"

    log "Starting anonymizer on 127.0.0.1:$ANONYMIZER_PORT..."
    docker run -d \
        --name "$ANONYMIZER_CONTAINER" \
        --restart unless-stopped \
        -p "127.0.0.1:${ANONYMIZER_PORT}:3000" \
        "$ANONYMIZER_IMAGE"
    log "Anonymizer started."
    wait_ready "$ANONYMIZER_CONTAINER" "$ANONYMIZER_PORT"
}

wait_ready() {
    local name="$1"
    local port="$2"
    local max=30
    local i=0
    log "Waiting for $name to be ready..."
    while ! curl -sf --max-time 3 "http://127.0.0.1:${port}/health" &>/dev/null; do
        sleep 1
        i=$((i + 1))
        if [ "$i" -ge "$max" ]; then
            log "ERROR: $name did not become ready within ${max}s"
            docker logs "$name" | tail -20
            exit 1
        fi
    done
    log "$name is ready."
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

CMD="${1:-start}"

case "$CMD" in
    start)
        start_analyzer
        start_anonymizer
        log "Both services up."
        log "  Analyzer:  http://127.0.0.1:${ANALYZER_PORT}"
        log "  Anonymizer: http://127.0.0.1:${ANONYMIZER_PORT}"
        # Final warmup: keep calling until we see two consecutive sub-second
        # responses, ensuring the one-shot startup overhead is fully absorbed.
        log "Final warmup pass..."
        _fast_streak=0
        for _pass in $(seq 1 10); do
            _t=$(curl -sf --max-time 90 -o /dev/null -w "%{time_total}" \
                -X POST "http://127.0.0.1:${ANALYZER_PORT}/analyze" \
                -H "Content-Type: application/json" \
                -d '{"text":"Herr Müller, Berlin. My name is John, email john@example.com, SSN 123-45-6789","language":"auto"}' 2>/dev/null || echo "90")
            log "  pass ${_pass}: ${_t}s"
            if awk "BEGIN{exit !($_t < 1.0)}"; then
                _fast_streak=$((_fast_streak + 1))
                if [ "$_fast_streak" -ge 2 ]; then break; fi
            else
                _fast_streak=0
            fi
        done
        log "Analyzer ready."
        ;;

    stop)
        stop_container "$ANALYZER_CONTAINER"
        stop_container "$ANONYMIZER_CONTAINER"
        log "Both services stopped."
        ;;

    rebuild)
        stop_container "$ANALYZER_CONTAINER"
        build_analyzer
        start_analyzer
        start_anonymizer
        log "Rebuild complete. Both services up."
        ;;

    logs)
        docker logs -f "$ANALYZER_CONTAINER" &
        docker logs -f "$ANONYMIZER_CONTAINER" &
        wait
        ;;

    status)
        for name in "$ANALYZER_CONTAINER" "$ANONYMIZER_CONTAINER"; do
            if container_running "$name"; then
                echo "$name: running"
            elif container_exists "$name"; then
                echo "$name: stopped"
            else
                echo "$name: not created"
            fi
        done
        ;;

    *)
        echo "Usage: $0 [start|stop|rebuild|logs|status]"
        exit 1
        ;;
esac
