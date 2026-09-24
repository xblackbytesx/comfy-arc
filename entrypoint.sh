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
note() { printf 'comfy-arc: %s\n' "$*"; }

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
CACHE_DIR="$DATA_DIR/cache"

DIRS=(
  "$DATA_DIR" "$DATA_DIR/models" "$DATA_DIR/input" "$DATA_DIR/output"
  "$DATA_DIR/user" "$CACHE_DIR" "$CACHE_DIR/sycl" "$CACHE_DIR/home"
  "$CACHE_DIR/huggingface" "$CACHE_DIR/torch" "$TEMP_DIR"
)
mkdir -p "${DIRS[@]}"

# Caches belong with the data, not in a container layer that is thrown away.
export SYCL_CACHE_DIR=${SYCL_CACHE_DIR:-$CACHE_DIR/sycl}
export HF_HOME=${HF_HOME:-$CACHE_DIR/huggingface}
export TORCH_HOME=${TORCH_HOME:-$CACHE_DIR/torch}
export HOME="$CACHE_DIR/home"

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

# Run as a normal account, so generated images on the host belong to whoever
# owns the dataset rather than to root. Set PUID/PGID to that account. Starting
# the container with docker's own `user:` works too and is respected as is.
run_as=()
if [[ -n ${PUID:-}${PGID:-} ]]; then
  if [[ $(id -u) -ne 0 ]]; then
    note "PUID/PGID ignored, already running as $(id -u):$(id -g)"
  else
    puid=${PUID:-1000}
    pgid=${PGID:-$puid}
    [[ $puid =~ ^[0-9]+$ ]] || die "PUID must be numeric (got '$puid')"
    [[ $pgid =~ ^[0-9]+$ ]] || die "PGID must be numeric (got '$pgid')"

    getent group "$pgid" >/dev/null 2>&1 || groupadd -g "$pgid" comfy
    getent passwd "$puid" >/dev/null 2>&1 \
      || useradd -r -u "$puid" -g "$pgid" -M -d "$HOME" -s /sbin/nologin comfy

    # /dev/dri is owned by the render group on the host. Without it as a
    # supplementary group the GPU is invisible to a non-root process.
    groups=$pgid
    for dev in /dev/dri/render*; do
      [[ -e $dev ]] || continue
      render_gid=$(stat -c '%g' "$dev")
      if [[ $render_gid != "$pgid" ]]; then
        groups="$groups,$render_gid"
      fi
      break
    done

    # Only the directories this script creates, never recursively: a models
    # tree can be terabytes, and its files are the operator's to own. Fix any
    # leftovers once on the host with chown -R.
    chown "$puid:$pgid" "${DIRS[@]}"

    note "running as ${puid}:${pgid} (groups ${groups})"
    run_as=(setpriv --reuid "$puid" --regid "$pgid" --groups "$groups" --inh-caps=-all --)
  fi
fi

printf 'comfy-arc: python3 main.py %s %s\n' "${args[*]}" "$*"
exec ${run_as[@]+"${run_as[@]}"} python3 main.py "${args[@]}" "$@"
