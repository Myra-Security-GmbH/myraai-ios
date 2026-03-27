# JSON Schema Guardrail

The JSON schema guardrail is a **Tier 1** (in-process, no external call) guardrail that validates model responses against a declared JSON schema. It is suited for structured-output enforcement — classification endpoints, data extraction pipelines, and any use case where the model must return machine-readable JSON conforming to a known shape.

---

## Configuration fields

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"json_schema"` |
| `name` | string | — | Human-readable label for this guardrail instance |
| `action` | string | `"block"` | What to do on a violation: `block` or `flag` |
| `target` | string | `"response"` | Must be `"response"` — this guardrail only inspects model responses |
| `schema` | object | — | JSON schema descriptor — see [Schema properties](#schema-properties) below |

!!! note "Response-only guardrail"
    The JSON schema guardrail cannot be targeted at `request` or `both`. Set `target: "response"` (or omit `target`, as `"response"` is the default).

---

## Schema properties

The `schema` object supports a `required` array and a `properties` map. Each entry in `properties` may declare any of the following constraints.

| Constraint | Applies to | Description |
|---|---|---|
| `type` | all | Expected JSON type: `string`, `number`, `boolean`, `array`, `object`, or `null` |
| `min` | number | Minimum value (inclusive) |
| `max` | number | Maximum value (inclusive) |
| `min_length` | string | Minimum character length (inclusive) |
| `max_length` | string | Maximum character length (inclusive) |
| `enum` | any | Array of allowed values — the field value must be one of the listed items |

---

## Block reason codes

When the guardrail triggers, the `block_reason` log field contains one of the following codes.

| Code | Meaning |
|---|---|
| `json_parse_error` | The response body is not valid JSON after stripping markdown code fences |
| `missing_field:<name>` | A field listed in `required` is absent from the response object |
| `type_mismatch:<name>` | The field is present but its JSON type does not match the declared `type` |
| `range_violation:<name>` | A numeric or string constraint (`min`, `max`, `min_length`, `max_length`, `enum`) is not satisfied |

!!! tip "Markdown code fences are stripped automatically"
    Before parsing, the guardrail removes any surrounding markdown code fences (`` ``` `` … `` ``` ``) from the response body. Models that habitually wrap JSON in `` ```json … ``` `` blocks are handled correctly without any special configuration.

---

## Examples

### Enforce structured output for a classification endpoint

Requires the response to be a JSON object containing `result` (a string) and `label` (one of three allowed values). Any response that fails to parse, omits a required field, or uses an unexpected label is blocked.

```json
{
  "type": "json_schema",
  "name": "classification-schema",
  "action": "block",
  "target": "response",
  "schema": {
    "required": ["result", "label"],
    "properties": {
      "result": { "type": "string" },
      "label": { "enum": ["positive", "negative", "neutral"] }
    }
  }
}
```

### Flag schema violations without blocking (monitoring mode)

Use `action: "flag"` during a rollout to measure how often the model produces non-conforming output before committing to blocking behaviour.

```json
{
  "type": "json_schema",
  "name": "classification-schema-monitor",
  "action": "flag",
  "target": "response",
  "schema": {
    "required": ["result", "label"],
    "properties": {
      "result": { "type": "string" },
      "label": { "enum": ["positive", "negative", "neutral"] }
    }
  }
}
```

↳ Violations are recorded in `detectors_fired` and `block_reason` on the log entry. The response is not modified and the caller receives it unchanged.

The JSON schema guardrail is **Tier 1** — it runs in-process with no external calls. It runs in the response phase only; request-phase guardrails are not affected. A `block` verdict from this guardrail stops the pipeline immediately. No subsequent guardrails run.

---

## See Also

- [Guardrail Pipeline Overview](../guardrails.md)
- [Regex Guardrail](regex.md)
