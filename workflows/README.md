# Workflows

Ready-made ComfyUI workflows for a 12 GB Arc card (tuned on a B580 with 64 GB
RAM). They use core nodes only, so they need nothing beyond this image.

| File | What it does |
|---|---|
| `flux3-klein-t2i-4k.json` | FLUX 3 Image Klein text to image at about 1 MP, decoded by PiD straight into a 4x image (4096 px square) |
| `seedvr2-upscale.json` | SeedVR2 7B restoration upscale of any image, 2x by default |

## Loading

Drag a `.json` onto the ComfyUI canvas. To have them listed in the Workflows
sidebar instead, copy them into the user directory:

```bash
cp workflows/*.json data/user/default/workflows/
```

Each workflow has a note listing its files and the knobs worth turning.

## Models

Every file is chosen to load completely on 12 GB. A checkpoint that only loads
partially tends to end in `UR_RESULT_ERROR_OUT_OF_RESOURCES` on Arc (see
"When a model does not fit" in the main README), so the bf16 Klein (11.1 GB)
is deliberately not used.

| Folder | File | Size | Used by |
|---|---|---|---|
| diffusion_models | flux3-image-klein-int8-convrot.safetensors | 5.8 GB | Klein |
| text_encoders | qwen3vl_4b_int8_convrot.safetensors | 4.9 GB | Klein |
| text_encoders | qwen3.5_9b_flux3_prompt_upsampler_w4a8.safetensors | 6.7 GB | Klein |
| vae | flux2-vae.safetensors | 0.3 GB | Klein |
| diffusion_models | pid_1.5_flux2_1024_to_4096_4step_bf16.safetensors | 2.8 GB | Klein |
| text_encoders | gemma_2_2b_it_elm_fp8_scaled.safetensors | 2.6 GB | Klein |
| diffusion_models | seedvr2_7b_int8_convrot.safetensors | 8.3 GB | SeedVR2 |
| vae | seedvr2_ema_vae_fp16.safetensors | 0.5 GB | SeedVR2 |

The int8 files need a working `torch._int_mm` on XPU. To check an image:

```bash
docker exec comfy-arc python3 -c "import torch; a=torch.randint(-128,127,(256,256),dtype=torch.int8,device='xpu'); print(torch._int_mm(a,a).dtype)"
```

`torch.int32` means it works.

## Downloading

The FLUX 3 repo is gated: accept the license on
[its Hugging Face page](https://huggingface.co/black-forest-labs/flux-3-image-klein-comfy)
first. The `hf` CLI ships in the image, and each repo's folders match ComfyUI's,
so everything lands under `/data/models`. `HF_HOME` keeps the login on the
mount. With `PUID`/`PGID` set, add `-u <PUID>:<PGID>` so the files are yours.

```bash
x="docker exec -e HF_HOME=/data/cache/huggingface comfy-arc"
docker exec -it -e HF_HOME=/data/cache/huggingface comfy-arc hf auth login

$x hf download black-forest-labs/flux-3-image-klein-comfy \
  diffusion_models/flux3-image-klein-int8-convrot.safetensors \
  text_encoders/qwen3vl_4b_int8_convrot.safetensors \
  text_encoders/qwen3.5_9b_flux3_prompt_upsampler_w4a8.safetensors \
  vae/flux2-vae.safetensors \
  --local-dir /data/models

$x hf download Comfy-Org/PixelDiT \
  diffusion_models/pid_1.5_flux2_1024_to_4096_4step_bf16.safetensors \
  text_encoders/gemma_2_2b_it_elm_fp8_scaled.safetensors \
  --local-dir /data/models

$x hf download Comfy-Org/SeedVR2 \
  diffusion_models/seedvr2_7b_int8_convrot.safetensors \
  vae/seedvr2_ema_vae_fp16.safetensors \
  --local-dir /data/models
```

## Memory

ComfyUI swaps the models through VRAM one at a time, and with smart memory on
it keeps the ones it is not using in RAM. The Klein workflow holds about 23 GB
of weights in total, plus about 4.4 GB of baseline; `COMFY_IDLE_UNLOAD`
returns it once you stop queueing.

A container memory limit below that is fine: ComfyUI reads the cgroup limit
and evicts models to stay inside it, at the cost of reloading them from disk
more often.

## Regenerating

These files are built from nodes in the official templates package that the
pinned ComfyUI ships (`comfyui-workflow-templates`), so their serialization
matches the bundled frontend. After a ComfyUI upgrade, load each one and save
it again if the frontend reports changed nodes.
