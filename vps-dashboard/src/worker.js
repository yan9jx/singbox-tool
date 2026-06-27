const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
};

const MAX_BODY_BYTES = 64 * 1024;
const NODE_ID_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    try {
      if (url.pathname === "/api/v1/health" && request.method === "GET") {
        return json({ ok: true, service: "ejectors-vps-dashboard" });
      }

      if (url.pathname === "/api/v1/session" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("查看密码不正确");
        return json({ ok: true });
      }

      if (url.pathname === "/api/v1/nodes" && request.method === "GET") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return statusStore(env).fetch(new Request("https://store/nodes"));
      }

      if (url.pathname === "/api/v1/node-settings" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return updateNodeSettings(request, env);
      }

      if (url.pathname === "/api/v1/telegram/test" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        if (!telegramConfigured(env)) return json({ ok: false, error: "Telegram 尚未配置" }, 400);
        await sendTelegram(env, "✅ VPS 状态面板 Telegram 提醒连接成功");
        return json({ ok: true });
      }

      if (url.pathname === "/api/v1/heartbeat" && request.method === "POST") {
        if (!isIngestAuthorized(request, env)) return unauthorized("上报密钥不正确");
        return receiveHeartbeat(request, env, "online");
      }

      if (url.pathname === "/api/v1/shutdown" && request.method === "POST") {
        if (!isIngestAuthorized(request, env)) return unauthorized("上报密钥不正确");
        return receiveHeartbeat(request, env, "shutdown");
      }

      if (url.pathname.startsWith("/api/")) {
        return json({ ok: false, error: "接口不存在" }, 404);
      }

      return env.ASSETS.fetch(request);
    } catch (error) {
      console.error(error);
      return json({ ok: false, error: "服务器内部错误" }, 500);
    }
  },

  async scheduled(controller, env, ctx) {
    ctx.waitUntil(statusStore(env).fetch(new Request(`https://store/run-reminders?now=${Math.floor(controller.scheduledTime / 1000)}`, {
      method: "POST",
    })));
  },
};

async function receiveHeartbeat(request, env, forcedState) {
  const contentLength = Number(request.headers.get("content-length") || 0);
  if (contentLength > MAX_BODY_BYTES) {
    return json({ ok: false, error: "上报数据过大" }, 413);
  }

  let input;
  try {
    input = await request.json();
  } catch {
    return json({ ok: false, error: "JSON 格式错误" }, 400);
  }

  if (!input || typeof input !== "object" || !NODE_ID_PATTERN.test(input.node_id || "")) {
    return json({ ok: false, error: "node_id 格式错误" }, 400);
  }

  const now = Math.floor(Date.now() / 1000);
  const nodeId = input.node_id;
  const name = cleanText(input.name || nodeId, 80);
  const payload = sanitizePayload(input, nodeId, name);
  payload.reported_at = now;
  payload.agent_state = forcedState;

  const record = {
    payload,
    agent_state: forcedState,
    last_seen: now,
    shutdown_at: forcedState === "shutdown" ? now : null,
  };
  return statusStore(env).fetch(new Request("https://store/report", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(record),
  }));
}

function statusStore(env) {
  return env.STATUS_STORE.getByName("global");
}

async function updateNodeSettings(request, env) {
  let input;
  try {
    input = await request.json();
  } catch {
    return json({ ok: false, error: "JSON 格式错误" }, 400);
  }

  const nodeId = String(input?.node_id || "");
  const expiryDate = String(input?.expiry_date || "");
  const memo = cleanText(input?.memo, 500);
  const reminderAt = Number(input?.reminder_at || 0);
  if (!NODE_ID_PATTERN.test(nodeId)) return json({ ok: false, error: "node_id 格式错误" }, 400);
  if (expiryDate && !isValidDate(expiryDate)) return json({ ok: false, error: "到期日期格式错误" }, 400);
  if (!Number.isInteger(reminderAt) || reminderAt < 0 || reminderAt > 4102444800) {
    return json({ ok: false, error: "提醒时间格式错误" }, 400);
  }

  const settings = {
    expiry_date: expiryDate,
    memo,
    reminder_at: reminderAt,
    telegram_enabled: input?.telegram_enabled !== false,
  };
  return statusStore(env).fetch(new Request("https://store/settings", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ node_id: nodeId, settings }),
  }));
}

export class VpsStatusStore {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname === "/report" && request.method === "POST") {
      const record = await request.json();
      const nodeId = record?.payload?.node_id;
      if (!NODE_ID_PATTERN.test(nodeId || "")) return json({ ok: false, error: "node_id 格式错误" }, 400);
      const existing = await this.ctx.storage.get(`node:${nodeId}`);
      record.settings = existing?.settings || defaultSettings();
      await this.ctx.storage.put(`node:${nodeId}`, record);
      return json({ ok: true, node_id: nodeId, state: record.agent_state, server_time: record.last_seen });
    }

    if (url.pathname === "/settings" && request.method === "POST") {
      const input = await request.json();
      const key = `node:${input.node_id}`;
      const record = await this.ctx.storage.get(key);
      if (!record) return json({ ok: false, error: "节点不存在" }, 404);
      const previous = record.settings || defaultSettings();
      const next = {
        ...previous,
        ...input.settings,
        updated_at: Math.floor(Date.now() / 1000),
      };
      if (previous.expiry_date !== next.expiry_date) next.expiry_notifications = [];
      if (previous.reminder_at !== next.reminder_at || previous.memo !== next.memo) next.reminder_sent_at = 0;
      record.settings = next;
      await this.ctx.storage.put(key, record);
      return json({ ok: true, node_id: input.node_id, settings: publicSettings(next) });
    }

    if (url.pathname === "/run-reminders" && request.method === "POST") {
      const now = clampNumber(url.searchParams.get("now"), 0, Number.MAX_SAFE_INTEGER, Math.floor(Date.now() / 1000));
      return this.runReminders(now);
    }

    if (url.pathname === "/nodes" && request.method === "GET") {
      const records = await this.ctx.storage.list({ prefix: "node:" });
      const now = Math.floor(Date.now() / 1000);
      const offlineAfter = clampNumber(this.env.OFFLINE_AFTER_SECONDS, 30, 3600, 150);
      const nodes = [...records.values()].map((record) => {
        const age = Math.max(0, now - record.last_seen);
        let status = "online";
        if (record.agent_state === "shutdown") status = "shutdown";
        else if (age > offlineAfter) status = "offline";
        else if (record.payload.health === "degraded" || (record.payload.alerts || []).length > 0) status = "degraded";
        return {
          ...record.payload,
          status,
          last_seen: record.last_seen,
          last_seen_age: age,
          shutdown_at: record.shutdown_at,
          settings: publicSettings(record.settings || defaultSettings()),
        };
      }).sort((a, b) => a.name.localeCompare(b.name, "zh-CN"));

      const summary = nodes.reduce((acc, node) => {
        acc.total += 1;
        acc[node.status] = (acc[node.status] || 0) + 1;
        return acc;
      }, { total: 0, online: 0, degraded: 0, offline: 0, shutdown: 0 });

      return json({
        ok: true,
        server_time: now,
        refresh_seconds: 15,
        offline_after_seconds: offlineAfter,
        cloud_drive_url: this.env.CLOUD_DRIVE_URL || "https://disk.example.com",
        telegram_configured: telegramConfigured(this.env),
        summary,
        nodes,
      });
    }

    return json({ ok: false, error: "存储接口不存在" }, 404);
  }

  async runReminders(now) {
    if (!telegramConfigured(this.env)) return json({ ok: true, configured: false, sent: 0 });
    const records = await this.ctx.storage.list({ prefix: "node:" });
    let sent = 0;
    const errors = [];

    for (const [key, record] of records.entries()) {
      const settings = record.settings || defaultSettings();
      if (!settings.telegram_enabled) continue;
      let changed = false;

      if (settings.reminder_at > 0 && settings.reminder_at <= now && !settings.reminder_sent_at) {
        const message = [
          "⏰ VPS 备忘提醒",
          `节点：${record.payload.name}`,
          settings.memo ? `备忘：${settings.memo}` : "备忘：请查看 VPS 状态面板",
        ].join("\n");
        try {
          await sendTelegram(this.env, message);
          settings.reminder_sent_at = now;
          changed = true;
          sent += 1;
        } catch (error) {
          errors.push(`${record.payload.node_id}: ${error.message}`);
        }
      }

      if (settings.expiry_date) {
        const daysLeft = daysUntil(settings.expiry_date, now);
        const notificationKey = `${settings.expiry_date}:${daysLeft}`;
        const sentKeys = Array.isArray(settings.expiry_notifications) ? settings.expiry_notifications : [];
        if ([30, 7, 3, 1, 0].includes(daysLeft) && !sentKeys.includes(notificationKey)) {
          const countdown = daysLeft === 0 ? "今天到期" : `剩余 ${daysLeft} 天`;
          const message = [
            "📅 VPS 到期提醒",
            `节点：${record.payload.name}`,
            `到期日期：${settings.expiry_date}`,
            `状态：${countdown}`,
            settings.memo ? `备忘：${settings.memo}` : "",
          ].filter(Boolean).join("\n");
          try {
            await sendTelegram(this.env, message);
            settings.expiry_notifications = [...sentKeys, notificationKey].slice(-20);
            changed = true;
            sent += 1;
          } catch (error) {
            errors.push(`${record.payload.node_id}: ${error.message}`);
          }
        }
      }

      if (changed) {
        record.settings = settings;
        await this.ctx.storage.put(key, record);
      }
    }

    return json({ ok: errors.length === 0, configured: true, sent, errors });
  }
}

function defaultSettings() {
  return {
    expiry_date: "",
    memo: "",
    reminder_at: 0,
    telegram_enabled: true,
    reminder_sent_at: 0,
    expiry_notifications: [],
  };
}

function publicSettings(settings) {
  return {
    expiry_date: settings.expiry_date || "",
    memo: settings.memo || "",
    reminder_at: Number(settings.reminder_at) || 0,
    telegram_enabled: settings.telegram_enabled !== false,
    reminder_sent: Boolean(settings.reminder_sent_at),
  };
}

function isValidDate(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
}

function daysUntil(expiryDate, nowSeconds) {
  const [year, month, day] = expiryDate.split("-").map(Number);
  const expiry = Date.UTC(year, month - 1, day);
  const china = new Date((nowSeconds + 8 * 3600) * 1000);
  const today = Date.UTC(china.getUTCFullYear(), china.getUTCMonth(), china.getUTCDate());
  return Math.round((expiry - today) / 86400000);
}

function telegramConfigured(env) {
  return Boolean(env.TELEGRAM_BOT_TOKEN && env.TELEGRAM_CHAT_ID);
}

async function sendTelegram(env, text) {
  const response = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      chat_id: env.TELEGRAM_CHAT_ID,
      text: String(text).slice(0, 4000),
      disable_web_page_preview: true,
    }),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok || !result.ok) throw new Error(result.description || `Telegram HTTP ${response.status}`);
  return result;
}

function sanitizePayload(input, nodeId, name) {
  const allowed = {
    node_id: nodeId,
    name,
    provider: cleanText(input.provider, 40),
    location: cleanText(input.location, 40),
    hostname: cleanText(input.hostname, 80),
    os: cleanText(input.os, 100),
    kernel: cleanText(input.kernel, 100),
    arch: cleanText(input.arch, 30),
    public_ip: cleanText(input.public_ip, 64),
    boot_id: cleanText(input.boot_id, 64),
    uptime_seconds: clampNumber(input.uptime_seconds, 0, Number.MAX_SAFE_INTEGER, 0),
    health: input.health === "degraded" ? "degraded" : "normal",
    cpu: cleanObject(input.cpu),
    memory: cleanObject(input.memory),
    swap: cleanObject(input.swap),
    disk: cleanObject(input.disk),
    network: cleanObject(input.network),
    services: cleanArray(input.services, 30),
    ports: cleanArray(input.ports, 200),
    alerts: cleanArray(input.alerts, 30),
    reachability: cleanObject(input.reachability),
    agent_version: cleanText(input.agent_version, 20),
  };
  return allowed;
}

function cleanObject(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return JSON.parse(JSON.stringify(value).slice(0, 12000));
}

function cleanArray(value, maxItems) {
  if (!Array.isArray(value)) return [];
  return JSON.parse(JSON.stringify(value.slice(0, maxItems)).slice(0, 24000));
}

function cleanText(value, maxLength) {
  return String(value ?? "").replace(/[\u0000-\u001f\u007f]/g, "").slice(0, maxLength);
}

function clampNumber(value, min, max, fallback) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

function isIngestAuthorized(request, env) {
  const header = request.headers.get("authorization") || "";
  return env.INGEST_TOKEN && safeEqual(header, `Bearer ${env.INGEST_TOKEN}`);
}

function isViewAuthorized(request, env) {
  const token = request.headers.get("x-view-token") || "";
  return env.VIEW_TOKEN && safeEqual(token, encodeURIComponent(env.VIEW_TOKEN));
}

function safeEqual(left, right) {
  if (typeof left !== "string" || typeof right !== "string") return false;
  let mismatch = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    mismatch |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return mismatch === 0;
}

function unauthorized(message) {
  return json({ ok: false, error: message }, 401);
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: JSON_HEADERS });
}
