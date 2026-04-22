#!/usr/bin/env python3
"""
gen_prompts.py — Generate synthetic performance-test prompt corpus.

Creates 200 prompts matching the production token distribution:
  50% short   (800–1 200 tokens)  — single-turn questions
  35% medium  (1 500–2 500 tokens) — multi-turn or code tasks
  15% long    (5 000–10 000 tokens)— document analysis, long context

Uses tiktoken cl100k_base as a proxy tokeniser (within ~10% of Qwen3 for English).
No PII — safe to commit and replay.

Usage:
  python3 gen_prompts.py [--output prompts.jsonl] [--seed 42]
"""

import argparse
import json
import random
import sys

try:
    import tiktoken
    enc = tiktoken.get_encoding("cl100k_base")
    def count_tokens(text: str) -> int:
        return len(enc.encode(text))
except ImportError:
    # fallback: ~4 chars per token
    def count_tokens(text: str) -> int:
        return max(1, len(text) // 4)

# ---------------------------------------------------------------------------
# Prompt templates
# ---------------------------------------------------------------------------

SHORT_TEMPLATES = [
    "Explain what {concept} is in 2–3 sentences, using a concrete example.",
    "What is the difference between {a} and {b}? Answer in bullet points.",
    "Write a one-paragraph summary of how {technology} works.",
    "List 5 common mistakes developers make when using {concept}.",
    "What are the pros and cons of {approach}?",
    "In plain language, explain {concept} to someone who has never programmed.",
    "How does {algorithm} work? Give the key steps.",
    "What does {term} mean in the context of {field}?",
    "Give 3 real-world use cases for {technology}.",
    "What is the time complexity of {algorithm} and why?",
]

MEDIUM_TEMPLATES = [
    """You are a senior software engineer reviewing a pull request.
The change introduces {pattern} into the codebase. Write a detailed code review comment
(3–5 paragraphs) explaining: (1) what the change does, (2) potential risks, (3) how to
improve it. Be specific and actionable.""",

    """Write a technical blog post (400–500 words) explaining {topic} for
intermediate developers. Cover: background, why it matters, how it works, and a
practical example. Use headers and bullet points where appropriate.""",

    """Design a REST API for a {domain} application. Specify the following:
- 5 main resource endpoints with HTTP methods and URL patterns
- Request/response body shapes (JSON) for each endpoint
- Authentication strategy
- Error response format
- Rate limiting approach
Provide a brief rationale for each design decision.""",

    """A system is experiencing {problem} under load. As a senior DevOps engineer:
1. List 5 possible root causes in order of likelihood
2. Explain how you would diagnose each one
3. Propose a fix for the most likely cause
4. Describe how you'd validate the fix in production""",

    """Write a Python function that {task}. Requirements:
- Full type annotations
- Docstring with Args/Returns/Raises
- Input validation
- Unit tests using pytest (at least 4 test cases including edge cases)
After the code, explain your design decisions in 2–3 paragraphs.""",

    """Compare and contrast {a} and {b} as solutions to {problem}.
Structure your answer as: (1) brief definition of each, (2) performance characteristics,
(3) when to choose each, (4) migration considerations, (5) summary table.""",
]

LONG_TEMPLATES = [
    """You are a principal engineer writing an Architecture Decision Record (ADR) for a
major infrastructure change: migrating from {old_tech} to {new_tech} at a company with
50 engineers, 200 microservices, and 99.99% SLA requirements.

The ADR must include:
1. Title and status
2. Context (technical and business)
3. Decision drivers (at least 6)
4. Considered options (at least 3 alternatives with full trade-offs for each)
5. Decision outcome with rationale
6. Consequences (positive, negative, neutral)
7. Implementation plan (phases, timelines, rollback strategy)
8. Success metrics

Write a thorough, production-quality ADR that a real engineering team could use.""",

    """Write a comprehensive tutorial on {technology} for developers who know
{prerequisite} but have never used {technology} before.

Structure:
1. Introduction and motivation (why {technology}, what problems it solves)
2. Core concepts and terminology (at least 8 concepts)
3. Installation and setup (step-by-step for Linux)
4. Hello World example with full explanation
5. Key features with code examples (at least 5 features)
6. Common patterns and best practices
7. Error handling and debugging
8. Performance considerations
9. Integration with {related_tool}
10. When NOT to use {technology}

Make the tutorial at least 1500 words, practical, and accurate.""",

    """You are a senior database architect. A startup is designing a data model for a
{domain} platform with the following requirements:
- 10 million users, 1 billion records projected in 3 years
- Real-time read latency < 10 ms at p99
- Complex analytics queries (aggregations, time-series, joins)
- Multi-tenancy with strict data isolation
- GDPR compliance (right to erasure, data portability)
- Audit logging for all mutations

Provide:
1. Entity-relationship diagram (described in text)
2. Full schema definition (table names, columns, types, constraints, indexes)
3. Sharding/partitioning strategy
4. Caching layer design
5. Analytics vs OLTP separation approach
6. GDPR implementation (specific tables and procedures)
7. Backup and disaster recovery plan
8. Estimated storage requirements at Year 1, Year 2, Year 3""",

    """Write a security threat model for a {application_type} application that:
- Handles payments and PII
- Has mobile apps (iOS, Android), a web app, and a REST API
- Uses third-party OAuth providers
- Stores data in a multi-tenant cloud database

The threat model must cover:
1. Architecture overview and trust boundaries
2. Asset inventory with sensitivity classification
3. Full STRIDE analysis (Spoofing, Tampering, Repudiation, Information Disclosure,
   Denial of Service, Elevation of Privilege) for each component
4. Top 10 OWASP risks and their mitigations in this context
5. Attack tree for the most critical threat
6. Security controls matrix (preventive, detective, corrective)
7. Incident response playbook for a data breach
8. Security testing checklist""",
]

# ---------------------------------------------------------------------------
# Fillers for templates
# ---------------------------------------------------------------------------

CONCEPTS = [
    "eventual consistency", "CAP theorem", "idempotency", "back-pressure",
    "service mesh", "circuit breaker", "distributed tracing", "blue-green deployment",
    "CQRS", "event sourcing", "saga pattern", "outbox pattern", "two-phase commit",
    "gossip protocol", "consistent hashing", "vector clocks",
]
TECHNOLOGIES = [
    "Kubernetes", "Redis", "Apache Kafka", "gRPC", "GraphQL", "PostgreSQL",
    "Elasticsearch", "Prometheus", "Terraform", "Istio", "ArgoCD", "HashiCorp Vault",
]
ALGORITHMS = [
    "quicksort", "Dijkstra's algorithm", "binary search", "B-tree indexing",
    "consistent hashing", "Bloom filter", "LRU cache eviction", "Raft consensus",
]
PAIRS = [
    ("REST", "GraphQL"), ("SQL", "NoSQL"), ("monolith", "microservices"),
    ("TCP", "UDP"), ("OAuth2", "API keys"), ("JWT", "session cookies"),
    ("Kafka", "RabbitMQ"), ("Docker", "Kubernetes"), ("Prometheus", "Datadog"),
]
PROBLEMS = [
    "high CPU utilisation", "memory leaks", "slow database queries",
    "race conditions", "cascading failures", "thundering herd",
]
TASKS = [
    "validates an email address and returns True/False",
    "parses a YAML config file and returns a typed dataclass",
    "retries an HTTP request with exponential backoff and jitter",
    "implements a rate limiter using the token bucket algorithm",
    "streams a large file to S3 with checksums and retry on failure",
]
DOMAINS = [
    "e-commerce", "healthcare", "fintech", "SaaS B2B", "ride-sharing", "edtech",
]
OLD_NEW = [
    ("bare-metal servers", "Kubernetes"),
    ("monolithic deployment", "microservices"),
    ("MySQL", "CockroachDB"),
    ("Jenkins CI", "GitHub Actions"),
    ("on-premise data centre", "AWS"),
]
TUTORIAL_TECH = [
    ("Kafka", "Python", "Redis"),
    ("gRPC", "REST APIs", "Protobuf"),
    ("Kubernetes", "Docker", "Helm"),
    ("Terraform", "bash scripting", "Ansible"),
]
APP_TYPES = [
    "healthcare", "financial services", "marketplace", "social media", "logistics",
]


def fill_template(template: str, rng: random.Random) -> str:
    replacements = {
        "{concept}": rng.choice(CONCEPTS),
        "{a}": rng.choice(TECHNOLOGIES),
        "{b}": rng.choice(TECHNOLOGIES),
        "{technology}": rng.choice(TECHNOLOGIES),
        "{algorithm}": rng.choice(ALGORITHMS),
        "{approach}": rng.choice(CONCEPTS),
        "{term}": rng.choice(CONCEPTS),
        "{field}": rng.choice(["distributed systems", "databases", "networking", "security"]),
        "{pattern}": rng.choice(CONCEPTS),
        "{topic}": rng.choice(CONCEPTS + TECHNOLOGIES),
        "{domain}": rng.choice(DOMAINS),
        "{problem}": rng.choice(PROBLEMS),
        "{task}": rng.choice(TASKS),
        "{old_tech}": rng.choice([x[0] for x in OLD_NEW]),
        "{new_tech}": rng.choice([x[1] for x in OLD_NEW]),
        "{prerequisite}": rng.choice(TECHNOLOGIES),
        "{related_tool}": rng.choice(TECHNOLOGIES),
        "{application_type}": rng.choice(APP_TYPES),
    }
    result = template
    for key, val in replacements.items():
        result = result.replace(key, val)
    # Handle pair templates
    if "{a}" in result or "{b}" in result:
        pair = rng.choice(PAIRS)
        result = result.replace("{a}", pair[0]).replace("{b}", pair[1])
    return result


def pad_to_tokens(text: str, target_min: int, target_max: int, rng: random.Random) -> str:
    """Pad a prompt with filler context to reach the target token range."""
    current = count_tokens(text)
    if target_min <= current <= target_max:
        return text

    padding_topics = [
        "networking protocols", "database indexing strategies", "containerization",
        "cryptographic algorithms", "load balancing techniques", "caching strategies",
        "API versioning approaches", "distributed system patterns",
    ]
    extra_parts = [
        f"\n\nAdditional context for your response: consider the implications for {rng.choice(padding_topics)} "
        f"and {rng.choice(padding_topics)}. Also think about scalability implications when the system "
        f"grows by 10x in the next year.",
        f"\n\nPlease also consider: (1) how this applies in a multi-region deployment, "
        f"(2) relevant {rng.choice(padding_topics)} considerations, "
        f"(3) operational complexity for a small team of 5 engineers.",
        f"\n\nContext: this is for a production system handling 50,000 requests per second "
        f"with strict SLA requirements. The team uses {rng.choice(TECHNOLOGIES)} extensively "
        f"and has expertise in {rng.choice(TECHNOLOGIES)}.",
    ]

    while count_tokens(text) < target_min:
        text += rng.choice(extra_parts)

    # Trim if too long (rare edge case)
    if count_tokens(text) > target_max:
        # crude trim by characters
        ratio = target_max / count_tokens(text)
        text = text[:int(len(text) * ratio * 0.95)]

    return text


def generate_corpus(n: int = 200, seed: int = 42) -> list:
    rng = random.Random(seed)
    corpus = []

    n_short  = int(n * 0.50)   # 100
    n_medium = int(n * 0.35)   # 70
    n_long   = n - n_short - n_medium  # 30

    def make_prompts(templates, bucket_size, tmin, tmax):
        prompts = []
        attempts = 0
        while len(prompts) < bucket_size and attempts < bucket_size * 10:
            attempts += 1
            tpl = rng.choice(templates)
            text = fill_template(tpl, rng)
            text = pad_to_tokens(text, tmin, tmax, rng)
            tok = count_tokens(text)
            if tmin <= tok <= tmax:
                prompts.append({"text": text, "approx_tokens": tok,
                                 "bucket": f"{tmin}-{tmax}"})
        # If we couldn't reach bucket_size, append duplicates with different seeds
        while len(prompts) < bucket_size:
            p = rng.choice(prompts) if prompts else {"text": "Explain REST APIs.", "approx_tokens": 5, "bucket": f"{tmin}-{tmax}"}
            prompts.append(p)
        return prompts

    corpus += make_prompts(SHORT_TEMPLATES,  n_short,  800,  1200)
    corpus += make_prompts(MEDIUM_TEMPLATES, n_medium, 1500, 2500)
    corpus += make_prompts(LONG_TEMPLATES,   n_long,   5000, 10000)

    rng.shuffle(corpus)
    return corpus


def main():
    parser = argparse.ArgumentParser(description="Generate synthetic prompt corpus")
    parser.add_argument("--output", default="prompts.jsonl")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--n", type=int, default=200)
    args = parser.parse_args()

    print(f"Generating {args.n} prompts (seed={args.seed})…", file=sys.stderr)
    corpus = generate_corpus(n=args.n, seed=args.seed)

    buckets = {}
    for p in corpus:
        b = p["bucket"]
        buckets[b] = buckets.get(b, 0) + 1

    with open(args.output, "w") as f:
        for p in corpus:
            f.write(json.dumps(p, ensure_ascii=False) + "\n")

    print(f"Written {len(corpus)} prompts to {args.output}", file=sys.stderr)
    print(f"Distribution: {dict(sorted(buckets.items()))}", file=sys.stderr)
    token_counts = [p["approx_tokens"] for p in corpus]
    print(f"Token stats  min={min(token_counts)} median={sorted(token_counts)[len(token_counts)//2]} max={max(token_counts)}", file=sys.stderr)


if __name__ == "__main__":
    main()
