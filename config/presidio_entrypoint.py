# config/presidio_entrypoint.py
# Minimal REST server for presidio-analyzer.
# Calls spacy.prefer_gpu() BEFORE loading models so spaCy uses the GPU.
#
# Endpoints (same interface as the official Microsoft image):
#   GET  /health           → "Presidio Analyzer service is up"
#   POST /analyze          → JSON list of RecognizerResult
#   GET  /recognizers      → list of available recognizer names
#   GET  /supportedentities → list of supported entity types

import spacy
spacy.prefer_gpu()

from flask import Flask, request, jsonify
from presidio_analyzer import AnalyzerEngine

app = Flask(__name__)
# Disable LemmaContextAwareEnhancer — it has O(n²) behavior in Presidio 2.2.x
# (iterates doc tokens for each recognizer result, causing 60M+ calls on first use).
# Context enhancement provides minor accuracy gains but causes multi-second latency.
from presidio_analyzer import AnalyzerEngine
from presidio_analyzer.nlp_engine import NlpEngineProvider
engine = AnalyzerEngine(context_aware_enhancer=None)

# Warm up: trigger model loading so the first real request is fast
import os, gc
for lang in os.environ.get("PRESIDIO_SUPPORTED_LANGUAGES", "en").split(","):
    try:
        engine.analyze(text="warmup", language=lang.strip())
    except Exception:
        pass  # language may not have recognizers configured — skip silently

# Flush any deferred CUDA deallocations so they don't stall the first real request.
try:
    import cupy
    cupy.cuda.Stream.null.synchronize()
    cupy.get_default_memory_pool().free_all_blocks()
    # Run one more analyze to re-warm after the pool free
    engine.analyze(text="warmup2", language="en")
    cupy.cuda.Stream.null.synchronize()
except Exception:
    pass

# Freeze all currently tracked objects so Python's cyclic GC never collects
# the loaded spaCy/cupy model tensors, preventing per-request re-allocation.
gc.freeze()
gc.disable()  # disable GC entirely — objects are short-lived per-request anyway


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
    return jsonify([r.to_dict() for r in results])


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
