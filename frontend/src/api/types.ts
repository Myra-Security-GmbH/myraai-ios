export type BudgetPeriod = "monthly" | "daily" | "total";

export interface SpendRecord {
  period: string;
  amount_micro: number;
  amount_usd: number;
  updated_at: number;
}

// ---------------------------------------------------------------------------
// SIEM connector types
// ---------------------------------------------------------------------------

export type SiemType = "splunk_hec" | "elasticsearch" | "vector" | "syslog";
export type SiemEvent = "blocked" | "guardrail" | "scrubbed" | "all";

export interface SiemConfig {
  type: SiemType;
  events?: SiemEvent[];
  // HTTP backends (splunk_hec, elasticsearch, vector)
  url?: string;
  token?: string;         // Splunk HEC only
  index?: string;         // Splunk HEC + Elasticsearch
  username?: string;      // Elasticsearch basic auth
  password?: string;      // Elasticsearch basic auth
  // Syslog backend
  host?: string;
  port?: number;
  protocol?: "udp" | "tcp";
  format?: "cef" | "rfc5424";
}

export interface TenantPreset {
  id: string;
  name: string;
  gateway_id: string;
  provider: string;
  model: string;
}

export interface Tenant {
  id: string;
  slug: string;
  plan: string;
  budget_usd: number | null;
  budget_period: BudgetPeriod;
  siem?: SiemConfig;
  chat_presets?: TenantPreset[];
  created_at: string;
}

// ---------------------------------------------------------------------------
// Detector types
// ---------------------------------------------------------------------------

export type DetectorAction = "block" | "scrub" | "flag";
export type DetectorTarget = "request" | "response" | "both";

/** Named individual patterns */
export type PatternName =
  | "email" | "phone" | "ssn" | "dob" | "ip_address"
  | "cc" | "cvv" | "card_expiry" | "iban" | "routing_number"
  | "mrn" | "npi" | "national_id" | "passport_number"
  | "api_key" | "jwt";

/** Named pattern sets */
export type PatternSetName =
  | "pci_pan" | "hipaa_structured" | "gdpr_structured"
  | "credentials" | "pii_basic";

export interface RegexDetector {
  type: "regex";
  name: string;
  action: DetectorAction;
  target?: DetectorTarget;
  patterns?: Array<PatternName | PatternSetName>;
  custom_patterns?: string[];
  scrub_placeholder?: string;
}

export interface KeywordDetector {
  type: "keyword";
  name: string;
  action: DetectorAction;
  target?: DetectorTarget;
  keywords: string[];
  case_sensitive?: boolean;
  whole_word?: boolean;
}

export interface JailbreakDetector {
  type: "jailbreak";
  name: string;
  action: DetectorAction;
  target?: DetectorTarget;
  /** When non-empty, replaces the built-in 18 phrases entirely. */
  keywords?: string[];
  case_sensitive?: boolean;
  whole_word?: boolean;
}

export interface PresidioDetector {
  type: "presidio";
  name: string;
  action: DetectorAction;
  target?: DetectorTarget;
  url?: string;
  entities?: string[];
  score_threshold?: number;
  allow_list?: string[];
  allow_list_match?: "exact" | "partial";
  fail_open?: boolean;
}

export interface PromptGuardDetector {
  type: "prompt_guard";
  name: string;
  action: DetectorAction;
  target?: DetectorTarget;
  url?: string;
  timeout_ms?: number;
  categories?: string[];
  context_prompt?: string;
  fail_open?: boolean;
}

export interface PiiProtectorDetector {
  type: "pii_protector";
  name: string;
  /** Always runs on both request and response phases. */
  target?: DetectorTarget;
  analyzer_url?: string;
  entities?: string[];
  score_threshold?: number;
  allow_list?: string[];
  allow_list_match?: "exact" | "partial";
  skip_system_messages?: boolean;
  fail_open?: boolean;
}

export type DetectorConfig =
  | RegexDetector
  | KeywordDetector
  | JailbreakDetector
  | PresidioDetector
  | PromptGuardDetector
  | PiiProtectorDetector;

// ---------------------------------------------------------------------------
// Gateway config
// ---------------------------------------------------------------------------

export interface LoadBalanceConfig {
  strategy?: "weighted_random" | "round_robin";
  sticky?: { field: string; ttl?: number };
  targets: Array<{ provider: string; model: string; weight: number }>;
}

export interface CircuitBreakerConfig {
  enabled: boolean;
  failure_threshold?: number;    // default 5
  window_sec?: number;           // default 60
  cooldown_ms?: number;          // default 30000
  failure_status_codes?: number[]; // default [500,502,503,504]
}

export type WebhookEvent = "blocked" | "budget_exceeded" | "circuit_open";

export interface WebhookConfig {
  url: string;
  secret?: string;               // optional HMAC-SHA256 signing key
  events?: WebhookEvent[];       // absent = subscribe to all events
}

export interface GatewayConfig {
  auth_required?: boolean;
  budget_usd?: number;
  budget_period?: BudgetPeriod;
  cache_ttl?: number;
  retry_count?: number;
  timeout_ms?: number;
  log_payloads?: boolean;
  rate_limit?: { requests: number; window_sec: number };
  circuit_breaker?: CircuitBreakerConfig;
  webhooks?: WebhookConfig;
  siem?: SiemConfig;
  guardrails?: DetectorConfig[];
  /** @deprecated Use `guardrails`. Accepted for backwards compatibility with configs saved before the rename. */
  detectors?: DetectorConfig[];
  provider_base_urls?: Record<string, string>;
}

export interface Gateway {
  id: string;
  slug: string;
  tenant_id: string;
  config: GatewayConfig;
  created_at: string;
}

export interface User {
  id: string;
  tenant_id: string | null;
  email: string;
  name: string | null;
  role: "admin" | "tenant_admin" | "member" | "viewer";
  created_at: string;
  last_login_at: string | null;
}

export interface AuthToken {
  id: string;
  gateway_id: string;
  token_hash: string;
  scopes: string[];
  expires_at: string | null;
  created_at: string;
  user_id: string | null;
  label: string | null;
  rate_limit: { requests: number; window_sec: number } | null;
  budget_usd: number | null;
}

export interface LogEntry {
  id: string;
  ts: string;
  tenant: string;
  tenant_id: string;
  gateway?: string;
  gateway_id: string;
  provider: string;
  model: string;
  status: number;
  cached: number;
  blocked: number;
  blocked_by: string | null;
  block_reason: string | null;
  guardrail_verdict: string | null;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
  latency_ms: number;
  upstream_latency_ms: number | null;
  guardrail_latency_ms: number | null;
  upstream_attempts: number;
  fallback_provider: string | null;
  fallback_model: string | null;
  saved_cost_usd: number | null;
  request_size_bytes: number;
  detectors_fired: string[];
  scrub_applied: number;
  response_raw?: string | null;
  prompt?: string | null;
  response?: string | null;
  trace_id?: string | null;
}

export interface TraceStep {
  id: number;
  trace_id: string;
  seq: number;
  step: string;
  data: Record<string, unknown>;
  ts: number;
}

export interface TraceDetail {
  trace: {
    id: string;
    gateway_id: string;
    model: string | null;
    created_at: number;
    completed_at: number | null;
    status: string;
    error: string | null;
    source: string;
  };
  steps: TraceStep[];
}

export interface PeriodStats {
  requests: number;
  cached: number;
  blocked: number;
  scrubbed: number;
  flagged: number;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
  saved_cost_usd: number;
  avg_latency_ms: number;
  avg_upstream_latency_ms: number;
}

export interface CircuitBreakerProviderStatus {
  state: "closed" | "open" | "half_open";
  failures: number;
  opened_at?: number;   // unix seconds; present when state is open or half_open
  cooldown_ms?: number;
}

export type CircuitBreakerStatus = Record<string, CircuitBreakerProviderStatus>;

export interface GatewayGuardrailStats {
  blocked: number;
  scrubbed: number;
  flagged: number;
  avg_guardrail_ms: number;
}

export interface GuardrailEvent {
  ts: string;
  blocked: number;
  scrub_applied: number;
  detectors_fired: string[];
  blocked_by: string | null;
  block_reason: string | null;
  guardrail_latency_ms: number | null;
  guardrail_verdict: string | null;
  provider: string;
  model: string;
  latency_ms: number;
  gateway?: string | null;
  gateway_id?: string | null;
  tenant?: string | null;
  tenant_id?: string | null;
}

export interface TenantStats {
  tenant_id: string;
  tenant: string;
  requests: number;
  blocked: number;
  cached: number;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
  saved_cost_usd: number;
  avg_latency_ms: number;
  errors: number;
}

export interface GatewayStats {
  gateway_id: string;
  gateway: string;
  tenant: string | null;
  requests: number;
  blocked: number;
  cached: number;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
  saved_cost_usd: number;
  avg_latency_ms: number;
  errors: number;
}

export interface UserStats {
  user_id: string;
  tenant_id: string;
  email: string | null;
  requests: number;
  blocked: number;
  cached: number;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
  saved_cost_usd: number;
  avg_latency_ms: number;
  errors: number;
}

export interface TenantAnalyticsDetail {
  timeseries: TimeseriesPoint[];
  top_models: TopModelRow[];
}

export type TimeseriesBucket = "5m" | "15m" | "30m" | "1h" | "6h" | "1d";

export interface TimeseriesPoint {
  ts: number;        // Unix ms, start of bucket
  requests: number;
  blocked: number;
  cost_usd: number;
}

export interface UsageStats {
  today: PeriodStats;
  yesterday: PeriodStats;
  last_7d: PeriodStats;
  hour: PeriodStats;
  last_min: PeriodStats;
  by_tenant: TenantStats[];
  recent: LogEntry[];
  recent_blocked: LogEntry[];
}

export interface ProviderConfig {
  id: string;
  provider: string;
  alias: string;
  created_at: string;
}

export interface RoutingRule {
  id: string;
  priority: number;
  conditions: Array<{ field: string; op: string; value: string }>;
  actions: {
    provider?: string;
    model?: string;
    fallbacks?: Array<{ provider: string; model: string }>;
    load_balance?: LoadBalanceConfig;
  };
  enabled: number;
}

export interface ModelPrice {
  provider: string;
  model: string;
  input_per_1k: number;
  output_per_1k: number;
  cache_write_per_1k: number | null;
  cache_read_per_1k: number | null;
  updated_at: string;
}

// ---------------------------------------------------------------------------
// Playground
// ---------------------------------------------------------------------------

export interface PlaygroundToken {
  token: string;
  expires_at: string;
  tenant_slug: string;
  gateway_slug: string;
}

export interface PlaygroundMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

export interface PlaygroundPanelResult {
  content: string;
  latency_ms: number;
  input_tokens: number | null;
  output_tokens: number | null;
  cost_usd: number | null;
  error: string | null;
}

export interface ProviderMeta {
  name: string;
  requires_key: boolean;
}

export interface LatencyPercentiles {
  p50: number | null;
  p95: number | null;
  p99: number | null;
}

export interface TopModelRow {
  model: string;
  provider: string;
  requests: number;
  cost_usd: number;
  avg_latency_ms: number;
}

export interface AnalyticsDepth {
  percentiles: LatencyPercentiles;
  top_models: TopModelRow[];
  by_tenant: TenantStats[];
  by_gateway: GatewayStats[];
  by_user: UserStats[];
}

// ---------------------------------------------------------------------------
// Chat types
// ---------------------------------------------------------------------------

export interface ChatConversation {
  id: string;
  user_id?: string;
  gateway_id: string;
  title: string;
  model: string;
  system_prompt: string | null;
  temperature: number;
  max_tokens: number;
  created_at: string;
  updated_at: string;
  messages?: ChatMessage[];
}

export interface ChatMessage {
  id: string;
  conversation_id?: string;
  parent_message_id: string | null;
  role: "user" | "assistant" | "system";
  /** Plain text, or JSON-serialised content blocks when attachments are present. */
  content: string;
  input_tokens: number | null;
  output_tokens: number | null;
  cost_usd: number | null;
  latency_ms: number | null;
  gateway_id?: string | null;
  model?: string | null;
  created_at: string;
  attachments?: ChatAttachment[];
}

export interface ChatAttachment {
  id: string;
  message_id: string;
  filename: string;
  mime_type: string;
  size_bytes: number;
  created_at: string;
  /** Only present when fetched via GET /attachments/:id */
  data?: string;
}

export interface ChatPreset {
  id: string;
  name: string;
  model: string;
  system_prompt: string | null;
  temperature: number | null;
  max_tokens: number | null;
  created_at: string;
  updated_at: string;
}
