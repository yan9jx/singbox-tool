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

      if (url.pathname.startsWith("/sub/anytls/") && request.method === "GET") {
        return serveAnyTlsSubscription(request, url, env);
      }

      if (requiresViewAuthorization(url.pathname)) {
        const authError = await enforceViewAuthorization(request, env);
        if (authError) return authError;
      }

      if (url.pathname === "/api/v1/session" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("查看密码不正确");
        return json({ ok: true });
      }

      if (url.pathname === "/api/v1/nodes" && request.method === "GET") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return statusStore(env).fetch(new Request("https://store/nodes"));
      }

      if (url.pathname === "/api/v1/anytls/info" && request.method === "GET") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return getAnyTlsInfo(request, env);
      }

      if (url.pathname === "/api/v1/anytls/toggle" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return toggleAnyTlsNode(request, env);
      }

      if (url.pathname === "/api/v1/anytls/reset-subscription" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return resetAnyTlsSubscription(request, env);
      }

      if (url.pathname === "/api/v1/node-settings" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return updateNodeSettings(request, env);
      }

      if (url.pathname === "/api/v1/node-profile" && request.method === "POST") {
        if (!isViewAuthorized(request, env)) return unauthorized("需要查看密码");
        return updateNodeProfile(request, env);
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

      if (url.pathname === "/api/v1/anytls" && request.method === "POST") {
        if (!isIngestAuthorized(request, env)) return unauthorized("上报密钥不正确");
        return receiveAnyTlsNode(request, env);
      }

      if (url.pathname === "/api/v1/anytls/delete" && request.method === "POST") {
        if (!isIngestAuthorized(request, env)) return unauthorized("上报密钥不正确");
        return deleteAnyTlsNode(request, env);
      }

      if (url.pathname === "/api/v1/xhttp" && request.method === "POST") {
        if (!isIngestAuthorized(request, env)) return unauthorized("上报密钥不正确");
        return receiveXhttpNode(request, env);
      }

      if (url.pathname === "/api/v1/xhttp/delete" && request.method === "POST") {
        if (!isIngestAuthorized(request, env)) return unauthorized("上报密钥不正确");
        return deleteProtocolNode(request, env, "xhttp");
      }

      if (url.pathname === "/api/v1/mieru" && request.method === "POST") {
        if (!isIngestAuthorized(request, env)) return unauthorized("上报密钥不正确");
        return receiveMieruNode(request, env);
      }

      if (url.pathname === "/api/v1/mieru/delete" && request.method === "POST") {
        if (!isIngestAuthorized(request, env)) return unauthorized("上报密钥不正确");
        return deleteProtocolNode(request, env, "mieru");
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

async function receiveAnyTlsNode(request, env) {
  const contentLength = Number(request.headers.get("content-length") || 0);
  if (contentLength > MAX_BODY_BYTES) return json({ ok: false, error: "上报数据过大" }, 413);
  let input;
  try {
    input = await request.json();
  } catch {
    return json({ ok: false, error: "JSON 格式错误" }, 400);
  }
  const nodeId = String(input?.node_id || "");
  const name = cleanText(input?.name || nodeId, 80);
  const server = cleanText(input?.server, 255);
  const port = Number(input?.port);
  const password = cleanText(input?.password, 512);
  const sni = cleanText(input?.sni, 255);
  if (!NODE_ID_PATTERN.test(nodeId)) return json({ ok: false, error: "node_id 格式错误" }, 400);
  if (!name || !server || /[\s/?#]/.test(server)) return json({ ok: false, error: "节点地址格式错误" }, 400);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return json({ ok: false, error: "端口格式错误" }, 400);
  if (!password) return json({ ok: false, error: "AnyTLS 密码不能为空" }, 400);
  if (!/^[A-Za-z0-9.-]+$/.test(sni)) return json({ ok: false, error: "SNI 格式错误" }, 400);
  const response = await statusStore(env).fetch(new Request("https://store/anytls/upsert", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      node_id: nodeId,
      name,
      server,
      port,
      password,
      sni,
      insecure: input?.insecure !== false,
      updated_at: Math.floor(Date.now() / 1000),
    }),
  }));
  if (!response.ok) return response;
  const result = await response.json();
  const accessToken = await getAnyTlsAccessToken(env);
  return json({
    ...result,
    subscription_url: accessToken ? `${new URL(request.url).origin}/sub/anytls/${accessToken}` : "",
  });
}

async function deleteAnyTlsNode(request, env) {
  let input;
  try {
    input = await request.json();
  } catch {
    return json({ ok: false, error: "JSON 格式错误" }, 400);
  }
  const nodeId = String(input?.node_id || "");
  if (!NODE_ID_PATTERN.test(nodeId)) return json({ ok: false, error: "node_id 格式错误" }, 400);
  return statusStore(env).fetch(new Request("https://store/anytls/delete", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ node_id: nodeId }),
  }));
}

async function receiveXhttpNode(request, env) {
  const input = await readSubscriptionInput(request);
  if (input instanceof Response) return input;
  const common = validateSubscriptionCommon(input);
  if (common instanceof Response) return common;
  const uuid = cleanText(input?.uuid, 64);
  const sni = cleanText(input?.sni, 255);
  const path = cleanText(input?.path, 512);
  const host = cleanText(input?.host || sni, 255);
  const encryption = cleanText(input?.encryption || "none", 4096);
  if (!/^[0-9a-fA-F-]{36}$/.test(uuid)) return json({ ok: false, error: "UUID 格式错误" }, 400);
  if (!/^[A-Za-z0-9.-]+$/.test(sni)) return json({ ok: false, error: "SNI 格式错误" }, 400);
  if (!/^[A-Za-z0-9.-]+$/.test(host)) return json({ ok: false, error: "Host 格式错误" }, 400);
  if (!path.startsWith("/") || /[\s?#]/.test(path)) return json({ ok: false, error: "XHTTP 路径格式错误" }, 400);
  if (!/^[A-Za-z0-9._-]+$/.test(encryption)) return json({ ok: false, error: "VLESS Encryption 参数格式错误" }, 400);
  return upsertProtocolNode(request, env, "xhttp", {
    ...common,
    uuid,
    sni,
    path,
    host,
    encryption,
    insecure: input?.insecure === true,
  });
}

async function receiveMieruNode(request, env) {
  const input = await readSubscriptionInput(request);
  if (input instanceof Response) return input;
  const common = validateSubscriptionCommon(input);
  if (common instanceof Response) return common;
  const username = cleanText(input?.username, 128);
  const password = cleanText(input?.password, 512);
  const transport = String(input?.transport || "").toUpperCase();
  const multiplexing = cleanText(input?.multiplexing || "MULTIPLEXING_LOW", 32);
  if (!username) return json({ ok: false, error: "Mieru 用户名不能为空" }, 400);
  if (!password) return json({ ok: false, error: "Mieru 密码不能为空" }, 400);
  if (!["TCP", "UDP"].includes(transport)) return json({ ok: false, error: "Mieru 传输协议错误" }, 400);
  if (!["MULTIPLEXING_OFF", "MULTIPLEXING_LOW", "MULTIPLEXING_MIDDLE", "MULTIPLEXING_HIGH"].includes(multiplexing)) {
    return json({ ok: false, error: "Mieru 多路复用设置错误" }, 400);
  }
  return upsertProtocolNode(request, env, "mieru", {
    ...common,
    username,
    password,
    transport,
    multiplexing,
  });
}

async function readSubscriptionInput(request) {
  const contentLength = Number(request.headers.get("content-length") || 0);
  if (contentLength > MAX_BODY_BYTES) return json({ ok: false, error: "上报数据过大" }, 413);
  try {
    return await request.json();
  } catch {
    return json({ ok: false, error: "JSON 格式错误" }, 400);
  }
}

function validateSubscriptionCommon(input) {
  const nodeId = String(input?.node_id || "");
  const name = cleanText(input?.name || nodeId, 80);
  const server = cleanText(input?.server, 255);
  const port = Number(input?.port);
  if (!NODE_ID_PATTERN.test(nodeId)) return json({ ok: false, error: "node_id 格式错误" }, 400);
  if (!name || !server || /[\s/?#]/.test(server)) return json({ ok: false, error: "节点地址格式错误" }, 400);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return json({ ok: false, error: "端口格式错误" }, 400);
  return { node_id: nodeId, name, server, port };
}

async function upsertProtocolNode(request, env, protocol, record) {
  const response = await statusStore(env).fetch(new Request(`https://store/${protocol}/upsert`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ ...record, updated_at: Math.floor(Date.now() / 1000) }),
  }));
  if (!response.ok) return response;
  const result = await response.json();
  const accessToken = await getAnyTlsAccessToken(env);
  return json({
    ...result,
    subscription_url: accessToken ? `${new URL(request.url).origin}/sub/anytls/${accessToken}` : "",
  });
}

async function deleteProtocolNode(request, env, protocol) {
  let input;
  try {
    input = await request.json();
  } catch {
    return json({ ok: false, error: "JSON 格式错误" }, 400);
  }
  const nodeId = String(input?.node_id || "");
  if (!NODE_ID_PATTERN.test(nodeId)) return json({ ok: false, error: "node_id 格式错误" }, 400);
  return statusStore(env).fetch(new Request(`https://store/${protocol}/delete`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ node_id: nodeId }),
  }));
}

async function getAnyTlsInfo(request, env) {
  const response = await statusStore(env).fetch(new Request("https://store/anytls/nodes"));
  const data = await response.json();
  const accessToken = await getAnyTlsAccessToken(env);
  const origin = new URL(request.url).origin;
  return json({
    ok: true,
    subscription_url: accessToken ? `${origin}/sub/anytls/${accessToken}` : "",
    nodes: data.nodes || [],
  });
}

async function toggleAnyTlsNode(request, env) {
  let input;
  try {
    input = await request.json();
  } catch {
    return json({ ok: false, error: "JSON 格式错误" }, 400);
  }
  const nodeId = String(input?.node_id || "");
  const protocol = String(input?.protocol || "anytls");
  if (!NODE_ID_PATTERN.test(nodeId) || !["anytls", "xhttp", "mieru"].includes(protocol)
    || typeof input?.enabled !== "boolean") {
    return json({ ok: false, error: "订阅节点设置错误" }, 400);
  }
  return statusStore(env).fetch(new Request("https://store/anytls/toggle", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ node_id: nodeId, protocol, enabled: input.enabled }),
  }));
}

async function resetAnyTlsSubscription(request, env) {
  const accessToken = await getAnyTlsAccessToken(env, true);
  if (!accessToken) return json({ ok: false, error: "订阅服务尚未配置" }, 503);
  return json({
    ok: true,
    subscription_url: `${new URL(request.url).origin}/sub/anytls/${accessToken}`,
  });
}

async function getAnyTlsAccessToken(env, reset = false) {
  if (!env.INGEST_TOKEN) return "";
  const initialToken = await sha256Hex(env.INGEST_TOKEN);
  const response = await statusStore(env).fetch(new Request("https://store/anytls/access-token", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ initial_token: initialToken, reset }),
  }));
  if (!response.ok) return "";
  return String((await response.json()).token || "");
}

async function serveAnyTlsSubscription(request, url, env) {
  const token = url.pathname.slice("/sub/anytls/".length);
  if (!/^[a-f0-9]{64}$/.test(token) || !env.INGEST_TOKEN) return new Response("Not Found", { status: 404 });
  const expected = await getAnyTlsAccessToken(env);
  if (!safeEqual(token, expected)) return new Response("Not Found", { status: 404 });
  const format = cleanText(url.searchParams.get("format"), 20).toLowerCase();
  const internalUrl = new URL("https://store/anytls/subscription");
  if (format) internalUrl.searchParams.set("format", format);
  return statusStore(env).fetch(new Request(internalUrl, {
    headers: { "user-agent": request.headers.get("user-agent") || "" },
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
  const reminderRepeatUntil = Number(input?.reminder_repeat_until || 0);
  if (!NODE_ID_PATTERN.test(nodeId)) return json({ ok: false, error: "node_id 格式错误" }, 400);
  if (expiryDate && !isValidDate(expiryDate)) return json({ ok: false, error: "到期日期格式错误" }, 400);
  if (!Number.isInteger(reminderAt) || reminderAt < 0 || reminderAt > 4102444800) {
    return json({ ok: false, error: "提醒时间格式错误" }, 400);
  }
  if (!Number.isInteger(reminderRepeatUntil) || reminderRepeatUntil < 0 || reminderRepeatUntil > 4102444800
    || (reminderRepeatUntil > 0 && (reminderAt < 1 || reminderRepeatUntil <= reminderAt))) {
    return json({ ok: false, error: "持续提醒截止时间错误" }, 400);
  }
  const settings = {
    expiry_date: expiryDate,
    memo,
    reminder_at: reminderAt,
    reminder_repeat_until: reminderRepeatUntil,
    telegram_enabled: input?.telegram_enabled !== false,
  };
  return statusStore(env).fetch(new Request("https://store/settings", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ node_id: nodeId, settings }),
  }));
}

async function updateNodeProfile(request, env) {
  let input;
  try { input = await request.json(); } catch { return json({ ok: false, error: "JSON 格式错误" }, 400); }
  const nodeId = String(input?.node_id || "");
  const maintenanceUntil = Number(input?.maintenance_until || 0);
  if (!NODE_ID_PATTERN.test(nodeId)) return json({ ok: false, error: "node_id 格式错误" }, 400);
  if (!Number.isInteger(maintenanceUntil) || maintenanceUntil < 0 || maintenanceUntil > 4102444800) {
    return json({ ok: false, error: "维护结束时间格式错误" }, 400);
  }
  return statusStore(env).fetch(new Request("https://store/settings", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      node_id: nodeId,
      settings: {
        display_name: cleanText(input?.display_name, 80),
        display_provider: cleanText(input?.display_provider, 40),
        display_location: cleanText(input?.display_location, 40),
        purpose: cleanText(input?.purpose, 80),
        group: cleanText(input?.group, 40),
        maintenance_until: maintenanceUntil,
      },
    }),
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
    schedule_end_at: Number(input?.schedule_end_at || 0),
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
  if (scheduleType === "hourly_until" && (!Number.isInteger(reminder.schedule_end_at) || reminder.schedule_end_at <= reminder.schedule_at)) {
    return json({ ok: false, error: "持续提醒结束时间必须晚于开始时间" }, 400);
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
  const settings = {};
  if (Object.hasOwn(input, "auto_delete_offline_days")) {
    const days = Number(input.auto_delete_offline_days);
    if (![0, 7, 30, 90].includes(days)) return json({ ok: false, error: "自动清理周期错误" }, 400);
    settings.auto_delete_offline_days = days;
  }
  if (Object.hasOwn(input, "telegram_repeat_interval_minutes")) {
    const interval = Number(input.telegram_repeat_interval_minutes);
    if (!Number.isInteger(interval) || interval < 1 || interval > 1440) return json({ ok: false, error: "提醒间隔应为 1～1440 分钟" }, 400);
    settings.telegram_repeat_interval_minutes = interval;
  }
  if (Object.hasOwn(input, "telegram_repeat_start") || Object.hasOwn(input, "telegram_repeat_end")) {
    const start = String(input.telegram_repeat_start || "");
    const end = String(input.telegram_repeat_end || "");
    if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(start) || !/^([01]\d|2[0-3]):[0-5]\d$/.test(end) || start >= end) {
      return json({ ok: false, error: "提醒结束时间必须晚于开始时间" }, 400);
    }
    settings.telegram_repeat_start = start;
    settings.telegram_repeat_end = end;
  }
  if (!Object.keys(settings).length) return json({ ok: false, error: "没有可保存的设置" }, 400);
  return statusStore(env).fetch(new Request("https://store/dashboard-settings", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(settings),
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

    if (url.pathname === "/anytls/upsert" && request.method === "POST") {
      const record = await request.json();
      const key = `anytls:${record.node_id}`;
      const existing = await this.ctx.storage.get(key);
      record.enabled = existing?.enabled !== false;
      await this.ctx.storage.put(key, record);
      return json({ ok: true, node_id: record.node_id, updated_at: record.updated_at });
    }

    if ((url.pathname === "/xhttp/upsert" || url.pathname === "/mieru/upsert") && request.method === "POST") {
      const protocol = url.pathname.split("/")[1];
      const record = await request.json();
      const key = `${protocol}:${record.node_id}`;
      const existing = await this.ctx.storage.get(key);
      record.enabled = existing?.enabled !== false;
      record.protocol = protocol;
      await this.ctx.storage.put(key, record);
      return json({ ok: true, node_id: record.node_id, protocol, updated_at: record.updated_at });
    }

    if (url.pathname === "/anytls/delete" && request.method === "POST") {
      const input = await request.json();
      await this.ctx.storage.delete(`anytls:${input.node_id}`);
      return json({ ok: true, node_id: input.node_id });
    }

    if ((url.pathname === "/xhttp/delete" || url.pathname === "/mieru/delete") && request.method === "POST") {
      const protocol = url.pathname.split("/")[1];
      const input = await request.json();
      await this.ctx.storage.delete(`${protocol}:${input.node_id}`);
      return json({ ok: true, node_id: input.node_id, protocol });
    }

    if (url.pathname === "/anytls/access-token" && request.method === "POST") {
      const input = await request.json();
      const tokenKey = "subscription:anytls:access-token";
      let token = await this.ctx.storage.get(tokenKey);
      let changed = false;
      if (input.reset === true) {
        token = randomHex(32);
        changed = true;
      }
      else if (!/^[a-f0-9]{64}$/.test(token || "")) {
        token = /^[a-f0-9]{64}$/.test(input.initial_token || "") ? input.initial_token : randomHex(32);
        changed = true;
      }
      if (changed) await this.ctx.storage.put(tokenKey, token);
      await this.ctx.storage.delete("anytls:access-token");
      return json({ ok: true, token });
    }

    if (url.pathname === "/anytls/toggle" && request.method === "POST") {
      const input = await request.json();
      const protocol = ["anytls", "xhttp", "mieru"].includes(input.protocol) ? input.protocol : "anytls";
      const key = `${protocol}:${input.node_id}`;
      const record = await this.ctx.storage.get(key);
      if (!record) return json({ ok: false, error: "订阅节点不存在" }, 404);
      record.enabled = input.enabled;
      await this.ctx.storage.put(key, record);
      return json({ ok: true, node_id: input.node_id, protocol, enabled: record.enabled });
    }

    if (url.pathname === "/anytls/nodes" && request.method === "GET") {
      const recordSets = await Promise.all(["anytls", "xhttp", "mieru"]
        .map((protocol) => this.ctx.storage.list({ prefix: `${protocol}:` })));
      const nodes = recordSets.flatMap((records) => [...records.values()])
        .filter((record) => record && typeof record === "object" && NODE_ID_PATTERN.test(record.node_id || ""))
        .map((record) => ({
          node_id: record.node_id,
          name: record.name,
          server: record.server,
          port: record.port,
          protocol: record.protocol || "anytls",
          enabled: record.enabled !== false,
          updated_at: record.updated_at,
        }))
        .sort((a, b) => `${a.name}-${a.protocol}`.localeCompare(`${b.name}-${b.protocol}`, "zh-CN"));
      return json({ ok: true, nodes });
    }

    if (url.pathname === "/anytls/subscription" && request.method === "GET") {
      const recordSets = await Promise.all(["anytls", "xhttp", "mieru"]
        .map((protocol) => this.ctx.storage.list({ prefix: `${protocol}:` })));
      const nodes = recordSets.flatMap((records) => [...records.values()])
        .filter((record) => record && typeof record === "object"
          && NODE_ID_PATTERN.test(record.node_id || "") && record.enabled !== false)
        .map((record) => ({ ...record, protocol: record.protocol || "anytls" }))
        .sort((a, b) => `${a.name}-${a.protocol}`.localeCompare(`${b.name}-${b.protocol}`, "zh-CN"));
      const format = subscriptionFormat(url.searchParams.get("format"), request.headers.get("user-agent"));
      return format === "yaml" ? subscriptionYaml(nodes) : subscriptionUri(nodes, format);
    }

    if (url.pathname === "/auth/check" && request.method === "GET") {
      const id = url.searchParams.get("id") || "unknown";
      const key = `auth:${id}`;
      const now = Math.floor(Date.now() / 1000);
      const record = await this.ctx.storage.get(key);
      if (!record) return json({ ok: true, blocked: false, has_failures: false });
      if (record.blocked_until > now) {
        return json({ ok: true, blocked: true, retry_after: record.blocked_until - now, has_failures: true });
      }
      const attempts = (record.attempts || []).filter((time) => now - time < 600);
      if (!attempts.length) {
        await this.ctx.storage.delete(key);
        return json({ ok: true, blocked: false, has_failures: false });
      }
      if (attempts.length !== (record.attempts || []).length) await this.ctx.storage.put(key, { attempts, blocked_until: 0 });
      return json({ ok: true, blocked: false, has_failures: true, attempts: attempts.length });
    }

    if (url.pathname === "/auth/fail" && request.method === "POST") {
      const input = await request.json();
      const id = String(input.id || "unknown");
      const key = `auth:${id}`;
      const now = Math.floor(Date.now() / 1000);
      const record = await this.ctx.storage.get(key) || { attempts: [], blocked_until: 0 };
      if (record.blocked_until > now) return json({ ok: true, blocked: true, retry_after: record.blocked_until - now });
      const attempts = [...(record.attempts || []).filter((time) => now - time < 600), now];
      if (attempts.length >= 5) {
        await this.ctx.storage.put(key, { attempts: [], blocked_until: now + 600 });
        return json({ ok: true, blocked: true, retry_after: 600, remaining_attempts: 0 });
      }
      await this.ctx.storage.put(key, { attempts, blocked_until: 0 });
      return json({ ok: true, blocked: false, remaining_attempts: 5 - attempts.length });
    }

    if (url.pathname === "/auth/success" && request.method === "POST") {
      const input = await request.json();
      await this.ctx.storage.delete(`auth:${String(input.id || "unknown")}`);
      return json({ ok: true });
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
      if (previous.reminder_at !== next.reminder_at || previous.reminder_repeat_until !== next.reminder_repeat_until || previous.memo !== next.memo) {
        next.reminder_sent_at = 0;
        next.reminder_hourly_key = "";
      }
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
      const settings = await this.ctx.storage.get("dashboard:settings") || {};
      return json({ ok: true, settings: {
        auto_delete_offline_days: 0,
        telegram_repeat_interval_minutes: 10,
        telegram_repeat_start: "09:00",
        telegram_repeat_end: "18:00",
        ...settings,
      } });
    }

    if (url.pathname === "/dashboard-settings" && request.method === "POST") {
      const input = await request.json();
      const previous = await this.ctx.storage.get("dashboard:settings") || {};
      const settings = { ...previous, ...input };
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
      const repeatInterval = clampNumber(input.dashboard_settings?.telegram_repeat_interval_minutes, 1, 1440, 10);
      const repeatStart = /^([01]\d|2[0-3]):[0-5]\d$/.test(input.dashboard_settings?.telegram_repeat_start)
        ? input.dashboard_settings.telegram_repeat_start : "09:00";
      const repeatEnd = /^([01]\d|2[0-3]):[0-5]\d$/.test(input.dashboard_settings?.telegram_repeat_end)
        ? input.dashboard_settings.telegram_repeat_end : "18:00";
      await this.ctx.storage.put("dashboard:settings", {
        auto_delete_offline_days: [0, 7, 30, 90].includes(days) ? days : 0,
        telegram_repeat_interval_minutes: repeatInterval,
        telegram_repeat_start: repeatStart < repeatEnd ? repeatStart : "09:00",
        telegram_repeat_end: repeatStart < repeatEnd ? repeatEnd : "18:00",
      });
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
        cloud_drive_url: this.env.CLOUD_DRIVE_URL || "",
        telegram_configured: telegramConfigured(this.env),
        summary,
        nodes,
      });
    }

    return json({ ok: false, error: "存储接口不存在" }, 404);
  }

  async runReminders(now) {
    const records = await this.ctx.storage.list({ prefix: "node:" });
    const dashboardSettings = {
      auto_delete_offline_days: 0,
      telegram_repeat_interval_minutes: 10,
      telegram_repeat_start: "09:00",
      telegram_repeat_end: "18:00",
      ...(await this.ctx.storage.get("dashboard:settings") || {}),
    };
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
    const queued = await this.processTelegramRepeatQueue(now);
    let sent = queued.sent;
    const errors = [...queued.errors];

    for (const [key, record] of records.entries()) {
      const settings = record.settings || defaultSettings();
      if (!settings.telegram_enabled) continue;
      if (settings.maintenance_until > now) continue;
      let changed = false;

      if (settings.reminder_at > 0 && settings.reminder_at <= now) {
        const message = [
          "⏰ VPS 备忘提醒",
          `节点：${record.payload.name}`,
          settings.memo ? `备忘：${settings.memo}` : "备忘：请查看 VPS 状态面板",
        ].join("\n");
        if (!settings.reminder_sent_at) {
          try {
            await this.sendReminder(message, now, dashboardSettings, {
              type: "node-reminder",
              id: record.payload.node_id,
              signature: String(settings.reminder_at),
            });
            settings.reminder_sent_at = now;
            changed = true;
            sent += 1;
          } catch (error) {
            errors.push(`${record.payload.node_id}: ${error.message}`);
          }
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
            await this.sendReminder(message, now, dashboardSettings, {
              type: "node-expiry",
              id: record.payload.node_id,
              signature: settings.expiry_date,
            });
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
      if (reminder.schedule_type === "hourly_until" && now > reminder.schedule_end_at) {
        reminder.enabled = false;
        reminder.completed = true;
        reminder.updated_at = now;
        await this.ctx.storage.put(key, reminder);
        continue;
      }
      const fireKey = globalReminderFireKey(reminder, now);
      if (!fireKey || reminder.last_fired_key === fireKey) continue;
      const message = [
        "📝 全局备忘提醒",
        `事项：${reminder.title}`,
        reminder.content ? `内容：${reminder.content}` : "",
        `计划：${globalReminderScheduleLabel(reminder)}`,
      ].filter(Boolean).join("\n");
      try {
        if (reminder.schedule_type === "hourly_until") {
          await sendTelegram(this.env, message);
        } else {
          await this.sendReminder(message, now, dashboardSettings, {
            type: "global",
            id: reminder.id,
            signature: fireKey,
          });
        }
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

  async sendReminder(text, now, dashboardSettings, source) {
    const interval = clampNumber(dashboardSettings.telegram_repeat_interval_minutes, 1, 1440, 10);
    const window = chinaTimeWindow(
      now,
      dashboardSettings.telegram_repeat_start || "09:00",
      dashboardSettings.telegram_repeat_end || "18:00",
    );
    if (now > window.end) {
      await sendTelegram(this.env, text);
      return;
    }
    const firstAt = Math.max(now, window.start);
    if (firstAt === now) await sendTelegram(this.env, text);
    await this.ctx.storage.put(`telegram-repeat:${crypto.randomUUID()}`, {
      text,
      source,
      next_at: firstAt === now ? now + interval * 60 : firstAt,
      interval_seconds: interval * 60,
      end_at: window.end,
    });
  }

  async processTelegramRepeatQueue(now) {
    const records = await this.ctx.storage.list({ prefix: "telegram-repeat:" });
    let sent = 0;
    const errors = [];
    for (const [key, item] of records.entries()) {
      if (!await this.repeatSourceActive(item.source)) {
        await this.ctx.storage.delete(key);
        continue;
      }
      if (item.end_at && now > item.end_at) {
        await this.ctx.storage.delete(key);
        continue;
      }
      if (item.next_at > now) continue;
      try {
        await sendTelegram(this.env, item.text);
        sent += 1;
        if (item.end_at) {
          item.next_at = now + item.interval_seconds;
          if (item.next_at > item.end_at) await this.ctx.storage.delete(key);
          else await this.ctx.storage.put(key, item);
        } else {
          item.remaining -= 1;
          if (item.remaining <= 0) await this.ctx.storage.delete(key);
          else {
            item.next_at = now + item.interval_seconds;
            await this.ctx.storage.put(key, item);
          }
        }
      } catch (error) {
        errors.push(`repeat:${error.message}`);
      }
    }
    return { sent, errors };
  }

  async repeatSourceActive(source) {
    if (!source?.id) return false;
    if (source.type === "global") {
      const reminder = await this.ctx.storage.get(`global-reminder:${source.id}`);
      return Boolean(reminder && reminder.last_fired_key === source.signature
        && (reminder.enabled || (reminder.schedule_type === "once" && reminder.completed)));
    }
    const record = await this.ctx.storage.get(`node:${source.id}`);
    if (!record || record.settings?.telegram_enabled === false) return false;
    if (source.type === "node-reminder") return String(record.settings?.reminder_at || 0) === source.signature;
    if (source.type === "node-expiry") return String(record.settings?.expiry_date || "") === source.signature;
    return false;
  }
}

function publicGlobalReminder(reminder) {
  return {
    id: reminder.id,
    title: reminder.title,
    content: reminder.content || "",
    schedule_type: reminder.schedule_type,
    schedule_at: Number(reminder.schedule_at) || 0,
    schedule_end_at: Number(reminder.schedule_end_at) || 0,
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
  return [reminder.schedule_type, reminder.schedule_at, reminder.schedule_end_at, reminder.schedule_time, reminder.weekday, reminder.schedule_month, reminder.monthday, reminder.interval_months].join("|");
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
  if (reminder.schedule_type === "hourly_until") {
    if (now < reminder.schedule_at || now > reminder.schedule_end_at) return "";
    const occurrence = Math.floor((now - reminder.schedule_at) / 3600);
    return `hourly:${reminder.schedule_at + occurrence * 3600}`;
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
  if (reminder.schedule_type === "hourly_until") {
    const start = new Date(reminder.schedule_at * 1000).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai" });
    const end = new Date(reminder.schedule_end_at * 1000).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai" });
    return `每小时，自 ${start} 至 ${end}`;
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
    reminder_repeat_until: 0,
    reminder_hourly_key: "",
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
    reminder_repeat_until: Number(settings.reminder_repeat_until) || 0,
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
    reminder_repeat_until: clampNumber(input?.reminder_repeat_until, 0, 4102444800, 0),
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

function chinaTimeWindow(nowSeconds, startText, endText) {
  const china = new Date((nowSeconds + 8 * 3600) * 1000);
  const [startHour, startMinute] = startText.split(":").map(Number);
  const [endHour, endMinute] = endText.split(":").map(Number);
  const offset = 8 * 3600;
  const start = Date.UTC(
    china.getUTCFullYear(), china.getUTCMonth(), china.getUTCDate(), startHour, startMinute,
  ) / 1000 - offset;
  const end = Date.UTC(
    china.getUTCFullYear(), china.getUTCMonth(), china.getUTCDate(), endHour, endMinute,
  ) / 1000 - offset;
  return { start, end };
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

function subscriptionYaml(nodes) {
  const counts = new Map();
  for (const node of nodes) counts.set(node.name, (counts.get(node.name) || 0) + 1);
  const normalized = nodes.map((node) => ({
    ...node,
    display_name: counts.get(node.name) > 1
      ? `${node.name} (${String(node.protocol).toUpperCase()}-${node.node_id})`
      : node.name,
  }));
  const proxyLines = normalized.map((node) => {
    const common = [
      `  - name: ${yamlString(node.display_name)}`,
      `    type: ${node.protocol === "xhttp" ? "vless" : node.protocol}`,
      `    server: ${yamlString(node.server)}`,
      `    port: ${node.port}`,
    ];
    if (node.protocol === "xhttp") {
      return [...common,
        `    uuid: ${yamlString(node.uuid)}`,
        `    encryption: ${yamlString(node.encryption || "none")}`,
        "    network: xhttp",
        "    tls: true",
        "    udp: true",
        "    alpn: [h2]",
        `    servername: ${yamlString(node.sni)}`,
        "    client-fingerprint: chrome",
        `    skip-cert-verify: ${node.insecure === true}`,
        "    xhttp-opts:",
        `      path: ${yamlString(node.path)}`,
        `      host: ${yamlString(node.host || node.sni)}`,
        "      mode: auto",
      ].join("\n");
    }
    if (node.protocol === "mieru") {
      return [...common,
        `    transport: ${node.transport}`,
        `    username: ${yamlString(node.username)}`,
        `    password: ${yamlString(node.password)}`,
        `    multiplexing: ${yamlString(node.multiplexing || "MULTIPLEXING_LOW")}`,
        "    udp: true",
      ].join("\n");
    }
    return [...common,
      `    password: ${yamlString(node.password)}`,
      "    client-fingerprint: chrome",
      "    udp: true",
      "    idle-session-check-interval: 30",
      "    idle-session-timeout: 30",
      "    min-idle-session: 0",
      `    sni: ${yamlString(node.sni)}`,
      "    alpn: [h2, http/1.1]",
      `    skip-cert-verify: ${node.insecure !== false}`,
    ].join("\n");
  });
  const groupNodes = normalized.map((node) => `      - ${yamlString(node.display_name)}`);
  const body = [
    "mixed-port: 7890",
    "allow-lan: false",
    "mode: rule",
    "log-level: info",
    "",
    ...(proxyLines.length ? ["proxies:", ...proxyLines] : ["proxies: []"]),
    "",
    "proxy-groups:",
    "  - name: PROXY",
    "    type: select",
    ...(groupNodes.length ? ["    proxies:", ...groupNodes] : ["    proxies: []"]),
    "    url: \"https://cp.cloudflare.com/\"",
    "    interval: 0",
    "    timeout: 5000",
    "    expected-status: 204",
    "",
    "rules:",
    "  - MATCH,PROXY",
    "",
  ].join("\n");
  return new Response(body, {
    headers: {
      "content-type": "text/yaml; charset=utf-8",
      "cache-control": "no-store, no-cache, must-revalidate",
      "content-disposition": 'inline; filename="subscription.yaml"',
      "x-content-type-options": "nosniff",
      "x-robots-tag": "noindex, nofollow, noarchive",
    },
  });
}

function yamlString(value) {
  return JSON.stringify(String(value ?? ""));
}

function subscriptionFormat(requested, userAgent) {
  const format = String(requested || "").toLowerCase();
  if (format === "shadowrocket") return "shadowrocket";
  if (["v2ray", "v2rayng", "v2rayn", "uri", "base64"].includes(format)) return "uri";
  if (["mihomo", "clash", "meta", "yaml"].includes(format)) return "yaml";
  if (/shadowrocket/i.test(String(userAgent || ""))) return "shadowrocket";
  return /\b(v2rayng|v2rayn)\b/i.test(String(userAgent || "")) ? "uri" : "yaml";
}

function subscriptionUri(nodes, format = "uri") {
  const counts = new Map();
  for (const node of nodes) counts.set(node.name, (counts.get(node.name) || 0) + 1);
  const links = nodes
    .filter((node) => node.protocol === "xhttp" || (format === "shadowrocket" && ["anytls", "mieru"].includes(node.protocol)))
    .map((node) => {
      const protocolName = String(node.protocol).toUpperCase();
      const displayName = counts.get(node.name) > 1 ? `${node.name} (${protocolName}-${node.node_id})` : node.name;
      if (node.protocol === "anytls") {
        const query = new URLSearchParams({
          sni: node.sni,
          insecure: node.insecure !== false ? "1" : "0",
        });
        return `anytls://${encodeURIComponent(node.password)}@${node.server}:${node.port}?${query.toString()}#${encodeURIComponent(displayName)}`;
      }
      if (node.protocol === "mieru") {
        if (format === "shadowrocket") {
          return [
            `${shadowrocketField(displayName)}=mieru`,
            shadowrocketField(node.server),
            node.port,
            `username=${shadowrocketField(node.username)}`,
            `user=${shadowrocketField(node.username)}`,
            `password=${shadowrocketField(node.password)}`,
            `protocol=${shadowrocketField(String(node.transport || "TCP").toLowerCase())}`,
            `transport=${shadowrocketField(String(node.transport || "TCP").toLowerCase())}`,
            `multiplexing=${shadowrocketField(node.multiplexing || "MULTIPLEXING_LOW")}`,
            "udp=1",
          ].join(",");
        }
        return "";
      }
      if (node.protocol === "xhttp" && format === "shadowrocket") {
        const userInfo = base64Utf8(`auto:${node.uuid}@${node.server}:${node.port}`);
        const query = new URLSearchParams({
          tfo: "1",
          remark: displayName,
          tls: "1",
          allowInsecure: node.insecure === true ? "1" : "0",
          peer: node.sni,
          fp: "chrome",
          obfs: "xhttp",
          path: node.path,
          obfsParam: node.host || node.sni,
          mode: "auto",
          encryption: node.encryption || "none",
        });
        return `vless://${userInfo}?${query.toString()}`;
      }
      const query = new URLSearchParams({
        encryption: node.encryption || "none",
        security: "tls",
        sni: node.sni,
        fp: "chrome",
        type: "xhttp",
        host: node.host || node.sni,
        path: node.path,
        mode: "auto",
      });
      return `vless://${encodeURIComponent(node.uuid)}@${node.server}:${node.port}?${query.toString()}#${encodeURIComponent(displayName)}`;
    });
  const plainText = links.join(format === "shadowrocket" ? "\r\n" : "\n");
  return new Response(base64Utf8(plainText), {
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store, no-cache, must-revalidate",
      "content-disposition": 'inline; filename="subscription.txt"',
      "x-content-type-options": "nosniff",
      "x-robots-tag": "noindex, nofollow, noarchive",
    },
  });
}

function shadowrocketField(value) {
  return String(value ?? "").replace(/[\r\n,=]/g, " ").trim();
}

function base64Utf8(value) {
  const plainText = String(value ?? "");
  const bytes = new TextEncoder().encode(plainText);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(String(value)));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function randomHex(byteLength) {
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
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

function requiresViewAuthorization(pathname) {
  return pathname.startsWith("/api/v1/")
    && !["/api/v1/health", "/api/v1/heartbeat", "/api/v1/shutdown",
      "/api/v1/anytls", "/api/v1/anytls/delete",
      "/api/v1/xhttp", "/api/v1/xhttp/delete",
      "/api/v1/mieru", "/api/v1/mieru/delete"].includes(pathname);
}

async function enforceViewAuthorization(request, env) {
  const ip = request.headers.get("cf-connecting-ip") || "local";
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip));
  const id = [...new Uint8Array(digest)].slice(0, 12).map((byte) => byte.toString(16).padStart(2, "0")).join("");
  const store = statusStore(env);
  const check = await store.fetch(new Request(`https://store/auth/check?id=${id}`));
  const state = await check.json();
  if (state.blocked) return rateLimited(state.retry_after || 600);

  if (isViewAuthorized(request, env)) {
    if (state.has_failures) {
      await store.fetch(new Request("https://store/auth/success", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ id }),
      }));
    }
    return null;
  }

  const failed = await store.fetch(new Request("https://store/auth/fail", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ id }),
  }));
  const result = await failed.json();
  if (result.blocked) return rateLimited(result.retry_after || 600);
  return json({ ok: false, error: "查看密码不正确", remaining_attempts: result.remaining_attempts }, 401);
}

function isViewAuthorized(request, env) {
  const token = request.headers.get("x-view-token") || "";
  return env.VIEW_TOKEN && safeEqual(token, encodeURIComponent(env.VIEW_TOKEN));
}

function rateLimited(seconds) {
  return new Response(JSON.stringify({ ok: false, error: "登录尝试过多，请稍后重试", retry_after: seconds }), {
    status: 429,
    headers: {
      ...JSON_HEADERS,
      "retry-after": String(seconds),
    },
  });
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
