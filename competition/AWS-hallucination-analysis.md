# AWS Bedrock — Hallucination Detection Analysis

> Source: AWS documentation and blog posts — analyzed March 2026.
> Focus: How Bedrock detects and blocks hallucinated LLM responses at runtime and offline.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Contextual Grounding Check](#2-contextual-grounding-check)
3. [Automated Reasoning Checks](#3-automated-reasoning-checks)
4. [Model Evaluation / LLM-as-a-Judge](#4-model-evaluation--llm-as-a-judge)
5. [Coverage by Phase](#5-coverage-by-phase)
6. [Third-Party Integrations](#6-third-party-integrations)
7. [Competitive Assessment](#7-competitive-assessment)
8. [Implementation Ideas](#8-implementation-ideas)

---

## 1. Overview

Bedrock addresses hallucination through three distinct mechanisms with different trade-offs:

| Mechanism | Type | When | Blocks? |
|---|---|---|---|
| Contextual Grounding Check | Probabilistic confidence scorer | Runtime, per-request | Yes |
| Automated Reasoning Checks | Formal logic / SMT verification | Runtime, per-request | Yes |
| Model Evaluation / LLM-as-a-Judge | Offline batch evaluation | Post-hoc measurement | No |

The first two are runtime filters configured as part of **Bedrock Guardrails**. The third is a benchmarking tool, not a blocking mechanism.

A key architectural feature: the `ApplyGuardrail` API decouples all three from Bedrock model invocation. Any LLM — OpenAI, Gemini, SageMaker, on-premises — can have its responses evaluated by Bedrock Guardrails as a standalone HTTP endpoint.

---

## 2. Contextual Grounding Check

**The primary runtime hallucination filter.** GA'd in 2024 as part of Bedrock Guardrails.

### How it works

The check requires three inputs per inference call:

| Input | Role | Limit |
|---|---|---|
| `grounding_source` | Reference text (RAG passages, documents) | 100,000 characters |
| `query` | The user's question | 1,000 characters |
| `guard_content` | The model response to evaluate | 5,000 characters |

The system produces two independent confidence scores (0.0–0.99):

| Score | What it measures |
|---|---|
| **Grounding** | Whether the response is factually supported by the reference source — no facts introduced beyond what the source contains |
| **Relevance** | Whether the response actually answers the query |

Both scores are compared against operator-configured thresholds. If either score falls below its threshold, the response is **blocked** and replaced with a configured fallback message.

AWS claims the check filters >75% of hallucinated responses in RAG and summarization workloads.

### Guardrail configuration

```python
bedrock.create_guardrail(
    name='rag-guardrail',
    contextualGroundingPolicyConfig={
        "filtersConfig": [
            {"type": "GROUNDING", "threshold": 0.85},
            {"type": "RELEVANCE", "threshold": 0.50},
        ]
    },
)
```

Threshold guidance from AWS:
- `0.7` — lenient (recommended for creative/conversational tasks)
- `0.85` — balanced (recommended starting point for RAG)
- `0.95+` — strict (for high-stakes fact-retrieval; high false-positive risk)

### ApplyGuardrail API — standalone use

The check can be used independently of Bedrock model invocation via the `ApplyGuardrail` endpoint:

```python
client.apply_guardrail(
    guardrailIdentifier='arn:aws:bedrock:...',
    guardrailVersion='DRAFT',
    source='OUTPUT',                  # grounding only runs on OUTPUT
    content=[
        {'text': {'text': '<reference passages>',  'qualifiers': ['grounding_source']}},
        {'text': {'text': '<user question>',        'qualifiers': ['query']}},
        {'text': {'text': '<model response>',       'qualifiers': ['guard_content']}},
    ],
    outputScope='FULL',               # return scores even when not blocked
)
```

Response shape:

```json
{
  "action": "GUARDRAIL_INTERVENED",
  "assessments": [{
    "contextualGroundingPolicy": {
      "filters": [
        {"type": "GROUNDING", "threshold": 0.85, "score": 0.23, "action": "BLOCKED"},
        {"type": "RELEVANCE", "threshold": 0.50, "score": 0.91, "action": "NONE"}
      ]
    }
  }]
}
```

### Technical notes

- **Phase**: response-only. The grounding source and query are provided at input time as reference material; scoring only runs against the model output. Input content is not hallucination-checked.
- **Scoring model**: black-box managed service — AWS does not document what embedding technique or underlying model powers the scorer.
- **Streaming**: relevance is evaluated per chunk; if any chunk is deemed relevant, the overall response is treated as relevant. A low-relevance response may partially stream before the block is applied.
- **Agent invocations**: scores are only accessible with `trace='ENABLED_FULL'` set on `invoke_agent`; by default only blocked responses surface the scores.

---

## 3. Automated Reasoning Checks

**The only deterministic (non-probabilistic) hallucination check.** GA'd August 2025.

### How it works

1. Operator uploads a policy/rules document (max 5 MB, 50,000 characters).
2. Bedrock extracts those rules into **SMT-LIB formal logic** (Satisfiability Modulo Theories — a standard mathematical logic format used in formal verification).
3. A fidelity report is generated with a **Coverage score** (fraction of source rules captured) and **Accuracy score** (correctness of the extraction), both 0.0–1.0.
4. At inference time, model responses are evaluated against the compiled logical model.

### Verdict per response

| Verdict | Meaning |
|---|---|
| `Valid` | Response is logically consistent with all extracted rules |
| `Invalid` | Response violates one or more rules — includes explanation and correction suggestions |
| `No Data` | Insufficient information to render a verdict (ambiguous input) |

AWS claims up to 99% accuracy at identifying correct responses.

### Use case distinction

| | Contextual Grounding | Automated Reasoning |
|---|---|---|
| **Question** | "Is this response supported by these passages?" | "Does this response comply with these defined rules?" |
| **Domain** | Free-form RAG, summarization | Closed-domain policy (benefits, terms, regulations) |
| **Scoring** | Probabilistic (0.0–0.99) | Deterministic (Valid/Invalid/No Data) |
| **Setup cost** | Low (pass reference text per call) | High (document upload, extraction, fidelity validation) |
| **Latency** | Low | Higher (SMT solving is computationally heavier) |

### Constraints

- English (US) only
- Maximum 2 Automated Reasoning policies per guardrail
- Contradictory or highly nested source documents degrade extraction quality
- Best suited for well-structured reference documents (insurance policy docs, benefit handbooks, regulatory text)

---

## 4. Model Evaluation / LLM-as-a-Judge

**Offline batch measurement tool — does not block responses at runtime.**

### How it works

An FM judge (operator-selectable) evaluates a batch of inference responses across built-in metric categories:

| Metric | Measures |
|---|---|
| **Faithfulness** | Hallucination rate relative to retrieved context; higher = fewer hallucinations |
| Correctness | Whether the answer is factually correct |
| Completeness | Whether the answer covers all required aspects |
| Relevance | Whether the answer addresses the query |
| Coherence | Logical and grammatical consistency |

### RAG-specific metrics

| Metric | Layer |
|---|---|
| Context relevance | Retrieval quality — are the retrieved chunks relevant to the query? |
| Context coverage | Do retrieved chunks cover the information needed to answer? |
| Citation coverage | Does the response cite all supporting chunks? |
| Citation precision | Do cited chunks actually support the response? |
| **Faithfulness** | Does the generation introduce facts not in the retrieved context? |

### Custom metrics

GA'd April 2025. Operators can write their own judge prompts with numerical or categorical scoring scales and inject dataset variables into the prompt at evaluation time. Pre-built starter templates are provided.

### Access model

You can bring your own inference responses via S3. The judge evaluates any model — not just Bedrock-hosted FMs.

### Documented limitations

- **Evaluator capability ceiling** — if the judge model cannot solve the underlying task, its evaluation is unreliable
- **Evaluation hallucination** — the judge may incorrectly penalize correct answers
- **Offline only** — this is a measurement/benchmarking tool, not a runtime filter

---

## 5. Coverage by Phase

| Check | Input/Request phase | Output/Response phase |
|---|---|---|
| Contextual Grounding (hallucination) | No — source provided here but not scored | **Yes** |
| Automated Reasoning | No | **Yes** |
| Content/harm filters | Yes | Yes |
| Denied topics | Yes | Yes |
| PII / sensitive info detection | Yes | Yes |
| Prompt attack detection | Yes | No |

The guardrail pipeline evaluates input first. If input is blocked, model inference is skipped entirely. Output evaluation only runs if input passes.

---

## 6. Third-Party Integrations

AWS publishes integration guides for the following open-source tools:

### RAGAS

Open-source evaluation framework. Natively supports Bedrock models as both the generator and the critic.

Metrics: faithfulness, answer relevancy, context precision, context recall.

AWS blog posts show: RAGAS + Bedrock Agents + Lambda for custom hallucination detection workflows with human-in-the-loop remediation. The RAGAS Lambda function is designed to be swappable with any other evaluation framework.

### LlamaIndex

RAG framework. AWS-published integration guides show LlamaIndex + RAGAS + Bedrock for end-to-end RAG evaluation including hallucination metrics. LlamaIndex provides the retrieval pipeline; RAGAS provides the metrics; Bedrock models serve as both LLM and evaluation critic.

### Langfuse

Open-source observability. Full compatibility with Bedrock: request tracing + LLM-as-a-judge evaluation + prompt experiments. Captures per-request traces and metrics for monitoring hallucination rates in production over time.

---

## 7. Competitive Assessment

### Strengths of Bedrock's approach

1. **ApplyGuardrail API** — The decoupling of guardrail evaluation from model invocation is architecturally significant. Any LLM can use Bedrock's hallucination detection as an external scoring service. This lowers the switching cost for customers who don't host on Bedrock.

2. **Dual scoring** — Returning both a grounding score (factual accuracy) and a relevance score (answer quality) separately allows operators to tune independently. A response can be factually grounded but non-responsive to the query, or responsive but hallucinated — the two-score model surfaces both failure modes.

3. **Automated Reasoning** — The only competitor offering formal mathematical verification rather than probabilistic scoring. For closed-domain policy compliance, this is categorically stronger than similarity-based approaches.

4. **Configurable thresholds** — Operators choose their own grounding/relevance thresholds per guardrail. This makes the false-positive rate tunable rather than fixed by the vendor.

5. **Provider-agnostic via API** — The scoring endpoint works regardless of what LLM produced the response.

### Weaknesses and limitations

1. **Black-box scorer** — The grounding score is a managed service with no documentation of the underlying model or embedding technique. Operators cannot inspect, audit, or improve the scoring mechanism.

2. **Input-phase gap** — Hallucination detection only runs at the response phase. There is no mechanism to pre-validate a prompt against a knowledge source before sending it to the model (e.g., "does this question have a grounded answer in our corpus?").

3. **5,000-character response cap** — The `guard_content` field has a hard 5,000-character limit. Long-form responses (reports, summaries, multi-section documents) cannot be fully evaluated in a single call. Long responses require chunking and multiple API calls.

4. **100,000-character grounding source cap** — For large document corpora, the operator must pre-select which passages to provide as the grounding source. Effective use requires a well-tuned retrieval layer to pass the right chunks.

5. **No score in streaming default** — Scores are only accessible in agent flows with `trace='ENABLED_FULL'`. Streaming responses may partially deliver before a block is applied.

6. **Automated Reasoning setup cost** — The formal logic extraction step requires clean, well-structured source documents and a fidelity validation cycle before the check is reliable. It is not suited for ad-hoc or frequently-changing reference material.

7. **English-only** — Automated Reasoning is English (US) only. Contextual grounding handles multilingual text but is not explicitly documented for non-English accuracy.

---

## 8. Implementation Ideas

Our AI Gateway currently has no hallucination detection. The Bedrock approach suggests two viable directions:

### Option A: RAG grounding check (inline, Tier 2 guardrail)

Add a `grounding` guardrail type that requires the client to pass a `grounding_source` alongside the inference request (as a system prompt extension or a custom header). After the upstream model responds, the guardrail calls an embedding-based similarity scorer to compare the response against the grounding source.

Implementation sketch:
- `src/guardrails/grounding.lua` — Tier 2 sidecar call
- Client passes `grounding_source` in the request body (under a custom key stripped before forwarding to provider)
- After upstream response, embed both the response and the grounding source chunks, compute max cosine similarity per claim (or use a locally hosted faithfulness model)
- Block or flag below a configurable threshold
- Log `grounding_score` on the request log entry

The embedding can reuse the semantic cache embedding infrastructure (`src/cache/semantic.lua` / `embed_text()`).

### Option B: LLM-as-a-judge faithfulness check (async, Tier 2 guardrail)

Add a `faithfulness` guardrail type that sends a judge prompt to a secondary LLM after the primary response is received. The judge prompt asks: "Given this context: [grounding_source], does this response: [model_output] introduce any claims not supported by the context? Answer YES/NO with explanation."

Implementation sketch:
- `src/guardrails/faithfulness.lua` — Tier 2 sidecar or inline secondary LLM call
- Uses the existing `upstream.lua` provider machinery to call the judge model
- Judge model configurable per gateway (can be a small model like `gpt-4o-mini` or a locally hosted Llama)
- Blocking or flagging based on the judge's YES/NO verdict
- Async option: score after response delivery, log the result without blocking (useful for monitoring before enabling blocking)

### Threshold exposure

Either implementation should expose a configurable threshold in the gateway config:

```json
{
  "guardrails": [{
    "type": "grounding",
    "name": "rag-grounding",
    "action": "block",
    "target": "response",
    "threshold": 0.85,
    "judge_model": "gpt-4o-mini"
  }]
}
```

### What Bedrock does that we should not replicate

- **Automated Reasoning (SMT)** — High setup cost, English-only, narrow applicability. Not worth implementing for a general-purpose gateway. Applicable only to very specific regulated-domain customers who have structured policy documents.
- **Managed scoring black box** — The grounding scorer AWS provides is a competitive moat precisely because it is opaque and managed. We should use an open or auditable scoring approach (embedding cosine similarity, RAGAS faithfulness, or LLM-as-a-judge with inspectable prompts).
