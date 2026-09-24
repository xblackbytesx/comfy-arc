# Agent notes

The canonical architecture contract for this repo.

A ComfyUI container image for Intel Arc (XPU) whose single promise is that a
build of a given commit always produces the same running software. Everything
below exists to keep that true.

## Invariants

1. **Nothing installs at runtime.** No package manager, no node manager, no
   `pip install` in the entrypoint. ComfyUI-Manager is deliberately not in the
   image, and must not be added: it installs packages on startup, which is how
   these setups drift into "booted yesterday, not today".
2. **Every version is pinned in the repo.** `COMFYUI_VERSION` and
   `TORCH_VERSION` in `Dockerfile`, one commit per node in `nodes.list`. A
   branch name is never acceptable; CI fails on anything that is not a full
   40 character sha.
3. **PyTorch is immovable.** `/etc/comfy-arc-constraints.txt` is generated
   right after torch is installed and passed as `-c` to every later `pip
   install`, so a node's requirements cannot swap the build that matches the
   Intel runtime.
4. **The image holds the application, the mount holds data.** Only
   `$COMFY_DATA_DIR` (default `/data`) is written to, plus the temp dir.
   Deleting the mount must never stop ComfyUI from starting. Custom nodes stay
   inside the image, which is why `--base-directory` is not used: it would
   relocate `custom_nodes` onto the mount.
5. **Configuration is environment variables, resolved in `entrypoint.sh`.**
   Bad values exit non-zero with a message naming the variable. Never quietly
   fall back to a default.
6. **The assembled command is printed** before exec, so a container states what
   it is running.
7. **Privileges drop when asked, never silently.** With `PUID`/`PGID` set and
   the container started as root, `entrypoint.sh` creates that account, adds
   the group owning `/dev/dri/render*` so the GPU stays visible, chowns the
   directories it creates (never recursively: a models tree can be terabytes)
   and execs through `setpriv`. Started with docker's `user:`, it says so and
   changes nothing. Caches (SYCL, Hugging Face, torch, HOME) live under
   `$COMFY_DATA_DIR/cache` so they survive container replacement.

## Layout

| Path | Role |
|---|---|
| `Dockerfile` | the image: Intel runtime, PyTorch XPU, ComfyUI, nodes, manifest |
| `nodes.list` | `<name> <git url> <commit>`, one node per line |
| `entrypoint.sh` | environment variables to ComfyUI flags, then exec |
| `docker-compose.yml` | reference deployment, pulls GHCR or builds locally |
| `.github/workflows/ci.yml` | hadolint, shellcheck, compose config, pin check |
| `.github/workflows/release.yml` | tag or manual run to GHCR |

## Making changes

- **Upgrade ComfyUI or PyTorch:** change the ARG, rebuild, tag a release.
- **Add or update a node:** one line in `nodes.list`, rebuild. Its
  `requirements.txt` is installed under the constraints file automatically.
- **New tunable:** add it to `entrypoint.sh` with a default and validation, to
  the table in `README.md`, and to `.env.example`. Compose passes it through.
- **Never** add a step that fetches anything at container start.

## Testing without Docker

`entrypoint.sh` is testable on its own: put a stub `python3` on `PATH` that
echoes its arguments, set `COMFY_DATA_DIR` to a temp dir, and check the flags
for each configuration plus the failure cases. `shellcheck entrypoint.sh` and
`python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml'))"` cover
the rest. The image build itself needs a real Docker daemon.

## Release

Tag `vX.Y.Z` and push. The workflow builds `linux/amd64` only (Arc is x86) and
publishes `vX.Y.Z`, `X.Y`, `X` and `latest` to
`ghcr.io/<owner>/comfy-arc`. Manual runs publish a short-sha tag and leave
`latest` alone.
