#!/usr/bin/env bash
set -euo pipefail

readonly COMFYUI_REPOSITORY="https://github.com/Comfy-Org/ComfyUI.git"
readonly COMFYUI_COMMIT="93810483a4739a1588236919a3128d3070244146"
readonly MODEL_REPOSITORY="Comfy-Org/Qwen-Image-2.1"
readonly MODEL_REVISION="9a44dbdb47cefd046be9c0a13476192f34c8db8e"
readonly TORCH_MANIFEST_COMMIT="444a502dcee92e651b6ba2311c781ad66a924848"
readonly REQUIRED_FREE_KIB=$((60 * 1024 * 1024))

RUNTIME_DIR="${STORYPRESS_RUNTIME_DIR:-${HOME}/Library/Application Support/StoryPressRuntime}"
COMFY_DIR="${STORYPRESS_COMFYUI_DIR:-${RUNTIME_DIR}/ComfyUI}"
PYTHON_VERSION="${STORYPRESS_PYTHON_VERSION:-3.13}"
DRY_RUN=0
SKIP_MODELS=0

usage() {
  cat <<'EOF'
Set up StoryPress's separate, local ComfyUI runtime on Apple Silicon macOS.

Usage: setup-comfyui.sh [--dry-run] [--skip-models] [--help]

Options:
  --dry-run     Print planned actions without changing files or downloading.
  --skip-models Install ComfyUI and Python dependencies, but do not download weights.
  --help        Show this help.

Environment:
  STORYPRESS_RUNTIME_DIR  Runtime directory (default: ~/Library/Application Support/StoryPressRuntime)
  STORYPRESS_COMFYUI_DIR  ComfyUI checkout path (default: <runtime>/ComfyUI)
  STORYPRESS_PYTHON_VERSION  Python minor version for uv (default: 3.13)

The setup pins ComfyUI, PyTorch packages, and the public model revision. Weight
downloads resume through partial files and are accepted only after SHA-256 checks.
EOF
}

fail() {
  printf 'setup-comfyui: %s\n' "$*" >&2
  exit 1
}

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if (( ! DRY_RUN )); then
    "$@"
  fi
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-models) SKIP_MODELS=1 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown option: $arg (use --help)" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "this setup targets Apple Silicon macOS"
[[ "$(uname -m)" == "arm64" ]] || fail "Apple Silicon is required for the local MPS runtime"

for command_name in git curl shasum df awk; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done
command -v uv >/dev/null 2>&1 || fail "uv is required; install it with Homebrew or from https://docs.astral.sh/uv/"

find_existing_parent() {
  local path="$1"
  while [[ ! -d "$path" ]]; do
    path="$(dirname "$path")"
  done
  printf '%s\n' "$path"
}

disk_parent="$(find_existing_parent "$COMFY_DIR")"
available_kib="$(df -Pk "$disk_parent" | awk 'NR == 2 {print $4}')"
if [[ -n "$available_kib" ]] && (( available_kib < REQUIRED_FREE_KIB )); then
  fail "need at least 60 GiB free on the runtime volume; available: $((available_kib / 1024 / 1024)) GiB"
fi

printf 'Runtime directory: %s\n' "$RUNTIME_DIR"
printf 'ComfyUI checkout: %s\n' "$COMFY_DIR"
printf 'ComfyUI commit:   %s\n' "$COMFYUI_COMMIT"
printf 'Model revision:   %s\n' "$MODEL_REVISION"
printf 'Weights:          32.44 GB total (three files)\n'

if (( DRY_RUN )); then
  printf 'Dry run: would create a Python %s venv, install pinned macOS PyTorch and ComfyUI requirements, then fetch/hash-check the selected Qwen Image 2.1 weights.\n' "$PYTHON_VERSION"
  exit 0
fi

mkdir -p "$RUNTIME_DIR"

if [[ -e "$COMFY_DIR" && ! -d "$COMFY_DIR/.git" ]]; then
  fail "refusing to replace an existing non-git ComfyUI directory: $COMFY_DIR"
fi

if [[ ! -d "$COMFY_DIR/.git" ]]; then
  mkdir -p "$(dirname "$COMFY_DIR")"
  git init "$COMFY_DIR"
  git -C "$COMFY_DIR" remote add origin "$COMFYUI_REPOSITORY"
fi

origin="$(git -C "$COMFY_DIR" remote get-url origin)"
[[ "$origin" == "$COMFYUI_REPOSITORY" ]] || fail "unexpected origin in $COMFY_DIR: $origin"

if [[ -n "$(git -C "$COMFY_DIR" status --porcelain)" ]]; then
  fail "ComfyUI checkout has local changes; refusing to replace them: $COMFY_DIR"
fi

git -C "$COMFY_DIR" fetch --depth=1 origin "$COMFYUI_COMMIT"
git -C "$COMFY_DIR" checkout --detach FETCH_HEAD

if [[ ! -x "$COMFY_DIR/.venv/bin/python" ]]; then
  uv venv --python "$PYTHON_VERSION" "$COMFY_DIR/.venv"
fi
PYTHON="$COMFY_DIR/.venv/bin/python"

# Install the pinned Apple Silicon wheels first; requirements.txt leaves Torch unpinned.
uv pip install --python "$PYTHON" \
  "torch==2.12.1" \
  "torchvision==0.27.1" \
  "torchaudio==2.11.0"
# SQLAlchemy 2.1.0's currently published sdist has duplicate normalized extras;
# ComfyUI accepts the latest 2.0 release and does not require 2.1-specific APIs.
CONSTRAINTS_FILE="$(mktemp /tmp/storypress-comfy-constraints.XXXXXX)"
trap 'rm -f "$CONSTRAINTS_FILE"' EXIT
printf 'SQLAlchemy<2.1\n' > "$CONSTRAINTS_FILE"
uv pip install --python "$PYTHON" -c "$CONSTRAINTS_FILE" -r "$COMFY_DIR/requirements.txt"

install_models() {
  local relative_path="$1"
  local target_path="$COMFY_DIR/models/$relative_path"
  local expected_bytes="$2"
  local expected_sha256="$3"
  local partial_path="${target_path}.part"
  local actual_sha256
  local actual_bytes
  local url="https://huggingface.co/${MODEL_REPOSITORY}/resolve/${MODEL_REVISION}/${relative_path}?download=true"

  mkdir -p "$(dirname "$target_path")"

  if [[ -f "$target_path" ]]; then
    actual_sha256="$(shasum -a 256 "$target_path" | awk '{print $1}')"
    if [[ "$actual_sha256" == "$expected_sha256" ]]; then
      printf 'Verified existing weight: %s\n' "$relative_path"
      return
    fi
    mv "$target_path" "${target_path}.checksum-mismatch.$(date +%s)"
  fi

  if [[ -f "$partial_path" ]]; then
    actual_bytes="$(stat -f '%z' "$partial_path")"
    if (( actual_bytes == expected_bytes )); then
      actual_sha256="$(shasum -a 256 "$partial_path" | awk '{print $1}')"
      if [[ "$actual_sha256" == "$expected_sha256" ]]; then
        mv "$partial_path" "$target_path"
        printf 'Verified resumed weight: %s\n' "$relative_path"
        return
      fi
      mv "$partial_path" "${partial_path}.checksum-mismatch.$(date +%s)"
    fi
  fi

  printf 'Downloading %s (%s bytes); an interrupted .part file will resume on the next run.\n' "$relative_path" "$expected_bytes"
  curl --fail --location --show-error --progress-bar \
    --retry 15 --retry-all-errors --retry-delay 3 \
    --continue-at - --output "$partial_path" "$url"

  actual_bytes="$(stat -f '%z' "$partial_path")"
  [[ "$actual_bytes" == "$expected_bytes" ]] || fail "wrong size for $relative_path: expected $expected_bytes, received $actual_bytes"
  actual_sha256="$(shasum -a 256 "$partial_path" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    mv "$partial_path" "${partial_path}.checksum-mismatch.$(date +%s)"
    fail "SHA-256 mismatch for $relative_path"
  fi
  mv "$partial_path" "$target_path"
  printf 'Verified weight: %s\n' "$relative_path"
}

if (( ! SKIP_MODELS )); then
  install_models \
    "diffusion_models/qwen_image_2.1_bf16.safetensors" \
    14230280616 \
    89f4158d066cc33906a199fca85634f766892dd78f49b6698dabf187ac86c4bc
  install_models \
    "text_encoders/qwen3vl_8b_bf16.safetensors" \
    17534334616 \
    68bdc82bc1b66851162ae656225e7e2068166b603db19bd5d5a3b90eb12669a9
  install_models \
    "vae/qwen_image_2.1_vae_bf16.safetensors" \
    675509688 \
    bb21f7473051e1ac368515dd3f2e15cd44d7a11748ee8823e1ddca3e4876b7c9
fi

"$PYTHON" - "$COMFY_DIR" "$COMFYUI_COMMIT" "$MODEL_REVISION" "$TORCH_MANIFEST_COMMIT" <<'PY'
import json
import platform
import sys
from pathlib import Path

import sqlalchemy
import torch
import torchaudio
import torchvision

comfy_dir = Path(sys.argv[1])
metadata = {
    "comfyui_commit": sys.argv[2],
    "model_repository": "Comfy-Org/Qwen-Image-2.1",
    "model_revision": sys.argv[3],
    "torch_manifest_repository": "Comfy-Org/ComfyUI-Standalone-Environments",
    "torch_manifest_commit": sys.argv[4],
    "python": platform.python_version(),
    "torch": torch.__version__,
    "torchvision": torchvision.__version__,
    "torchaudio": torchaudio.__version__,
    "sqlalchemy": sqlalchemy.__version__,
    "mps_built": bool(torch.backends.mps.is_built()),
    "mps_available": bool(torch.backends.mps.is_available()),
}
(comfy_dir.parent / "runtime-provenance.json").write_text(
    json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
)
print(json.dumps(metadata, indent=2))
if not metadata["mps_available"]:
    raise SystemExit("PyTorch MPS is unavailable; see the runtime report above")
try:
    value = torch.ones((2, 2), device="mps", dtype=torch.bfloat16)
    _ = value @ value
    print("MPS bfloat16 matrix multiply: supported")
except Exception as exc:  # The full graph test will establish model-level support.
    print(f"MPS bfloat16 matrix multiply: unsupported ({type(exc).__name__}: {exc})")
PY

printf 'Setup complete. Start the explicit runtime with: scripts/start-comfyui.sh\n'
