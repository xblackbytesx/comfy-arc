# comfy-arc

A deterministic [ComfyUI](https://github.com/Comfy-Org/ComfyUI) container image
for **Intel Arc** GPUs, using PyTorch's native XPU backend.

Everything is pinned at build time: ComfyUI, PyTorch, every custom node and
every Python package. Nothing installs itself while the container runs, and
ComfyUI-Manager is deliberately absent. A container built from a given commit
of this repo is the same thing every time it starts.

[![CI](https://github.com/xblackbytesx/comfy-arc/actions/workflows/ci.yml/badge.svg)](https://github.com/xblackbytesx/comfy-arc/actions/workflows/ci.yml)
[![Release](https://github.com/xblackbytesx/comfy-arc/actions/workflows/release.yml/badge.svg)](https://github.com/xblackbytesx/comfy-arc/actions/workflows/release.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

## Why

Most ComfyUI images install the application, its custom nodes and their Python
packages into a mounted folder, then let a node manager `pip install` more of
them at runtime. It is convenient until a node's requirements move a shared
library, and then an image that booted yesterday does not boot today.

comfy-arc puts the application in the image and only data in the mounts:

- **The image** holds ComfyUI, the nodes from [`nodes.list`](nodes.list) and
  every Python package.
- **The mount** holds models, inputs, outputs and user settings. Delete it and
  ComfyUI still starts.
- **Upgrades** are a new image tag, and rolling back is the previous tag.

## Requirements

- An Intel Arc GPU (A-series or B-series) with the kernel driver loaded on the
  host, so `/dev/dri` exists. Nothing else is needed on the host: the Intel
  compute runtime and Level Zero live inside the image.
- Docker.

## Quick start

```bash
cp .env.example .env         # optional, every value has a default
docker compose up -d
```

Or without this repo:

```bash
docker run -d --name comfy-arc \
  --device /dev/dri:/dev/dri --ipc host \
  -p 8188:8188 -v "$PWD/data:/data" \
  ghcr.io/xblackbytesx/comfy-arc:latest
```

Then open `http://<host>:8188`.

## Configuration

Set these as environment variables. Anything you pass after the image name is
appended to ComfyUI's command line and wins over them.

| Variable | Default | Effect |
|---|---|---|
| `COMFY_SMART_MEMORY` | `off` | `on` keeps a model in VRAM between runs (faster repeats). `off` hands VRAM back after every run. |
| `COMFY_ASYNC_OFFLOAD` | `on` | Overlaps weight transfers with compute. `on`, `off`, or a stream count such as `4`. |
| `COMFY_CACHE` | `classic` | Node result cache: `classic`, `none` (least RAM, re-executes everything) or `lru:N`. |
| `COMFY_RESERVE_VRAM` | unset | GB of VRAM ComfyUI leaves unused. |
| `COMFY_VRAM_HEADROOM` | unset | GB kept free, counting other processes' usage too. |
| `COMFY_API_NODES` | `on` | `off` stops the frontend contacting remote API services. |
| `COMFY_PREVIEW_METHOD` | unset | Passed to `--preview-method`, for example `none`. |
| `COMFY_EXTRA_ARGS` | unset | Extra flags, verbatim. |
| `COMFY_HOST`, `COMFY_PORT` | `0.0.0.0`, `8188` | Listen address and port. |
| `COMFY_DATA_DIR` | `/data` | Where models, input, output, user and the kernel cache live. |

Invalid values fail at startup with a message naming the variable, rather than
falling back to a default you did not ask for.

The container prints the command it assembled, so `docker logs` always shows
what a running instance is actually doing.

## Data layout

```
/data/models        checkpoints, LoRAs, VAEs
/data/input         images in
/data/output        images out
/data/user          settings, and default/workflows
/data/cache/sycl    compiled GPU kernels, see Performance
```

## Sharing the GPU

If something else uses the same card, an LLM server for instance, leave
`COMFY_SMART_MEMORY=off` so VRAM goes back after each run, and consider
`COMFY_VRAM_HEADROOM`. ComfyUI has no idle timer, so to drop everything on
demand:

```bash
curl -s -X POST http://127.0.0.1:8188/free \
  -H 'Content-Type: application/json' \
  -d '{"unload_models": true, "free_memory": true}'
```

Run that from cron for automatic idle unloading.

## Custom nodes

[`nodes.list`](nodes.list) is the whole node set, one per line, each pinned to
a commit:

```
rgthree-comfy    https://github.com/rgthree/rgthree-comfy.git    2c5342a8cb0eaecaabf61435a5f37dd594c510ba
```

Add a line, rebuild, and the image carries exactly that set. To find a repo's
current tip: `git ls-remote https://github.com/<owner>/<repo> HEAD`. CI rejects
anything that is not a full 40 character commit, because a branch name would
make two builds of the same commit differ.

A node whose requirements clash with the pinned PyTorch fails the build, which
is the point: it fails for you at build time rather than at 3am on a Tuesday.

## Performance

- **Compiled kernels are cached** in `/data/cache/sycl`
  (`SYCL_CACHE_PERSISTENT`), so the first-generation stall happens once rather
  than on every container start.
- **Async weight offloading** is on by default, which suits Arc's PCIe
  transfers.
- **Free VRAM reporting** is enabled (`ZES_ENABLE_SYSMAN`), which ComfyUI's
  memory management uses to decide what fits.
- **Ops without an XPU kernel fall back to the CPU**
  (`PYTORCH_ENABLE_XPU_FALLBACK=1`). Set it to `0` to find out which ops those
  are, at the cost of a hard failure instead of a slow one.

## Versions

Pins live in the [`Dockerfile`](Dockerfile) (`COMFYUI_VERSION`,
`TORCH_VERSION`) and in `nodes.list`. To see exactly what an image contains,
without starting it:

```bash
docker run --rm --entrypoint cat \
  ghcr.io/xblackbytesx/comfy-arc:latest /opt/comfy-arc-packages.txt
```

Tagged releases publish `vX.Y.Z`, `X.Y`, `X` and `latest`.

## Building locally

```bash
docker compose build          # or: docker build -t comfy-arc:dev .
```

The build fetches the Intel runtime, the PyTorch XPU wheels and the node
requirements. It takes a while and produces a large image; after that, nothing
downloads at runtime.

## Verifying

```bash
docker compose logs --tail 30 comfy-arc
curl -s http://127.0.0.1:8188/system_stats | head -20
```

The log should name the device, for example
`Device: xpu:0 Intel(R) Arc(TM) B580 Graphics`, with a `pytorch version: 2.x+xpu`.
If it reports a CPU device instead, `/dev/dri` is not reaching the container.

## Licence

GPL-3.0-or-later, see [LICENSE](LICENSE). ComfyUI and the bundled custom nodes
carry their own licences.
