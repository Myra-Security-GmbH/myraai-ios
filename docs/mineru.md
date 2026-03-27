# MinerU2.5 — Architecture & Integration Notes

## Overview

MinerU2.5 is a 1.2B-parameter vision-language model for high-accuracy document parsing.
It converts scanned PDFs, screenshots, and image-based documents into structured Markdown or JSON.
On the OmniDocBench benchmark it outperforms GPT-4o, Gemini 2.5 Pro, and Qwen2.5-VL-72B.

**Model:** `opendatalab/MinerU2.5-2509-1.2B`
**Paper:** arXiv:2509.22186 — *MinerU2.5: A Decoupled Vision-Language Model for Efficient High-Resolution Document Parsing*

---

## How MinerU2.5 Works

MinerU2.5 uses a **two-stage decoupled strategy**:

1. **Global layout analysis** — the full page is downsampled and processed to identify regions:
   text blocks, tables, figures, formulas, headings, reading order.
2. **Fine-grained recognition** — each identified region is cropped at native resolution and
   processed individually for accurate text/formula/table extraction.

This decoupling reduces total FLOPs by ~10× compared to monolithic native-resolution VLMs,
enabling a 1.2B model to beat much larger systems.

The `MinerULogitsProcessor` (from `mineru-vl-utils`) constrains token sampling during inference
to enforce MinerU's structured output format — layout tags interleaved with markdown content.

---

## Deployment on This Machine

```
Client (HTTP)
     │  POST http://127.0.0.1:8084/v1/chat/completions
     ▼
vllm serve opendatalab/MinerU2.5-2509-1.2B
     │  binary:   /home/vllm/.vllm/bin/vllm  (vLLM 0.16.0+cu130)
     │  extra:    mineru-vl-utils 0.1.22 (logits processor)
     │  flag:     --logits-processors mineru_vl_utils:MinerULogitsProcessor
     │  GPU:      CUDA_VISIBLE_DEVICES=1  (RTX PRO 6000 Blackwell, 94.97 GiB)
     │  memory:   --gpu-memory-utilization 0.17  (~16 GiB claimed)
     │  port:     8084, model name: mineru2
     ▼
/opt/models/huggingface/hub/models--opendatalab--MinerU2.5-2509-1.2B  (~3 GiB)
```

### Systemd service

```
/home/sas/work/ai-gateway/config/vllm-mineru2.service
  → symlinked to /etc/systemd/system/vllm-mineru2.service
```

```bash
sudo systemctl status vllm-mineru2
sudo journalctl -fu vllm-mineru2
```

### GPU memory budget (GPU 1)

| Service          | gpu_memory_utilization | Claimed   |
|------------------|------------------------|-----------|
| Llama Guard 3 8B | 0.80                   | ~75.97 GiB|
| MinerU2.5        | 0.17                   | ~16.15 GiB|
| **Total**        |                        | ~92.12 GiB|
| Headroom         |                        | ~2.85 GiB |

If OOM occurs: lower Llama Guard to `--gpu-memory-utilization 0.77` in
`config/vllm-llama-guard-3-8b.service`.

### Compilation caches

```
/opt/models/cache/inductor-mineru/
/opt/models/cache/vllm-mineru/
```

---

## API Usage

The service exposes a standard OpenAI-compatible chat completions endpoint.
Send a page image (PNG, JPG, or PDF page rendered to image) as `image_url` with a conversion
instruction as `text`.

### curl example

```bash
python3 -c "
import json, base64
b64 = base64.b64encode(open('page.png','rb').read()).decode()
open('/tmp/req.json','w').write(json.dumps({
  'model': 'mineru2',
  'messages': [{'role': 'user', 'content': [
    {'type': 'image_url', 'image_url': {'url': f'data:image/png;base64,{b64}'}},
    {'type': 'text', 'text': 'Convert this document page to markdown.'}
  ]}],
  'max_tokens': 2048
}))
"

curl -s -X POST http://127.0.0.1:8084/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d @/tmp/req.json \
  | jq -r '.choices[0].message.content'
```

### Python example

```python
from openai import OpenAI
import base64, pathlib

client = OpenAI(base_url="http://127.0.0.1:8084/v1", api_key="unused")

b64 = base64.b64encode(pathlib.Path("page.png").read_bytes()).decode()

response = client.chat.completions.create(
    model="mineru2",
    messages=[{"role": "user", "content": [
        {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}},
        {"type": "text",      "text": "Convert this document page to markdown."},
    ]}],
    max_tokens=2048,
)
print(response.choices[0].message.content)
```

### Multi-page PDF workflow

MinerU processes one page at a time. For a multi-page PDF:

```python
import fitz  # pymupdf
import base64
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8084/v1", api_key="unused")
doc = fitz.open("document.pdf")
pages_md = []

for page in doc:
    pix = page.get_pixmap(dpi=150)
    b64 = base64.b64encode(pix.tobytes("png")).decode()
    resp = client.chat.completions.create(
        model="mineru2",
        messages=[{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}},
            {"type": "text",      "text": "Convert this document page to markdown."},
        ]}],
        max_tokens=2048,
    )
    pages_md.append(resp.choices[0].message.content)

full_markdown = "\n\n---\n\n".join(pages_md)
```

---

## Why Not `mineru[all]`

The system runs **CUDA 13.1**. The `mineru[all]` package bundles its own vLLM and pulls
PyTorch cu12x wheels from PyPI, which are incompatible with CUDA 13.1. The solution is to use
the existing `/home/vllm/.vllm/` environment (built for this machine's CUDA version) and install
only `mineru-vl-utils` (59 KB, CPU-only) which provides the logits processor.

---

## Planned Gateway Integration (not yet implemented)

Pre-process scanned PDFs transparently before forwarding to Claude:

1. Detect scanned PDF: extract text with `pdfminer`; if < 50 chars/page → scanned
2. Render each page to PNG at 150 DPI (via `pymupdf` / `pdftoppm`)
3. POST each page to `http://127.0.0.1:8084/v1/chat/completions`
4. Assemble returned Markdown pages into a single text document block
5. Forward to Claude as `{"type": "text", "text": "<markdown>"}` instead of the raw PDF

Entry point: `src/admin/api.lua` or a new Lua pre-processor module.
