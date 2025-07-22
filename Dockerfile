# Dockerfile

# 1) Base image
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04

# 2) Non‑interactive installs & unbuffered Python
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

WORKDIR /workspace

# 3) System packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git wget curl aria2 python3 python3-pip python-is-python3 \
      libgl1-mesa-glx libglib2.0-0 libsm6 libxext6 libxrender-dev libgomp1 ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 4) FileBrowser CLI
RUN curl -fsSL "https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz" \
    | tar -xz -C /usr/local/bin filebrowser && \
    chmod +x /usr/local/bin/filebrowser

# 5) Non‑root user
RUN useradd -m -s /bin/bash -d /home/sduser sduser && \
    chown -R sduser:sduser /workspace
USER sduser

# 6) Clone repos (full history for `git describe`)
RUN git clone https://github.com/lllyasviel/stable-diffusion-webui-forge.git /workspace/stable-diffusion-webui-forge && \
    git clone https://github.com/Hearmeman24/CivitAI_Downloader.git /workspace/civitai-downloader

WORKDIR /workspace/stable-diffusion-webui-forge

# 7) Python deps in order:
#    a) pip/tooling
#    b) NIGHTLY torch (no version pin) → sm_120 kernels
#    c) xformers
#    d) Forge requirements (minus torch*, torchvision*, torchaudio*)
#    e) misc utilities
RUN pip install --upgrade pip setuptools wheel && \
    pip install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/nightly/cu121 && \
    pip install xformers==0.0.27 --no-deps && \
    sed '/^torch/d;/^torchvision/d;/^torchaudio/d' requirements_versions.txt > /tmp/forge_reqs.txt && \
    pip install -r /tmp/forge_reqs.txt && rm /tmp/forge_reqs.txt && \
    pip install requests opencv-python-headless joblib

# 8) Entrypoint & ports
WORKDIR /workspace
COPY --chown=sduser:sduser start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 7860 8080
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD curl -f http://localhost:7860/ >/dev/null || exit 1

ENTRYPOINT ["/start.sh"]
