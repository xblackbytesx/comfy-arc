#!/usr/bin/env bash
#
# Hand memory back when nothing has been queued for a while.
#
# ComfyUI keeps a model loaded after a run so the next one starts quickly, and
# has no idle timer of its own. This polls the queue and, once it has been
# empty for COMFY_IDLE_UNLOAD seconds, asks ComfyUI to unload models and drop
# its execution cache. It never fires while a prompt is running or queued, and
# fires once per idle period rather than repeatedly.
#
# Started in the background by entrypoint.sh when COMFY_IDLE_UNLOAD is set.
set -euo pipefail

BASE="http://127.0.0.1:${COMFY_PORT:-8188}"
IDLE=${COMFY_IDLE_UNLOAD:-0}
POLL=${COMFY_IDLE_POLL:-15}

log() { printf 'comfy-arc idle: %s\n' "$*"; }

[[ $IDLE =~ ^[0-9]+$ ]] || { log "COMFY_IDLE_UNLOAD must be seconds (got '$IDLE')"; exit 1; }
[[ $POLL =~ ^[0-9]+$ ]] || { log "COMFY_IDLE_POLL must be seconds (got '$POLL')"; exit 1; }
[[ $IDLE -gt 0 ]] || exit 0

# Busy means either list in /queue has something in it: queue_running while a
# prompt executes, queue_pending for anything waiting behind it.
queue_busy() {
  local body
  body=$(curl -fsS --max-time 5 "$BASE/queue") || return 2
  python3 -c '
import json, sys
try:
    q = json.load(sys.stdin)
except ValueError:
    sys.exit(2)
sys.exit(0 if (q.get("queue_running") or q.get("queue_pending")) else 1)
' <<< "$body"
}

last_busy=$(date +%s)
armed=1   # something has happened since the last unload, so an unload is due

while true; do
  sleep "$POLL"

  status=0
  queue_busy || status=$?
  case $status in
    0)  # busy: a prompt is running or waiting
        last_busy=$(date +%s)
        armed=1
        continue ;;
    1)  # idle, carry on below
        ;;
    *)  # server not up yet, restarting, or a malformed reply
        continue ;;
  esac

  [[ $armed -eq 1 ]] || continue
  idle_for=$(( $(date +%s) - last_busy ))
  [[ $idle_for -ge $IDLE ]] || continue

  if curl -fsS --max-time 30 -X POST "$BASE/free" \
      -H 'Content-Type: application/json' \
      -d '{"unload_models": true, "free_memory": true}' >/dev/null; then
    log "idle ${idle_for}s, released models and cache"
    armed=0
  else
    log "idle ${idle_for}s, but /free failed; will retry"
  fi
done
