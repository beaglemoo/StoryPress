# ComfyUI image generation

StoryPress uses ComfyUI's local HTTP API for image generation. The app does not bundle ComfyUI, Python, or model weights. A user installs the runtime separately with the project setup script; it lives in the user's Application Support area and starts only when the user runs the start script. The server binds to loopback (`127.0.0.1`) on port `8188` by default.

## Set up and start

Requirements are Apple Silicon macOS, `git`, `curl`, `uv`, and at least 60 GiB free on the volume that holds the runtime. Setup downloads approximately 32.44 GB of model files. Interrupted transfers leave resumable `.part` files. The setup script checks each completed file against the SHA-256 published by Hugging Face before accepting it.

```sh
scripts/setup-comfyui.sh --help
scripts/setup-comfyui.sh --dry-run
scripts/setup-comfyui.sh
scripts/start-comfyui.sh
```

The server stays in the foreground; press Control-C to stop it. It is not registered as a login item or background service. `STORYPRESS_RUNTIME_DIR` and `STORYPRESS_COMFYUI_DIR` can point setup and start at a different per-user runtime location. `STORYPRESS_COMFYUI_PORT` changes the local port. The default `STORYPRESS_COMFYUI_MEMORY_MODE=balanced` starts ComfyUI with `--lowvram`, `--disable-smart-memory`, and `--cpu-vae`; set it to `upstream` to use ComfyUI's built-in defaults.

Use `scripts/setup-comfyui.sh --skip-models` to install the runtime without downloading Qwen weights. The bundled Qwen workflows still require their three checkpoint files in the ComfyUI model folders listed below.

The setup pins ComfyUI at commit [`93810483a4739a1588236919a3128d3070244146`](https://github.com/Comfy-Org/ComfyUI/commit/93810483a4739a1588236919a3128d3070244146). It uses Python 3.13 and the Apple Silicon PyTorch package versions listed in Comfy-Org's [macOS requirements manifest](https://github.com/Comfy-Org/ComfyUI-Standalone-Environments/blob/444a502dcee92e651b6ba2311c781ad66a924848/requirements-mac.txt): PyTorch 2.12.1, torchvision 0.27.1, and torchaudio 2.11.0. ComfyUI currently declares `SQLAlchemy>=2.0.0`; setup constrains it to `<2.1` because the published SQLAlchemy 2.1.0 source package currently has invalid duplicate optional-dependency metadata. The external runtime writes a `runtime-provenance.json` with the versions it actually installed and the MPS availability check.

## Model files and license

Setup fetches only the three required BF16 files from [`Comfy-Org/Qwen-Image-2.1`](https://huggingface.co/Comfy-Org/Qwen-Image-2.1), pinned to repository revision [`9a44dbdb47cefd046be9c0a13476192f34c8db8e`](https://huggingface.co/Comfy-Org/Qwen-Image-2.1/tree/9a44dbdb47cefd046be9c0a13476192f34c8db8e).

| ComfyUI model folder | File | Size | SHA-256 |
| --- | --- | ---: | --- |
| `models/diffusion_models` | `qwen_image_2.1_bf16.safetensors` | 14,230,280,616 bytes | `89f4158d066cc33906a199fca85634f766892dd78f49b6698dabf187ac86c4bc` |
| `models/text_encoders` | `qwen3vl_8b_bf16.safetensors` | 17,534,334,616 bytes | `68bdc82bc1b66851162ae656225e7e2068166b603db19bd5d5a3b90eb12669a9` |
| `models/vae` | `qwen_image_2.1_vae_bf16.safetensors` | 675,509,688 bytes | `bb21f7473051e1ac368515dd3f2e15cd44d7a11748ee8823e1ddca3e4876b7c9` |

The Qwen weights are licensed under the [Qwen Research License](https://github.com/QwenLM/Qwen-Image-2.1/blob/fb7ae1d1f9611cd91524d03c53c5246b36ac8577/LICENSE). The agreement defines “Non-Commercial” as research or evaluation and grants use of the materials for non-commercial purposes only. Commercial use requires a separate license from Qwen. Review that license before installing or using the weights. The StoryPress source and signed app do not include these model files.

The bundled graphs follow the official [Qwen Image 2.1 text-to-image template](https://github.com/Comfy-Org/workflow_templates/blob/a7acaf8cee9ccccdaf4b26ce04a9fced4c4d13de/templates/image_qwen_image_2_1_t2i.json) and [image-edit template](https://github.com/Comfy-Org/workflow_templates/blob/a7acaf8cee9ccccdaf4b26ce04a9fced4c4d13de/templates/image_qwen_image_2_1_image_edit.json), converted to ComfyUI API prompt graphs. The upstream templates currently select INT8 ConvRot weights. StoryPress selects the published BF16 files, explicitly places the Qwen text encoder on CPU, and does not assume that a CUDA-oriented quantized checkpoint runs on MPS.

## API graph contract

The bundled graph resources are API prompt dictionaries for `POST /prompt`, wrapped as `{"prompt": graph}` by the app. Both `{{prompt}}` and `{{seed}}` are quoted string tokens so the resources remain valid JSON. After decoding, the app must set the prompt value as a string and replace the seed token with an integer before encoding the graph for ComfyUI.

- `qwen-image-2.1-api.json` generates a 1024 × 1024 image. It follows the official template's `EmptyLatentImage` path; the pinned ComfyUI sampler expands and rescales this empty latent to Qwen Image 2.1's 64-channel, 16× latent format before sampling.
- `StoryPress-Qwen-Image-2.1-Reference.api.json` uploads one reference image and connects it to the `images.image_1` API slot. `{{reference_image}}` is the filename returned by ComfyUI's upload endpoint; it is not a local file path.
- Both graphs save output through `SaveImage` node `8`. The app reads the resulting filename from the prompt history response and fetches it through ComfyUI's `/view` endpoint.
- The graphs use 25 steps, CFG 1, Euler sampling, and the simple scheduler, matching the current official template defaults.

## Verified runtime

The bundled API graphs were exercised on an Apple M5 Pro system with 64 GB unified memory, using Python 3.13.14, PyTorch 2.12.1, and the default `balanced` start mode (`--lowvram --disable-smart-memory --cpu-vae`). The BF16 Qwen text-encoder checkpoint ran on CPU, where ComfyUI reported a float16 runtime dtype; the BF16 image model ran on MPS.

The production text-to-image graph completed at its bundled 1024 × 1024 size and 25 steps. ComfyUI reported 120.18 seconds from job execution through decode and save, including about 86 seconds for sampling. The saved PNG was inspected and showed a complete, coherent illustration. During sampling, macOS reported 57–64% system-wide memory free; after stopping this foreground server, the reading recovered to 90%.

The reference graph was also exercised through the same multipart upload fields used by the app. Its uploaded filename resolved at `TextEncodeQwenImage21` input `images.image_1`, and a one-step run with a 512 × 512 reference returned a non-empty 512 × 512 PNG. That one-step check confirms the upload and graph connection; it is not a measure of finished-image quality. The bundled graph uses 25 steps for normal generation.

API routes used by the app are `GET /object_info`, `POST /upload/image`, `POST /prompt`, `GET /history/{prompt_id}`, and `GET /view`. They carry story prompts and any reference image over HTTP to the configured ComfyUI endpoint. With the default local runtime they stay on the same Mac. ComfyUI stores generated files in its runtime output directory.

## Apple Silicon behavior

ComfyUI selects PyTorch's MPS backend on supported Apple Silicon systems. The setup checks that MPS is available and records whether a small BF16 matrix operation is supported. That check does not prove that the full Qwen graph can execute; model loading, text encoding, sampling, and VAE decode must all be exercised on the target runtime before claiming image-generation support. The start script enables PyTorch's MPS CPU fallback for individual unsupported operations. It does not enable CUDA-specific quantization or force an unverified low-precision path.

If MPS or the model graph fails, keep the exact traceback with the ComfyUI, Python, and PyTorch versions from `runtime-provenance.json`. The local runtime can be removed independently from the app by deleting its configured runtime directory after preserving any output images the user wants to keep.
