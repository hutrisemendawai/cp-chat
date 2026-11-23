import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';

import type { AppContext } from './context.js';
import { requireAuth } from './context.js';
import { ApiError } from '../lib/errors.js';
import { verifyAccessToken } from '../lib/tokens.js';
import type { LogLevel } from '../lib/log-store.js';

const clientLogSchema = z.object({
  level: z.enum(['debug', 'info', 'warn', 'error', 'fatal']).default('info'),
  tag: z.string().trim().max(80).optional(),
  message: z.string().min(1).max(2_000),
  meta: z.record(z.string(), z.unknown()).optional(),
  ts: z.coerce.number().int().positive().optional(),
});

const MAX_CLIENT_ENTRY_BYTES = 4 * 1024;
const CLIENT_RATE_LIMIT = 120;
const CLIENT_RATE_WINDOW_SECONDS = 60;
const SSE_KEEPALIVE_MS = 15_000;

/**
 * Authorizes the dashboard and the log API.
 *
 * When `LOG_VIEWER_TOKEN` is configured it is the only accepted credential
 * (header, query string, or bearer). When it is empty — the default for local
 * and LAN use — the viewer is open, but a bearer access token is still decoded
 * so entries can be attributed when a signed-in user browses.
 */
function authorizeLogAccess(request: FastifyRequest, ctx: AppContext): string | null {
  const config = ctx.config;
  const expected = config.LOG_VIEWER_TOKEN;

  const header = request.headers.authorization;
  const bearer = header?.startsWith('Bearer ') ? header.slice('Bearer '.length).trim() : null;
  const query = request.query as { token?: unknown } | undefined;
  const queryToken = typeof query?.token === 'string' ? query.token : null;
  const viewerHeader = request.headers['x-log-token'];
  const viewedToken = typeof viewerHeader === 'string' ? viewerHeader : null;

  const presented = viewedToken ?? queryToken ?? bearer;

  if (expected) {
    if (!presented || presented !== expected) {
      throw new ApiError('unauthorized', 'A valid log viewer token is required');
    }
    return null;
  }

  if (!bearer) return null;
  try {
    return verifyAccessToken(bearer, config).sub;
  } catch {
    return null;
  }
}

function parseOptionalNumber(value: unknown): number | undefined {
  if (typeof value !== 'string' || value.trim() === '') return undefined;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function parseSince(value: unknown): number | undefined {
  if (typeof value !== 'string' || value.trim() === '') return undefined;
  const asNumber = Number(value);
  if (Number.isFinite(asNumber)) return asNumber;
  const asDate = Date.parse(value);
  return Number.isFinite(asDate) ? asDate : undefined;
}

function parseString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined;
}

/**
 * Limits mobile log submission per user. Logging must never be able to exhaust
 * the API, but a failed counter read should not reject the entry either — the
 * buffer itself is bounded and pruned.
 */
async function enforceClientRateLimit(ctx: AppContext, userId: string): Promise<void> {
  const key = `cpchat:logs:client:${userId}`;
  try {
    const count = await ctx.redis.incr(key);
    if (count === 1) await ctx.redis.expire(key, CLIENT_RATE_WINDOW_SECONDS);
    if (count > CLIENT_RATE_LIMIT) {
      throw new ApiError('rate_limited', 'Too many client log entries');
    }
  } catch (error) {
    if (error instanceof ApiError) throw error;
  }
}

export function registerLogRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { logs, config } = ctx;

  app.get('/api/v1/logs', async (request, reply) => {
    authorizeLogAccess(request, ctx);
    const query = request.query as Record<string, unknown>;

    const result = await logs.query({
      service: parseString(query.service),
      level: parseString(query.level),
      q: parseString(query.q),
      since: parseSince(query.since),
      limit: parseOptionalNumber(query.limit),
    });

    reply.header('cache-control', 'no-store');
    return {
      logs: result.logs,
      count: result.count,
      retention_seconds: result.retention_seconds,
      viewer: { retention_seconds: result.retention_seconds, enabled: logs.isEnabled },
    };
  });

  /**
   * Server-Sent Events tail. Each browser tab receives new entries as they are
   * published to `cpchat:logs:live`; a comment frame keeps intermediary proxies
   * from closing an idle connection.
   */
  app.get('/api/v1/logs/stream', async (request, reply) => {
    authorizeLogAccess(request, ctx);

    // Take the response over from Fastify: an SSE handler writes the raw socket
    // and never returns a body, so the normal reply lifecycle must be bypassed.
    reply.hijack();
    const res = reply.raw;
    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-store, no-transform',
      connection: 'keep-alive',
      'x-accel-buffering': 'no',
    });
    res.write(': connected\n\n');
    res.write('retry: 3000\n\n');

    let closed = false;
    const send = (data: unknown) => {
      if (closed) return;
      try {
        res.write(`data: ${JSON.stringify(data)}\n\n`);
      } catch {
        closed = true;
      }
    };

    const unsubscribe = await logs.subscribeLive(send);
    const keepalive = setInterval(() => {
      if (closed) return;
      try {
        res.write(': keepalive\n\n');
      } catch {
        closed = true;
      }
    }, SSE_KEEPALIVE_MS);
    keepalive.unref?.();

    const cleanup = () => {
      if (closed) return;
      closed = true;
      clearInterval(keepalive);
      unsubscribe();
      try {
        res.end();
      } catch {
        // The socket is already gone.
      }
    };

    res.on('close', cleanup);
    res.on('error', cleanup);
  });

  app.post('/api/v1/logs/client', async (request, reply) => {
    requireAuth(request, config);
    await enforceClientRateLimit(ctx, request.userId);

    const parsed = clientLogSchema.safeParse(request.body);
    if (!parsed.success) {
      throw new ApiError('validation_error', 'Request failed validation', {
        issues: parsed.error.issues.map((issue) => ({
          path: issue.path.join('.'),
          message: issue.message,
        })),
      });
    }
    const input = parsed.data;

    const meta: Record<string, unknown> = { ...(input.meta ?? {}) };
    if (input.tag) meta.tag = input.tag;

    const size = Buffer.byteLength(JSON.stringify({ ...input, meta }), 'utf8');
    if (size > MAX_CLIENT_ENTRY_BYTES) {
      throw new ApiError(
        'validation_error',
        `Client log entries are limited to ${MAX_CLIENT_ENTRY_BYTES} bytes`,
      );
    }

    await logs.append({
      service: 'mobile',
      level: input.level as LogLevel,
      message: input.message,
      ts: input.ts,
      user_id: request.userId,
      meta: Object.keys(meta).length > 0 ? meta : undefined,
    });

    reply.status(202).send({ accepted: true });
  });

  app.delete('/api/v1/logs', async (request, reply) => {
    authorizeLogAccess(request, ctx);
    await logs.clear();
    reply.status(204).send();
  });

  app.get('/logs', async (request, reply) => {
    authorizeLogAccess(request, ctx);
    reply.header('cache-control', 'no-store');
    reply.type('text/html; charset=utf-8');
    return renderDashboard(logs.retentionSeconds);
  });
}

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/**
 * Zero-build dashboard. Everything is inlined so it works on a LAN with no
 * internet access and no bundler step.
 */
export function renderDashboard(retentionSeconds: number): string {
  const retentionLabel =
    retentionSeconds >= 3600
      ? `${Math.round(retentionSeconds / 3600)} hour`
      : `${retentionSeconds} seconds`;
  const banner = escapeHtml(`Retention: ${retentionLabel} (auto-purge)`);

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>CP Chat — Live Logs</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #0b0f17;
    --panel: #111827;
    --panel-2: #0f1626;
    --border: #1f2a3d;
    --text: #e5edf7;
    --muted: #8b9bb4;
    --accent: #60a5fa;
    --info: #38bdf8;
    --warn: #fbbf24;
    --error: #f87171;
    --debug: #94a3b8;
    --ok: #34d399;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; }
  body {
    background: var(--bg);
    color: var(--text);
    font: 14px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    display: flex;
    flex-direction: column;
    min-height: 100vh;
  }
  header {
    padding: 14px 16px;
    background: var(--panel);
    border-bottom: 1px solid var(--border);
    display: flex;
    flex-wrap: wrap;
    gap: 12px;
    align-items: center;
    justify-content: space-between;
  }
  .brand { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
  .brand h1 { font-size: 16px; margin: 0; letter-spacing: .02em; }
  .badge {
    font-size: 11px;
    padding: 3px 8px;
    border-radius: 999px;
    border: 1px solid var(--border);
    background: var(--panel-2);
    color: var(--muted);
    white-space: nowrap;
  }
  .badge.ok { color: var(--ok); border-color: #14532d; }
  .badge.bad { color: var(--error); border-color: #7f1d1d; }
  .stats { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  .toolbar {
    display: flex;
    gap: 10px;
    flex-wrap: wrap;
    align-items: center;
    padding: 10px 16px;
    background: var(--panel-2);
    border-bottom: 1px solid var(--border);
  }
  .group { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
  .group-label { color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: .08em; }
  button, .chip {
    font: inherit;
    font-size: 12px;
    color: var(--text);
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 6px 10px;
    cursor: pointer;
    transition: border-color .15s ease, background .15s ease;
  }
  button:hover, .chip:hover { border-color: var(--accent); }
  .chip.active { border-color: var(--accent); background: #172554; color: #dbeafe; }
  .chip[data-level="warn"].active { border-color: var(--warn); background: #422006; color: #fde68a; }
  .chip[data-level="error"].active { border-color: var(--error); background: #450a0a; color: #fecaca; }
  input[type="search"] {
    font: inherit;
    font-size: 13px;
    color: var(--text);
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 7px 10px;
    min-width: 220px;
    flex: 1;
  }
  input[type="search"]:focus { outline: none; border-color: var(--accent); }
  main { flex: 1; overflow: auto; padding: 8px 12px 40px; }
  .empty { color: var(--muted); text-align: center; padding: 48px 12px; }
  .row {
    border: 1px solid transparent;
    border-bottom-color: var(--border);
    padding: 7px 10px;
    cursor: pointer;
  }
  .row:hover { background: var(--panel-2); }
  .row.open { background: var(--panel); border-color: var(--border); border-radius: 8px; }
  .line { display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap; }
  .ts { color: var(--muted); font-size: 12px; white-space: nowrap; }
  .svc {
    font-size: 11px;
    padding: 1px 7px;
    border-radius: 999px;
    background: var(--panel-2);
    border: 1px solid var(--border);
    color: var(--muted);
  }
  .svc.rest { color: #93c5fd; }
  .svc.gateway { color: #c4b5fd; }
  .svc.mobile { color: #6ee7b7; }
  .lvl { font-size: 11px; font-weight: 700; letter-spacing: .06em; min-width: 46px; }
  .lvl.debug { color: var(--debug); }
  .lvl.info { color: var(--info); }
  .lvl.warn { color: var(--warn); }
  .lvl.error, .lvl.fatal { color: var(--error); }
  .msg { flex: 1; min-width: 200px; word-break: break-word; }
  .route { color: var(--muted); font-size: 12px; }
  .detail {
    margin-top: 8px;
    background: var(--panel-2);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 10px;
    overflow: auto;
  }
  .detail pre { margin: 0; font-size: 12px; color: #cbd5e1; white-space: pre-wrap; word-break: break-word; }
  @media (max-width: 640px) {
    header { padding: 10px 12px; }
    .toolbar { padding: 8px 12px; }
    input[type="search"] { min-width: 100%; }
  }
</style>
</head>
<body>
<header>
  <div class="brand">
    <h1>CP Chat — Live Logs</h1>
    <span class="badge">${banner}</span>
  </div>
  <div class="stats">
    <span class="badge" id="count">0 entries</span>
    <span class="badge" id="connection">SSE: connecting</span>
  </div>
</header>
<div class="toolbar">
  <div class="group" id="service-chips">
    <span class="group-label">Service</span>
    <button class="chip active" data-service="all">All</button>
    <button class="chip" data-service="rest">rest</button>
    <button class="chip" data-service="gateway">gateway</button>
    <button class="chip" data-service="mobile">mobile</button>
  </div>
  <div class="group" id="level-chips">
    <span class="group-label">Level</span>
    <button class="chip active" data-level="all">ALL</button>
    <button class="chip" data-level="info">INFO</button>
    <button class="chip" data-level="warn">WARN</button>
    <button class="chip" data-level="error">ERROR</button>
  </div>
  <input type="search" id="search" placeholder="Search messages, paths, users..." autocomplete="off" />
  <div class="group">
    <button id="pause">Pause</button>
    <button id="clear">Clear Logs</button>
  </div>
</div>
<main id="list"><div class="empty">Loading…</div></main>
<script>
(function () {
  var state = { service: 'all', level: 'all', q: '', paused: false, entries: [], source: null };
  var list = document.getElementById('list');
  var countEl = document.getElementById('count');
  var connectionEl = document.getElementById('connection');
  var searchEl = document.getElementById('search');
  var pauseEl = document.getElementById('pause');
  var clearEl = document.getElementById('clear');
  var token = new URLSearchParams(window.location.search).get('token');
  var LEVEL_WEIGHT = { debug: 10, info: 20, warn: 30, error: 40, fatal: 50 };

  function headers() {
    return token ? { 'x-log-token': token, authorization: 'Bearer ' + token } : {};
  }
  function apiUrl(path) {
    return token ? path + (path.indexOf('?') >= 0 ? '&' : '?') + 'token=' + encodeURIComponent(token) : path;
  }
  function matches(entry) {
    if (state.service !== 'all' && entry.service !== state.service) return false;
    if (state.level !== 'all' && (LEVEL_WEIGHT[entry.level] || 0) < LEVEL_WEIGHT[state.level]) return false;
    if (!state.q) return true;
    var haystack = JSON.stringify(entry).toLowerCase();
    return haystack.indexOf(state.q) >= 0;
  }
  function nearestRows() {
    return list.querySelectorAll('.row');
  }
  function formatTime(ts) {
    var d = new Date(ts);
    return d.toLocaleTimeString([], { hour12: false }) + '.' + String(d.getMilliseconds()).padStart(3, '0');
  }
  function buildRow(entry) {
    var row = document.createElement('div');
    row.className = 'row';
    var line = document.createElement('div');
    line.className = 'line';
    var ts = document.createElement('span');
    ts.className = 'ts';
    ts.textContent = formatTime(entry.ts);
    var svc = document.createElement('span');
    svc.className = 'svc ' + entry.service;
    svc.textContent = entry.service;
    var lvl = document.createElement('span');
    lvl.className = 'lvl ' + entry.level;
    lvl.textContent = entry.level.toUpperCase();
    var msg = document.createElement('span');
    msg.className = 'msg';
    msg.textContent = entry.message;
    line.appendChild(ts);
    line.appendChild(svc);
    line.appendChild(lvl);
    line.appendChild(msg);
    if (entry.method || entry.path) {
      var route = document.createElement('span');
      route.className = 'route';
      route.textContent = (entry.method || '') + ' ' + (entry.path || '');
      line.appendChild(route);
    }
    if (typeof entry.status_code === 'number') {
      var status = document.createElement('span');
      status.className = 'route';
      status.textContent = String(entry.status_code);
      line.appendChild(status);
    }
    row.appendChild(line);

    var detail = null;
    row.addEventListener('click', function () {
      if (detail) {
        detail.remove();
        detail = null;
        row.classList.remove('open');
        return;
      }
      detail = document.createElement('div');
      detail.className = 'detail';
      var pre = document.createElement('pre');
      pre.textContent = JSON.stringify(entry, null, 2);
      detail.appendChild(pre);
      row.appendChild(detail);
      row.classList.add('open');
    });
    return row;
  }
  function shouldStick() {
    return state.paused === false && (list.scrollTop + list.clientHeight >= list.scrollHeight - 80);
  }
  function render() {
    var stick = shouldStick();
    var visible = state.entries.filter(matches);
    list.textContent = '';
    if (visible.length === 0) {
      var empty = document.createElement('div');
      empty.className = 'empty';
      empty.textContent = state.entries.length === 0 ? 'No log entries in the last hour.' : 'No entries match the current filters.';
      list.appendChild(empty);
    } else {
      var frag = document.createDocumentFragment();
      for (var i = 0; i < visible.length; i += 1) frag.appendChild(buildRow(visible[i]));
      list.appendChild(frag);
    }
    updateCount();
    if (stick) list.scrollTop = list.scrollHeight;
  }
  function updateCount() {
    countEl.textContent = state.entries.length + (state.entries.length === 1 ? ' entry' : ' entries');
  }
  function addEntry(entry) {
    state.entries.push(entry);
    if (state.entries.length > 5000) state.entries.splice(0, state.entries.length - 5000);
    if (!matches(entry)) { updateCount(); return; }
    var stick = shouldStick();
    var empty = list.querySelector('.empty');
    if (empty) list.textContent = '';
    list.appendChild(buildRow(entry));
    updateCount();
    if (stick) list.scrollTop = list.scrollHeight;
  }
  function load() {
    fetch(apiUrl('/api/v1/logs?limit=1000'), { headers: headers() })
      .then(function (res) {
        if (!res.ok) throw new Error('HTTP ' + res.status);
        return res.json();
      })
      .then(function (body) {
        state.entries = Array.isArray(body.logs) ? body.logs : [];
        render();
      })
      .catch(function () {
        list.textContent = '';
        var empty = document.createElement('div');
        empty.className = 'empty';
        empty.textContent = 'Could not load logs. Check the viewer token.';
        list.appendChild(empty);
      });
  }
  function connect() {
    if (typeof EventSource === 'undefined') {
      connectionEl.textContent = 'SSE: unsupported';
      connectionEl.className = 'badge bad';
      return;
    }
    var source = new EventSource(apiUrl('/api/v1/logs/stream'));
    state.source = source;
    source.onopen = function () {
      connectionEl.textContent = 'SSE: live';
      connectionEl.className = 'badge ok';
    };
    source.onmessage = function (event) {
      try { addEntry(JSON.parse(event.data)); } catch (e) { /* ignore malformed frame */ }
    };
    source.onerror = function () {
      connectionEl.textContent = 'SSE: reconnecting';
      connectionEl.className = 'badge bad';
    };
  }
  function selectChip(containerId, attribute, value) {
    var chips = document.getElementById(containerId).querySelectorAll('.chip');
    for (var i = 0; i < chips.length; i += 1) {
      chips[i].classList.toggle('active', chips[i].getAttribute(attribute) === value);
    }
  }
  document.getElementById('service-chips').addEventListener('click', function (event) {
    var chip = event.target.closest('.chip');
    if (!chip) return;
    state.service = chip.getAttribute('data-service');
    selectChip('service-chips', 'data-service', state.service);
    render();
  });
  document.getElementById('level-chips').addEventListener('click', function (event) {
    var chip = event.target.closest('.chip');
    if (!chip) return;
    state.level = chip.getAttribute('data-level');
    selectChip('level-chips', 'data-level', state.level);
    render();
  });
  searchEl.addEventListener('input', function () {
    state.q = searchEl.value.trim().toLowerCase();
    render();
  });
  pauseEl.addEventListener('click', function () {
    state.paused = !state.paused;
    pauseEl.textContent = state.paused ? 'Resume' : 'Pause';
    pauseEl.classList.toggle('active', state.paused);
    if (!state.paused) list.scrollTop = list.scrollHeight;
  });
  clearEl.addEventListener('click', function () {
    fetch(apiUrl('/api/v1/logs'), { method: 'DELETE', headers: headers() })
      .then(function () {
        state.entries = [];
        render();
      })
      .catch(function () { /* the next live entry will surface the error */ });
  });

  load();
  connect();
})();
</script>
</body>
</html>`;
}
