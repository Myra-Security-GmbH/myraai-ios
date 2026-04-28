#!/usr/bin/env bash
# Download Qwen/Qwen3.6-35B-A3B-FP8 into the shared HF hub cache.
# Run as root or with sudo; the download runs as the vllm user so file ownership
# matches what the service expects.
#
# Estimated size: ~35 GiB
# Typical download time on 1 Gbit/s: ~5–8 min
#
# Usage: sudo bash download-qwen3.6-35b-a3b-fp8.sh

set -euo pipefail

MODEL="Qwen/Qwen3.6-35B-A3B-FP8"
HUB_DIR="/opt/models/huggingface/hub"
VLLM_CLI="/home/vllm/.vllm/bin/huggingface-cli"

echo "[download] Starting: $MODEL → $HUB_DIR"
echo "[download] Model size: ~35 GiB"

sudo -u vllm bash -c "
    HF_HUB_DISABLE_XET=1 \
    HF_HOME=/opt/models/huggingface \
    /home/vllm/.vllm/bin/hf download \
        '$MODEL' \
        --cache-dir '$HUB_DIR'
"

echo "[download] Done. Model is in: $HUB_DIR/models--Qwen--Qwen3.6-35B-A3B-FP8"
echo "[download] Next steps:"
echo "  sudo cp /home/sas/work/ai-gateway/config/vllm-qwen3.6-A3B.service /etc/systemd/system/"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl stop vllm-qwen3-A3B"
echo "  sudo systemctl start vllm-qwen3.6-A3B"
echo "  sudo systemctl enable vllm-qwen3.6-A3B"
echo ""
echo "  Then update the gateway vLLM model name from 'qwen3-30b-a3b' to 'qwen3.6-35b-a3b'."
