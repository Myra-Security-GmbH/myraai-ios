-- admin/monitor.lua — real-time monitor dashboard + JSON stats endpoint
--
-- GET /monitor       → HTML dashboard (auto-refreshes via JS)
-- GET /monitor/stats → JSON snapshot (polled by the dashboard)

local json    = require("utils.json")
local cfg     = require("core.app_config")
local storage = require("storage")

local M = {}

-- ---------------------------------------------------------------------------
-- JSON stats — reads from storage module (reuses open DB handles) + shared dict
-- ---------------------------------------------------------------------------
function M.stats()
    local data = {
        now      = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        live     = {},
        today    = {},
        hour     = {},
        last_min = {},
        recent   = {},
        by_tenant = {},
    }

    -- Live counters from shared dict
    local d = ngx.shared[cfg.shared_dict and cfg.shared_dict.metrics or "aig_metrics"]
    if d then
        local function gv(k) return d:get(k) or 0 end
        local lsum   = gv("aig_latency_ms_sum")
        local lcount = gv("aig_latency_ms_count")
        data.live = {
            requests       = gv("aig_requests_total"),
            input_tokens   = gv("aig_input_tokens_total"),
            output_tokens  = gv("aig_output_tokens_total"),
            avg_latency_ms = lcount > 0 and math.floor(lsum / lcount) or 0,
            blocked        = gv("aig_blocked_total"),
        }
    end

    -- SQLite stats via the already-open storage handles
    local ok, stats = pcall(storage.get_usage_stats)
    if ok and stats then
        data.today          = stats.today
        data.hour           = stats.hour
        data.last_min       = stats.last_min
        data.by_tenant      = stats.by_tenant
        data.recent         = stats.recent
        data.recent_blocked = stats.recent_blocked
    end

    ngx.header["Content-Type"] = "application/json"
    ngx.say(json.encode(data))
end

-- ---------------------------------------------------------------------------
-- HTML dashboard
-- ---------------------------------------------------------------------------
function M.dashboard()
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.print([[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>AI Gateway Monitor</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: system-ui, sans-serif; background: #0f1117; color: #e2e8f0; font-size: 14px; }
  h1 { padding: 16px 24px; font-size: 18px; border-bottom: 1px solid #2d3748;
       display: flex; align-items: center; gap: 12px; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #48bb78;
         animation: pulse 2s infinite; }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.3} }
  .ts { margin-left: auto; font-size: 12px; color: #718096; font-weight: normal; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px,1fr));
          gap: 16px; padding: 20px 24px; }
  .card { background: #1a202c; border-radius: 8px; padding: 16px;
          border: 1px solid #2d3748; }
  .card .label { font-size: 11px; color: #718096; text-transform: uppercase;
                 letter-spacing: .05em; margin-bottom: 6px; }
  .card .value { font-size: 26px; font-weight: 700; color: #fff; }
  .card .sub   { font-size: 11px; color: #4a5568; margin-top: 4px; }
  .card.green .value { color: #68d391; }
  .card.blue  .value { color: #63b3ed; }
  .card.yellow .value { color: #f6e05e; }
  .card.purple .value { color: #b794f4; }
  .card.red   .value { color: #fc8181; }
  section { padding: 0 24px 24px; }
  h2 { font-size: 13px; color: #718096; text-transform: uppercase;
       letter-spacing: .05em; margin-bottom: 12px; padding-top: 4px; }
  table { width: 100%; border-collapse: collapse; }
  th { text-align: left; font-size: 11px; color: #4a5568; padding: 6px 10px;
       border-bottom: 1px solid #2d3748; }
  td { padding: 7px 10px; border-bottom: 1px solid #1a202c; font-size: 13px; }
  tr:hover td { background: #1a202c; }
  .pill { display:inline-block; padding: 1px 6px; border-radius: 3px;
          font-size: 11px; font-weight: 600; }
  .ok      { background:#2f855a; color:#c6f6d5; }
  .err     { background:#742a2a; color:#fed7d7; }
  .hit     { background:#2c5282; color:#bee3f8; }
  .blocked { background:#744210; color:#fefcbf; }
  #error { color: #fc8181; padding: 16px 24px; }
</style>
</head>
<body>
<h1>
  <span class="dot" id="dot"></span>
  AI Gateway Monitor
  <span class="ts" id="ts"></span>
</h1>
<div id="error"></div>

<div class="grid" id="cards">
  <div class="card blue">
    <div class="label">Requests today</div>
    <div class="value" id="c-req-today">—</div>
    <div class="sub" id="c-cached-today"></div>
  </div>
  <div class="card green">
    <div class="label">Cost today</div>
    <div class="value" id="c-cost-today">—</div>
    <div class="sub" id="c-cost-hour">last hour: —</div>
  </div>
  <div class="card purple">
    <div class="label">Input tokens today</div>
    <div class="value" id="c-in-today">—</div>
    <div class="sub" id="c-in-hour"></div>
  </div>
  <div class="card yellow">
    <div class="label">Output tokens today</div>
    <div class="value" id="c-out-today">—</div>
    <div class="sub" id="c-out-hour"></div>
  </div>
  <div class="card">
    <div class="label">Avg latency today</div>
    <div class="value" id="c-lat-today">—</div>
    <div class="sub">milliseconds</div>
  </div>
  <div class="card">
    <div class="label">Reqs last minute</div>
    <div class="value" id="c-req-min">—</div>
    <div class="sub" id="c-cost-min"></div>
  </div>
  <div class="card red">
    <div class="label">Blocked today</div>
    <div class="value" id="c-blocked-today">—</div>
    <div class="sub" id="c-blocked-hour">last hour: —</div>
  </div>
</div>

<section>
  <h2>By tenant — today</h2>
  <table id="tenant-table">
    <thead><tr>
      <th>Tenant</th><th>Requests</th>
      <th>Input tok</th><th>Output tok</th><th>Cost USD</th>
    </tr></thead>
    <tbody id="tenant-body"></tbody>
  </table>
</section>

<section style="margin-top:20px">
  <h2>Recent requests</h2>
  <table id="recent-table">
    <thead><tr>
      <th>Time</th><th>Tenant</th><th>Provider</th><th>Model</th>
      <th>Status</th><th>In</th><th>Out</th><th>Cost</th><th>ms</th>
    </tr></thead>
    <tbody id="recent-body"></tbody>
  </table>
</section>

<section style="margin-top:20px">
  <h2>Recent blocked requests</h2>
  <table id="blocked-table">
    <thead><tr>
      <th>Time</th><th>Tenant</th><th>Blocked by</th><th>Reason</th><th>ms</th>
    </tr></thead>
    <tbody id="blocked-body"></tbody>
  </table>
</section>

<script>
function fmt(n, decimals) {
  if (n == null) return '0';
  if (decimals != null) return Number(n).toFixed(decimals);
  if (n >= 1e6) return (n/1e6).toFixed(1) + 'M';
  if (n >= 1e3) return (n/1e3).toFixed(1) + 'K';
  return String(n);
}

function set(id, val) {
  var el = document.getElementById(id);
  if (el) el.textContent = val;
}

async function refresh() {
  try {
    const r = await fetch('/monitor/stats');
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const d = await r.json();

    document.getElementById('error').textContent = '';
    document.getElementById('dot').style.background = '#48bb78';
    set('ts', 'updated ' + d.now.slice(11,19) + ' UTC');

    const t = d.today || {};
    set('c-req-today',    fmt(t.requests));
    set('c-cached-today', t.cached ? fmt(t.cached) + ' cached' : '');
    set('c-cost-today',   '$' + fmt(t.cost_usd, 4));
    set('c-in-today',     fmt(t.input_tokens));
    set('c-out-today',    fmt(t.output_tokens));
    set('c-lat-today',    fmt(t.avg_latency_ms) + ' ms');

    const h = d.hour || {};
    set('c-cost-hour', 'last hour: $' + fmt(h.cost_usd, 4));
    set('c-in-hour',   'last hour: ' + fmt(h.input_tokens));
    set('c-out-hour',  'last hour: ' + fmt(h.output_tokens));

    const m = d.last_min || {};
    set('c-req-min',  fmt(m.requests));
    set('c-cost-min', '$' + fmt(m.cost_usd, 6));

    set('c-blocked-today', fmt(t.blocked || 0));
    set('c-blocked-hour',  'last hour: ' + fmt((d.hour || {}).blocked || 0));

    // Tenant table
    const tb = document.getElementById('tenant-body');
    tb.innerHTML = '';
    (d.by_tenant || []).forEach(function(row) {
      const tr = tb.insertRow();
      [row.tenant || row.tenant_id, fmt(row.requests),
       fmt(row.input_tokens), fmt(row.output_tokens),
       '$' + fmt(row.cost_usd, 4)].forEach(function(v) {
        tr.insertCell().textContent = v;
      });
    });

    // Recent requests
    const rb = document.getElementById('recent-body');
    rb.innerHTML = '';
    (d.recent || []).forEach(function(row) {
      const tr = rb.insertRow();
      const status = row.status;
      const ok = (status >= 200 && status < 300);
      const cells = [
        row.ts, row.tenant_id, row.provider, row.model,
        '', fmt(row.input_tokens), fmt(row.output_tokens),
        '$' + fmt(row.cost_usd, 5), row.latency_ms
      ];
      cells.forEach(function(v, i) {
        const td = tr.insertCell();
        if (i === 4) {
          const pill = document.createElement('span');
          if (row.blocked) {
            pill.className = 'pill blocked';
            pill.textContent = row.blocked_by || 'blocked';
          } else if (row.cached) {
            pill.className = 'pill hit';
            pill.textContent = 'cached';
          } else {
            pill.className = 'pill ' + (ok ? 'ok' : 'err');
            pill.textContent = status;
          }
          td.appendChild(pill);
        } else {
          td.textContent = v;
        }
      });
    });

    // Blocked requests
    const bb = document.getElementById('blocked-body');
    bb.innerHTML = '';
    (d.recent_blocked || []).forEach(function(row) {
      const tr = bb.insertRow();
      [row.ts, row.tenant || row.tenant_id, row.blocked_by, row.block_reason, row.latency_ms]
        .forEach(function(v, i) {
          const td = tr.insertCell();
          if (i === 2) {
            const pill = document.createElement('span');
            pill.className = 'pill blocked';
            pill.textContent = v || '';
            td.appendChild(pill);
          } else {
            td.textContent = v != null ? v : '';
          }
        });
    });

  } catch(e) {
    document.getElementById('dot').style.background = '#fc8181';
    document.getElementById('error').textContent = 'Error fetching stats: ' + e.message;
  }
}

refresh();
setInterval(refresh, 2000);
</script>
</body>
</html>]])
end

-- ---------------------------------------------------------------------------
-- Router
-- ---------------------------------------------------------------------------
function M.handle()
    require("admin.auth").require_session()
    local uri = ngx.var.uri
    if uri == "/monitor/stats" then
        M.stats()
    else
        M.dashboard()
    end
end

return M
