#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="${STORYPRESS_RUNTIME_DIR:-${HOME}/Library/Application Support/StoryPressRuntime}"
COMFY_DIR="${STORYPRESS_COMFYUI_DIR:-${RUNTIME_DIR}/ComfyUI}"
PYTHON="${COMFY_DIR}/.venv/bin/python"
PORT="${STORYPRESS_COMFYUI_PORT:-8188}"
MEMORY_MODE="${STORYPRESS_COMFYUI_MEMORY_MODE:-balanced}"

usage() {
  cat <<'EOF'
Start the StoryPress ComfyUI runtime in the foreground on loopback.

Usage: start-comfyui.sh [--help]

The server stays in the current terminal so its logs and exit status remain visible.
Press Control-C to stop it. This script does not install a background or login service.

Environment:
  STORYPRESS_RUNTIME_DIR  Runtime directory (default: ~/Library/Application Support/StoryPressRuntime)
  STORYPRESS_COMFYUI_DIR  ComfyUI checkout path (default: <runtime>/ComfyUI)
  STORYPRESS_COMFYUI_PORT  Local API port (default: 8188)
  STORYPRESS_COMFYUI_MEMORY_MODE  `balanced` uses ComfyUI low-VRAM, aggressive offload, and CPU VAE flags (default); `upstream` uses ComfyUI defaults.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || { printf 'start-comfyui: unknown argument: %s\n' "$1" >&2; exit 2; }

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || {
  printf 'start-comfyui: this runtime targets Apple Silicon macOS\n' >&2
  exit 1
}
[[ -x "$PYTHON" ]] || {
  printf 'start-comfyui: runtime is not installed; run scripts/setup-comfyui.sh first\n' >&2
  exit 1
}
[[ -f "$COMFY_DIR/main.py" ]] || {
  printf 'start-comfyui: ComfyUI source is missing; run scripts/setup-comfyui.sh first\n' >&2
  exit 1
}
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
  printf 'start-comfyui: STORYPRESS_COMFYUI_PORT must be between 1024 and 65535\n' >&2
  exit 2
fi

# Use MPS when available; allow unsupported individual operations to fall back to CPU.
export PYTORCH_ENABLE_MPS_FALLBACK="${PYTORCH_ENABLE_MPS_FALLBACK:-1}"

MEMORY_ARGS=()
case "$MEMORY_MODE" in
  balanced)
    MEMORY_ARGS=(--lowvram --disable-smart-memory --cpu-vae)
    ;;
  upstream)
    ;;
  *)
    printf 'start-comfyui: STORYPRESS_COMFYUI_MEMORY_MODE must be balanced or upstream\n' >&2
    exit 2
    ;;
esac
printf 'Starting ComfyUI on http://127.0.0.1:%s (foreground; Control-C stops it)\n' "$PORT"
printf 'Memory mode: %s\n' "$MEMORY_MODE"
exec "$PYTHON" "$COMFY_DIR/main.py" --listen 127.0.0.1 --port "$PORT" --disable-auto-launch "${MEMORY_ARGS[@]}"
