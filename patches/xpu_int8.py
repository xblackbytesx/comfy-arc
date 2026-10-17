"""Let int8 and w4a8 checkpoints use real int8 kernels on Intel Arc.

Upstream gates both layers on NVIDIA:

- ComfyUI's supports_int8_compute() returns False for every XPU, so each int8
  layer is dequantized to bf16 on every forward pass.
- comfy-kitchen reads the compute capability through torch.cuda only, so on
  XPU it is None and the Triton int8_linear / w4a8_int8_linear kernels are
  rejected for the eager fallback, which rebuilds the weight on every call.

Measured on a B580 with FLUX 3 Klein's w4a8 prompt upsampler: 2.5 s per token
before, 0.15 s after. Each edit must match exactly once, so an upstream change
fails the build instead of quietly dropping the fix. When a build fails here,
check whether upstream now handles XPU itself and delete the edit.
"""
import importlib.util
import os
import sys


def patch(path, old, new):
    with open(path) as f:
        text = f.read()
    count = text.count(old)
    if count != 1:
        sys.exit(f"xpu_int8: expected one match in {path}, found {count}")
    with open(path, "w") as f:
        f.write(text.replace(old, new))
    print(f"xpu_int8: patched {path}")


comfyui = sys.argv[1]

patch(
    os.path.join(comfyui, "comfy", "model_management.py"),
    """    # https://github.com/pytorch/pytorch/issues/141287
    if (device is not None and is_device_mps(device)) or mps_mode():
        return False

    if is_intel_xpu():
        return False
""",
    """    # https://github.com/pytorch/pytorch/issues/141287
    if (device is not None and is_device_mps(device)) or mps_mode():
        return False
""",
)

# (8, 0) is the floor the Triton int8 kernels declare. The only other
# capability-gated Triton kernel (nvfp4) is limited to CUDA devices anyway.
kitchen = importlib.util.find_spec("comfy_kitchen").submodule_search_locations[0]
patch(
    os.path.join(kitchen, "registry.py"),
    """            except Exception:
                return None
        return None
""",
    """            except Exception:
                return None
        if hasattr(torch, "xpu") and torch.xpu.is_available():
            return (8, 0)
        return None
""",
)
