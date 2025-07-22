#!/usr/bin/env bash
# start.sh - Updated for RTX 5090 compatibility

set -euo pipefail

# --- Configuration ---
readonly WEBUI_DIR="/workspace/stable-diffusion-webui-forge"
readonly DOWNLOADER_SCRIPT="/workspace/civitai-downloader/download_with_aria.py"
readonly TOKEN_ARG=${CIVITAI_API_TOKEN:+--token "$CIVITAI_API_TOKEN"}
readonly MAX_RETRIES=${MAX_RETRIES:-3}
readonly DOWNLOAD_TIMEOUT=${DOWNLOAD_TIMEOUT:-600}

# --- Functions ---
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

exit_clean() {
  log "🧹 Cleaning up logs and cache before exit..."
  find "$WEBUI_DIR" -maxdepth 1 -type f \( -name "log.txt" -o -name "params.txt" -o -name "ui-config.json" -o -name "config.json" \) -delete
  rm -rf "$WEBUI_DIR/logs" "$WEBUI_DIR/cache"
  log "✅ Cleanup complete."
}

download_model() {
  local id="$1" out_dir="$2"
  [ -z "$id" ] && return
  local retries=0
  while (( retries < MAX_RETRIES )); do
    log "📥 Downloading model ID: $id (Attempt $((retries+1))/$MAX_RETRIES)..."
    if timeout "$DOWNLOAD_TIMEOUT" python3 "$DOWNLOADER_SCRIPT" -m "$id" -o "$out_dir" $TOKEN_ARG; then
      log "✅ Download complete: $id"
      return 0
    fi
    ((retries++))
    log "⚠️ Download failed for $id. Retrying in 10 seconds..."
    sleep 10
  done
  log "❌ Failed to download $id after $MAX_RETRIES attempts."
  return 1
}

check_cuda_compatibility() {
  log "🔍 Checking CUDA and PyTorch compatibility..."
  python3 -c "
import torch
print(f'PyTorch version: {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'CUDA version: {torch.version.cuda}')
    print(f'GPU: {torch.cuda.get_device_name(0)}')
    print(f'CUDA capability: {torch.cuda.get_device_capability(0)}')
else:
    print('CUDA not available!')
"
}

# --- Main Execution ---
trap exit_clean SIGINT SIGTERM EXIT

log "🚀 Starting Stable Diffusion WebUI Forge setup..."

# 0. Check CUDA compatibility first
check_cuda_compatibility

# 1. Configure Storage
STORAGE="/workspace"
if [ -d "/runpod-volume" ]; then
  log "Persistent volume detected. Linking /runpod-volume to models and outputs."
  STORAGE="/runpod-volume"
  mkdir -p "$STORAGE/models" "$STORAGE/outputs"
  ln -sfn "$STORAGE/models"  "$WEBUI_DIR/models"
  ln -sfn "$STORAGE/outputs" "$WEBUI_DIR/outputs"
else
  log "No persistent volume found. Using temporary storage in /workspace."
fi

# 2. Start FileBrowser (if enabled)
if [ "${FILEBROWSER:-false}" = "true" ]; then
  FB_PASS="${FILEBROWSER_PASSWORD:-admin}"
  log "🚀 Starting FileBrowser on port 8080 (Login: admin / $FB_PASS)"
  nohup filebrowser -r "$STORAGE" -p 8080 -a 0.0.0.0 --username admin --password "$FB_PASS" >/dev/null 2>&1 &
fi

# 3. Download Models
log "⏳ Starting model downloads..."
mkdir -p "$WEBUI_DIR/models/Stable-diffusion" "$WEBUI_DIR/models/Lora" "$WEBUI_DIR/models/VAE"

# Only download if environment variables are set
if [ -n "${CHECKPOINT_IDS_TO_DOWNLOAD:-}" ]; then
  for id in ${CHECKPOINT_IDS_TO_DOWNLOAD//,/ }; do
    download_model "$id" "$WEBUI_DIR/models/Stable-diffusion/"
  done
fi

if [ -n "${LORA_IDS_TO_DOWNLOAD:-}" ]; then
  for id in ${LORA_IDS_TO_DOWNLOAD//,/ }; do
    download_model "$id" "$WEBUI_DIR/models/Lora/"
  done
fi

if [ -n "${VAE_IDS_TO_DOWNLOAD:-}" ]; then
  for id in ${VAE_IDS_TO_DOWNLOAD//,/ }; do
    download_model "$id" "$WEBUI_DIR/models/VAE/"
  done
fi

log "✔️ All model downloads are complete."

# 4. Launch the WebUI
cd "$WEBUI_DIR"
log "🚀 Launching Stable Diffusion WebUI on port 7860..."

# Updated command line args for RTX 5090 and better compatibility
export COMMANDLINE_ARGS="--listen --port 7860 --enable-insecure-extension-access --theme dark --api --no-half --precision full --disable-safe-unpickle"

# Alternative: If you still get CUDA issues, try with CPU fallback
# export COMMANDLINE_ARGS="--listen --port 7860 --enable-insecure-extension-access --theme dark --api --use-cpu all"

exec python3 launch.py