# config/presidio_entrypoint.py
# Presidio Analyzer — GLiNER multilingual NER + lingua language detection.
#
# Architecture
# ────────────
#   Presidio regex/pattern recognisers  → structured PII (email, IBAN, phone, credit card, …)
#   GLiNER urchade/gliner_multi_pii-v1  → NER-based PII (person, org, location, …) in 6 languages
#   lingua-language-detector            → auto-detect language when language="auto"
#
# /analyze language field
# ───────────────────────
#   "auto"  → detect with lingua; defaults to "en" when confidence is low
#   "en"    → treat as English
#   "de"    → treat as German
#   (other) → passed through; GLiNER handles any Latin-script language natively
#
# Endpoints (same interface as the official Microsoft presidio-analyzer image):
#   GET  /health               → "Presidio Analyzer service is up"
#   POST /analyze              → JSON list of RecognizerResult dicts
#   GET  /recognizers          → list of available recogniser names
#   GET  /supportedentities    → list of supported entity types

import gc
import os
from typing import List, Optional

import torch

from flask import Flask, request, jsonify
from presidio_analyzer import AnalyzerEngine, RecognizerRegistry
from presidio_analyzer.context_aware_enhancers import ContextAwareEnhancer
from presidio_analyzer.nlp_engine import NlpEngineProvider
from presidio_analyzer.predefined_recognizers import SpacyRecognizer

from gliner import GLiNER
from lingua import Language, LanguageDetectorBuilder


app = Flask(__name__)

# Chunking: keep well below GLiNER's 384-token internal limit.
# ~5 chars/token average → 1 400 chars ≈ 280 tokens (safe headroom for entity labels).
_CHUNK_CHARS   = 1400
_OVERLAP_CHARS = 140   # ~10 % overlap to catch entities split at chunk boundaries


def _chunk_text(text: str) -> list[tuple[str, int]]:
    """
    Split *text* into overlapping windows of ≤ _CHUNK_CHARS characters.
    Returns list of (chunk_text, char_offset_in_original) tuples.
    Breaks preferentially at NUL (pii_protector field separator) or whitespace.
    """
    if len(text) <= _CHUNK_CHARS:
        return [(text, 0)]

    chunks: list[tuple[str, int]] = []
    start = 0
    while start < len(text):
        end = min(start + _CHUNK_CHARS, len(text))
        if end < len(text):
            for sep in ("\x00", " "):
                pos = text.rfind(sep, end - 100, end)
                if pos > start:
                    end = pos + 1
                    break
        chunks.append((text[start:end], start))
        next_start = end - _OVERLAP_CHARS
        if next_start <= start:          # guard against infinite loop on very long tokens
            next_start = start + _CHUNK_CHARS
        start = next_start
    return chunks


# ── Language detection ────────────────────────────────────────────────────────
# Cover EN + DE + FR + ES + IT + PT.  with_minimum_relative_distance(0.1) means
# we require at least a 10 % confidence edge before committing; below that we
# default to "en" rather than guessing.
_lang_detector = (
    LanguageDetectorBuilder
    .from_languages(
        Language.ENGLISH, Language.GERMAN, Language.FRENCH,
        Language.SPANISH, Language.ITALIAN, Language.PORTUGUESE,
    )
    .with_minimum_relative_distance(0.1)
    .build()
)

_LINGUA_MAP = {
    Language.GERMAN:     "de",
    Language.FRENCH:     "fr",
    Language.SPANISH:    "es",
    Language.ITALIAN:    "it",
    Language.PORTUGUESE: "pt",
}


def detect_language(text: str) -> str:
    """Return ISO code if detected with sufficient confidence, else 'en'."""
    lang = _lang_detector.detect_language_of(text)
    return _LINGUA_MAP.get(lang, "en")


# ── GLiNER multilingual NER ───────────────────────────────────────────────────
_device = "cuda" if torch.cuda.is_available() else "cpu"
print(f"[presidio] Loading GLiNER model on {_device}…", flush=True)
_gliner = GLiNER.from_pretrained("urchade/gliner_multi_pii-v1").to(_device).eval()
print("[presidio] GLiNER ready.", flush=True)

# GLiNER entity label → Presidio entity type
# gliner_multi_pii-v1 was fine-tuned on these exact label strings.
_GLINER_LABEL_MAP: dict[str, str] = {
    "person":                     "PERSON",
    "organization":               "ORG",
    "phone number":               "PHONE_NUMBER",
    "mobile phone number":        "PHONE_NUMBER",
    "address":                    "LOCATION",
    "email":                      "EMAIL_ADDRESS",
    "credit card number":         "CREDIT_CARD",
    "social security number":     "US_SSN",
    "passport number":            "PASSPORT",
    "health insurance id number": "MEDICAL_LICENSE",
    "date of birth":              "DATE_TIME",
}
_GLINER_LABELS = list(_GLINER_LABEL_MAP.keys())


def _run_gliner(
    text: str,
    entities: Optional[List[str]],
    threshold: float,
    allow_list: Optional[List[str]],
    allow_list_match: str,
) -> list:
    """
    Run GLiNER on *text* and return results in Presidio RecognizerResult dict format.

    GLiNER is language-agnostic — the same model handles en, de, fr, es, it, pt
    without any language hint.  Long texts are split into overlapping windows to
    stay below GLiNER's 384-token internal truncation limit (~1 400 chars).
    Results are filtered against *entities* (if given) and *allow_list* (if given).
    """
    labels = _GLINER_LABELS
    if entities:
        requested = set(entities)
        labels = [lbl for lbl, etype in _GLINER_LABEL_MAP.items() if etype in requested]
    if not labels:
        return []

    # Collect predictions across all chunks; deduplicate by (start, end, label).
    seen: set[tuple[int, int, str]] = set()
    all_preds: list[dict] = []

    for chunk, offset in _chunk_text(text):
        with torch.no_grad():
            preds = _gliner.predict_entities(chunk, labels, threshold=threshold)
        for p in preds:
            abs_start = offset + p["start"]
            abs_end   = offset + p["end"]
            key = (abs_start, abs_end, p["label"])
            if key not in seen:
                seen.add(key)
                all_preds.append({**p, "start": abs_start, "end": abs_end})

    results = []
    for p in all_preds:
        ptype = _GLINER_LABEL_MAP.get(p["label"])
        if not ptype:
            continue
        # Allow-list filtering (mirrors Presidio's own allow_list behaviour)
        if allow_list:
            span_text = text[p["start"]:p["end"]]
            if allow_list_match == "exact" and span_text in allow_list:
                continue
            if allow_list_match != "exact" and any(
                a in span_text or span_text in a for a in allow_list
            ):
                continue
        results.append({
            "entity_type": ptype,
            "start": p["start"],
            "end": p["end"],
            "score": round(float(p["score"]), 4),
            "recognition_metadata": {"recognizer_name": "GlinerRecognizer"},
        })
    return results


# ── Presidio engine (regex / pattern recognisers only) ───────────────────────
# SpacyRecognizer is removed — all NER is handled by GLiNER above.
# The remaining recognisers are pattern-based (email, IBAN, phone, credit card,
# IP address, URL, …) and work on any language without modification.

class _NoOpEnhancer(ContextAwareEnhancer):
    """Skip the O(n²) LemmaContextAwareEnhancer — not needed with GLiNER."""
    def __init__(self):
        pass  # skip super().__init__() which requires positional args

    def enhance_using_context(self, text, raw_results, nlp_artifacts, recognizers, context):
        return raw_results


# Minimal NLP engine — en_core_web_sm is used only for tokenisation by the
# pattern recognisers' context lookup (which is itself a no-op via _NoOpEnhancer).
_nlp_config = {
    "nlp_engine_name": "spacy",
    "models": [{"lang_code": "en", "model_name": "en_core_web_sm"}],
}
_nlp_engine = NlpEngineProvider(nlp_configuration=_nlp_config).create_engine()

_registry = RecognizerRegistry()
_registry.load_predefined_recognizers(nlp_engine=_nlp_engine)
# Remove SpacyRecognizer — its NER output is replaced by GLiNER
_registry.recognizers = [
    r for r in _registry.recognizers if not isinstance(r, SpacyRecognizer)
]

engine = AnalyzerEngine(
    nlp_engine=_nlp_engine,
    registry=_registry,
    context_aware_enhancer=_NoOpEnhancer(),
)

# ── Warm-up ───────────────────────────────────────────────────────────────────
# Trigger model loading and any one-shot JIT / CUDA kernel compilation so the
# first real request is fast.
engine.analyze(text="warmup test@example.com +49-30-1234567", language="en")
_run_gliner("John Smith, Berlin, john@example.com", None, 0.1, None, "exact")
_run_gliner(
    "Herr Müller, München. IBAN DE89 3704 0044 0532 0130 00. Geb. 12.03.1980.",
    None, 0.1, None, "exact",
)

gc.freeze()

# Warm-up: exercise the chunking path with a text longer than _CHUNK_CHARS
_long_warmup = (
    "François Dupont, né le 12 mars 1980 à Paris. "
    "Son adresse email est francois.dupont@example.fr. "
    "Numéro de sécurité sociale: 1 80 03 75 123 456 78. "
) * 20   # ~1 400 chars × 20 = ~28 000 chars → exercises multi-chunk path
_run_gliner(_long_warmup, None, 0.1, None, "exact")
del _long_warmup

print("[presidio] Warm-up complete.", flush=True)


# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return "Presidio Analyzer service is up", 200


@app.post("/analyze")
def analyze():
    body             = request.get_json(force=True)
    text             = body.get("text", "")
    language         = body.get("language", "auto")
    entities         = body.get("entities") or None
    score_threshold  = body.get("score_threshold", 0.35)
    allow_list       = body.get("allow_list") or None
    allow_list_match = body.get("allow_list_match") or "exact"

    if not text:
        return jsonify([])

    # Auto language detection
    if language == "auto":
        language = detect_language(text)

    # Presidio regex/pattern recognisers.
    # Always run without an entity filter — after removing SpacyRecognizer the
    # remaining recognisers only cover pattern-based types (EMAIL_ADDRESS, IBAN_CODE,
    # CREDIT_CARD, …).  Passing GLiNER-only types such as PERSON would raise a
    # ValueError inside Presidio.  We filter the merged results in Python instead.
    presidio_results = engine.analyze(
        text=text, language="en",
        entities=None, score_threshold=score_threshold,
        allow_list=allow_list, allow_list_match=allow_list_match,
    )

    # GLiNER NER — handles all supported languages in a single pass.
    gliner_results = _run_gliner(text, entities, score_threshold, allow_list, allow_list_match)

    all_results = [r.to_dict() for r in presidio_results] + gliner_results

    # Apply entity-type filter to merged results if the caller requested specific types.
    if entities:
        entity_set = set(entities)
        all_results = [r for r in all_results if r["entity_type"] in entity_set]

    # Release per-request objects from generation 0.
    gc.collect(0)
    return jsonify(all_results)


@app.get("/recognizers")
def recognizers():
    names = [r.name for r in engine.get_recognizers(language="en")] + ["GlinerRecognizer"]
    return jsonify(names)


@app.get("/supportedentities")
def supported_entities():
    entities = set(engine.get_supported_entities(language="en"))
    entities.update(set(_GLINER_LABEL_MAP.values()))
    return jsonify(sorted(entities))


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 3000))
    app.run(host="0.0.0.0", port=port, threaded=False, use_reloader=False)
