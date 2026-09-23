#!/usr/bin/env bash
#
# Turn environment variables into ComfyUI's command line, then exec it.
#
# Every setting is optional and has a documented default (see README.md). The
# resulting command is printed before it runs, so a container always states
# what it is doing. Anything passed to `docker run` after the image name is
# appended last and therefore wins.
set -euo pipefail

die() { printf 'entrypoint: %s\n' "$*" >&2; exit 1; }

# Accept the usual spellings for a boolean and reject anything else, so a typo
# in a compose file fails loudly instead of silently picking a default.
is_on() {
  case "${2,,}" in
    on|true|yes|1|enabled)   return 0 ;;
    off|false|no|0|disabled) return 1 ;;
    *) die "$1 must be on or off (got '$2')" ;;
  esac
}

DATA_DIR=${COMFY_DATA_DIR:-/data}
TEMP_DIR=${COMFY_TEMP_DIR:-/tmp/comfyui}

mkdir -p \
  "$DATA_DIR/models" "$DATA_DIR/input" "$DATA_DIR/output" "$DATA_DIR/user" \
  "$DATA_DIR/cache/sycl" "$TEMP_DIR"

# Kernel cache, only useful when it outlives the container.
export SYCL_CACHE_DIR=${SYCL_CACHE_DIR:-$DATA_DIR/cache/sycl}

args=(
  --listen "${COMFY_HOST:-0.0.0.0}"
  --port "${COMFY_PORT:-8188}"
  --models-directory "$DATA_DIR/models"
  --input-directory "$DATA_DIR/input"
  --output-directory "$DATA_DIR/output"
  --user-directory "$DATA_DIR/user"
  --temp-directory "$TEMP_DIR"
)

# Smart memory keeps a model in VRAM after a run so the next one starts fast.
# Turn it off to hand VRAM back between runs, which is what you want when
# something else (an LLM server, another GPU job) shares the card.
if ! is_on COMFY_SMART_MEMORY "${COMFY_SMART_MEMORY:-off}"; then
  args+=(--disable-smart-memory)
fi

# Async weight offloading overlaps transfers with compute. "on" uses ComfyUI's
# default stream count; a number sets it explicitly.
async=${COMFY_ASYNC_OFFLOAD:-on}
if [[ $async =~ ^[0-9]+$ ]]; then
  args+=(--async-offload "$async")
elif is_on COMFY_ASYNC_OFFLOAD "$async"; then
  args+=(--async-offload)
else
  args+=(--disable-async-offload)
fi

# Node result cache: classic keeps the last run's results, none keeps nothing
# (least RAM, re-executes everything), lru:N keeps N results.
cache=${COMFY_CACHE:-classic}
case "$cache" in
  classic) ;;
  none)    args+=(--cache-none) ;;
  lru:*)   n=${cache#lru:}
           [[ $n =~ ^[0-9]+$ ]] || die "COMFY_CACHE lru size must be a number (got '$n')"
           args+=(--cache-lru "$n") ;;
  *)       die "COMFY_CACHE must be classic, none or lru:N (got '$cache')" ;;
esac

# Leave VRAM alone for other software. RESERVE is ComfyUI's own reservation;
# HEADROOM additionally counts what other processes are using.
[[ -n ${COMFY_RESERVE_VRAM:-} ]] && args+=(--reserve-vram "$COMFY_RESERVE_VRAM")
[[ -n ${COMFY_VRAM_HEADROOM:-} ]] && args+=(--vram-headroom "$COMFY_VRAM_HEADROOM")

# API nodes reach out to remote services; off keeps the frontend local.
is_on COMFY_API_NODES "${COMFY_API_NODES:-on}" || args+=(--disable-api-nodes)

[[ -n ${COMFY_PREVIEW_METHOD:-} ]] && args+=(--preview-method "$COMFY_PREVIEW_METHOD")

# Anything else, verbatim, for flags this wrapper does not model.
if [[ -n ${COMFY_EXTRA_ARGS:-} ]]; then
  read -r -a extra <<< "$COMFY_EXTRA_ARGS"
  args+=("${extra[@]}")
fi

printf 'comfy-arc: python3 main.py %s %s\n' "${args[*]}" "$*"
exec python3 main.py "${args[@]}" "$@"
