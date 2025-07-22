#!/usr/bin/env bash
set -euo pipefail

readonly FORGEUI_DIR="/workspace/forgeui"
readonly DOWNLOADER_SCRIPT="/workspace/civitai-downloader/download_with_aria.py"
readonly TOKEN_ARG=${CIVITAI_TOKEN:+--token "$CIVITAI_TOKEN"}
readonly MAX_RETRIES=${MAX_RETRIES:-3}
readonly DOWNLOAD_TIMEOUT=${DOWNLOAD_TIMEOUT:-600}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

exit_clean() {
  log "🧹 Cleaning up logs and cache before exit..."
  find "$FORGEUI_DIR" -maxdepth 1 -type f \( -name "log.txt" -o -name "params.txt" -o -name "ui-config.json" -o -name "config.json" \) -delete 2>/dev/null || true
  rm -rf "$FORGEUI_DIR/logs" "$FORGEUI_DIR/cache" "$FORGEUI_DIR/tmp" 2>/dev/null || true
  log "✅ Cleanup complete."
}

download_model() {
  local id="$1" out_dir="$2"
  [ -z "$id" ] && return 0
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
    # Test RTX 5090 sm_120 support
    try:
        test_tensor = torch.randn(100, 100).cuda()
        result = torch.mm(test_tensor, test_tensor)
        print('✅ CUDA operations working correctly')
    except Exception as e:
        print(f'⚠️ CUDA test failed: {e}')
else:
    print('❌ CUDA not available!')
"
}

detect_startup_method() {
  if [ -f "$FORGEUI_DIR/launch.py" ]; then
    echo "launch"
  elif [ -f "$FORGEUI_DIR/app.py" ]; then
    echo "app"
  elif [ -f "$FORGEUI_DIR/server.js" ]; then
    echo "server"
  elif [ -f "$FORGEUI_DIR/main.py" ]; then
    echo "main"
  else
    echo "launch"  # default fallback
  fi
}

trap exit_clean SIGINT SIGTERM EXIT

log "🚀 Starting ForgeUI setup..."

# Check CUDA compatibility first
check_cuda_compatibility

# Configure storage based on USE_VOLUME setting
USE_VOLUME_SETTING="${USE_VOLUME:-true}"
STORAGE="/workspace"

if [ "$USE_VOLUME_SETTING" = "true" ] && [ -d "/runpod-volume" ]; then
  log "📁 Persistent volume detected. Linking /runpod-volume to models and outputs."
  STORAGE="/runpod-volume"
  
  # Create directory structure
  mkdir -p "$STORAGE/models/Stable-diffusion" \
           "$STORAGE/models/Lora" \
           "$STORAGE/models/VAE" \
           "$STORAGE/models/embeddings" \
           "$STORAGE/models/hypernetworks" \
           "$STORAGE/models/ControlNet" \
           "$STORAGE/outputs"
  
  # Create symlinks
  ln -sfn "$STORAGE/models" "$FORGEUI_DIR/models"
  ln -sfn "$STORAGE/outputs" "$FORGEUI_DIR/outputs"
else
  log "📁 Using local storage in /workspace."
  mkdir -p "$FORGEUI_DIR/models/Stable-diffusion" \
           "$FORGEUI_DIR/models/Lora" \
           "$FORGEUI_DIR/models/VAE" \
           "$FORGEUI_DIR/models/embeddings" \
           "$FORGEUI_DIR/models/hypernetworks" \
           "$FORGEUI_DIR/models/ControlNet" \
           "$FORGEUI_DIR/outputs"
fi

# Start FileBrowser if enabled
if [ "${FILEBROWSER:-false}" = "true" ]; then
  FB_PASS="${FILEBROWSER_PASSWORD:-admin}"
  log "🌐 Starting FileBrowser on port 8080 (Login: admin / $FB_PASS)"
  nohup filebrowser -r "$STORAGE" -p 8080 -a 0.0.0.0 --username admin --password "$FB_PASS" >/dev/null 2>&1 &
fi

# Download models if specified
log "⏳ Starting model downloads..."

if [ -n "${CHECKPOINT_IDS_TO_DOWNLOAD:-}" ]; then
  log "📥 Downloading checkpoints..."
  for id in ${CHECKPOINT_IDS_TO_DOWNLOAD//,/ }; do
    download_model "$id" "$FORGEUI_DIR/models/Stable-diffusion/"
  done
fi

if [ -n "${LORA_IDS_TO_DOWNLOAD:-}" ]; then
  log "📥 Downloading LoRAs..."
  for id in ${LORA_IDS_TO_DOWNLOAD//,/ }; do
    download_model "$id" "$FORGEUI_DIR/models/Lora/"
  done
fi

if [ -n "${VAE_IDS_TO_DOWNLOAD:-}" ]; then
  log "📥 Downloading VAEs..."
  for id in ${VAE_IDS_TO_DOWNLOAD//,/ }; do
    download_model "$id" "$FORGEUI_DIR/models/VAE/"
  done
fi

log "✔️ All model downloads complete."

# Launch ForgeUI
cd "$FORGEUI_DIR"
STARTUP_METHOD=$(detect_startup_method)
log "🚀 Launching ForgeUI using $STARTUP_METHOD method on port 7860..."

case $STARTUP_METHOD in
  "launch")
    log "Starting with launch.py..."
    export COMMANDLINE_ARGS="--listen --port 7860 --enable-insecure-extension-access --theme dark --api --no-half --precision full --disable-safe-unpickle --skip-torch-cuda-test"
    exec python3 launch.py
    ;;
  "app")
    log "Starting with app.py..."
    exec python3 app.py --host 0.0.0.0 --port 7860 --api
    ;;
  "main")
    log "Starting with main.py..."
    exec python3 main.py --host 0.0.0.0 --port 7860 --api
    ;;
  "server")
    log "Starting Node.js server..."
    export PORT=7860
    export HOST=0.0.0.0
    exec node server.js
    ;;
  *)
    log "❌ No suitable startup method found. Available files:"
    ls -la "$FORGEUI_DIR" | grep -E "\.(py|js)$" || true
    log "Attempting launch.py anyway..."
    export COMMANDLINE_ARGS="--listen --port 7860 --enable-insecure-extension-access --theme dark --api --no-half --precision full --disable-safe-unpickle --skip-torch-cuda-test"
    exec python3 launch.py || exit 1
    ;;
esac