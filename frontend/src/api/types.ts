export interface Tenant {
  id: string;
  slug: string;
  plan: string;
  budget_usd: number | null;
  created_at: string;
}

export interface GatewayConfig {
  auth_required?: boolean;
  budget_usd?: number;
  cache_ttl?: number;
  retry_count?: number;
  timeout_ms?: number;
  log_payloads?: boolean;
  rate_limit?: { requests: number; window_sec: number };
  guardrails?: { enabled: boolean; llama_guard_url?: string; timeout_ms?: number; fail_open?: boolean };
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
  tenant_id: string;
  tenant_slug: string;
  email: string;
  name: string | null;
  role: "admin" | "member" | "viewer";
  created_at: string;
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
}

export interface PeriodStats {
  requests: number;
  cached: number;
  blocked: number;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
  saved_cost_usd: number;
  avg_latency_ms: number;
  avg_upstream_latency_ms: number;
}

export interface TenantStats {
  tenant_id: string;
  tenant: string;
  requests: number;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
}

export interface UsageStats {
  today: PeriodStats;
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
  actions: { provider?: string; model?: string; fallbacks?: Array<{ provider: string; model: string }> };
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
