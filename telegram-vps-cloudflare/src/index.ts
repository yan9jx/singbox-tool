import { Agent, getAgentByName, type AgentNamespace } from "agents";

type JsonObject = Record<string, unknown>;

export interface Env {
  TelegramVpsAgent: AgentNamespace<TelegramVpsAgent>;
  TELEGRAM_BOT_TOKEN: string;
  TELEGRAM_CHAT_ID: string;
  TELEGRAM_WEBHOOK_SECRET: string;
  DEEPSEEK_API_KEY: string;
  VPS_AGENT_SECRET: string;
}

interface ManagerState {
  aiMode: boolean;
  dailyBrief: boolean;
  selectedNode: string;
  alertsPausedUntil: number;
  aiModel: string;
  aiFallbackModel: string;
}

interface CommandResult {
  command_id: string;
  ok: boolean;
  output: string;
  finished_at: number;
}

interface NodeSyncPayload {
  version: string;
  node_id: string;
  name: string;
  reported_at: number;
  snapshot: JsonObject;
  command_results: CommandResult[];
}

interface AgentCommand {
  command_id: string;
  action: string;
  target: string;
  created_at: number;
  expires_at: number;
}

interface NodeRow {
  node_id: string;
  name: string;
  version: string;
  reported_at: number;
  last_seen: number;
  snapshot_json: string;
}

interface CommandRow {
  command_id: string;
  node_id: string;
  action: string;
  target: string;
  status: string;
  created_at: number;
  expires_at: number;
  last_sent: number;
  attempts: number;
}

interface PendingRow {
  token: string;
  node_id: string;
  action: string;
  target: string;
  label: string;
  expires_at: number;
}

interface ModelChoiceRow {
  token: string;
  model_id: string;
  expires_at: number;
}

interface PendingModelSwitchRow {
  token: string;
  model_id: string;
  previous_model: string;
  expires_at: number;
}

interface AlertStateRow {
  active: number;
  consecutive: number;
  last_sent: number;
  last_detail: string;
}

interface DeepSeekMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | null;
  tool_calls?: DeepSeekToolCall[];
  tool_call_id?: string;
}

interface DeepSeekToolCall {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
}

interface DeepSeekResponse {
  choices?: Array<{ message?: DeepSeekMessage }>;
}

interface DeepSeekCallResult {
  message: DeepSeekMessage | null;
  status: number;
}

const MAX_BODY_BYTES = 128 * 1024;
const COMMAND_TTL_MS = 2 * 60 * 1000;
const MODEL_CHOICE_TTL_MS = 10 * 60 * 1000;
const NODE_STALE_MS = 2 * 60 * 1000;
const ALERT_REPEAT_MS = 30 * 60 * 1000;
const TELEGRAM_TEXT_LIMIT = 4000;
const VALID_ACTIONS = new Set([
  "refresh",
  "clean",
  "pause10",
  "resume",
  "restart_node",
  "restart_proxy",
  "reboot",
]);
const VALID_TARGETS = new Set(["auto", "node", "reverse-proxy"]);
const DEFAULT_DEEPSEEK_MODEL = "deepseek-v4-flash";
const MODEL_FALLBACK_STATUSES = new Set([400, 404, 422]);

export function nodeIsOffline(lastSeen: number, now = Date.now()): boolean {
  return now - lastSeen > NODE_STALE_MS;
}

export function parseNodeDeletionTarget(text: string): string {
  const normalized = text.replace(/\s+/g, " ").trim();
  const slash = normalized.match(/^\/delete(?:@[A-Za-z0-9_]+)?\s+([A-Za-z0-9][A-Za-z0-9._-]{0,63})$/i);
  if (slash?.[1]) return slash[1];
  const chinese = normalized.match(/^删除\s*(?:节点\s*)?([A-Za-z0-9][A-Za-z0-9._-]{0,63})(?:\s|这台|的|$)/i);
  return chinese?.[1] ?? "";
}

function log(level: "info" | "warn" | "error", event: string, data: JsonObject = {}): void {
  console.log(JSON.stringify({ level, event, at: new Date().toISOString(), ...data }));
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asString(value: unknown, max = 256): string {
  return typeof value === "string" ? value.slice(0, max) : "";
}

function asInteger(value: unknown): number {
  return typeof value === "number" && Number.isSafeInteger(value) ? value : 0;
}

export function formatBeijingTime(timestamp: number): string {
  return `${new Date(timestamp + 8 * 60 * 60 * 1000).toISOString().slice(0, 16).replace("T", " ")} 北京时间`;
}

export function normalizeBriefTimes(text: string): string {
  return text.replace(
    /\b(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(?:UTC|Z)\b/g,
    (original, year: string, month: string, day: string, hour: string, minute: string, second = "00") => {
      const timestamp = Date.UTC(Number(year), Number(month) - 1, Number(day), Number(hour), Number(minute), Number(second));
      return Number.isFinite(timestamp) ? formatBeijingTime(timestamp) : original;
    },
  );
}

function isDeepSeekModelId(value: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$/.test(value);
}

export function deepSeekModelIds(value: unknown): string[] {
  if (!isObject(value) || !Array.isArray(value.data)) return [];
  const ids = value.data.flatMap((item) => {
    if (!isObject(item)) return [];
    const id = asString(item.id, 129);
    return isDeepSeekModelId(id) ? [id] : [];
  });
  return [...new Set(ids)].sort((a, b) => a.localeCompare(b));
}

function asNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

export function nodeIssues(snapshot: JsonObject): { resource: string; service: string } {
  const diagnostics = isObject(snapshot.diagnostics) ? snapshot.diagnostics : {};
  const policy = isObject(diagnostics.alert_policy) ? diagnostics.alert_policy : {};
  const memory = isObject(diagnostics.memory) ? diagnostics.memory : {};
  const disk = isObject(diagnostics.disk) ? diagnostics.disk : {};
  const cpu = isObject(diagnostics.cpu) ? diagnostics.cpu : {};
  const network = isObject(diagnostics.network) ? diagnostics.network : {};
  const resource: string[] = [];

  const memoryPct = asNumber(memory.used_pct);
  const swapPct = asNumber(memory.swap_used_pct);
  const cpuPct = asNumber(cpu.used_pct);
  const diskPct = asNumber(disk.used_pct);
  if (memoryPct >= (asNumber(policy.ram_warn) || 80)) resource.push(`RAM ${memoryPct}%`);
  if (swapPct >= (asNumber(policy.swap_warn) || 30)) resource.push(`SWAP ${swapPct}%`);
  if (cpuPct >= (asNumber(policy.cpu_warn) || 80)) resource.push(`CPU ${cpuPct}%`);
  if (diskPct >= (asNumber(policy.disk_warn) || 90)) resource.push(`磁盘 ${diskPct}%`);

  const bandwidth = asNumber(policy.bandwidth_mbps);
  const saturationRatio = asNumber(policy.traffic_saturation_ratio) || 90;
  const rxMbps = asNumber(network.rx_mbps);
  const txMbps = asNumber(network.tx_mbps);
  if (bandwidth > 0 && Math.max(rxMbps, txMbps) >= bandwidth * saturationRatio / 100) {
    resource.push(`带宽接近跑满（入 ${rxMbps.toFixed(1)} / 出 ${txMbps.toFixed(1)} Mbps）`);
  }

  const service: string[] = [];
  if (isObject(diagnostics.services)) {
    for (const [name, state] of Object.entries(diagnostics.services)) {
      if (typeof state === "string" && state !== "active") service.push(`${name}: ${state}`);
    }
  }
  const expectedPorts = Array.isArray(diagnostics.expected_ports)
    ? diagnostics.expected_ports.map((value) => Number(value)).filter((value) => Number.isInteger(value) && value > 0)
    : [];
  const listeningPorts = new Set(
    Array.isArray(diagnostics.listening_tcp_ports)
      ? diagnostics.listening_tcp_ports.map((value) => Number(value)).filter((value) => Number.isInteger(value) && value > 0)
      : [],
  );
  const missingPorts = expectedPorts.filter((port) => !listeningPorts.has(port));
  if (missingPorts.length > 0) service.push(`端口未监听: ${missingPorts.join(", ")}`);
  return { resource: resource.join("；"), service: service.join("；") };
}

export const PANEL_KEYBOARD: JsonObject = {
  inline_keyboard: [
    [{ text: "📊 状态刷新", callback_data: "status" }, { text: "🔍 状态更新", callback_data: "refresh_local" }],
    [{ text: "🔄 重启节点", callback_data: "restart_node" }, { text: "🌐 重启反代", callback_data: "restart_proxy" }],
    [{ text: "🖥 切换 VPS", callback_data: "nodes" }, { text: "♻️ 重启 VPS", callback_data: "reboot_ask" }],
  ],
};

export function alertPolicyText(snapshot: JsonObject, nodeName: string, version: string): string {
  const diagnostics = isObject(snapshot.diagnostics) ? snapshot.diagnostics : {};
  const policy = isObject(diagnostics.alert_policy) ? diagnostics.alert_policy : {};
  const configured = Object.keys(policy).length > 0;
  const ram = asNumber(policy.ram_warn) || 80;
  const swap = asNumber(policy.swap_warn) || 30;
  const cpu = asNumber(policy.cpu_warn) || 80;
  const disk = asNumber(policy.disk_warn) || 90;
  const bandwidth = asNumber(policy.bandwidth_mbps);
  const ratio = asNumber(policy.traffic_saturation_ratio) || 90;
  const lines = [
    `🚨 VPS 告警阈值\n[${nodeName}]`,
    `CPU：≥ ${cpu}%`,
    `RAM：≥ ${ram}%`,
    `SWAP：≥ ${swap}%`,
    `磁盘：≥ ${disk}%`,
  ];
  if (bandwidth > 0) lines.push(`带宽：≥ ${ratio}%（约 ${(bandwidth * ratio / 100).toFixed(0)} Mbps）`);
  lines.push("资源和服务异常连续检测 2 次才告警，节点超过约 2 分钟未上报则判定离线。");
  lines.push(configured
    ? `来源：VPS Agent ${version} 实际上报配置。`
    : `注意：当前 Agent ${version} 尚未上报自定义阈值，以上是 Cloudflare 默认值；升级 Agent 后会显示 VPS 实际配置。`);
  return lines.join("\n");
}

function redact(text: string): string {
  return text
    .replace(/\bsk-[A-Za-z0-9_-]{10,}\b/g, "[已隐藏 API Key]")
    .replace(/\b\d{6,12}:[A-Za-z0-9_-]{20,}\b/g, "[已隐藏 Bot Token]")
    .replace(/(api[_ -]?key|token|password|passwd|secret)\s*[:=]\s*\S+/gi, "$1=[已隐藏]")
    .slice(0, 24_000);
}

function clampTelegram(text: string): string {
  const clean = redact(text.trim());
  return clean.length > TELEGRAM_TEXT_LIMIT ? `${clean.slice(0, TELEGRAM_TEXT_LIMIT - 20)}\n…内容已截断` : clean;
}

function safeJsonParse(text: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return null;
  }
}

function validateSyncPayload(value: unknown): NodeSyncPayload | null {
  if (!isObject(value)) return null;
  const nodeId = asString(value.node_id, 64);
  const name = asString(value.name, 100);
  const version = asString(value.version, 32);
  const reportedAt = asInteger(value.reported_at);
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(nodeId) || !name || !version || !reportedAt) return null;
  if (!isObject(value.snapshot) || !Array.isArray(value.command_results)) return null;
  const results: CommandResult[] = [];
  for (const item of value.command_results.slice(0, 20)) {
    if (!isObject(item)) return null;
    const commandId = asString(item.command_id, 64);
    if (!/^[0-9a-f-]{36}$/i.test(commandId) || typeof item.ok !== "boolean") return null;
    results.push({
      command_id: commandId,
      ok: item.ok,
      output: redact(asString(item.output, 4000)),
      finished_at: asInteger(item.finished_at),
    });
  }
  return {
    version,
    node_id: nodeId,
    name,
    reported_at: reportedAt,
    snapshot: value.snapshot,
    command_results: results,
  };
}

function timingSafeEqual(a: string, b: string): boolean {
  const aa = new TextEncoder().encode(a);
  const bb = new TextEncoder().encode(b);
  const length = Math.max(aa.length, bb.length);
  let diff = aa.length ^ bb.length;
  for (let i = 0; i < length; i += 1) diff |= (aa[i] ?? 0) ^ (bb[i] ?? 0);
  return diff === 0;
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(signature)].map((value) => value.toString(16).padStart(2, "0")).join("");
}

async function telegramApi(env: Env, method: string, payload: JsonObject): Promise<JsonObject> {
  const response = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const value = (await response.json()) as unknown;
  if (!response.ok || !isObject(value) || value.ok !== true) {
    throw new Error(`Telegram ${method} failed with HTTP ${response.status}`);
  }
  return value;
}

export class TelegramVpsAgent extends Agent<Env, ManagerState> {
  override initialState: ManagerState = {
    aiMode: false,
    dailyBrief: true,
    selectedNode: "",
    alertsPausedUntil: 0,
    aiModel: DEFAULT_DEEPSEEK_MODEL,
    aiFallbackModel: DEFAULT_DEEPSEEK_MODEL,
  };

  override async onStart(): Promise<void> {
    await this.sql`
      CREATE TABLE IF NOT EXISTS nodes (
        node_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        version TEXT NOT NULL,
        reported_at INTEGER NOT NULL,
        last_seen INTEGER NOT NULL,
        snapshot_json TEXT NOT NULL
      )
    `;
    await this.sql`
      CREATE TABLE IF NOT EXISTS commands (
        command_id TEXT PRIMARY KEY,
        node_id TEXT NOT NULL,
        action TEXT NOT NULL,
        target TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        last_sent INTEGER NOT NULL DEFAULT 0,
        attempts INTEGER NOT NULL DEFAULT 0,
        result_text TEXT NOT NULL DEFAULT ''
      )
    `;
    await this.sql`
      CREATE TABLE IF NOT EXISTS pending_confirmations (
        token TEXT PRIMARY KEY,
        node_id TEXT NOT NULL,
        action TEXT NOT NULL,
        target TEXT NOT NULL,
        label TEXT NOT NULL,
        expires_at INTEGER NOT NULL
      )
    `;
    await this.sql`
      CREATE TABLE IF NOT EXISTS model_choices (
        token TEXT PRIMARY KEY,
        model_id TEXT NOT NULL,
        expires_at INTEGER NOT NULL
      )
    `;
    await this.sql`
      CREATE TABLE IF NOT EXISTS pending_model_switches (
        token TEXT PRIMARY KEY,
        model_id TEXT NOT NULL,
        previous_model TEXT NOT NULL,
        expires_at INTEGER NOT NULL
      )
    `;
    await this.sql`
      CREATE TABLE IF NOT EXISTS processed_updates (
        update_id INTEGER PRIMARY KEY,
        processed_at INTEGER NOT NULL
      )
    `;
    await this.sql`
      CREATE TABLE IF NOT EXISTS chat_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    `;
    await this.sql`
      CREATE TABLE IF NOT EXISTS scheduled_runs (
        run_key TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL
      )
    `;
    await this.sql`
      CREATE TABLE IF NOT EXISTS alert_states (
        node_id TEXT NOT NULL,
        alert_key TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 0,
        consecutive INTEGER NOT NULL DEFAULT 0,
        last_sent INTEGER NOT NULL DEFAULT 0,
        last_detail TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (node_id, alert_key)
      )
    `;
  }

  async syncNode(payload: NodeSyncPayload): Promise<{ commands: AgentCommand[]; server_time: number }> {
    const now = Date.now();
    const snapshotJson = JSON.stringify(payload.snapshot).slice(0, 96_000);
    await this.sql`
      INSERT INTO nodes (node_id, name, version, reported_at, last_seen, snapshot_json)
      VALUES (${payload.node_id}, ${payload.name}, ${payload.version}, ${payload.reported_at}, ${now}, ${snapshotJson})
      ON CONFLICT(node_id) DO UPDATE SET
        name = excluded.name,
        version = excluded.version,
        reported_at = excluded.reported_at,
        last_seen = excluded.last_seen,
        snapshot_json = excluded.snapshot_json
    `;

    if (!this.state.selectedNode) this.setState({ ...this.state, selectedNode: payload.node_id });

    const node: NodeRow = {
      node_id: payload.node_id,
      name: payload.name,
      version: payload.version,
      reported_at: payload.reported_at,
      last_seen: now,
      snapshot_json: snapshotJson,
    };
    await this.evaluateNodeAlerts(node);

    for (const result of payload.command_results) {
      const rows = await this.sql<CommandRow>`
        SELECT * FROM commands WHERE command_id = ${result.command_id} AND node_id = ${payload.node_id}
      `;
      if (rows.length === 0 || rows[0]?.status === "done") continue;
      await this.sql`
        UPDATE commands SET status = 'done', result_text = ${result.output} WHERE command_id = ${result.command_id}
      `;
      const icon = result.ok ? "✅" : "⚠️";
      await this.sendMessage(`${icon} VPS 操作结果\n[${payload.name}]\n\n${result.output || (result.ok ? "执行成功" : "执行失败")}`);
    }

    await this.sql`DELETE FROM pending_confirmations WHERE expires_at < ${now}`;
    await this.sql`UPDATE commands SET status = 'expired' WHERE status != 'done' AND expires_at < ${now}`;
    const pending = await this.sql<CommandRow>`
      SELECT * FROM commands
      WHERE node_id = ${payload.node_id}
        AND status IN ('queued', 'sent')
        AND expires_at >= ${now}
        AND (last_sent = 0 OR last_sent < ${now - 10_000})
      ORDER BY created_at ASC
      LIMIT 5
    `;
    const commands: AgentCommand[] = [];
    for (const row of pending) {
      await this.sql`
        UPDATE commands SET status = 'sent', last_sent = ${now}, attempts = attempts + 1
        WHERE command_id = ${row.command_id}
      `;
      commands.push({
        command_id: row.command_id,
        action: row.action,
        target: row.target,
        created_at: row.created_at,
        expires_at: row.expires_at,
      });
    }
    return { commands, server_time: now };
  }

  async healthSummary(): Promise<{ connected_nodes: number; online_nodes: number; newest_last_seen: number }> {
    const rows = await this.sql<{ connected_nodes: number; online_nodes: number; newest_last_seen: number }>`
      SELECT
        COUNT(*) AS connected_nodes,
        COALESCE(SUM(CASE WHEN last_seen >= ${Date.now() - NODE_STALE_MS} THEN 1 ELSE 0 END), 0) AS online_nodes,
        COALESCE(MAX(last_seen), 0) AS newest_last_seen
      FROM nodes
    `;
    return rows[0] ?? { connected_nodes: 0, online_nodes: 0, newest_last_seen: 0 };
  }

  async processUpdate(update: JsonObject): Promise<void> {
    const updateId = asInteger(update.update_id);
    if (!updateId) return;
    const prior = await this.sql<{ update_id: number }>`SELECT update_id FROM processed_updates WHERE update_id = ${updateId}`;
    if (prior.length > 0) return;
    await this.sql`INSERT INTO processed_updates (update_id, processed_at) VALUES (${updateId}, ${Date.now()})`;
    await this.sql`DELETE FROM processed_updates WHERE processed_at < ${Date.now() - 7 * 86_400_000}`;

    const callback = isObject(update.callback_query) ? update.callback_query : null;
    if (callback) {
      const callbackMessage = isObject(callback.message) ? callback.message : null;
      const chat = callbackMessage && isObject(callbackMessage.chat) ? callbackMessage.chat : null;
      if (!chat || !timingSafeEqual(String(chat.id ?? ""), this.env.TELEGRAM_CHAT_ID)) return;
      await this.selectNodeFromMessage(
        callbackMessage ? asString(callbackMessage.text, 4000) || asString(callbackMessage.caption, 4000) : "",
      );
      const callbackId = asString(callback.id, 128);
      if (callbackId) await this.answerCallback(callbackId);
      await this.handleCallback(asString(callback.data, 128));
      return;
    }

    const message = isObject(update.message) ? update.message : null;
    const chat = message && isObject(message.chat) ? message.chat : null;
    if (!message || !chat || !timingSafeEqual(String(chat.id ?? ""), this.env.TELEGRAM_CHAT_ID)) return;
    const text = asString(message.text, 4000).trim();
    if (text) await this.handleText(text);
  }

  async runDailyBrief(): Promise<void> {
    if (!this.state.dailyBrief) return;
    const context = await this.diagnosticsContext();
    if (!context) return;
    const generatedAt = formatBeijingTime(Date.now());
    const answer = await this.deepSeekSimple([
      { role: "system", content: "你是中文 VPS 运维助手。根据真实状态生成简洁的每日简报：总体结论、异常、风险、建议。禁止编造。所有时间必须使用用户提供的北京时间，禁止输出 UTC、Z 或其他时区。" },
      { role: "user", content: `简报生成时间：${generatedAt}\n${context}` },
    ]);
    if (answer) await this.sendMessage(`🧭 每日 AI 运维简报\n\n${normalizeBriefTimes(answer)}`, this.panelKeyboard());
  }

  async runWeeklyCleanup(scheduledTime: number): Promise<void> {
    const runKey = `weekly-clean:${scheduledTime}`;
    const prior = await this.sql<{ run_key: string }>`SELECT run_key FROM scheduled_runs WHERE run_key = ${runKey}`;
    if (prior.length > 0) return;
    await this.sql`INSERT INTO scheduled_runs (run_key, created_at) VALUES (${runKey}, ${Date.now()})`;
    await this.sql`DELETE FROM scheduled_runs WHERE created_at < ${Date.now() - 90 * 86_400_000}`;

    const nodes = await this.sql<NodeRow>`
      SELECT * FROM nodes WHERE last_seen >= ${Date.now() - NODE_STALE_MS} ORDER BY name ASC
    `;
    for (const node of nodes) await this.enqueueCommand(node.node_id, "clean", "auto");
    log("info", "weekly_cleanup_queued", { scheduledTime, nodes: nodes.length });
  }

  async runMonitorTick(scheduledTime: number): Promise<void> {
    const runKey = `monitor:${scheduledTime}`;
    const prior = await this.sql<{ run_key: string }>`SELECT run_key FROM scheduled_runs WHERE run_key = ${runKey}`;
    if (prior.length > 0) return;
    await this.sql`INSERT INTO scheduled_runs (run_key, created_at) VALUES (${runKey}, ${Date.now()})`;
    await this.sql`DELETE FROM scheduled_runs WHERE created_at < ${Date.now() - 14 * 86_400_000}`;

    const nodes = await this.sql<NodeRow>`SELECT * FROM nodes ORDER BY name ASC`;
    const now = Date.now();
    for (const node of nodes) {
      const offline = now - node.last_seen > NODE_STALE_MS;
      await this.updateAlert(node, "offline", offline ? `超过 ${Math.ceil(NODE_STALE_MS / 60_000)} 分钟没有上报` : "", 1);
    }
    if (new Date(scheduledTime).getUTCMinutes() !== 0) return;
    for (const node of nodes.filter((item) => now - item.last_seen <= NODE_STALE_MS)) {
      await this.sendMessage(`⏱ Cloudflare 每小时状态\n\n${this.formatNodeStatus(node)}`, this.panelKeyboard());
    }
  }

  private alertsPaused(): boolean {
    return Number(this.state.alertsPausedUntil ?? 0) > Date.now();
  }

  private async evaluateNodeAlerts(node: NodeRow): Promise<void> {
    await this.updateAlert(node, "offline", "", 1);
    const snapshot = safeJsonParse(node.snapshot_json);
    if (!isObject(snapshot)) return;
    const issues = nodeIssues(snapshot);
    await this.updateAlert(node, "resource", issues.resource, 2);
    await this.updateAlert(node, "service", issues.service, 2);
  }

  private async updateAlert(node: NodeRow, key: string, detail: string, requiredConsecutive: number): Promise<void> {
    if (this.alertsPaused()) return;
    const rows = await this.sql<AlertStateRow>`
      SELECT active, consecutive, last_sent, last_detail FROM alert_states
      WHERE node_id = ${node.node_id} AND alert_key = ${key}
    `;
    const previous = rows[0];
    const now = Date.now();
    if (!detail) {
      if (!previous) return;
      if (previous?.active) {
        const labels: Record<string, string> = { offline: "节点已恢复上报", resource: "资源已恢复正常", service: "服务与端口已恢复正常" };
        await this.sendMessage(`✅ ${labels[key] ?? "异常已恢复"}\n[${node.name}]`);
      }
      if (!previous.active && previous.consecutive === 0 && !previous.last_detail) return;
      await this.sql`
        INSERT INTO alert_states (node_id, alert_key, active, consecutive, last_sent, last_detail)
        VALUES (${node.node_id}, ${key}, 0, 0, ${previous?.last_sent ?? 0}, '')
        ON CONFLICT(node_id, alert_key) DO UPDATE SET active = 0, consecutive = 0, last_detail = ''
      `;
      return;
    }

    const consecutive = previous?.active ? previous.consecutive : (previous?.consecutive ?? 0) + 1;
    const activate = Boolean(previous?.active) || consecutive >= requiredConsecutive;
    const shouldSend = activate && (!previous?.active || now - previous.last_sent >= ALERT_REPEAT_MS);
    if (previous?.active && !shouldSend && previous.last_detail === detail) return;
    if (shouldSend) {
      const labels: Record<string, string> = { offline: "节点离线", resource: "资源异常", service: "服务或端口异常" };
      await this.sendMessage(`🚨 ${labels[key] ?? "VPS 异常"}\n[${node.name}]\n\n${detail}`);
    }
    await this.sql`
      INSERT INTO alert_states (node_id, alert_key, active, consecutive, last_sent, last_detail)
      VALUES (${node.node_id}, ${key}, ${activate ? 1 : 0}, ${consecutive}, ${shouldSend ? now : previous?.last_sent ?? 0}, ${detail})
      ON CONFLICT(node_id, alert_key) DO UPDATE SET
        active = excluded.active,
        consecutive = excluded.consecutive,
        last_sent = excluded.last_sent,
        last_detail = excluded.last_detail
    `;
  }

  private async handleText(text: string): Promise<void> {
    const normalized = text.replace(/\s+/g, " ").trim();
    const lower = normalized.toLowerCase();
    const deletionTarget = parseNodeDeletionTarget(normalized);
    if (["/start", "/menu", "菜单"].includes(lower)) {
      await this.sendMessage(await this.statusText(), this.panelKeyboard());
    } else if (["/status", "状态", "状态刷新", "我的vps状态", "我的 vps 状态", "vps状态"].includes(lower)) {
      await this.sendMessage(await this.statusText(), this.panelKeyboard());
    } else if (lower === "/thresholds" || lower.includes("告警阈值") || lower.includes("报警阈值")) {
      await this.sendMessage(await this.thresholdsText());
    } else if (["/latency", "/speedtest", "/testsetup", "/testdisable"].includes(lower) || ["测延迟", "延迟测试", "测试延迟", "网络延迟", "测网速", "测速", "网速测试", "下载测速", "网络测速", "启用本地测速", "配置本地测速", "开启本地测速", "停用本地测速", "关闭本地测速"].some((item) => lower.includes(item))) {
      await this.sendMessage("测延迟和测速功能已取消。");
    } else if (["断线提醒", "掉线提醒", "离线提醒"].some((item) => lower.includes(item))) {
      await this.sendMessage(this.offlineReminderText());
    } else if (lower.includes("整点播报") || lower.includes("每小时播报")) {
      await this.sendMessage("✅ Cloudflare 每小时整点播报已启用。它直接读取 VPS 上报状态，不调用 DeepSeek；异常告警仍独立运行。", this.panelKeyboard());
    } else if (lower === "/nodes") {
      await this.sendMessage(await this.nodesText(), this.nodesKeyboard());
    } else if (lower.startsWith("/use ")) {
      await this.selectNode(normalized.slice(5).trim());
    } else if (lower === "/delete" || lower === "删除节点") {
      await this.sendMessage("删除命令：/delete 节点ID\n也可以进入 /nodes，点击离线节点旁的删除按钮。\n仅允许删除离线节点，并且需要二次确认。");
    } else if (deletionTarget) {
      await this.requestNodeDeletion(deletionTarget);
    } else if (["/pause10", "暂停"].includes(lower)) {
      this.setState({ ...this.state, alertsPausedUntil: Date.now() + 10 * 60_000 });
      await this.sendMessage("🟡 Cloudflare 异常告警已暂停 10 分钟。", this.panelKeyboard());
    } else if (["/resume", "恢复"].includes(lower)) {
      this.setState({ ...this.state, alertsPausedUntil: 0 });
      await this.sendMessage("🟢 Cloudflare 异常告警已恢复。", this.panelKeyboard());
    } else if (["/ping", "ping"].includes(lower)) {
      await this.sendMessage("pong");
    } else if (["/balance", "/ai balance", "/ai 余额", "查询余额", "查余额", "余额", "ai余额", "deepseek余额"].includes(lower)) {
      await this.sendMessage(await this.balanceText());
    } else if (["/models", "刷新模型", "可用模型", "切换模型", "更换模型"].includes(lower)) {
      await this.showModels();
    } else if (["/model", "当前模型", "现在模型", "使用的模型"].includes(lower)) {
      await this.sendMessage(`🤖 当前 DeepSeek 模型：${this.currentModel()}\n发送 /models 可读取最新可用模型。`);
    } else if (lower === "/brief on") {
      this.setState({ ...this.state, dailyBrief: true });
      await this.sendMessage("✅ 每日 AI 运维简报已开启，将在北京时间每天 09:00 发送。");
    } else if (lower === "/brief off") {
      this.setState({ ...this.state, dailyBrief: false });
      await this.sendMessage("✅ 每日 AI 运维简报已关闭；原监控和告警不受影响。");
    } else if (lower === "/brief") {
      await this.runDailyBrief();
    } else if (lower === "/ai on") {
      this.setState({ ...this.state, aiMode: true });
      await this.sendMessage("🤖 AI 连续对话模式已开启。普通文字会发送给 DeepSeek；请勿发送密码、Token、API Key 或 SSH 私钥。发送 /ai off 可退出。");
    } else if (lower === "/ai off") {
      this.setState({ ...this.state, aiMode: false });
      await this.sql`DELETE FROM chat_history`;
      await this.sendMessage("✅ AI 连续对话模式已关闭，对话上下文已清空。");
    } else if (lower === "/ai") {
      await this.sendMessage(
        `当前 AI 连续对话模式：${this.state.aiMode ? "开启" : "关闭"}\n` +
          `当前模型：${this.currentModel()}\n` +
          "开启：/ai on\n关闭：/ai off\n单次提问：/ai 你的问题\n模型列表：/models\n即时简报：/brief\n每日简报：/brief on 或 /brief off\n节点列表：/nodes",
      );
    } else if (lower.startsWith("/ai ")) {
      await this.aiChat(normalized.slice(4).trim());
    } else if (lower === "确认重启vps") {
      await this.requestConfirmation("reboot", "auto", "重启整台 VPS");
    } else if (this.state.aiMode) {
      await this.aiChat(normalized);
    } else {
      await this.sendMessage("发送 /start 打开控制面板；发送 /ai on 开启连续对话。", this.panelKeyboard());
    }
  }

  private async handleCallback(data: string): Promise<void> {
    if (data === "status") await this.sendMessage(await this.statusText(), this.panelKeyboard());
    else if (data === "nodes") await this.sendMessage(await this.nodesText(), this.nodesKeyboard());
    else if (data.startsWith("use:")) await this.selectNode(data.slice(4));
    else if (data === "refresh_local") await this.queueImmediate("refresh", "auto", "刷新本机状态");
    else if (data === "restart_node") await this.requestConfirmation("restart_node", "node", "重启节点服务");
    else if (data === "restart_proxy") await this.requestConfirmation("restart_proxy", "reverse-proxy", "重启反向代理");
    else if (data === "reboot_ask") await this.requestConfirmation("reboot", "auto", "重启整台 VPS");
    else if (data.startsWith("model_pick:")) await this.requestModelSwitch(data.slice(11));
    else if (data.startsWith("model_confirm:")) await this.confirmModelSwitch(data.slice(14));
    else if (data.startsWith("model_cancel:")) await this.cancelModelSwitch(data.slice(13));
    else if (data.startsWith("delete_ask:")) await this.requestNodeDeletionFromToken(data.slice(11));
    else if (data.startsWith("delete_confirm:")) await this.confirmNodeDeletion(data.slice(15));
    else if (data.startsWith("confirm:")) await this.confirmAction(data.slice(8));
    else if (data.startsWith("cancel:")) await this.cancelAction(data.slice(7));
    else await this.sendMessage(await this.statusText(), this.panelKeyboard());
  }

  private async selectNode(nodeId: string): Promise<void> {
    const rows = await this.sql<NodeRow>`SELECT * FROM nodes WHERE node_id = ${nodeId}`;
    if (rows.length === 0) {
      await this.sendMessage(`未找到节点：${nodeId}\n发送 /nodes 查看可用节点。`);
      return;
    }
    this.setState({ ...this.state, selectedNode: nodeId });
    await this.sendMessage(`✅ 当前管理节点已切换为：${rows[0]?.name} (${nodeId})`, this.panelKeyboard());
  }

  private async selectNodeFromMessage(text: string): Promise<void> {
    const match = text.match(/\[([^\]\n]{1,100})\]/);
    if (!match?.[1]) return;
    const rows = await this.sql<NodeRow>`SELECT * FROM nodes WHERE name = ${match[1]} ORDER BY last_seen DESC LIMIT 1`;
    if (rows[0] && rows[0].node_id !== this.state.selectedNode) {
      this.setState({ ...this.state, selectedNode: rows[0].node_id });
    }
  }

  private async selectedNode(): Promise<NodeRow | null> {
    if (this.state.selectedNode) {
      const selected = await this.sql<NodeRow>`SELECT * FROM nodes WHERE node_id = ${this.state.selectedNode}`;
      if (selected[0]) return selected[0];
    }
    const rows = await this.sql<NodeRow>`SELECT * FROM nodes ORDER BY last_seen DESC LIMIT 1`;
    if (!rows[0]) return null;
    this.setState({ ...this.state, selectedNode: rows[0].node_id });
    return rows[0];
  }

  private async statusText(): Promise<string> {
    const node = await this.selectedNode();
    if (!node) return "尚未收到 VPS 代理上报。请先在 VPS 安装 Cloudflare Telegram Agent。";
    return this.formatNodeStatus(node);
  }

  private async thresholdsText(): Promise<string> {
    const node = await this.selectedNode();
    if (!node) return "尚未收到 VPS Agent 上报，无法读取告警阈值。";
    const snapshot = safeJsonParse(node.snapshot_json);
    return alertPolicyText(isObject(snapshot) ? snapshot : {}, node.name, node.version);
  }

  private offlineReminderText(): string {
    return "✅ 断线提醒已启用。VPS Agent 每 30 秒上报；超过约 2 分钟未上报，Cloudflare 会在下一次 5 分钟巡检时主动提醒，恢复后也会主动通知。该功能不调用 DeepSeek。";
  }

  private formatNodeStatus(node: NodeRow): string {
    const snapshot = safeJsonParse(node.snapshot_json);
    const status = isObject(snapshot) ? asString(snapshot.status_text, 20_000) : "";
    const stale = Date.now() - node.last_seen > NODE_STALE_MS;
    const prefix = `${stale ? "🔴 节点离线或上报超时" : "🟢 Cloudflare 已连接"}\n当前节点：${node.name} (${node.node_id})\n`;
    return clampTelegram(`${prefix}\n${status || JSON.stringify(snapshot, null, 2)}`);
  }

  private async nodesText(): Promise<string> {
    const rows = await this.sql<NodeRow>`SELECT * FROM nodes ORDER BY name ASC`;
    if (rows.length === 0) return "尚无已连接节点。";
    const lines = ["🖥 VPS 节点列表"];
    for (const row of rows) {
      const icon = Date.now() - row.last_seen > NODE_STALE_MS ? "🔴" : "🟢";
      const selected = row.node_id === this.state.selectedNode ? " ← 当前" : "";
      lines.push(`${icon} ${row.name} (${row.node_id})${selected}`);
    }
    lines.push("\n切换命令：/use 节点ID");
    lines.push("删除命令：/delete 节点ID（仅限离线节点，需二次确认）");
    return lines.join("\n");
  }

  private async findNode(nodeReference: string): Promise<{ node: NodeRow | null; ambiguous: NodeRow[] }> {
    const byId = await this.sql<NodeRow>`SELECT * FROM nodes WHERE node_id = ${nodeReference} LIMIT 1`;
    if (byId[0]) return { node: byId[0], ambiguous: [] };
    const byName = await this.sql<NodeRow>`SELECT * FROM nodes WHERE name = ${nodeReference} ORDER BY last_seen DESC LIMIT 10`;
    return byName.length === 1 ? { node: byName[0] ?? null, ambiguous: [] } : { node: null, ambiguous: byName };
  }

  private async createNodeDeletionToken(node: NodeRow, expiresAt: number): Promise<string> {
    const token = crypto.randomUUID();
    const label = `删除节点 ${node.name} (${node.node_id})`;
    await this.sql`
      INSERT INTO pending_confirmations (token, node_id, action, target, label, expires_at)
      VALUES (${token}, ${node.node_id}, 'delete_node', 'auto', ${label}, ${expiresAt})
    `;
    return token;
  }

  private async requestNodeDeletion(nodeReference: string): Promise<void> {
    const found = await this.findNode(nodeReference);
    if (found.ambiguous.length > 1) {
      const ids = found.ambiguous.map((node) => `${node.name}：${node.node_id}`).join("\n");
      await this.sendMessage(`发现多个同名节点，请使用节点 ID 删除：\n${ids}`);
      return;
    }
    const node = found.node;
    if (!node) {
      await this.sendMessage(`未找到节点：${nodeReference}\n发送 /nodes 查看节点 ID。`);
      return;
    }
    if (!nodeIsOffline(node.last_seen)) {
      await this.sendMessage(`拒绝删除：${node.name} (${node.node_id}) 仍在正常上报。\n请先停用该 VPS Agent，等待节点显示为离线后再删除。`);
      return;
    }
    const token = await this.createNodeDeletionToken(node, Date.now() + COMMAND_TTL_MS);
    await this.sendNodeDeletionConfirmation(node, token);
  }

  private async requestNodeDeletionFromToken(token: string): Promise<void> {
    const rows = await this.sql<PendingRow>`SELECT * FROM pending_confirmations WHERE token = ${token} AND action = 'delete_node'`;
    const pending = rows[0];
    if (!pending || pending.expires_at < Date.now()) {
      await this.sql`DELETE FROM pending_confirmations WHERE token = ${token}`;
      await this.sendMessage("删除入口已失效，请重新打开 /nodes。");
      return;
    }
    const nodes = await this.sql<NodeRow>`SELECT * FROM nodes WHERE node_id = ${pending.node_id}`;
    const node = nodes[0];
    if (!node) {
      await this.sql`DELETE FROM pending_confirmations WHERE token = ${token}`;
      await this.sendMessage("该节点记录已经不存在。", this.panelKeyboard());
      return;
    }
    if (!nodeIsOffline(node.last_seen)) {
      await this.sql`DELETE FROM pending_confirmations WHERE token = ${token}`;
      await this.sendMessage(`拒绝删除：${node.name} (${node.node_id}) 已恢复上报。`);
      return;
    }
    await this.sql`UPDATE pending_confirmations SET expires_at = ${Date.now() + COMMAND_TTL_MS} WHERE token = ${token}`;
    await this.sendNodeDeletionConfirmation(node, token);
  }

  private async sendNodeDeletionConfirmation(node: NodeRow, token: string): Promise<void> {
    await this.sendMessage(
      `⚠️ 请确认删除离线节点\n目标：${node.name} (${node.node_id})\n\n将清除 Cloudflare 管家中的节点状态、告警和待执行命令；不会操作其他 VPS。确认按钮 2 分钟内有效。`,
      {
        inline_keyboard: [[
          { text: "🗑 确认删除", callback_data: `delete_confirm:${token}` },
          { text: "取消", callback_data: `cancel:${token}` },
        ]],
      },
    );
  }

  private async confirmNodeDeletion(token: string): Promise<void> {
    const rows = await this.sql<PendingRow>`SELECT * FROM pending_confirmations WHERE token = ${token} AND action = 'delete_node'`;
    const pending = rows[0];
    if (!pending || pending.expires_at < Date.now()) {
      await this.sql`DELETE FROM pending_confirmations WHERE token = ${token}`;
      await this.sendMessage("删除确认已失效，请重新发起。", this.panelKeyboard());
      return;
    }
    const nodes = await this.sql<NodeRow>`SELECT * FROM nodes WHERE node_id = ${pending.node_id}`;
    const node = nodes[0];
    if (!node) {
      await this.sql`DELETE FROM pending_confirmations WHERE token = ${token}`;
      await this.sendMessage("该节点记录已经删除。", this.panelKeyboard());
      return;
    }
    if (!nodeIsOffline(node.last_seen)) {
      await this.sql`DELETE FROM pending_confirmations WHERE token = ${token}`;
      await this.sendMessage(`拒绝删除：${node.name} (${node.node_id}) 已恢复上报。`);
      return;
    }

    this.ctx.storage.transactionSync(() => {
      this.ctx.storage.sql.exec("DELETE FROM commands WHERE node_id = ?", node.node_id);
      this.ctx.storage.sql.exec("DELETE FROM alert_states WHERE node_id = ?", node.node_id);
      this.ctx.storage.sql.exec("DELETE FROM pending_confirmations WHERE node_id = ?", node.node_id);
      this.ctx.storage.sql.exec("DELETE FROM nodes WHERE node_id = ?", node.node_id);
    });

    if (this.state.selectedNode === node.node_id) {
      const next = await this.sql<NodeRow>`
        SELECT * FROM nodes
        ORDER BY CASE WHEN last_seen >= ${Date.now() - NODE_STALE_MS} THEN 0 ELSE 1 END, last_seen DESC
        LIMIT 1
      `;
      this.setState({ ...this.state, selectedNode: next[0]?.node_id ?? "" });
    }
    log("info", "offline_node_deleted", { nodeId: node.node_id, nodeName: node.name });
    await this.sendMessage(`✅ 已删除离线节点记录：${node.name} (${node.node_id})\n该节点不再显示，也不会继续触发离线告警。`, this.panelKeyboard());
  }

  private async diagnosticsContext(): Promise<string> {
    const node = await this.selectedNode();
    if (!node) return "";
    return redact(`节点：${node.name} (${node.node_id})\n最后上报：${formatBeijingTime(node.last_seen)}\n状态：${node.snapshot_json}`);
  }

  private async queueImmediate(action: string, target: string, label: string): Promise<void> {
    const node = await this.selectedNode();
    if (!node) {
      await this.sendMessage("没有在线 VPS 节点，无法执行操作。");
      return;
    }
    await this.enqueueCommand(node.node_id, action, target);
    await this.sendMessage(`⏳ 已下发：${label}\n[${node.name}]\n等待 VPS 代理回报结果。`);
  }

  private async requestConfirmation(action: string, target: string, label: string): Promise<string> {
    if (!VALID_ACTIONS.has(action) || !VALID_TARGETS.has(target)) return "拒绝了不在白名单中的操作。";
    const node = await this.selectedNode();
    if (!node) {
      await this.sendMessage("没有在线 VPS 节点，无法执行操作。");
      return "没有可用节点。";
    }
    const token = crypto.randomUUID();
    await this.sql`
      INSERT INTO pending_confirmations (token, node_id, action, target, label, expires_at)
      VALUES (${token}, ${node.node_id}, ${action}, ${target}, ${label}, ${Date.now() + COMMAND_TTL_MS})
    `;
    await this.sendMessage(`⚠️ 请确认：${label}\n目标：${node.name}\n确认按钮 2 分钟内有效。`, {
      inline_keyboard: [[
        { text: `✅ 确认${label}`, callback_data: `confirm:${token}` },
        { text: "取消", callback_data: `cancel:${token}` },
      ]],
    });
    return "已发送二次确认按钮，等待用户确认。";
  }

  private async confirmAction(token: string): Promise<void> {
    const rows = await this.sql<PendingRow>`SELECT * FROM pending_confirmations WHERE token = ${token}`;
    const pending = rows[0];
    if (!pending || pending.expires_at < Date.now()) {
      await this.sql`DELETE FROM pending_confirmations WHERE token = ${token}`;
      await this.sendMessage("确认已失效，请重新发起操作。");
      return;
    }
    await this.sql`DELETE FROM pending_confirmations WHERE token = ${token}`;
    await this.enqueueCommand(pending.node_id, pending.action, pending.target);
    await this.sendMessage(`⏳ 已确认并下发：${pending.label}\n等待 VPS 代理回报结果。`);
  }

  private async cancelAction(token: string): Promise<void> {
    await this.sql`DELETE FROM pending_confirmations WHERE token = ${token}`;
    await this.sendMessage("✅ 操作已取消。");
  }

  private async enqueueCommand(nodeId: string, action: string, target: string): Promise<void> {
    if (!VALID_ACTIONS.has(action) || !VALID_TARGETS.has(target)) throw new Error("Command is not allowlisted");
    const id = crypto.randomUUID();
    const now = Date.now();
    await this.sql`
      INSERT INTO commands (command_id, node_id, action, target, status, created_at, expires_at, last_sent, attempts)
      VALUES (${id}, ${nodeId}, ${action}, ${target}, 'queued', ${now}, ${now + COMMAND_TTL_MS}, 0, 0)
    `;
  }

  private async balanceText(): Promise<string> {
    const response = await fetch("https://api.deepseek.com/user/balance", {
      headers: { Authorization: `Bearer ${this.env.DEEPSEEK_API_KEY}`, Accept: "application/json" },
    });
    if (!response.ok) return `DeepSeek 余额查询失败：HTTP ${response.status}`;
    const value = (await response.json()) as unknown;
    if (!isObject(value) || !Array.isArray(value.balance_infos)) return "DeepSeek 余额接口未返回余额明细。";
    const lines = [`💰 DeepSeek API 余额`, `状态：${value.is_available === true ? "可用" : "不可用"}`];
    for (const item of value.balance_infos) {
      if (!isObject(item)) continue;
      lines.push(`\n${asString(item.currency, 8)} 总余额：${asString(item.total_balance, 32)}`);
      lines.push(`充值余额：${asString(item.topped_up_balance, 32)}；赠送余额：${asString(item.granted_balance, 32)}`);
    }
    return lines.join("\n");
  }

  private currentModel(): string {
    const model = String(this.state.aiModel ?? "");
    return isDeepSeekModelId(model) ? model : DEFAULT_DEEPSEEK_MODEL;
  }

  private fallbackModel(): string {
    const model = String(this.state.aiFallbackModel ?? "");
    return isDeepSeekModelId(model) ? model : DEFAULT_DEEPSEEK_MODEL;
  }

  private async fetchModels(): Promise<string[]> {
    const response = await fetch("https://api.deepseek.com/models", {
      headers: { Authorization: `Bearer ${this.env.DEEPSEEK_API_KEY}`, Accept: "application/json" },
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const models = deepSeekModelIds(await response.json());
    if (models.length === 0) throw new Error("接口未返回可用模型");
    return models;
  }

  private async showModels(): Promise<void> {
    let models: string[];
    try {
      models = await this.fetchModels();
    } catch (error) {
      log("warn", "deepseek_models_failed", { error: String(error) });
      await this.sendMessage(`DeepSeek 模型列表读取失败：${redact(String(error))}\n当前仍使用：${this.currentModel()}`);
      return;
    }
    const now = Date.now();
    await this.sql`DELETE FROM model_choices WHERE expires_at < ${now}`;
    const keyboard: JsonObject[][] = [];
    for (const model of models.slice(0, 12)) {
      const token = crypto.randomUUID();
      await this.sql`
        INSERT INTO model_choices (token, model_id, expires_at)
        VALUES (${token}, ${model}, ${now + MODEL_CHOICE_TTL_MS})
      `;
      keyboard.push([{ text: `${model === this.currentModel() ? "✅ " : ""}${model}`, callback_data: `model_pick:${token}` }]);
    }
    await this.sendMessage(
      `🤖 DeepSeek 可用模型\n当前：${this.currentModel()}\n\n点击模型后还需要再次确认；刷新列表不产生对话 Token。`,
      { inline_keyboard: keyboard },
    );
  }

  private async requestModelSwitch(choiceToken: string): Promise<void> {
    const rows = await this.sql<ModelChoiceRow>`SELECT * FROM model_choices WHERE token = ${choiceToken}`;
    const choice = rows[0];
    await this.sql`DELETE FROM model_choices WHERE token = ${choiceToken}`;
    if (!choice || choice.expires_at < Date.now() || !isDeepSeekModelId(choice.model_id)) {
      await this.sendMessage("模型选择已失效，请发送 /models 重新读取。");
      return;
    }
    const previous = this.currentModel();
    if (choice.model_id === previous) {
      await this.sendMessage(`当前已经在使用 ${previous}，未做修改。`);
      return;
    }
    const token = crypto.randomUUID();
    await this.sql`
      INSERT INTO pending_model_switches (token, model_id, previous_model, expires_at)
      VALUES (${token}, ${choice.model_id}, ${previous}, ${Date.now() + COMMAND_TTL_MS})
    `;
    await this.sendMessage(`⚠️ 确认切换 DeepSeek 模型？\n${previous} → ${choice.model_id}\n确认按钮 2 分钟内有效。`, {
      inline_keyboard: [[
        { text: `✅ 确认切换`, callback_data: `model_confirm:${token}` },
        { text: "取消", callback_data: `model_cancel:${token}` },
      ]],
    });
  }

  private async confirmModelSwitch(token: string): Promise<void> {
    const rows = await this.sql<PendingModelSwitchRow>`SELECT * FROM pending_model_switches WHERE token = ${token}`;
    const pending = rows[0];
    await this.sql`DELETE FROM pending_model_switches WHERE token = ${token}`;
    if (!pending || pending.expires_at < Date.now() || !isDeepSeekModelId(pending.model_id)) {
      await this.sendMessage("模型切换确认已失效，请发送 /models 重新选择。");
      return;
    }
    try {
      const available = await this.fetchModels();
      if (!available.includes(pending.model_id)) {
        await this.sendMessage(`未切换：${pending.model_id} 已不在 DeepSeek 最新模型列表中。`);
        return;
      }
    } catch (error) {
      log("warn", "deepseek_model_recheck_failed", { error: String(error) });
      await this.sendMessage("未切换：确认时无法重新验证 DeepSeek 模型列表，请稍后重试。");
      return;
    }
    const previous = isDeepSeekModelId(pending.previous_model) ? pending.previous_model : this.currentModel();
    this.setState({ ...this.state, aiModel: pending.model_id, aiFallbackModel: previous });
    await this.sendMessage(`✅ DeepSeek 模型已切换为：${pending.model_id}\n若新模型调用不兼容，将自动退回：${previous}`);
  }

  private async cancelModelSwitch(token: string): Promise<void> {
    await this.sql`DELETE FROM pending_model_switches WHERE token = ${token}`;
    await this.sendMessage(`✅ 已取消模型切换，继续使用：${this.currentModel()}`);
  }

  private async aiChat(userText: string): Promise<void> {
    if (!userText) return;
    const historyRows = await this.sql<{ role: string; content: string }>`
      SELECT role, content FROM chat_history ORDER BY id DESC LIMIT 12
    `;
    const history: DeepSeekMessage[] = historyRows.reverse().flatMap((row) =>
      row.role === "user" || row.role === "assistant"
        ? [{ role: row.role, content: row.content } as DeepSeekMessage]
        : [],
    );
    const system: DeepSeekMessage = {
      role: "system",
      content:
        "你是用户私有 Telegram 中的中文智能助手和 VPS 管家。回答简洁准确。" +
        "涉及 VPS 事实时必须使用工具里的真实上报，不得编造。联网时可调用 web_search，并在答案中保留来源链接。" +
        "任何重启操作只申请二次确认，禁止直接执行。不得索要或输出密码、Token、API Key、SSH 私钥。",
    };
    const messages: DeepSeekMessage[] = [system, ...history, { role: "user", content: userText }];
    const first = await this.deepSeek(messages, this.tools());
    if (!first) {
      await this.sendMessage("AI 暂时不可用，请稍后再试。");
      return;
    }
    let final = first;
    if (first.tool_calls && first.tool_calls.length > 0) {
      const toolMessages: DeepSeekMessage[] = [];
      for (const call of first.tool_calls.slice(0, 4)) {
        const result = await this.runTool(call);
        toolMessages.push({ role: "tool", tool_call_id: call.id, content: result });
      }
      final = (await this.deepSeek([...messages, first, ...toolMessages], this.tools(), "none")) ?? first;
    }
    const answer = clampTelegram(final.content ?? "");
    if (!answer) {
      await this.sendMessage("AI 未返回可用内容，请换一种问法。");
      return;
    }
    if (this.state.aiMode) {
      await this.sql`INSERT INTO chat_history (role, content, created_at) VALUES ('user', ${userText.slice(0, 4000)}, ${Date.now()})`;
      await this.sql`INSERT INTO chat_history (role, content, created_at) VALUES ('assistant', ${answer}, ${Date.now()})`;
      await this.sql`DELETE FROM chat_history WHERE id NOT IN (SELECT id FROM chat_history ORDER BY id DESC LIMIT 20)`;
    }
    await this.sendMessage(answer);
  }

  private tools(): JsonObject[] {
    return [
      {
        type: "function",
        function: {
          name: "show_vps_status",
          description: "读取当前选中 VPS 的真实状态、资源、流量、服务、端口和最近诊断摘要",
          parameters: { type: "object", properties: {}, additionalProperties: false },
        },
      },
      {
        type: "function",
        function: {
          name: "list_vps_nodes",
          description: "列出 Cloudflare 管理的 VPS 节点及在线状态",
          parameters: { type: "object", properties: {}, additionalProperties: false },
        },
      },
      {
        type: "function",
        function: {
          name: "request_service_action",
          description: "申请重启节点服务、反向代理或整台 VPS。只发送二次确认按钮，不直接执行。",
          parameters: {
            type: "object",
            properties: { action: { type: "string", enum: ["restart_node", "restart_proxy", "reboot"] } },
            required: ["action"],
            additionalProperties: false,
          },
        },
      },
      {
        type: "function",
        function: {
          name: "web_search",
          description: "联网查询公开资料、近期信息或官方文档，返回摘要和来源链接",
          parameters: {
            type: "object",
            properties: { query: { type: "string", minLength: 2, maxLength: 200 } },
            required: ["query"],
            additionalProperties: false,
          },
        },
      },
    ];
  }

  private async runTool(call: DeepSeekToolCall): Promise<string> {
    const argsValue = safeJsonParse(call.function.arguments);
    const args = isObject(argsValue) ? argsValue : {};
    if (call.function.name === "show_vps_status") return await this.diagnosticsContext() || "没有 VPS 上报数据。";
    if (call.function.name === "list_vps_nodes") return await this.nodesText();
    if (call.function.name === "web_search") return await this.webSearch(asString(args.query, 200));
    if (call.function.name === "request_service_action") {
      const action = asString(args.action, 32);
      const map: Record<string, [string, string]> = {
        restart_node: ["node", "重启节点服务"],
        restart_proxy: ["reverse-proxy", "重启反向代理"],
        reboot: ["auto", "重启整台 VPS"],
      };
      const item = map[action];
      return item ? await this.requestConfirmation(action, item[0], item[1]) : "拒绝了无效操作。";
    }
    return "未知工具。";
  }

  private async webSearch(query: string): Promise<string> {
    if (!query) return "搜索词为空。";
    const url = new URL("https://api.duckduckgo.com/");
    url.search = new URLSearchParams({ q: query, format: "json", no_html: "1", no_redirect: "1" }).toString();
    const response = await fetch(url, { headers: { "User-Agent": "ejectors-telegram-vps-manager/1.0" } });
    if (!response.ok) return `联网搜索失败：HTTP ${response.status}`;
    const value = (await response.json()) as unknown;
    if (!isObject(value)) return "联网搜索没有返回有效结果。";
    const lines: string[] = [];
    const heading = asString(value.Heading, 200);
    const abstract = asString(value.AbstractText, 2000);
    const source = asString(value.AbstractURL, 1000);
    if (heading || abstract) lines.push(`${heading}\n${abstract}\n${source}`.trim());
    if (Array.isArray(value.RelatedTopics)) {
      for (const topic of value.RelatedTopics.slice(0, 5)) {
        if (!isObject(topic)) continue;
        const text = asString(topic.Text, 500);
        const link = asString(topic.FirstURL, 1000);
        if (text) lines.push(`${text}\n${link}`.trim());
      }
    }
    return lines.length > 0 ? lines.join("\n\n") : "未找到可靠的即时搜索结果；请缩小关键词或提供具体网址。";
  }

  private async deepSeekSimple(messages: Array<{ role: "system" | "user"; content: string }>): Promise<string> {
    const response = await this.deepSeek(messages, []);
    return clampTelegram(response?.content ?? "");
  }

  private async deepSeek(
    messages: DeepSeekMessage[] | Array<{ role: "system" | "user"; content: string }>,
    tools: JsonObject[],
    toolChoice: "auto" | "none" = "auto",
  ): Promise<DeepSeekMessage | null> {
    const selected = this.currentModel();
    const first = await this.callDeepSeek(selected, messages, tools, toolChoice);
    if (first.message) return first.message;

    const fallback = this.fallbackModel();
    if (fallback === selected || !MODEL_FALLBACK_STATUSES.has(first.status)) return null;
    const second = await this.callDeepSeek(fallback, messages, tools, toolChoice);
    if (!second.message) return null;

    this.setState({ ...this.state, aiModel: fallback, aiFallbackModel: DEFAULT_DEEPSEEK_MODEL });
    await this.sendMessage(`⚠️ 模型 ${selected} 调用失败，已自动退回 ${fallback}。`).catch((error: unknown) =>
      log("warn", "deepseek_fallback_notice_failed", { error: String(error) }),
    );
    return second.message;
  }

  private async callDeepSeek(
    model: string,
    messages: DeepSeekMessage[] | Array<{ role: "system" | "user"; content: string }>,
    tools: JsonObject[],
    toolChoice: "auto" | "none",
  ): Promise<DeepSeekCallResult> {
    const payload: JsonObject = {
      model,
      thinking: { type: "disabled" },
      messages,
      max_tokens: 1000,
    };
    if (tools.length > 0) {
      payload.tools = tools;
      payload.tool_choice = toolChoice;
    }
    let response: Response;
    try {
      response = await fetch("https://api.deepseek.com/chat/completions", {
        method: "POST",
        headers: { Authorization: `Bearer ${this.env.DEEPSEEK_API_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
    } catch (error) {
      log("warn", "deepseek_network_error", { model, error: String(error) });
      return { message: null, status: 0 };
    }
    if (!response.ok) {
      log("warn", "deepseek_http_error", { model, status: response.status });
      return { message: null, status: response.status };
    }
    const value = (await response.json()) as DeepSeekResponse;
    return { message: value.choices?.[0]?.message ?? null, status: response.status };
  }

  private panelKeyboard(): JsonObject {
    return PANEL_KEYBOARD;
  }

  private async nodesKeyboard(): Promise<JsonObject> {
    const rows = await this.sql<NodeRow>`SELECT * FROM nodes ORDER BY name ASC LIMIT 12`;
    const now = Date.now();
    await this.sql`DELETE FROM pending_confirmations WHERE expires_at < ${now}`;
    const keyboard: JsonObject[][] = [];
    for (const row of rows) {
      const offline = nodeIsOffline(row.last_seen, now);
      const buttons: JsonObject[] = [{
        text: `${offline ? "🔴" : "🟢"} ${row.name}`,
        callback_data: `use:${row.node_id}`,
      }];
      if (offline) {
        const token = await this.createNodeDeletionToken(row, now + MODEL_CHOICE_TTL_MS);
        buttons.push({ text: "🗑 删除", callback_data: `delete_ask:${token}` });
      }
      keyboard.push(buttons);
    }
    return { inline_keyboard: keyboard };
  }

  private async sendMessage(text: string, replyMarkup?: JsonObject | Promise<JsonObject>): Promise<void> {
    const payload: JsonObject = { chat_id: this.env.TELEGRAM_CHAT_ID, text: clampTelegram(text) };
    if (replyMarkup) payload.reply_markup = await replyMarkup;
    await telegramApi(this.env, "sendMessage", payload);
  }

  private async answerCallback(callbackId: string): Promise<void> {
    await telegramApi(this.env, "answerCallbackQuery", { callback_query_id: callbackId, text: "已收到" });
  }
}

async function readLimitedBody(request: Request): Promise<string> {
  const length = Number(request.headers.get("content-length") ?? "0");
  if (length > MAX_BODY_BYTES) throw new Error("Request body too large");
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_BODY_BYTES) throw new Error("Request body too large");
  return text;
}

async function manager(env: Env) {
  if (!env.TELEGRAM_CHAT_ID) throw new Error("TELEGRAM_CHAT_ID is not configured");
  return getAgentByName(env.TelegramVpsAgent, env.TELEGRAM_CHAT_ID);
}

async function handleAgentSync(request: Request, env: Env): Promise<Response> {
  const timestampText = request.headers.get("x-agent-timestamp") ?? "";
  const nodeHeader = request.headers.get("x-agent-id") ?? "";
  const signature = (request.headers.get("x-agent-signature") ?? "").toLowerCase();
  const timestamp = Number(timestampText);
  if (!env.VPS_AGENT_SECRET || env.VPS_AGENT_SECRET.length < 32) return Response.json({ error: "agent secret not configured" }, { status: 503 });
  if (!Number.isSafeInteger(timestamp) || Math.abs(Date.now() - timestamp) > 5 * 60_000) {
    return Response.json({ error: "invalid timestamp" }, { status: 401 });
  }
  const body = await readLimitedBody(request);
  const expected = await hmacHex(env.VPS_AGENT_SECRET, `${timestampText}.${body}`);
  if (!/^[0-9a-f]{64}$/.test(signature) || !timingSafeEqual(signature, expected)) {
    return Response.json({ error: "invalid signature" }, { status: 401 });
  }
  const payload = validateSyncPayload(safeJsonParse(body));
  if (!payload || !timingSafeEqual(payload.node_id, nodeHeader)) {
    return Response.json({ error: "invalid payload" }, { status: 400 });
  }
  const result = await (await manager(env)).syncNode(payload);
  return Response.json(result, { headers: { "Cache-Control": "no-store" } });
}

async function handleTelegramWebhook(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const secret = request.headers.get("x-telegram-bot-api-secret-token") ?? "";
  if (!env.TELEGRAM_WEBHOOK_SECRET || !timingSafeEqual(secret, env.TELEGRAM_WEBHOOK_SECRET)) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const body = await readLimitedBody(request);
  const update = safeJsonParse(body);
  if (!isObject(update) || !asInteger(update.update_id)) return Response.json({ error: "invalid update" }, { status: 400 });
  const agent = await manager(env);
  ctx.waitUntil(agent.processUpdate(update).catch((error: unknown) => log("error", "telegram_update_failed", { error: String(error) })));
  return Response.json({ ok: true });
}

function configured(env: Env): JsonObject {
  return {
    telegram_bot_token: Boolean(env.TELEGRAM_BOT_TOKEN),
    telegram_chat_id: Boolean(env.TELEGRAM_CHAT_ID),
    telegram_webhook_secret: Boolean(env.TELEGRAM_WEBHOOK_SECRET),
    deepseek_api_key: Boolean(env.DEEPSEEK_API_KEY),
    vps_agent_secret: Boolean(env.VPS_AGENT_SECRET && env.VPS_AGENT_SECRET.length >= 32),
  };
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const requestId = crypto.randomUUID();
    try {
      if (request.method === "GET" && url.pathname === "/health") {
        const configuration = configured(env);
        const ready = Object.values(configuration).every((value) => value === true);
        const nodes = ready ? await (await manager(env)).healthSummary() : { connected_nodes: 0, online_nodes: 0, newest_last_seen: 0 };
        return Response.json({ ok: true, service: "ejectors-telegram-vps-manager", configured: configuration, nodes }, {
          headers: { "Cache-Control": "no-store", "X-Request-Id": requestId },
        });
      }
      if (request.method === "POST" && url.pathname === "/telegram/webhook") {
        return await handleTelegramWebhook(request, env, ctx);
      }
      if (request.method === "POST" && url.pathname === "/api/agent/sync") {
        return await handleAgentSync(request, env);
      }
      return Response.json({ error: "not found" }, { status: 404 });
    } catch (error) {
      log("error", "request_failed", { requestId, path: url.pathname, error: String(error) });
      return Response.json({ error: "internal error", request_id: requestId }, { status: 500 });
    }
  },

  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    if (!env.TELEGRAM_CHAT_ID || !env.TELEGRAM_BOT_TOKEN) return;
    const agent = await manager(env);
    if (controller.cron === "0 20 * * SAT") {
      ctx.waitUntil(
        agent.runWeeklyCleanup(controller.scheduledTime).catch((error: unknown) =>
          log("error", "weekly_cleanup_failed", { error: String(error) }),
        ),
      );
      return;
    }
    if (controller.cron === "*/5 * * * *") {
      ctx.waitUntil(
        agent.runMonitorTick(controller.scheduledTime).catch((error: unknown) =>
          log("error", "monitor_tick_failed", { error: String(error) }),
        ),
      );
      return;
    }
    if (!env.DEEPSEEK_API_KEY) return;
    ctx.waitUntil(agent.runDailyBrief().catch((error: unknown) => log("error", "daily_brief_failed", { error: String(error) })));
  },
} satisfies ExportedHandler<Env>;
