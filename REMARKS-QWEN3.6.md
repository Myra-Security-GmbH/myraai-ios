# Remarks — Qwen3.6-35B-A3B

## 1M context is feasible on the H200 NVL

The model natively supports 262,144 tokens and is officially extensible to **1,010,000 tokens**
via YaRN. The YaRN scaling config is baked into the model's `config.json` — no custom RoPE
flags are needed in vLLM.

### KV cache budget at 1M context

The hybrid architecture (30 GDN recurrent layers + 10 full-attention layers) keeps KV cost low:
only the 10 full-attention layers allocate KV cache.

| | 262K (current) | 1M |
|---|---|---|
| KV per sequence (FP8, 2 KV heads, head_dim=256, 10 layers) | ~2.5 GiB | ~9.7 GiB |
| Available KV budget on H200 NVL (~86 GiB) | 34 sessions | **~8 sessions** |
| `--max-num-seqs` | 32 | 8 |

A single H200 NVL (144 GiB) fits the 1M config with ~8 concurrent sessions.

### Service file changes required

Two lines in `vllm-qwen3.6-A3B.service`:

```
--max-model-len 1010000 \
--max-num-seqs 8 \
```

No other flags needed. vLLM ≥ 0.19.0 is required (currently running 0.20.0 ✓).

### Caveats

- First-run torch.compile at 1M context takes longer than at 262K (`MAX_JOBS=16` cap already
  in place to prevent OOM during compilation).
- Chunked prefill (`--enable-chunked-prefill`) is already enabled — essential at this length.
- SGLang is recommended by Qwen for maximum throughput at 1M, but vLLM is explicitly supported.
- Concurrent session capacity drops 4× (32 → 8). Fine for a coding-agent workload where
  sessions are long but few; not suitable for high-concurrency inference.
