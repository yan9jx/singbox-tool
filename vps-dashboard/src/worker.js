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

      if (url.pathname === "/api/v1/reminders" && request.method === "GET") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return statusStore(env).fetch(new Request("https://store/global-reminders"));
      }

      if (url.pathname === "/api/v1/reminders" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return saveGlobalReminder(request, env);
      }

      if (url.pathname === "/api/v1/reminders/delete" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return mutateGlobalReminder(request, env, "delete");
      }

      if (url.pathname === "/api/v1/reminders/toggle" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return mutateGlobalReminder(request, env, "toggle");
      }

      if (url.pathname === "/api/v1/dashboard-settings" && request.method === "GET") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return statusStore(env).fetch(new Request("https://store/dashboard-settings"));
      }

      if (url.pathname === "/api/v1/dashboard-settings" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return saveDashboardSettings(request, env);
      }

      if (url.pathname === "/api/v1/nodes/delete" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return deleteOfflineNode(request, env);
      }

      if (url.pathname === "/api/v1/nodes/order" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return statusStore(env).fetch(new Request("https://store/nodes/order", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: await request.text(),
        }));
      }

      if (url.pathname === "/api/v1/config/export" && request.method === "GET") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return statusStore(env).fetch(new Request("https://store/config/export"));
      }

      if (url.pathname === "/api/v1/config/import" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return statusStore(env).fetch(new Request("https://store/config/import", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: await request.text(),
        }));
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
  const maintenanceUntil = Number(input?.maintenance_until || 0);
  if (!NODE_ID_PATTERN.test(nodeId)) return json({ ok: false, error: "node_id 格式错误" }, 400);
  if (expiryDate && !isValidDate(expiryDate)) return json({ ok: false, error: "到期日期格式错误" }, 400);
  if (!Number.isInteger(reminderAt) || reminderAt < 0 || reminderAt > 4102444800) {
    return json({ ok: false, error: "提醒时间格式错误" }, 400);
  }
  if (!Number.isInteger(maintenanceUntil) || maintenanceUntil < 0 || maintenanceUntil > 4102444800) {
    return json({ ok: false, error: "维护结束时间格式错误" }, 400);
  }

  const settings = {
    expiry_date: expiryDate,
    memo,
    reminder_at: reminderAt,
    telegram_enabled: input?.telegram_enabled !== false,
    display_name: cleanText(input?.display_name, 80),
    display_provider: cleanText(input?.display_provider, 40),
    display_location: cleanText(input?.display_location, 40),
    purpose: cleanText(input?.purpose, 80),
    group: cleanText(input?.group, 40),
    maintenance_until: maintenanceUntil,
  };
  return statusStore(env).fetch(new Request("https://store/settings", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ node_id: nodeId, settings }),
  }));
}

async function saveGlobalReminder(request, env) {
  let input;
  try {
    input = await request.json();
  } catch {
    return json({ ok: false, error: "JSON 格式错误" }, 400);
  }

  const scheduleType = String(input?.schedule_type || "");
  const allowedTypes = ["once", "daily", "weekly", "monthly", "yearly", "interval_months"];
  const reminder = {
    id: /^[a-zA-Z0-9_-]{1,64}$/.test(input?.id || "") ? input.id : crypto.randomUUID(),
    title: cleanText(input?.title, 100),
    content: cleanText(input?.content, 1000),
    schedule_type: scheduleType,
    schedule_at: Number(input?.schedule_at || 0),
    schedule_time: String(input?.schedule_time || ""),
    weekday: Number(input?.weekday || 0),
    schedule_month: Number(input?.schedule_month || 1),
    monthday: Number(input?.monthday || 1),
    interval_months: Number(input?.interval_months || 1),
    enabled: input?.enabled !== false,
  };
  if (!reminder.title) return json({ ok: false, error: "提醒名称不能为空" }, 400);
  if (!allowedTypes.includes(scheduleType)) return json({ ok: false, error: "提醒类型错误" }, 400);
  if (["once", "interval_months"].includes(scheduleType) && (!Number.isInteger(reminder.schedule_at) || reminder.schedule_at < 1)) {
    return json({ ok: false, error: "首次提醒时间错误" }, 400);
  }
  if (!["once", "interval_months"].includes(scheduleType) && !/^([01]\d|2[0-3]):[0-5]\d$/.test(reminder.schedule_time)) {
    return json({ ok: false, error: "循环提醒时间错误" }, 400);
  }
  if (scheduleType === "weekly" && (!Number.isInteger(reminder.weekday) || reminder.weekday < 0 || reminder.weekday > 6)) {
    return json({ ok: false, error: "星期设置错误" }, 400);
  }
  if (["monthly", "yearly"].includes(scheduleType) && (!Number.isInteger(reminder.monthday) || reminder.monthday < 1 || reminder.monthday > 31)) {
    return json({ ok: false, error: "每月日期设置错误" }, 400);
  }
  if (scheduleType === "yearly" && (!Number.isInteger(reminder.schedule_month) || reminder.schedule_month < 1 || reminder.schedule_month > 12)) {
    return json({ ok: false, error: "每年月份设置错误" }, 400);
  }
  if (scheduleType === "interval_months" && (!Number.isInteger(reminder.interval_months) || reminder.interval_months < 1 || reminder.interval_months > 60)) {
    return json({ ok: false, error: "间隔月数错误" }, 400);
  }
  return statusStore(env).fetch(new Request("https://store/global-reminder/save", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(reminder),
  }));
}

async function mutateGlobalReminder(request, env, action) {
  let input;
  try {
    input = await request.json();
  } catch {
    return json({ ok: false, error: "JSON 格式错误" }, 400);
  }
  const id = String(input?.id || "");
  if (!/^[a-zA-Z0-9_-]{1,64}$/.test(id)) return json({ ok: false, error: "提醒 ID 错误" }, 400);
  return statusStore(env).fetch(new Request(`https://store/global-reminder/${action}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ id, enabled: input?.enabled !== false }),
  }));
}

async function saveDashboardSettings(request, env) {
  let input;
  try { input = await request.json(); } catch { return json({ ok: false, error: "JSON 格式错误" }, 400); }
  const days = Number(input?.auto_delete_offline_days || 0);
  if (![0, 7, 30, 90].includes(days)) return json({ ok: false, error: "自动清理周期错误" }, 400);
  return statusStore(env).fetch(new Request("https://store/dashboard-settings", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ auto_delete_offline_days: days }),
  }));
}

async function deleteOfflineNode(request, env) {
  let input;
  try { input = await request.json(); } catch { return json({ ok: false, error: "JSON 格式错误" }, 400); }
  const nodeId = String(input?.node_id || "");
  if (!NODE_ID_PATTERN.test(nodeId)) return json({ ok: false, error: "node_id 格式错误" }, 400);
  return statusStore(env).fetch(new Request("https://store/node/delete", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ node_id: nodeId }),
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

    if (url.pathname === "/global-reminders" && request.method === "GET") {
      const records = await this.ctx.storage.list({ prefix: "global-reminder:" });
      const reminders = [...records.values()]
        .map(publicGlobalReminder)
        .sort((a, b) => b.updated_at - a.updated_at);
      return json({ ok: true, reminders });
    }

    if (url.pathname === "/global-reminder/save" && request.method === "POST") {
      const input = await request.json();
      const key = `global-reminder:${input.id}`;
      const previous = await this.ctx.storage.get(key);
      const signature = reminderSignature(input);
      const now = Math.floor(Date.now() / 1000);
      const record = {
        ...input,
        created_at: previous?.created_at || now,
        updated_at: now,
        completed: false,
        last_fired_key: previous && reminderSignature(previous) === signature ? previous.last_fired_key || "" : "",
      };
      await this.ctx.storage.put(key, record);
      return json({ ok: true, reminder: publicGlobalReminder(record) });
    }

    if (url.pathname === "/global-reminder/delete" && request.method === "POST") {
      const input = await request.json();
      await this.ctx.storage.delete(`global-reminder:${input.id}`);
      return json({ ok: true });
    }

    if (url.pathname === "/global-reminder/toggle" && request.method === "POST") {
      const input = await request.json();
      const key = `global-reminder:${input.id}`;
      const record = await this.ctx.storage.get(key);
      if (!record) return json({ ok: false, error: "提醒不存在" }, 404);
      record.enabled = Boolean(input.enabled);
      record.completed = false;
      record.updated_at = Math.floor(Date.now() / 1000);
      await this.ctx.storage.put(key, record);
      return json({ ok: true, reminder: publicGlobalReminder(record) });
    }

    if (url.pathname === "/dashboard-settings" && request.method === "GET") {
      const settings = await this.ctx.storage.get("dashboard:settings") || { auto_delete_offline_days: 0 };
      return json({ ok: true, settings });
    }

    if (url.pathname === "/dashboard-settings" && request.method === "POST") {
      const settings = await request.json();
      await this.ctx.storage.put("dashboard:settings", settings);
      return json({ ok: true, settings });
    }

    if (url.pathname === "/node/delete" && request.method === "POST") {
      const input = await request.json();
      const key = `node:${input.node_id}`;
      const record = await this.ctx.storage.get(key);
      if (!record) return json({ ok: false, error: "节点不存在" }, 404);
      const now = Math.floor(Date.now() / 1000);
      const offlineAfter = clampNumber(this.env.OFFLINE_AFTER_SECONDS, 30, 3600, 150);
      const offline = record.agent_state === "shutdown" || now - record.last_seen > offlineAfter;
      if (!offline) return json({ ok: false, error: "在线节点不能删除" }, 409);
      await this.ctx.storage.delete(key);
      return json({ ok: true });
    }

    if (url.pathname === "/nodes/order" && request.method === "POST") {
      const input = await request.json();
      if (!Array.isArray(input.node_ids) || input.node_ids.length > 500) return json({ ok: false, error: "排序数据错误" }, 400);
      let updated = 0;
      for (let index = 0; index < input.node_ids.length; index += 1) {
        const nodeId = String(input.node_ids[index] || "");
        if (!NODE_ID_PATTERN.test(nodeId)) continue;
        const key = `node:${nodeId}`;
        const record = await this.ctx.storage.get(key);
        if (!record) continue;
        record.settings = { ...(record.settings || defaultSettings()), sort_order: index };
        await this.ctx.storage.put(key, record);
        updated += 1;
      }
      return json({ ok: true, updated });
    }

    if (url.pathname === "/config/export" && request.method === "GET") {
      const nodeRecords = await this.ctx.storage.list({ prefix: "node:" });
      const reminderRecords = await this.ctx.storage.list({ prefix: "global-reminder:" });
      const dashboardSettings = await this.ctx.storage.get("dashboard:settings") || { auto_delete_offline_days: 0 };
      const nodes = {};
      for (const record of nodeRecords.values()) nodes[record.payload.node_id] = publicSettings(record.settings || defaultSettings());
      return json({
        format: "ejectors-dashboard-config",
        version: 1,
        exported_at: Math.floor(Date.now() / 1000),
        dashboard_settings: dashboardSettings,
        nodes,
        reminders: [...reminderRecords.values()].map(publicGlobalReminder),
      });
    }

    if (url.pathname === "/config/import" && request.method === "POST") {
      const input = await request.json();
      if (input?.format !== "ejectors-dashboard-config" || input?.version !== 1) return json({ ok: false, error: "备份文件格式错误" }, 400);
      let nodes = 0;
      let skipped = 0;
      for (const [nodeId, imported] of Object.entries(input.nodes || {}).slice(0, 500)) {
        if (!NODE_ID_PATTERN.test(nodeId)) { skipped += 1; continue; }
        const key = `node:${nodeId}`;
        const record = await this.ctx.storage.get(key);
        if (!record) { skipped += 1; continue; }
        record.settings = sanitizeImportedSettings(imported, record.settings || defaultSettings());
        await this.ctx.storage.put(key, record);
        nodes += 1;
      }
      let reminders = 0;
      for (const imported of Array.isArray(input.reminders) ? input.reminders.slice(0, 500) : []) {
        if (!/^[a-zA-Z0-9_-]{1,64}$/.test(imported?.id || "")) continue;
        await this.ctx.storage.put(`global-reminder:${imported.id}`, {
          ...imported,
          title: cleanText(imported.title, 100),
          content: cleanText(imported.content, 1000),
          updated_at: Math.floor(Date.now() / 1000),
        });
        reminders += 1;
      }
      const days = Number(input.dashboard_settings?.auto_delete_offline_days || 0);
      await this.ctx.storage.put("dashboard:settings", { auto_delete_offline_days: [0, 7, 30, 90].includes(days) ? days : 0 });
      return json({ ok: true, imported: { nodes, reminders }, skipped_nodes: skipped });
    }

    if (url.pathname === "/nodes" && request.method === "GET") {
      const records = await this.ctx.storage.list({ prefix: "node:" });
      const now = Math.floor(Date.now() / 1000);
      const offlineAfter = clampNumber(this.env.OFFLINE_AFTER_SECONDS, 30, 3600, 150);
      const nodes = [...records.values()].map((record) => {
        const age = Math.max(0, now - record.last_seen);
        let status = "online";
        const settings = publicSettings(record.settings || defaultSettings());
        if (settings.maintenance_until > now) status = "maintenance";
        else if (record.agent_state === "shutdown") status = "shutdown";
        else if (age > offlineAfter) status = "offline";
        else if (record.payload.health === "degraded" || (record.payload.alerts || []).length > 0) status = "degraded";
        return {
          ...record.payload,
          name: settings.display_name || record.payload.name,
          provider: settings.display_provider || record.payload.provider,
          location: settings.display_location || record.payload.location,
          purpose: settings.purpose,
          status,
          last_seen: record.last_seen,
          last_seen_age: age,
          shutdown_at: record.shutdown_at,
          settings,
        };
      }).sort((a, b) => {
        const groupOrder = (a.settings.group || "未分组").localeCompare(b.settings.group || "未分组", "zh-CN");
        return groupOrder || (a.settings.sort_order - b.settings.sort_order) || a.name.localeCompare(b.name, "zh-CN");
      });

      const summary = nodes.reduce((acc, node) => {
        acc.total += 1;
        acc[node.status] = (acc[node.status] || 0) + 1;
        return acc;
      }, { total: 0, online: 0, degraded: 0, offline: 0, shutdown: 0, maintenance: 0 });

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
    const records = await this.ctx.storage.list({ prefix: "node:" });
    const dashboardSettings = await this.ctx.storage.get("dashboard:settings") || { auto_delete_offline_days: 0 };
    let deleted = 0;
    if (dashboardSettings.auto_delete_offline_days > 0) {
      const cutoff = now - dashboardSettings.auto_delete_offline_days * 86400;
      for (const [key, record] of records.entries()) {
        if (record.last_seen < cutoff) {
          await this.ctx.storage.delete(key);
          records.delete(key);
          deleted += 1;
        }
      }
    }
    if (!telegramConfigured(this.env)) return json({ ok: true, configured: false, sent: 0, deleted });
    let sent = 0;
    const errors = [];

    for (const [key, record] of records.entries()) {
      const settings = record.settings || defaultSettings();
      if (!settings.telegram_enabled) continue;
      if (settings.maintenance_until > now) continue;
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

    const globalRecords = await this.ctx.storage.list({ prefix: "global-reminder:" });
    for (const [key, reminder] of globalRecords.entries()) {
      if (!reminder.enabled) continue;
      const fireKey = globalReminderFireKey(reminder, now);
      if (!fireKey || reminder.last_fired_key === fireKey) continue;
      const message = [
        "📝 全局备忘提醒",
        `事项：${reminder.title}`,
        reminder.content ? `内容：${reminder.content}` : "",
        `计划：${globalReminderScheduleLabel(reminder)}`,
      ].filter(Boolean).join("\n");
      try {
        await sendTelegram(this.env, message);
        reminder.last_fired_key = fireKey;
        reminder.updated_at = now;
        if (reminder.schedule_type === "once") {
          reminder.enabled = false;
          reminder.completed = true;
        }
        await this.ctx.storage.put(key, reminder);
        sent += 1;
      } catch (error) {
        errors.push(`${reminder.id}: ${error.message}`);
      }
    }

    return json({ ok: errors.length === 0, configured: true, sent, deleted, errors });
  }
}

function publicGlobalReminder(reminder) {
  return {
    id: reminder.id,
    title: reminder.title,
    content: reminder.content || "",
    schedule_type: reminder.schedule_type,
    schedule_at: Number(reminder.schedule_at) || 0,
    schedule_time: reminder.schedule_time || "",
    weekday: Number(reminder.weekday) || 0,
    schedule_month: Number(reminder.schedule_month) || 1,
    monthday: Number(reminder.monthday) || 1,
    interval_months: Number(reminder.interval_months) || 1,
    enabled: Boolean(reminder.enabled),
    completed: Boolean(reminder.completed),
    created_at: reminder.created_at,
    updated_at: reminder.updated_at,
  };
}

function reminderSignature(reminder) {
  return [reminder.schedule_type, reminder.schedule_at, reminder.schedule_time, reminder.weekday, reminder.schedule_month, reminder.monthday, reminder.interval_months].join("|");
}

function globalReminderFireKey(reminder, now) {
  const china = new Date((now + 8 * 3600) * 1000);
  const year = china.getUTCFullYear();
  const month = china.getUTCMonth() + 1;
  const day = china.getUTCDate();
  const dateKey = `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  if (reminder.schedule_type === "once") {
    return reminder.schedule_at <= now ? `once:${reminder.schedule_at}` : "";
  }
  if (reminder.schedule_type === "interval_months") {
    const anchor = new Date((reminder.schedule_at + 8 * 3600) * 1000);
    const anchorMonthIndex = anchor.getUTCFullYear() * 12 + anchor.getUTCMonth();
    const currentMonthIndex = year * 12 + (month - 1);
    let occurrence = Math.floor((currentMonthIndex - anchorMonthIndex) / reminder.interval_months);
    if (occurrence < 0) return "";
    const targetMonthIndex = anchorMonthIndex + occurrence * reminder.interval_months;
    const targetYear = Math.floor(targetMonthIndex / 12);
    const targetMonth = targetMonthIndex % 12;
    const daysInTargetMonth = new Date(Date.UTC(targetYear, targetMonth + 1, 0)).getUTCDate();
    const targetDay = Math.min(anchor.getUTCDate(), daysInTargetMonth);
    let targetUtc = Date.UTC(targetYear, targetMonth, targetDay, anchor.getUTCHours(), anchor.getUTCMinutes()) / 1000 - 8 * 3600;
    if (targetUtc > now) {
      occurrence -= 1;
      if (occurrence < 0) return "";
      const previousIndex = anchorMonthIndex + occurrence * reminder.interval_months;
      const previousYear = Math.floor(previousIndex / 12);
      const previousMonth = previousIndex % 12;
      const previousDays = new Date(Date.UTC(previousYear, previousMonth + 1, 0)).getUTCDate();
      targetUtc = Date.UTC(previousYear, previousMonth, Math.min(anchor.getUTCDate(), previousDays), anchor.getUTCHours(), anchor.getUTCMinutes()) / 1000 - 8 * 3600;
    }
    return `interval:${targetUtc}`;
  }
  const [hour, minute] = reminder.schedule_time.split(":").map(Number);
  if (china.getUTCHours() * 60 + china.getUTCMinutes() < hour * 60 + minute) return "";
  if (reminder.schedule_type === "daily") return `daily:${dateKey}`;
  if (reminder.schedule_type === "weekly") {
    return china.getUTCDay() === reminder.weekday ? `weekly:${dateKey}` : "";
  }
  if (reminder.schedule_type === "monthly") {
    const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate();
    return day === Math.min(reminder.monthday, daysInMonth) ? `monthly:${dateKey}` : "";
  }
  if (reminder.schedule_type === "yearly") {
    if (month !== reminder.schedule_month) return "";
    const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate();
    return day === Math.min(reminder.monthday, daysInMonth) ? `yearly:${dateKey}` : "";
  }
  return "";
}

function globalReminderScheduleLabel(reminder) {
  if (reminder.schedule_type === "once") {
    return new Date(reminder.schedule_at * 1000).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai" });
  }
  if (reminder.schedule_type === "interval_months") {
    return `每 ${reminder.interval_months} 个月，自 ${new Date(reminder.schedule_at * 1000).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai" })}`;
  }
  if (reminder.schedule_type === "daily") return `每天 ${reminder.schedule_time}`;
  if (reminder.schedule_type === "weekly") return `每周${"日一二三四五六"[reminder.weekday]} ${reminder.schedule_time}`;
  if (reminder.schedule_type === "monthly") return `每月 ${reminder.monthday} 日 ${reminder.schedule_time}`;
  return `每年 ${reminder.schedule_month} 月 ${reminder.monthday} 日 ${reminder.schedule_time}`;
}

function defaultSettings() {
  return {
    expiry_date: "",
    memo: "",
    reminder_at: 0,
    telegram_enabled: true,
    reminder_sent_at: 0,
    expiry_notifications: [],
    display_name: "",
    display_provider: "",
    display_location: "",
    purpose: "",
    group: "",
    sort_order: 999999,
    maintenance_until: 0,
  };
}

function publicSettings(settings) {
  return {
    expiry_date: settings.expiry_date || "",
    memo: settings.memo || "",
    reminder_at: Number(settings.reminder_at) || 0,
    telegram_enabled: settings.telegram_enabled !== false,
    reminder_sent: Boolean(settings.reminder_sent_at),
    display_name: settings.display_name || "",
    display_provider: settings.display_provider || "",
    display_location: settings.display_location || "",
    purpose: settings.purpose || "",
    group: settings.group || "",
    sort_order: Number.isFinite(Number(settings.sort_order)) ? Number(settings.sort_order) : 999999,
    maintenance_until: Number(settings.maintenance_until) || 0,
  };
}

function sanitizeImportedSettings(input, previous) {
  const expiryDate = String(input?.expiry_date || "");
  return {
    ...previous,
    expiry_date: expiryDate && isValidDate(expiryDate) ? expiryDate : "",
    memo: cleanText(input?.memo, 500),
    reminder_at: clampNumber(input?.reminder_at, 0, 4102444800, 0),
    telegram_enabled: input?.telegram_enabled !== false,
    display_name: cleanText(input?.display_name, 80),
    display_provider: cleanText(input?.display_provider, 40),
    display_location: cleanText(input?.display_location, 40),
    purpose: cleanText(input?.purpose, 80),
    group: cleanText(input?.group, 40),
    sort_order: clampNumber(input?.sort_order, 0, 1000000, 999999),
    maintenance_until: clampNumber(input?.maintenance_until, 0, 4102444800, 0),
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
