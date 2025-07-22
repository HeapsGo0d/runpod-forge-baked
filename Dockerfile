# Dockerfile for ForgeUI with RTX 5090 compatibility

FROM nvidia/cuda:12.1.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

WORKDIR /workspace

# System packages including Node.js
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git wget curl aria2 python3 python3-pip python-is-python3 \
      libgl1-mesa-glx libglib2.0-0 libsm6 libxext6 libxrender-dev libgomp1 ca-certificates \
      nodejs npm \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# FileBrowser CLI
RUN curl -fsSL "https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz" \
    | tar -xz -C /usr/local/bin filebrowser && \
    chmod +x /usr/local/bin/filebrowser

# Non-root user
RUN useradd -m -s /bin/bash -d /home/sduser sduser && \
    chown -R sduser:sduser /workspace
USER sduser

# Copy your local ForgeUI code and clone the downloader
COPY --chown=sduser:sduser forgeui /workspace/forgeui
RUN git clone https://github.com/Hearmeman24/CivitAI_Downloader.git /workspace/civitai-downloader

WORKDIR /workspace/forgeui

# Install Python dependencies
RUN pip install --upgrade pip setuptools wheel && \
    pip install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/nightly/cu121 && \
    pip install xformers==0.0.27 --no-deps

# Install ForgeUI requirements (strip torch versions)
RUN if [ -f requirements_versions.txt ]; then \
        sed '/^torch/d;/^torchvision/d;/^torchaudio/d' requirements_versions.txt > /tmp/forgeui_reqs.txt; \
    elif [ -f requirements.txt ]; then \
        sed '/^torch/d;/^torchvision/d;/^torchaudio/d' requirements.txt > /tmp/forgeui_reqs.txt; \
    else \
        echo "gradio>=3.41.2" > /tmp/forgeui_reqs.txt; \
        echo "transformers>=4.25.1" >> /tmp/forgeui_reqs.txt; \
        echo "accelerate>=0.18.0" >> /tmp/forgeui_reqs.txt; \
        echo "diffusers>=0.21.0" >> /tmp/forgeui_reqs.txt; \
        echo "safetensors>=0.3.2" >> /tmp/forgeui_reqs.txt; \
    fi && \
    pip install -r /tmp/forgeui_reqs.txt && rm /tmp/forgeui_reqs.txt

# Install additional utilities
RUN pip install requests opencv-python-headless joblib

# Install Node.js dependencies if package.json exists
RUN if [ -f package.json ]; then npm install; fi

WORKDIR /workspace
COPY --chown=sduser:sduser start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 7860 8080 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD curl -f http://localhost:7860/ >/dev/null || exit 1

ENTRYPOINT ["/start.sh"]