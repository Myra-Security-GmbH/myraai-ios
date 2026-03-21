# config/presidio_entrypoint.py
# Minimal REST server for presidio-analyzer.
# Calls spacy.prefer_gpu() BEFORE loading models so spaCy uses the GPU.
#
# Endpoints (same interface as the official Microsoft image):
#   GET  /health           → "Presidio Analyzer service is up"
#   POST /analyze          → JSON list of RecognizerResult
#   GET  /recognizers      → list of available recognizer names
#   GET  /supportedentities → list of supported entity types

import gc, os

# Cap the CuPy memory pool before spaCy loads its models onto the GPU.
# Without a limit the pool grows unboundedly across requests, eventually
# consuming all VRAM and raising cupy.cuda.memory.OutOfMemoryError.
# 8 GB is well above what en_core_web_lg + de_core_news_lg need (~2 GB peak).
try:
    import cupy
    cupy.get_default_memory_pool().set_limit(size=8 * 1024**3)  # 8 GB
except Exception:
    pass

import spacy
spacy.prefer_gpu()

from flask import Flask, request, jsonify
from presidio_analyzer import AnalyzerEngine
from presidio_analyzer.context_aware_enhancers import ContextAwareEnhancer

app = Flask(__name__)

# Passing None to context_aware_enhancer is falsy, so Presidio creates a
# LemmaContextAwareEnhancer anyway (if not context_aware_enhancer: ...).
# We need a real object that is a no-op to actually skip the O(n²) enhancer.
class _NoOpEnhancer(ContextAwareEnhancer):
    def __init__(self):
        pass  # skip super().__init__() which requires 4 positional args
    def enhance_using_context(self, text, raw_results, nlp_artifacts, recognizers, context):
        return raw_results

engine = AnalyzerEngine(context_aware_enhancer=_NoOpEnhancer())

# Warm up: trigger model loading so the first real request is fast.
for lang in os.environ.get("PRESIDIO_SUPPORTED_LANGUAGES", "en").split(","):
    try:
        engine.analyze(text="warmup", language=lang.strip())
    except Exception:
        pass  # language may not have recognizers configured — skip silently

# Synchronize CUDA and free any cached-but-idle blocks accumulated during warmup.
try:
    import cupy
    cupy.cuda.Stream.null.synchronize()
    cupy.get_default_memory_pool().free_all_blocks()
    engine.analyze(text="warmup2", language="en")
    cupy.cuda.Stream.null.synchronize()
except Exception:
    pass

# Freeze model objects into the permanent GC generation so they are never
# collected. New per-request objects (spaCy Docs, result lists) are created
# after this point and remain in generation 0, collected explicitly per request.
gc.freeze()


@app.get("/health")
def health():
    return "Presidio Analyzer service is up", 200


@app.post("/analyze")
def analyze():
    body = request.get_json(force=True)
    text = body.get("text", "")
    language = body.get("language", "en")
    entities = body.get("entities") or None
    score_threshold = body.get("score_threshold", 0.35)
    results = engine.analyze(text=text, language=language,
                             entities=entities, score_threshold=score_threshold)
    response = jsonify([r.to_dict() for r in results])
    # Break reference cycles in spaCy Doc objects created during this request
    # so CuPy can reclaim their GPU tensors back into the pool's free list.
    # (gc.freeze() above protects model objects; only gen-0 request objects are collected.)
    gc.collect(0)
    try:
        cupy.get_default_memory_pool().free_all_blocks()
    except Exception:
        pass
    return response


@app.get("/recognizers")
def recognizers():
    regs = engine.get_recognizers(language="en")
    return jsonify([r.name for r in regs])


@app.get("/supportedentities")
def supported_entities():
    entities = engine.get_supported_entities(language="en")
    return jsonify(entities)


if __name__ == "__main__":
    import os
    port = int(os.environ.get("PORT", 3000))
    app.run(host="0.0.0.0", port=port, threaded=False, use_reloader=False)
