# syntax=docker/dockerfile:1
################################################################################
# comfy-arc: ComfyUI for Intel Arc (XPU), built to be deterministic.
#
#   - every version is pinned here or in nodes.list
#   - nothing installs itself at runtime, and ComfyUI-Manager is not present
#   - the image holds the application, the mounts hold only data
#
# A container built from a given commit of this repo is always the same thing.
# To change what is inside, edit a pin and rebuild.
#
# The Intel runtime package set and the PyTorch XPU wheel index follow
# YanWenKun/ComfyUI-Docker (xpu), the reference for running ComfyUI on Arc.
################################################################################

FROM fedora:44

# pipefail so a failing command in a pipe fails the build instead of feeding
# the next one empty input.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG COMFYUI_VERSION=v0.41.3
ARG TORCH_VERSION=2.14.1
# torchaudio XPU builds stopped at 2.11 (upstream is in maintenance), and
# ComfyUI core no longer needs it; it stays for custom nodes that do.
ARG TORCHVISION_VERSION=0.29.1
ARG TORCHAUDIO_VERSION=2.11.0
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/xpu

LABEL org.opencontainers.image.title="comfy-arc" \
      org.opencontainers.image.description="Deterministic ComfyUI image for Intel Arc GPUs (XPU)" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

# Build-time only, so ARG rather than ENV: none of this should linger in the
# runtime environment of the image.
ARG PIP_ROOT_USER_ACTION=ignore
ARG PIP_NO_CACHE_DIR=1
ARG PIP_NO_BUILD_ISOLATION=1
ARG CMAKE_POLICY_VERSION_MINIMUM=3.5

ENV PYTHONUNBUFFERED=1

# System packages. intel-compute-runtime and Level Zero are what torch.xpu
# talks to; the host supplies only the kernel driver and /dev/dri. ffmpeg comes
# from rpmfusion. The toolchain is for wheels that build from source, and for
# Triton (COMFY_TRITON), which compiles its XPU launcher with g++ on first use
# against the Level Zero headers and libze_loader.so from the -devel package;
# the SYCL half of that comes from the intel-sycl-rt wheel torch pulls in.
RUN dnf install -y --nogpgcheck \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-44.noarch.rpm" \
 && dnf install -y \
      python3.14-devel python3-pip python3-wheel python3-setuptools python3-cython \
      python3-cmake make ninja-build gcc gcc-c++ \
      git curl \
      shadow-utils util-linux \
      intel-compute-runtime intel-level-zero oneapi-level-zero oneapi-level-zero-devel \
      intel-opencl intel-igc intel-ocloc clinfo \
      mesa-libGL mesa-libEGL ffmpeg \
 && dnf clean all \
 && rm -rf /var/cache/dnf

RUN python3 -m pip install --upgrade pip wheel setuptools packaging \
 && python3 -m pip install "torch==${TORCH_VERSION}" \
      "torchvision==${TORCHVISION_VERSION}" "torchaudio==${TORCHAUDIO_VERSION}" \
      --index-url "${TORCH_INDEX_URL}"

# The XPU wheels ship the Intel runtime (libsycl and friends) into
# /usr/local/lib through the wheel data scheme, and Fedora does not search
# there. Register that and torch's own lib directory with the dynamic loader,
# which beats LD_LIBRARY_PATH: it survives dropping privileges and any
# environment the operator passes in. The import is a smoke test, so a broken
# library path fails the build instead of every container start.
RUN { echo /usr/local/lib; \
      python3 -c "import sysconfig, os; print(os.path.join(sysconfig.get_paths()['platlib'], 'torch', 'lib'))"; \
    } > /etc/ld.so.conf.d/comfy-arc.conf \
 && ldconfig \
 && python3 -c "import torch; print('torch', torch.__version__, 'xpu:', torch.version.xpu)"

# Constraints stop any later requirements file from moving PyTorch, the one
# package that has to match the Intel runtime installed above.
RUN python3 -m pip list --format=freeze | grep -E '^(torch|torchvision|torchaudio)==' \
      > /etc/comfy-arc-constraints.txt \
 && cat /etc/comfy-arc-constraints.txt

WORKDIR /opt
RUN git clone --depth 1 --branch "${COMFYUI_VERSION}" \
      https://github.com/Comfy-Org/ComfyUI.git comfyui \
 && rm -rf comfyui/.git \
 && python3 -m pip install -r comfyui/requirements.txt -c /etc/comfy-arc-constraints.txt

# Custom nodes, each pinned to a commit in nodes.list. A full clone is needed
# because a shallow one can not check out an arbitrary commit.
COPY nodes.list /tmp/nodes.list
WORKDIR /opt/comfyui/custom_nodes
# The braces keep an empty list (comments only) from failing under pipefail.
RUN set -eu; \
    { grep -vE '^\s*(#|$)' /tmp/nodes.list || true; } | while IFS=' ' read -r name url sha; do \
      echo "== ${name} @ ${sha}"; \
      git clone --quiet "${url}" "${name}"; \
      git -C "${name}" checkout --quiet --detach "${sha}"; \
      rm -rf "${name}/.git"; \
      if [ -f "${name}/requirements.txt" ]; then \
        python3 -m pip install -r "${name}/requirements.txt" -c /etc/comfy-arc-constraints.txt; \
      fi; \
    done; \
    rm -f /tmp/nodes.list

# Upstream only lets NVIDIA run int8 and w4a8 checkpoints on int8 kernels; on
# Arc they are dequantized on every call, which makes an LLM prompt upsampler
# take minutes. The script explains both edits and fails the build if either
# no longer matches, so an upgrade cannot drop the fix silently.
COPY patches/xpu_int8.py /tmp/xpu_int8.py
RUN python3 /tmp/xpu_int8.py /opt/comfyui && rm /tmp/xpu_int8.py

# A manifest of what ended up inside, readable without starting the app:
#   docker run --rm --entrypoint cat <image> /opt/comfy-arc-packages.txt
RUN python3 -m pip freeze > /opt/comfy-arc-packages.txt

# Intel runtime tuning. SYCL_CACHE_PERSISTENT keeps compiled kernels between
# runs, which removes most of the first-generation stall; the cache lives under
# the data mount so it survives container replacement. ZES_ENABLE_SYSMAN lets
# the runtime report free VRAM, which ComfyUI's memory management uses.
# PYTORCH_ENABLE_XPU_FALLBACK sends ops without an XPU kernel to the CPU rather
# than failing the run; set it to 0 to see where that is happening.
ENV SYCL_CACHE_PERSISTENT=1 \
    ZES_ENABLE_SYSMAN=1 \
    PYTORCH_ENABLE_XPU_FALLBACK=1

COPY --chmod=755 entrypoint.sh idle-unload.sh /usr/local/bin/

WORKDIR /opt/comfyui
EXPOSE 8188
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
