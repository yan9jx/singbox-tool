#!/usr/bin/env bash
set -Eeuo pipefail

# Installs a local OpenClaw plugin that lets one claimed WeChat sender manage
# common model-provider API keys with /aikey commands. This is intentionally
# separate from the Tencent WeChat channel plugin and does not expose ports.

umask 077

on_error() {
  local exit_code=$?
  printf '\nInstallation stopped at line %s (exit code %s).\n' "${BASH_LINENO[0]}" "$exit_code" >&2
  printf 'No API key was printed by this installer.\n' >&2
  exit "$exit_code"
}
trap on_error ERR

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf 'Run this script as root.\n' >&2
  exit 1
fi

export HOME=/root
export PATH="/root/.local/bin:/root/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
hash -r

if ! command -v openclaw >/dev/null 2>&1; then
  printf 'OpenClaw is not installed. Install and verify the WeChat bot first.\n' >&2
  exit 1
fi

if ! systemctl is-active --quiet openclaw-gateway.service; then
  printf 'openclaw-gateway.service is not active. Repair the bot before installing this plugin.\n' >&2
  exit 1
fi

openclaw_bin="$(command -v openclaw)"
systemd_run_bin="$(command -v systemd-run)"
node_bin="$(command -v node || true)"
if [[ -z "$node_bin" ]]; then
  printf 'Node.js is required by OpenClaw but was not found in PATH.\n' >&2
  exit 1
fi
plugin_dir=/opt/openclaw-wechat-ai-provider-admin
state_dir=/root/.openclaw/wechat-ai-provider-admin
state_file="$state_dir/state.json"

mkdir -p "$plugin_dir" "$state_dir"
chmod 700 "$plugin_dir" "$state_dir"

new_claim_code=""
if [[ ! -f "$state_file" ]]; then
  if ! command -v openssl >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y openssl
  fi
  new_claim_code="$(openssl rand -hex 16)"
  claim_hash="$(printf '%s' "$new_claim_code" | sha256sum | awk '{print $1}')"
  cat > "$state_file" <<EOF
{"version":1,"bootstrapCodeHash":"$claim_hash","adminSenderId":"","providers":{},"openclawBin":"$openclaw_bin","systemdRunBin":"$systemd_run_bin"}
EOF
  unset claim_hash
  chmod 600 "$state_file"
fi

cat > "$plugin_dir/package.json" <<'EOF'
{
  "name": "openclaw-wechat-ai-provider-admin",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "peerDependencies": {
    "openclaw": ">=2026.7.1"
  },
  "openclaw": {
    "extensions": ["./index.js"],
    "compat": {
      "pluginApi": ">=2026.7.1",
      "minGatewayVersion": ">=2026.7.1"
    }
  }
}
EOF

cat > "$plugin_dir/openclaw.plugin.json" <<'EOF'
{
  "id": "wechat-ai-provider-admin",
  "name": "WeChat AI Provider Admin",
  "description": "Owner-claimed WeChat commands for local model-provider management.",
  "entry": "./index.js",
  "activation": {
    "onStartup": true
  },
  "configSchema": {
    "type": "object",
    "additionalProperties": false
  },
  "commandAliases": [
    {
      "name": "aikey",
      "kind": "runtime-slash",
      "cliCommand": "models"
    }
  ]
}
EOF

cat > "$plugin_dir/index.js" <<'EOF'
import crypto from "node:crypto";
import fs from "node:fs";
import { execFileSync, spawn } from "node:child_process";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const STATE_FILE = "/root/.openclaw/wechat-ai-provider-admin/state.json";
const MAX_KEY_LENGTH = 512;
const MAX_MODEL_LENGTH = 160;
const RESET_PENDING = new Set();

const PLATFORMS = {
  deepseek: {
    label: "DeepSeek",
    baseUrl: "https://api.deepseek.com/v1",
    api: "openai-completions",
  },
  siliconflow: {
    label: "SiliconFlow",
    baseUrl: "https://api.siliconflow.cn/v1",
    api: "openai-completions",
    note: "模型名请从硅基流动模型广场复制完整 ID。",
  },
  doubao: {
    label: "Doubao Ark",
    baseUrl: "https://ark.cn-beijing.volces.com/api/v3",
    api: "openai-completions",
    note: "模型名填写火山方舟推理接入点 ID。",
  },
  kimi: {
    label: "Kimi Moonshot",
    baseUrl: "https://api.moonshot.cn/v1",
    api: "openai-completions",
  },
  openai: {
    label: "OpenAI",
    baseUrl: "https://api.openai.com/v1",
    api: "openai-completions",
  },
  gemini: {
    label: "Google Gemini",
    baseUrl: "https://generativelanguage.googleapis.com/v1beta/openai",
    api: "openai-completions",
  },
  claude: {
    label: "Anthropic Claude",
    baseUrl: "https://api.anthropic.com/v1",
    api: "anthropic-messages",
  },
  grok: {
    label: "xAI Grok",
    baseUrl: "https://api.x.ai/v1",
    api: "openai-completions",
  },
  openrouter: {
    label: "OpenRouter",
    baseUrl: "https://openrouter.ai/api/v1",
    api: "openai-completions",
  },
  qwen: {
    label: "Qwen DashScope",
    baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
    api: "openai-completions",
    note: "模型名填写通义千问模型 ID，例如 qwen-plus。",
  },
  zhipu: {
    label: "Zhipu AI",
    baseUrl: "https://open.bigmodel.cn/api/paas/v4",
    api: "openai-completions",
    note: "模型名填写智谱模型 ID，例如 glm-4-plus。",
  },
};

function loadState() {
  const state = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
  if (!state || state.version !== 1 || typeof state.bootstrapCodeHash !== "string") {
    throw new Error("invalid state");
  }
  state.providers ??= {};
  state.pendingDelete ??= null;
  state.pendingHighRisk ??= null;
  return state;
}

function saveState(state) {
  const temporary = `${STATE_FILE}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(state)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, STATE_FILE);
}

function text(value) {
  return { text: value };
}

function safeEqualHex(expected, actual) {
  if (!/^[a-f0-9]{64}$/i.test(expected)) return false;
  const left = Buffer.from(expected, "hex");
  const right = crypto.createHash("sha256").update(actual, "utf8").digest();
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function isOwner(ctx, state) {
  return Boolean(ctx.senderId) && state.adminSenderId === ctx.senderId;
}

function requireOwner(ctx, state) {
  if (!isOwner(ctx, state)) {
    return text("此命令仅限已认领的管理员微信使用。先在自己的私聊发送 /aikey whoami，再用终端显示的一次性认领码发送 /aikey claim 认领码。");
  }
  return null;
}

function providerId(platform) {
  return `wechat-${platform}`;
}

function checkModelAndKey(apiKey, model) {
  if (!apiKey || apiKey.length > MAX_KEY_LENGTH || /\s/.test(apiKey)) {
    throw new Error("invalid API key");
  }
  if (!model || model.length > MAX_MODEL_LENGTH || /\s/.test(model)) {
    throw new Error("invalid model");
  }
}

const NATURAL_PLATFORM_ALIASES = [
  ["深度求索", "deepseek"],
  ["硅基流动", "siliconflow"],
  ["siliconflow", "siliconflow"],
  ["open router", "openrouter"],
  ["openrouter", "openrouter"],
  ["通义千问", "qwen"],
  ["dashscope", "qwen"],
  ["智谱", "zhipu"],
  ["bigmodel", "zhipu"],
  ["open ai", "openai"],
  ["openai", "openai"],
  ["anthropic", "claude"],
  ["claude", "claude"],
  ["deepseek", "deepseek"],
  ["豆包", "doubao"],
  ["火山方舟", "doubao"],
  ["doubao", "doubao"],
  ["月之暗面", "kimi"],
  ["kimi", "kimi"],
  ["gemini", "gemini"],
  ["谷歌", "gemini"],
  ["google", "gemini"],
  ["grok", "grok"],
  ["qwen", "qwen"],
  ["zhipu", "zhipu"],
];

function normalizeNaturalText(value) {
  return String(value ?? "").replace(/\u3000/g, " ").replace(/：/g, ":");
}

function naturalPlatform(source) {
  const lower = source.toLowerCase();
  return NATURAL_PLATFORM_ALIASES.find(([alias]) => lower.includes(alias))?.[1];
}

function parseNaturalRequest(body) {
  const source = normalizeNaturalText(body);
  const platform = naturalPlatform(source);
  if (!platform) return null;

  const apiKey = source.match(/(?:api\s*key|api|key|密钥)\s*:\s*([^\s，,；;。！？!]+)/i)?.[1];
  const model = source.match(/(?:模型|model)\s*:\s*([^\s，,；;。！？!]+)/i)?.[1];
  if (/(?:确认\s*(?:删除|移除|清除)|(?:删除|移除|清除)\s*确认)/.test(source)) {
    return { kind: "delete-confirm", platform };
  }
  if (/(?:删除|移除|清除)/.test(source) && /(?:api|key|密钥|配置)/i.test(source)) {
    return { kind: "delete-request", platform };
  }
  if (apiKey && /(?:添加|新增|配置|加入)/.test(source)) {
    return { kind: "add", platform, apiKey, model };
  }
  if (model && /(?:切换|换成|改用|设为|设置为)/.test(source)) {
    return { kind: "use", platform, model };
  }
  return null;
}

function parseNaturalModelAddition(body) {
  const source = normalizeNaturalText(body);
  const platform = naturalPlatform(source);
  const model =
    source.match(/^新增\s*模型\s+[^\s，,；;。！？!]+\s+([^\s，,；;。！？!]+)/i)?.[1]
    ?? source.match(/(?:添加|新增|加入)\s*模型\s+([^\s，,；;。！？!]+)/i)?.[1]
    ?? source.match(/(?:模型|model)\s*:\s*([^\s，,；;。！？!]+)/i)?.[1];
  const hasApiKey = /(?:api\s*key|api|key|密钥)\s*:/i.test(source);
  if (!platform || !model || hasApiKey) return null;
  if (!/(?:添加|新增|加入)/.test(source) || !/(?:模型|model)/i.test(source)) return null;
  return { platform, model };
}

function runOpenClaw(state, args) {
  return execFileSync(state.openclawBin, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 30_000,
    env: { ...process.env, HOME: "/root" },
  });
}

function modelCatalogMetadata(state, platform, modelNames) {
  const raw = readFixedOutput(state.openclawBin, ["models", "list", "--all", "--json"], 30_000);
  if (!raw) return new Map();
  try {
    const parsed = JSON.parse(raw);
    const rows = Array.isArray(parsed) ? parsed : (Array.isArray(parsed?.models) ? parsed.models : parsed?.items);
    if (!Array.isArray(rows)) return new Map();
    const wanted = new Set(modelNames);
    const result = new Map();
    for (const row of rows) {
      const key = String(row?.key ?? "");
      const prefix = `${platform}/`;
      if (!key.startsWith(prefix)) continue;
      const modelId = key.slice(prefix.length);
      if (!wanted.has(modelId)) continue;
      const contextWindow = Number(row.contextWindow);
      const maxTokens = Number(row.maxTokens ?? row.maxOutputTokens ?? row.maxOutput);
      result.set(modelId, {
        contextWindow: Number.isFinite(contextWindow) && contextWindow > 0 ? contextWindow : null,
        maxTokens: Number.isFinite(maxTokens) && maxTokens > 0 ? maxTokens : null,
      });
    }
    return result;
  } catch {
    return new Map();
  }
}

function providerModelEntries(definition, modelNames, metadata) {
  return modelNames.map((modelId) => {
    const known = metadata.get(modelId);
    const entry = {
      id: modelId,
      name: `${definition.label} ${modelId}`,
      input: ["text"],
    };
    if (known?.contextWindow) {
      entry.contextWindow = known.contextWindow;
      entry.contextTokens = known.contextWindow;
    }
    if (known?.maxTokens) entry.maxTokens = known.maxTokens;
    return entry;
  });
}

async function fetchAvailableProviderModels(state, platform) {
  const managed = state.providers[platform];
  if (!managed) throw new Error("provider not managed");
  const config = JSON.parse(fs.readFileSync("/root/.openclaw/openclaw.json", "utf8"));
  const provider = config.models?.providers?.[providerId(platform)];
  if (!provider || provider.api !== "openai-completions" || typeof provider.apiKey !== "string" || !provider.apiKey) {
    throw new Error("unsupported provider discovery");
  }
  const baseUrl = String(provider.baseUrl ?? "");
  if (!baseUrl.startsWith("https://")) throw new Error("invalid provider base URL");
  const endpoint = new URL("models", baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);
  try {
    const response = await fetch(endpoint, {
      headers: { Authorization: `Bearer ${provider.apiKey}`, Accept: "application/json" },
      signal: controller.signal,
    });
    if (!response.ok) throw new Error("model list request failed");
    const payload = await response.json();
    const ids = Array.isArray(payload?.data)
      ? payload.data.map((item) => String(item?.id ?? "").trim()).filter((id) => id && !/\s/.test(id))
      : [];
    if (ids.length === 0) throw new Error("empty model list");
    return [...new Set(ids)].sort();
  } finally {
    clearTimeout(timeout);
  }
}

async function availableModelsReply(state, platform) {
  const available = await fetchAvailableProviderModels(state, platform);
  const configured = new Set(state.providers[platform].models);
  const newModels = available.filter((model) => !configured.has(model));
  if (newModels.length === 0) return `${platform} 已配置了当前接口返回的全部 ${available.length} 个模型。`;
  const shown = newModels.slice(0, 30);
  const suffix = newModels.length > shown.length ? `\n其余 ${newModels.length - shown.length} 个暂未列出。` : "";
  return `${platform} 当前可用 ${available.length} 个模型；其中 ${newModels.length} 个尚未添加：\n${shown.map((model) => `- ${model}`).join("\n")}${suffix}\n\n要添加其中一个，直接发送“给 ${platform} 添加模型：模型名”。`;
}

function naturalProviderModelDiscovery(body, state) {
  const source = normalizeNaturalText(body).trim();
  const platform = naturalPlatform(source);
  if (platform && /(?:获取|查看|检查).*(?:新模型|可用模型|模型列表)/.test(source)) return platform;
  if (!/^(?:获取|查看|检查)(?:新模型|可用模型|模型列表)$/.test(source)) return null;
  const configured = Object.keys(state.providers);
  return configured.length === 1 ? configured[0] : null;
}

// These status readers deliberately use a small fixed allow-list. They are
// not a shell and never accept a command, path, API key, or argument supplied
// by a WeChat message.
function readFixedOutput(bin, args, timeout = 10_000) {
  try {
    return execFileSync(bin, args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout,
      env: { ...process.env, HOME: "/root" },
    }).trim();
  } catch {
    return null;
  }
}

function readCompactionStatus() {
  try {
    const config = JSON.parse(fs.readFileSync("/root/.openclaw/openclaw.json", "utf8"));
    const value = config.agents?.defaults?.compaction;
    if (!value || typeof value !== "object") return "上下文压缩：当前未读取到可展示的参数。";
    const shown = [];
    const labels = [
      ["mode", "模式"],
      ["reserveTokens", "预留令牌"],
      ["reserveTokensFloor", "最低预留令牌"],
      ["keepRecentTokens", "保留最近令牌"],
      ["recentTurnsPreserve", "保留最近轮数"],
      ["maxHistoryShare", "最大历史占比"],
    ];
    for (const [key, label] of labels) {
      if (value[key] !== undefined) {
        const output = key === "maxHistoryShare" && typeof value[key] === "number"
          ? `${Math.round(value[key] * 100)}%`
          : String(value[key]);
        shown.push(`${label}：${output}`);
      }
    }
    const qualityGuard = value.qualityGuard?.enabled;
    const precheck = value.midTurnPrecheck?.enabled;
    if (typeof qualityGuard === "boolean") shown.push(`质量保护：${qualityGuard ? "开启" : "关闭"}`);
    if (typeof precheck === "boolean") shown.push(`预检查：${precheck ? "开启" : "关闭"}`);
    return shown.length ? `上下文压缩：${shown.join("；")}。` : "上下文压缩：当前未读取到可展示的参数。";
  } catch {
    return "上下文压缩：暂时无法读取配置。";
  }
}

function readMemoryStatus(state) {
  const output = readFixedOutput(state.openclawBin, ["memory", "status", "--deep", "--agent", "main"], 20_000);
  if (!output) return "长期记忆：暂时无法读取状态。";
  const indexed = output.match(/Indexed:\s*(\d+\/\d+\s+files\s*[·.]\s*\d+\s+chunks)/i)?.[1];
  const ready = [];
  if (/Embeddings:\s*ready/i.test(output)) ready.push("向量嵌入已就绪");
  if (/Vector store:\s*ready/i.test(output)) ready.push("向量库已就绪");
  if (/FTS:\s*ready/i.test(output)) ready.push("关键词检索已就绪");
  const details = [];
  if (indexed) details.push(`已索引 ${indexed.replace(/files/i, "个文件").replace(/chunks/i, "个片段")}`);
  if (ready.length) details.push(ready.join("、"));
  return details.length ? `长期记忆：${details.join("；")}。` : "长期记忆：已执行查询，但没有读取到完整就绪信息。";
}

function readSystemStatus() {
  try {
    const memory = fs.readFileSync("/proc/meminfo", "utf8");
    const value = (name) => Number(memory.match(new RegExp(`^${name}:\\s+(\\d+)`, "m"))?.[1] ?? 0);
    const mib = (kib) => Math.round(kib / 1024);
    const memTotal = mib(value("MemTotal"));
    const memAvailable = mib(value("MemAvailable"));
    const swapTotal = mib(value("SwapTotal"));
    const swapFree = mib(value("SwapFree"));
    if (!memTotal) return "内存与交换分区：暂时无法读取状态。";
    return `内存与交换分区：内存总计 ${memTotal} MiB、可用 ${memAvailable} MiB；交换分区总计 ${swapTotal} MiB、可用 ${swapFree} MiB。`;
  } catch {
    return "内存与交换分区：暂时无法读取状态。";
  }
}

function readSearxStatus() {
  const dockerBin = fs.existsSync("/usr/bin/docker") ? "/usr/bin/docker" : "/usr/local/bin/docker";
  const output = readFixedOutput(dockerBin, ["ps", "--filter", "name=openclaw-searxng", "--format", "{{.Status}}|{{.Ports}}"]);
  if (!output) return "SearXNG：未读取到运行中的本地容器。";
  const [status, ports] = output.split("|", 2);
  if (!/^Up\b/i.test(status ?? "")) return "SearXNG：容器当前未运行。";
  const localOnly = /127\.0\.0\.1:8888/i.test(ports ?? "");
  return `SearXNG：运行中${localOnly ? "，仅监听本机 127.0.0.1:8888" : "，端口状态已读取"}。`;
}

function readGatewayStatus(state) {
  const service = readFixedOutput("/bin/systemctl", ["is-active", "openclaw-gateway.service"]);
  const channels = readFixedOutput(state.openclawBin, ["channels", "status", "--probe"], 20_000);
  const active = service === "active" ? "网关运行中" : "网关未处于运行状态";
  const wechat = /openclaw-weixin[\s\S]{0,300}\brunning\b/i.test(channels ?? "") || /\brunning\b[\s\S]{0,300}openclaw-weixin/i.test(channels ?? "")
    ? "微信通道运行中"
    : "微信通道状态暂时无法确认";
  return `微信机器人：${active}；${wechat}。`;
}

function readBackupStatus() {
  const backupDir = "/root/.openclaw/backups/automatic";
  const successMark = "/var/lib/openclaw-ops/onedrive-backup.last-success";
  try {
    const archives = fs.readdirSync(backupDir)
      .filter((name) => /^openclaw-auto-.*\.tgz$/.test(name))
      .map((name) => ({ name, stat: fs.statSync(path.join(backupDir, name)) }))
      .sort((left, right) => right.stat.mtimeMs - left.stat.mtimeMs);
    const latest = archives[0];
    const local = latest
      ? `本机备份正常，最近一次为 ${new Date(latest.stat.mtimeMs).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai", hour12: false })}`
      : "未找到本机自动备份";
    const rcloneBin = fs.existsSync("/usr/bin/rclone") ? "/usr/bin/rclone" : "/usr/local/bin/rclone";
    const cloudProbe = fs.existsSync(rcloneBin) ? readFixedOutput(rcloneBin, ["lsf", "onedrive-crypt:"], 15_000) : null;
    const cloudAccess = cloudProbe === null ? "OneDrive 当前无法访问" : "OneDrive 可访问";
    const cloudSuccess = fs.existsSync(successMark)
      ? `最近同步成功为 ${new Date(fs.statSync(successMark).mtimeMs).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai", hour12: false })}`
      : "尚未找到 OneDrive 成功记录";
    return `备份状态：${local}；${cloudAccess}；${cloudSuccess}。`;
  } catch {
    return "备份状态暂时无法读取，请稍后再试。";
  }
}

function jobNextRunAtMs(job) {
  const fromState = Number(job?.state?.nextRunAtMs);
  if (Number.isFinite(fromState) && fromState > 0) return fromState;
  const fromSchedule = Date.parse(String(job?.schedule?.at ?? ""));
  return Number.isFinite(fromSchedule) ? fromSchedule : null;
}

const INTERNAL_REMINDER_NAMES = new Set(["系统监控通知", "备份失败通知", "每月备份演练结果"]);

function allPendingWeChatReminders(state) {
  const raw = readFixedOutput(state.openclawBin, ["cron", "list", "--all", "--json"], 20_000);
  if (raw === null) throw new Error("cron list unavailable");
  const parsed = JSON.parse(raw);
  const jobs = Array.isArray(parsed) ? parsed : (Array.isArray(parsed?.jobs) ? parsed.jobs : []);
  return jobs
    .filter((job) => job?.enabled !== false)
    .filter((job) => job?.schedule?.kind === "at")
    .filter((job) => job?.payload?.kind === "agentTurn")
    .filter((job) => job?.delivery?.mode === "announce" && job?.delivery?.channel === "openclaw-weixin")
    .filter((job) => !INTERNAL_REMINDER_NAMES.has(String(job?.name ?? "").trim()))
    .map((job) => ({ ...job, nextRunAtMs: jobNextRunAtMs(job) }))
    .filter((job) => Number.isFinite(job.nextRunAtMs) && job.nextRunAtMs > Date.now())
    .sort((left, right) => left.nextRunAtMs - right.nextRunAtMs);
}

function reminderDisplayName(job) {
  const name = String(job?.name ?? "提醒").trim().replace(/\s+/g, " ");
  return name.length > 50 ? `${name.slice(0, 50)}…` : name;
}

function reminderTime(job) {
  return new Date(job.nextRunAtMs).toLocaleString("zh-CN", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

function allRemindersReply(state) {
  try {
    const jobs = allPendingWeChatReminders(state);
    if (jobs.length === 0) return "目前没有尚未执行的提醒。";
    const lines = jobs.map((job, index) => `${index + 1}. ${reminderTime(job)}：${reminderDisplayName(job)}`);
    return `所有尚未执行的提醒共 ${jobs.length} 条：\n${lines.join("\n")}\n\n要取消其中一条，直接发送“取消提醒 2”；要全部取消，发送“取消所有提醒”。`;
  } catch {
    return "暂时无法读取所有提醒，请稍后再试。";
  }
}

function reminderIndexFromText(input) {
  const match = normalizeNaturalText(input).match(/^取消(?:第)?(\d+)(?:条)?提醒$/);
  if (!match) return null;
  const index = Number(match[1]);
  return Number.isSafeInteger(index) && index > 0 ? index : null;
}

function cancelReminderByIndexReply(state, index) {
  try {
    const job = allPendingWeChatReminders(state)[index - 1];
    if (!job) return `没有找到第 ${index} 条提醒。先发送“查看所有提醒”确认一下清单。`;
    const jobId = String(job?.jobId ?? job?.id ?? "");
    if (!jobId) throw new Error("missing job id");
    runOpenClaw(state, ["cron", "rm", jobId]);
    return `已取消第 ${index} 条提醒：${reminderTime(job)} 的“${reminderDisplayName(job)}”。`;
  } catch {
    return "取消这条提醒时没有完成。现有提醒已保留，请稍后再试。";
  }
}

function cancelAllRemindersReply(state) {
  try {
    const jobs = allPendingWeChatReminders(state);
    if (jobs.length === 0) return "目前没有尚未执行的提醒，所以没有删除任何内容。";
    let removed = 0;
    for (const job of jobs) {
      const jobId = String(job?.jobId ?? job?.id ?? "");
      if (!jobId) continue;
      runOpenClaw(state, ["cron", "rm", jobId]);
      removed += 1;
    }
    return `已取消所有尚未执行的提醒，共 ${removed} 条。已经送达的提醒和系统任务都没有动。`;
  } catch {
    return "取消所有提醒时没有完成。现有提醒已保留，请稍后再试。";
  }
}

function readDiskDetails() {
  try {
    const df = readFixedOutput("/bin/df", ["-P", "/"]);
    const line = df?.split("\n").find((entry) => /\s\/\s*$/.test(entry));
    const columns = line?.trim().split(/\s+/) ?? [];
    const disk = columns.length >= 5 ? `磁盘已用 ${columns[4]}，可用 ${columns[3]}` : "磁盘总览暂时无法读取";
    const directories = [
      ["系统目录", "/usr"],
      ["服务数据", "/var"],
      ["管理员文件", "/root"],
      ["应用目录", "/opt"],
      ["临时文件", "/tmp"],
      ["用户目录", "/home"],
    ];
    const details = directories.map(([label, directory]) => {
      const output = readFixedOutput("/usr/bin/du", ["-sx", "-B1M", directory]);
      const size = Number(output?.match(/^(\d+)/)?.[1] ?? 0);
      return { label, size };
    }).filter((item) => item.size > 0).sort((left, right) => right.size - left.size).slice(0, 4);
    const largest = details.length ? details.map((item) => `${item.label}约 ${item.size}MB`).join("、") : "暂未读取到目录占用";
    return `磁盘明细：${disk}；主要占用为 ${largest}。`;
  } catch {
    return "磁盘明细暂时无法读取，请稍后再试。";
  }
}

function startKnownSystemService(service) {
  const child = spawn("/bin/systemctl", ["start", "--no-block", service], {
    detached: true,
    stdio: "ignore",
  });
  child.unref();
}

function normalizeStatusTopic(value) {
  const source = normalizeNaturalText(value).toLowerCase();
  if (/压缩|compaction|上下文/.test(source)) return "compaction";
  if (/记忆|memory|索引/.test(source)) return "memory";
  if (/searxng|搜索/.test(source)) return "searxng";
  if (/内存|swap|交换/.test(source)) return "system";
  if (/微信|网关|gateway/.test(source)) return "gateway";
  return "all";
}

function statusReply(state, topic) {
  const readers = {
    compaction: () => readCompactionStatus(),
    memory: () => readMemoryStatus(state),
    system: () => readSystemStatus(),
    searxng: () => readSearxStatus(),
    gateway: () => readGatewayStatus(state),
  };
  if (topic !== "all" && readers[topic]) return readers[topic]();
  return [readers.gateway(), readers.system(), readers.searxng(), readers.memory(), readers.compaction()].join("\n");
}

function parseNaturalStatusRequest(body) {
  const source = normalizeNaturalText(body).toLowerCase();
  const asks = /(?:查|查询|查看|看看|状态|多少|阈值|还剩|剩余)/.test(source);
  if (!asks) return null;
  if (/(?:上下文.*(?:压缩|compaction)|(?:压缩|compaction).*(?:阈值|参数|多少|状态))/.test(source)) return "compaction";
  if (/(?:长期记忆|记忆索引|memory).*(?:状态|索引|多少|查|查询|查看)/.test(source)) return "memory";
  if (/(?:searxng|搜索服务).*(?:状态|查|查询|查看)/.test(source)) return "searxng";
  if (/(?:内存|swap|交换分区).*(?:状态|查|查询|查看|多少|剩余)/.test(source)) return "system";
  if (/(?:微信机器人|微信通道|网关).*(?:状态|查|查询|查看)/.test(source)) return "gateway";
  if (/^(?:查|查询|查看|看看)\s*(?:全部|所有)?状态/.test(source)) return "all";
  return null;
}

function normalizedConfirmation(value) {
  return normalizeNaturalText(value).replace(/[。！!，,、\s]/g, "").toLowerCase();
}

function isHighRiskConfirmation(value) {
  return /^(?:确认执行|确认|继续执行|同意执行|我确认)$/.test(normalizedConfirmation(value));
}

function parseHighRiskConfirmation(value) {
  const source = normalizeNaturalText(value).trim();
  const match = source.match(/^(?:确认执行|继续执行|同意执行|确认)\s*(?:[:：]\s*|\s*)(.+)$/i);
  return match?.[1]?.trim() || null;
}

function confirmationOperationText(value) {
  return normalizeNaturalText(value)
    .trim()
    .replace(/^(?:我要|我想|我需要|帮我|请(?:你)?|麻烦(?:你)?|能否(?:帮我)?|可以(?:帮我)?|现在(?:帮我)?)/, "")
    .trim();
}

function confirmationActor(ctx) {
  if (typeof ctx.senderId === "string" && ctx.senderId.length > 0 && ctx.senderId.length <= 512) {
    return `sender:${ctx.senderId}`;
  }
  // The Tencent WeChat hook does not always expose senderId at this stage.
  // A session key is still scoped to the same conversation, so it safely
  // binds the two natural-language confirmation messages together.
  if (typeof ctx.sessionKey === "string" && ctx.sessionKey.startsWith("agent:") && ctx.sessionKey.length <= 512) {
    return `session:${ctx.sessionKey}`;
  }
  return null;
}

function needsHighRiskConfirmation(value) {
  const source = normalizeNaturalText(value).toLowerCase();
  if (!source || source.startsWith("/aikey")) return false;
  return /(?:删除|移除|清空|清除|格式化|重置|恢复出厂|关机|重启|停止|卸载|安装|升级|覆盖|替换|开放端口|防火墙|权限|密码|密钥|令牌|api\s*key|(?:添加|新增|创建|修改|更改)\s*(?:系统)?用户|\b(?:useradd|usermod|userdel|passwd)\b|\brm\b|\bchmod\b|\bchown\b|\bcurl\b|\bwget\b|\bapt(?:-get)?\b|\bsystemctl\b|\bdocker\b|\biptables\b|\bufw\b|\bnft\b|\bcrontab\b|openclaw\s+(?:config|approvals|exec-policy)|tools\.exec)/i.test(source);
}

function isCronRunContext(ctx) {
  return ctx?.trigger === "cron" || (typeof ctx?.sessionKey === "string" && ctx.sessionKey.includes(":cron:"));
}

const ALLOWED_ENGLISH_TERMS = /\b(?:OpenClaw|SearXNG|Docker|Gateway|API|Key|DeepSeek|SiliconFlow|BAAI|bge|SQLite|FTS|RAM|Swap|VPS|GitHub|WeChat|Linux|Ubuntu|Windows|SSH|JSON|YAML|SQL|HTTP|HTTPS|URL|IP|TCP|UDP|DNS|TLS|cron|announce|delivery|none|sessions_send|exec|root|systemctl|node|npm|bash|PowerShell|Python|Nginx|Caddy|Cloudflare|DeepSeek|OpenAI|Claude|Gemini|Qwen|Kimi|Grok|Zhipu|Doubao)\b/gi;

function hasUntranslatedEnglishProse(value) {
  const prose = String(value ?? "")
    .replace(/```[\s\S]*?```/g, "")
    .replace(/`[^`]*`/g, "")
    .replace(/https?:\/\/\S+/g, "")
    .replace(ALLOWED_ENGLISH_TERMS, "");
  return (prose.match(/\b[A-Za-z]{3,}\b/g) ?? []).length >= 2;
}

function cronFailureNotice(value) {
  const source = String(value ?? "");
  // Cron failures may be generated by the Gateway itself, with no ordinary
  // WeChat or cron context attached to the outgoing delivery. Match the raw
  // envelopes before the context gate below, and never echo a job name or a
  // provider error because either can contain user-supplied English text.
  if (/\bcron\s+job\b/i.test(source)) {
    if (/model\s+(?:did not produce a response|idle timeout)|request timed out before a response|\btimeout\b/i.test(source)) {
      return "⚠️ 有一条定时任务本次因 AI 响应超时未完成。系统和其他功能仍可用，下一次计划会继续执行；如果连续出现，我会再检查模型服务。";
    }
    return "⚠️ 有一条定时任务本次未完成。系统和其他功能仍可用，下一次计划会继续执行；如果连续出现，我会再检查。";
  }
  if (/model\s+(?:did not produce a response|idle timeout)|request timed out before a response/i.test(source)) {
    return "⚠️ AI 服务本次响应超时，任务没有完成。其他功能仍可用，请稍后再试；如果连续出现，我会再检查模型服务。";
  }
  return null;
}

function isWeChatReminderJob(event) {
  const targets = [event?.sessionKey, event?.job?.sessionTarget]
    .filter((value) => typeof value === "string")
    .join(" ");
  return targets.includes(":openclaw-weixin:");
}

async function enforceWeChatReminderDelivery(event, gatewayCtx) {
  // Natural-language reminders made from this private WeChat conversation must
  // always reach the same chat. This closes the gap where a model creates a
  // cron job but omits `delivery: announce` (or mistakenly uses `none`).
  if (event?.action !== "added" || !event?.jobId || !isWeChatReminderJob(event)) return;
  const rawDelivery = event.job?.delivery;
  const delivery = rawDelivery && typeof rawDelivery === "object" ? rawDelivery : {};
  if (delivery.mode === "announce") return;
  const cron = gatewayCtx?.getCron?.();
  if (!cron) return;
  try {
    await cron.update(event.jobId, {
      delivery: {
        ...delivery,
        mode: "announce",
        channel: delivery.channel || "last",
      },
    });
  } catch {
    // Do not break a newly-created reminder if a future Gateway revision
    // changes its cron patch schema. The prompt guidance remains as fallback.
  }
}

function requestHighRiskConfirmation(ctx, state, request) {
  const actor = confirmationActor(ctx);
  if (!actor) return text("无法识别当前会话，不能执行重要操作。");
  const originalRequest = typeof request === "string" ? request.trim() : "";
  if (!originalRequest || originalRequest.length > 4000) {
    return text("无法保存这条重要操作的原始请求。请把操作说明控制在 4000 个字符以内后重新发送。");
  }
  state.pendingHighRisk = {
    actor,
    request: originalRequest,
    expiresAt: Date.now() + 5 * 60_000,
  };
  saveState(state);
  return text(`这是重要操作，暂未执行。若要执行，请直接发送一条完整指令：“确认${confirmationOperationText(originalRequest)}”。普通查询无需确认。`);
}

function scheduleRestart(state) {
  const unit = `openclaw-ai-provider-admin-${Date.now()}`;
  const child = spawn(
    state.systemdRunBin,
    ["--quiet", `--unit=${unit}`, "--on-active=2s", "--collect", "/bin/systemctl", "restart", "openclaw-gateway.service"],
    { detached: true, stdio: "ignore" },
  );
  child.unref();
}

function scheduleSessionReset(state, sessionKey) {
  if (typeof sessionKey !== "string" || !sessionKey.startsWith("agent:") || sessionKey.length > 512) {
    throw new Error("invalid session key");
  }
  if (RESET_PENDING.has(sessionKey)) return;
  RESET_PENDING.add(sessionKey);
  const clearPending = setTimeout(() => RESET_PENDING.delete(sessionKey), 30_000);
  clearPending.unref();
  const unit = `openclaw-auto-reset-${Date.now()}`;
  try {
    const child = spawn(
      state.systemdRunBin,
      [
        "--quiet",
        `--unit=${unit}`,
        "--on-active=2s",
        "--collect",
        state.openclawBin,
        "gateway",
        "call",
        "sessions.reset",
        "--params",
        JSON.stringify({ key: sessionKey }),
      ],
      { detached: true, stdio: "ignore" },
    );
    child.unref();
  } catch (error) {
    RESET_PENDING.delete(sessionKey);
    throw error;
  }
}

function isWeChatContext(ctx) {
  return ctx?.channel === "openclaw-weixin"
    || ctx?.channelId === "openclaw-weixin"
    || ctx?.messageProvider === "openclaw-weixin"
    || ctx?.metadata?.channel === "openclaw-weixin";
}

function isNaturalSessionResetRequest(input) {
  const normalized = String(input ?? "").trim().replace(/[\s，。！？、.!?]/g, "");
  return new Set([
    "新开对话",
    "开始新对话",
    "开个新对话",
    "重新开始对话",
    "重新开始聊天",
  ]).has(normalized);
}

function normalizedNaturalCommand(input) {
  return String(input ?? "").trim().replace(/[\s，。！？、.!?]/g, "");
}

function isOneOfNaturalCommands(input, commands) {
  return commands.includes(normalizedNaturalCommand(input));
}

function requestProviderDelete(ctx, state, platform) {
  const record = state.providers[platform];
  if (!record) return text("这个平台没有由 AI Key 管理器添加的 API 配置。");
  state.pendingDelete = {
    platform,
    senderId: ctx.senderId,
    expiresAt: Date.now() + 5 * 60_000,
  };
  saveState(state);
  return text(`将删除 ${platform} 的 API Key 和本机 Provider 配置。请在 5 分钟内回复：确认删除 ${platform}`);
}

function deleteProvider(state, platform) {
  const record = state.providers[platform];
  if (!record) throw new Error("provider not managed");
  runOpenClaw(state, ["config", "unset", `models.providers.${providerId(platform)}`]);
  delete state.providers[platform];
  state.pendingDelete = null;
  saveState(state);
}

function addProvider(state, platform, apiKey, model, customBaseUrl, customApi) {
  const builtIn = PLATFORMS[platform];
  const definition =
    platform === "custom"
      ? { label: "Custom", baseUrl: customBaseUrl, api: customApi }
      : builtIn;
  if (!definition) throw new Error("unsupported platform");
  if (!definition.baseUrl || !definition.baseUrl.startsWith("https://")) {
    throw new Error("invalid base URL");
  }
  if (!new Set(["openai-completions", "anthropic-messages", "google-generative-ai"]).has(definition.api)) {
    throw new Error("invalid API adapter");
  }

  const id = providerId(platform);
  const record = state.providers[platform] ?? { label: definition.label, models: [] };
  const modelNames = record.models.includes(model) ? record.models : [...record.models, model];
  const modelEntries = providerModelEntries(definition, modelNames, modelCatalogMetadata(state, platform, modelNames));
  runOpenClaw(state, [
    "config",
    "set",
    `models.providers.${id}`,
    JSON.stringify({ baseUrl: definition.baseUrl, api: definition.api, apiKey, timeoutSeconds: 120 }),
    "--strict-json",
    "--merge",
  ]);
  runOpenClaw(state, [
    "config",
    "set",
    `models.providers.${id}.models`,
    JSON.stringify(modelEntries),
    "--strict-json",
    "--merge",
  ]);
  runOpenClaw(state, [
    "config",
    "set",
    "agents.defaults.models",
    JSON.stringify({ [`${id}/${model}`]: { alias: `${definition.label}-${model}` } }),
    "--strict-json",
    "--merge",
  ]);

  record.label = definition.label;
  record.models = modelNames;
  state.providers[platform] = record;
  saveState(state);
  return `${id}/${model}`;
}

function addModelToProvider(state, platform, model) {
  if (!model || model.length > MAX_MODEL_LENGTH || /\s/.test(model)) throw new Error("invalid model");
  const definition = PLATFORMS[platform];
  const record = state.providers[platform];
  if (!definition || !record) throw new Error("provider not managed");
  if (record.models.includes(model)) return { ref: `${providerId(platform)}/${model}`, added: false };

  const modelNames = [...record.models, model];
  const modelEntries = providerModelEntries(definition, modelNames, modelCatalogMetadata(state, platform, modelNames));
  const id = providerId(platform);
  runOpenClaw(state, [
    "config",
    "set",
    `models.providers.${id}.models`,
    JSON.stringify(modelEntries),
    "--strict-json",
    "--merge",
  ]);
  runOpenClaw(state, [
    "config",
    "set",
    "agents.defaults.models",
    JSON.stringify({ [`${id}/${model}`]: { alias: `${definition.label}-${model}` } }),
    "--strict-json",
    "--merge",
  ]);
  record.models = modelNames;
  saveState(state);
  return { ref: `${id}/${model}`, added: true };
}

function configuredModelsReply(state) {
  const entries = Object.entries(state.providers);
  if (entries.length === 0) return "尚未添加任何 API 配置。";
  return `已配置的模型：\n${entries.map(([id, item]) => `${id}：${item.models.join("、")}`).join("\n")}`;
}

function setDefaultProviderModel(state, platform, model) {
  const record = state.providers[platform];
  if (!record || !record.models.includes(model)) throw new Error("model not managed");
  const ref = `${providerId(platform)}/${model}`;
  runOpenClaw(state, ["models", "set", ref]);
  scheduleRestart(state);
  return ref;
}

function helpMessage() {
  return [
    "AI Key 管理命令（只限认领者）：",
    "/aikey whoami",
    "/aikey claim 一次性认领码",
    "/aikey platforms",
    "/aikey add 平台 API_KEY 模型名",
    "/aikey model-add 平台 模型名   （已有 API 时新增模型，不必再发 Key）",
    "/aikey discover 平台   （列出接口当前可用、尚未添加的模型）",
    "/aikey delete 平台   （随后发送 /aikey confirm-delete 平台）",
    "/aikey add custom API_KEY 模型名 https://接口地址/v1 openai-completions",
    "/aikey list",
    "/aikey use 平台 模型名   （改默认模型）",
    "/aikey session 平台 模型名   （只改当前会话）",
    "/aikey fallback add 平台 模型名",
    "/aikey fallback clear",
    "/aikey status [all|compaction|memory|system|searxng|gateway]",
    "自然语言：添加 DeepSeek，API：你的Key，模型：deepseek-chat",
    "新增模型：给 DeepSeek 添加模型：deepseek-reasoner（已有 API 时无需再发 Key）",
    "获取新模型：获取 DeepSeek 新模型；只列出，不自动切换。",
    "查看模型：查看已配置模型；切换默认：切换 DeepSeek，模型：deepseek-chat。",
    "删除 API：删除 DeepSeek API；再单独发送 确认删除 DeepSeek API。",
    "状态查询：上下文压缩阈值是多少、查内存和 swap、查 SearXNG 状态、查长期记忆索引。",
    "会话：直接发送“新开对话”即可开始新的对话。",
    "提醒：查看所有提醒；取消提醒 2；取消所有提醒后发送“确认取消所有提醒”。",
    "运维：查看备份、查看磁盘明细、重新索引记忆；立即备份后发送“确认立即备份”；清理空间后发送“确认清理空间”。",
    "支持平台：deepseek、siliconflow、doubao、kimi、openai、gemini、claude、grok、openrouter、qwen、zhipu。",
    "API Key 不会在回复中显示；请勿在群聊中发送。",
  ].join("\n");
}

export default definePluginEntry({
  id: "wechat-ai-provider-admin",
  name: "WeChat AI Provider Admin",
  description: "Owner-claimed API provider administration from WeChat.",
  register(api) {
    api.registerCommand({
      name: "aikey",
      description: "管理本机 AI Provider API Key 和模型。",
      channels: ["openclaw-weixin"],
      acceptsArgs: true,
      requireAuth: false,
      handler: async (ctx) => {
        let state;
        try {
          state = loadState();
        } catch {
          return text("AI Key 管理插件状态文件不可用。请在服务器重新运行安装脚本。");
        }
        const parts = (ctx.args ?? "").trim().split(/\s+/).filter(Boolean);
        const action = (parts.shift() ?? "help").toLowerCase();

        if (action === "help") return text(helpMessage());
        if (action === "whoami") {
          return text(ctx.senderId ? `你的微信发送者 ID：${ctx.senderId}` : "无法读取当前微信发送者 ID。");
        }
        if (action === "claim") {
          const code = parts[0] ?? "";
          if (state.adminSenderId) return text("管理员已认领；此操作不可重复。");
          if (!ctx.senderId || !safeEqualHex(state.bootstrapCodeHash, code)) {
            return text("认领码无效，或当前消息没有可用的发送者 ID。");
          }
          state.adminSenderId = ctx.senderId;
          state.bootstrapCodeHash = "claimed";
          saveState(state);
          return text("管理员微信已认领。现在可发送 /aikey help 查看命令。");
        }

        const denied = requireOwner(ctx, state);
        if (denied) return denied;
        if (action === "status") return text(statusReply(state, normalizeStatusTopic(parts.join(" "))));
        if (action === "platforms") {
          return text(Object.entries(PLATFORMS).map(([id, item]) => `${id}：${item.label}${item.note ? `（${item.note}）` : ""}`).join("\n"));
        }
        if (action === "list") {
          return text(configuredModelsReply(state));
        }
        if (action === "add") {
          const [platformRaw, apiKey, model, customBaseUrl, customApi] = parts;
          const platform = (platformRaw ?? "").toLowerCase();
          try {
            checkModelAndKey(apiKey, model);
            if (platform === "custom" && (!customBaseUrl || !customApi)) throw new Error("custom arguments");
            const ref = addProvider(state, platform, apiKey, model, customBaseUrl, customApi);
            scheduleRestart(state);
            return text(`已添加 ${platform}/${model}，Key 未回显。Gateway 将在约 2 秒后重启；之后可用 /model ${ref} -s 切换当前会话。`);
          } catch {
            return text("添加失败。检查平台名、模型名和接口格式；Key 未显示也未写入回复。发送 /aikey help 查看格式。");
          }
        }
        if (action === "model-add") {
          const [platformRaw, model] = parts;
          const platform = (platformRaw ?? "").toLowerCase();
          try {
            const result = addModelToProvider(state, platform, model);
            return text(result.added
              ? `已为 ${platform} 新增模型 ${model}。默认模型没有改变；需要切换时发送 /model ${result.ref} -s。`
              : `${platform}/${model} 已在模型列表中，默认模型没有改变。`);
          } catch {
            return text("新增模型失败。请确认该平台已通过 /aikey add 添加，且模型名填写正确。Key 未显示也未写入回复。");
          }
        }
        if (action === "discover") {
          const platform = (parts[0] ?? "").toLowerCase();
          try {
            return text(await availableModelsReply(state, platform));
          } catch {
            return text("暂时无法获取该平台的模型列表。请确认该平台已添加 API，或稍后再试。");
          }
        }
        if (action === "delete") {
          const platform = (parts[0] ?? "").toLowerCase();
          if (!state.providers[platform]) return text("该平台没有已添加的 API 配置。");
          return text(`将删除 ${platform} 的 API 配置和模型列表。确定的话，单独发送：/aikey confirm-delete ${platform}`);
        }
        if (action === "confirm-delete") {
          const platform = (parts[0] ?? "").toLowerCase();
          try {
            deleteProvider(state, platform);
            scheduleRestart(state);
            return text(`已删除 ${platform} 的 API 配置和模型列表，网关将在约两秒后重启。`);
          } catch {
            return text("删除失败。请确认平台名正确且此前已添加过该 API 配置。");
          }
        }
        if (action === "fallback" && parts[0] === "clear") {
          try {
            runOpenClaw(state, ["models", "fallbacks", "clear"]);
            return text("已清空自动备用模型。");
          } catch {
            return text("备用模型设置失败；请稍后发送 /model status 检查。");
          }
        }
        if (action === "use" || action === "session" || action === "fallback") {
          const [subAction, platformRaw, model] = action === "fallback" ? parts : ["", parts[0], parts[1]];
          const platform = (platformRaw ?? "").toLowerCase();
          const record = state.providers[platform];
          if (!record || !record.models.includes(model)) return text("该平台或模型尚未通过 /aikey add 添加。");
          const ref = `${providerId(platform)}/${model}`;
          try {
            if (action === "use") {
              setDefaultProviderModel(state, platform, model);
              return text(`默认模型已设为 ${ref}；Gateway 将在约 2 秒后重启。当前已固定模型的会话可发送 /model default -s 继承新默认值。`);
            }
            if (action === "session") return text(`请直接发送：/model ${ref} -s`);
            if (subAction === "add") {
              runOpenClaw(state, ["models", "fallbacks", "add", ref]);
              return text(`已加入自动备用模型：${ref}`);
            }
          } catch {
            return text("模型设置失败；Gateway 配置未返回可用结果。请稍后发送 /model status 检查。");
          }
        }
        return text(helpMessage());
      },
    });

    // Do not intercept ordinary natural-language WeChat messages here. They
    // must reach the normal Agent so the owner can use natural language for
    // server work and reminders. The explicit /aikey command remains the only
    // owner-claimed provider-management entry point.

    api.on(
      "before_agent_reply",
      async (event, ctx) => {
        if (!isWeChatContext(ctx)) return;
        // A scheduled reminder already received its authorization when it was
        // created. Its internal prompt may mention a user or a cron id, which
        // must never be mistaken for a new high-risk command.
        if (isCronRunContext(ctx)) return;
        let state;
        try {
          state = loadState();
        } catch {
          return { handled: true, reply: text("重要操作确认组件暂时不可用。请在服务器重新运行安装脚本。") };
        }

        const discoveryPlatform = naturalProviderModelDiscovery(event.cleanedBody, state);
        if (discoveryPlatform) {
          const denied = requireOwner(ctx, state);
          if (denied) return { handled: true, reply: denied };
          try {
            return { handled: true, reply: text(await availableModelsReply(state, discoveryPlatform)) };
          } catch {
            return { handled: true, reply: text("暂时无法获取该平台的模型列表。请确认该平台已添加 API，或稍后再试。") };
          }
        }

        const naturalModelAddition = parseNaturalModelAddition(event.cleanedBody);
        if (naturalModelAddition) {
          const denied = requireOwner(ctx, state);
          if (denied) return { handled: true, reply: denied };
          try {
            const result = addModelToProvider(state, naturalModelAddition.platform, naturalModelAddition.model);
            return {
              handled: true,
              reply: text(result.added
                ? `已为 ${naturalModelAddition.platform} 新增模型 ${naturalModelAddition.model}。默认模型没有改变；需要切换时发送 /model ${result.ref} -s。`
                : `${naturalModelAddition.platform}/${naturalModelAddition.model} 已在模型列表中，默认模型没有改变。`),
            };
          } catch {
            return { handled: true, reply: text("新增模型失败。请确认该平台已添加过 API，且模型名填写正确。") };
          }
        }

        const naturalProviderRequest = parseNaturalRequest(event.cleanedBody);
        if (naturalProviderRequest?.kind === "add") {
          const denied = requireOwner(ctx, state);
          if (denied) return { handled: true, reply: denied };
          if (!naturalProviderRequest.model) {
            return {
              handled: true,
              reply: text(`已识别 ${naturalProviderRequest.platform}。还缺模型名；为避免猜错模型，请把 API 和模型名放在同一条消息，例如：添加 ${naturalProviderRequest.platform}，API：你的密钥，模型：模型名。`),
            };
          }
          try {
            const ref = addProvider(state, naturalProviderRequest.platform, naturalProviderRequest.apiKey, naturalProviderRequest.model);
            scheduleRestart(state);
            return {
              handled: true,
              reply: text(`已添加 ${naturalProviderRequest.platform}/${naturalProviderRequest.model}，密钥未回显。网关将在约两秒后重启；之后可发送 /model ${ref} -s 切换当前对话。`),
            };
          } catch {
            return { handled: true, reply: text("添加失败。请检查平台名、模型名和密钥格式；密钥未显示也未写入回复。") };
          }
        }

        if (naturalProviderRequest?.kind === "use") {
          const denied = requireOwner(ctx, state);
          if (denied) return { handled: true, reply: denied };
          try {
            const ref = setDefaultProviderModel(state, naturalProviderRequest.platform, naturalProviderRequest.model);
            return {
              handled: true,
              reply: text(`默认模型已设为 ${ref}，网关将在约两秒后重启。当前已固定模型的对话可发送 /model default -s 继承新默认值。`),
            };
          } catch {
            return { handled: true, reply: text("切换失败。请先发送“查看已配置模型”确认平台和模型名。") };
          }
        }

        if (naturalProviderRequest?.kind === "delete-request") {
          const denied = requireOwner(ctx, state);
          if (denied) return { handled: true, reply: denied };
          if (!state.providers[naturalProviderRequest.platform]) {
            return { handled: true, reply: text("该平台没有已添加的 API 配置。") };
          }
          return {
            handled: true,
            reply: text(`将删除 ${naturalProviderRequest.platform} 的 API 配置和模型列表。确定的话，直接单独发送“确认删除 ${naturalProviderRequest.platform} API”即可。`),
          };
        }

        if (naturalProviderRequest?.kind === "delete-confirm") {
          const denied = requireOwner(ctx, state);
          if (denied) return { handled: true, reply: denied };
          try {
            deleteProvider(state, naturalProviderRequest.platform);
            scheduleRestart(state);
            return {
              handled: true,
              reply: text(`已删除 ${naturalProviderRequest.platform} 的 API 配置和模型列表，网关将在约两秒后重启。`),
            };
          } catch {
            return { handled: true, reply: text("删除失败。请确认平台名正确且此前已添加过该 API 配置。") };
          }
        }

        if (isOneOfNaturalCommands(event.cleanedBody, ["查看已配置模型", "查看已添加模型", "查看模型列表"])) {
          const denied = requireOwner(ctx, state);
          return { handled: true, reply: denied ?? text(configuredModelsReply(state)) };
        }

        if (isOneOfNaturalCommands(event.cleanedBody, ["查看备份", "检查备份", "备份状态"])) {
          const denied = requireOwner(ctx, state);
          return { handled: true, reply: denied ?? text(readBackupStatus()) };
        }

        if (isOneOfNaturalCommands(event.cleanedBody, ["查看所有提醒", "查看提醒", "所有提醒"])) {
          const denied = requireOwner(ctx, state);
          return { handled: true, reply: denied ?? text(allRemindersReply(state)) };
        }

        const reminderIndex = reminderIndexFromText(event.cleanedBody);
        if (reminderIndex !== null) {
          const denied = requireOwner(ctx, state);
          return { handled: true, reply: denied ?? text(cancelReminderByIndexReply(state, reminderIndex)) };
        }

        if (isOneOfNaturalCommands(event.cleanedBody, ["取消所有提醒"])) {
          const denied = requireOwner(ctx, state);
          return {
            handled: true,
            reply: denied ?? text("我会重新读取所有尚未执行的提醒并全部取消；系统任务、已送达提醒不会动。确定的话，直接单独发送“确认取消所有提醒”即可，不依赖前一条消息。"),
          };
        }

        if (isOneOfNaturalCommands(event.cleanedBody, ["确认取消所有提醒"])) {
          const denied = requireOwner(ctx, state);
          return { handled: true, reply: denied ?? text(cancelAllRemindersReply(state)) };
        }

        if (isOneOfNaturalCommands(event.cleanedBody, ["查看磁盘明细", "查磁盘明细", "磁盘明细"])) {
          const denied = requireOwner(ctx, state);
          return { handled: true, reply: denied ?? text(readDiskDetails()) };
        }

        if (isOneOfNaturalCommands(event.cleanedBody, ["立即备份", "马上备份", "现在备份"])) {
          const denied = requireOwner(ctx, state);
          return {
            handled: true,
            reply: denied ?? text("可以。如要执行，直接单独发送“确认立即备份”即可；不需要先发送这句话。我会马上创建本机备份并同步到 OneDrive，失败会立即提醒你。"),
          };
        }

        if (isOneOfNaturalCommands(event.cleanedBody, ["确认立即备份"])) {
          const denied = requireOwner(ctx, state);
          if (denied) return { handled: true, reply: denied };
          try {
            startKnownSystemService("openclaw-server-backup.service");
            return { handled: true, reply: text("已开始立即备份。本机备份会同步到 OneDrive；完成后会更新备份记录，如有失败会马上提醒你。") };
          } catch {
            return { handled: true, reply: text("暂时无法启动备份任务，请稍后再试。") };
          }
        }

        if (isOneOfNaturalCommands(event.cleanedBody, ["重新索引记忆", "刷新记忆索引", "更新记忆索引"])) {
          const denied = requireOwner(ctx, state);
          if (denied) return { handled: true, reply: denied };
          try {
            startKnownSystemService("openclaw-memory-index.service");
            return { handled: true, reply: text("已开始重新索引长期记忆，完成后新资料就能更好地被检索到。") };
          } catch {
            return { handled: true, reply: text("暂时无法启动记忆索引，请稍后再试。") };
          }
        }

        if (isOneOfNaturalCommands(event.cleanedBody, ["清理空间", "清理缓存"])) {
          const denied = requireOwner(ctx, state);
          return {
            handled: true,
            reply: denied ?? text("这会清理可再生缓存、过期日志和临时文件，不会碰 OpenClaw 数据或备份。如要执行，直接单独发送“确认清理空间”即可；不需要先发送这句话。"),
          };
        }

        if (isOneOfNaturalCommands(event.cleanedBody, ["确认清理空间"])) {
          const denied = requireOwner(ctx, state);
          if (denied) return { handled: true, reply: denied };
          try {
            startKnownSystemService("openclaw-space-cleanup.service");
            return { handled: true, reply: text("已开始清理空间，只会处理可再生缓存、过期日志和临时文件，不会删除 OpenClaw 数据或备份。") };
          } catch {
            return { handled: true, reply: text("暂时无法启动空间清理，请稍后再试。") };
          }
        }

        if (isNaturalSessionResetRequest(event.cleanedBody)) {
          try {
            scheduleSessionReset(state, ctx.sessionKey);
            return { handled: true, reply: text("好的，正在为你开始新的对话。请稍等两秒后再发新的问题。") };
          } catch {
            return { handled: true, reply: text("暂时无法自动开始新对话，请发送 /new 后再试。") };
          }
        }

        const confirmedRequest = parseHighRiskConfirmation(event.cleanedBody);
        if (confirmedRequest) {
          // A complete instruction such as “确认重启 SearXNG” is an explicit
          // one-message authorization. Let the Agent receive that operation
          // directly, without requiring a previously stored request.
          const pending = state.pendingHighRisk;
          if (pending && pending.actor === confirmationActor(ctx)) {
            state.pendingHighRisk = null;
            saveState(state);
          }
          return;
        }

        if (isHighRiskConfirmation(event.cleanedBody)) {
          const pending = state.pendingHighRisk;
          if (!pending || pending.actor !== confirmationActor(ctx) || pending.expiresAt < Date.now()) {
            state.pendingHighRisk = null;
            saveState(state);
            return { handled: true, reply: text("请在同一条消息写明要执行的操作，例如：确认重启 SearXNG。") };
          }
          if (typeof pending.request !== "string" || !pending.request.trim()) {
            state.pendingHighRisk = null;
            saveState(state);
            return { handled: true, reply: text("这条待确认操作缺少原始内容。请重新发送原操作后再确认。") };
          }
          return { handled: true, reply: text(`请带上完整原操作确认：确认${confirmationOperationText(pending.request)}`) };
        }

        if (needsHighRiskConfirmation(event.cleanedBody)) {
          return { handled: true, reply: requestHighRiskConfirmation(ctx, state, event.cleanedBody) };
        }
      },
      { eligibleTriggers: ["user"], priority: 110 },
    );

    api.on(
      "before_prompt_build",
      (_event, ctx) => {
        if (!isWeChatContext(ctx) && !isCronRunContext(ctx)) return;
        return {
          appendSystemContext:
            "面向用户的最终回复、状态说明、错误解释必须只使用简体中文。不得发送独立英文句子、英文系统提示或英文错误原文；代码、命令、URL、产品名、模型名和用户明确要求保留的原文可以保持原样。若工具或服务返回英文，只保留必要产品名和代码标识，并用中文概述，绝不原样转发。不要向用户输出工具调用的原始失败文本、命令、文件路径、堆栈或错误码；工具失败时用自然中文简述，并在安全可行时换一种方式继续处理。定时提醒实际触发时，只输出一两句简洁的中文提醒正文，语气自然、亲切、带一点关怀，可用一个合适表情；不要复述任务描述、内部时间、定时任务编号、英文运行说明或系统提示。用户以自然语言要求备忘、定时提醒或到点通知时，使用 OpenClaw 的定时任务，并明确选择 announce 推送到当前微信通道；绝不创建 delivery 为 none 的提醒，也不要仅依赖 sessions_send。创建后先核对任务的推送方式和下一次执行时间，再用中文告知用户。提醒增强规则：当用户说“提醒 X 次”时，X 必须是 1 至 24 的整数，必须创建恰好 X 条独立的一次性提醒任务；若给出间隔，第一条在指定起点触发，后续按该间隔触发；若只给次数而没有间隔，默认每 5 分钟一条，并在确认消息中说明。用户说“从几点开始每 X 小时提醒一次直到几点”时，创建起点起、结束时间止且不超过结束时间的全部一次性提醒；若结束时间刚好落在间隔上，结束时间也必须包含。跨日期但未说清日期时，先用中文追问，不能猜测。每条提醒都用 isolate 加 agentTurn 与 announce 微信推送；创建完必须核对总条数、推送方式和每条的执行时间，再用中文汇总。对于重要操作，用户可在一条完整消息中明确授权，例如“确认重启 SearXNG”；这已经是授权和操作本身，立即执行，不要再要求确认。未带“确认”的重要操作由插件提示用户改用该格式。",
        };
      },
      { priority: 100 },
    );

    // Default every reminder created from the private WeChat session to
    // announcement delivery. This is a post-create safety net, independent of
    // whether the Agent remembered to supply delivery settings in its tool call.
    api.on(
      "cron_changed",
      (event, gatewayCtx) => enforceWeChatReminderDelivery(event, gatewayCtx),
      { priority: 100 },
    );

    // Schedule the fresh session at the terminal failure point as well as in
    // the delivery-rewrite hook below. This catches a compaction failure even
    // when a channel returns no ordinary outgoing error message.
    api.on(
      "agent_end",
      (event, ctx) => {
        if (!isWeChatContext(ctx)) return;
        const errorText = String(event.error?.message ?? event.error ?? event.reason ?? "");
        if (!/auto-compaction|compaction.*(?:fail|recover)|context is too large/i.test(errorText)) return;
        try {
          scheduleSessionReset(loadState(), ctx.sessionKey);
        } catch {
          // The visible handler below tells the owner how to recover if reset
          // scheduling is unavailable; never replace the original error here.
        }
      },
      { priority: 100 },
    );

    api.on(
      "message_sending",
      (event, ctx) => {
        if (typeof event.content !== "string") return;
        const content = event.content;
        const compact = content.trim();
        // This check deliberately runs before the context gate. Gateway-owned
        // cron-failure deliveries don't always carry the original cron context,
        // which was why their raw English envelope could bypass prior filters.
        const cronFailure = cronFailureNotice(content);
        if (cronFailure) return { content: cronFailure };
        if (!isWeChatContext(ctx) && !isCronRunContext(ctx)) return;
        // A cron reminder must never expose the Gateway's English scheduling
        // envelope. If a provider ignores the Chinese-only prompt, keep the
        // delivery useful and warm instead of forwarding mixed system text.
        if (isCronRunContext(ctx) && /[A-Za-z]{3,}/.test(compact)) {
          return { content: "⏰ 到提醒时间啦，别忘了你刚才安排的事情哦～" };
        }
        // Gateway and provider errors must never leak to the WeChat user as
        // raw English transport text. These patterns intentionally replace the
        // whole message because an error string is not a useful answer.
        if (/^(?:error|failed|invalid request|permission denied|unauthorized|forbidden|not found|internal server error|service unavailable|gateway error|command failed|tool call failed)\b/i.test(compact)) {
          return { content: "刚才的服务操作没有成功，但机器人仍可用。我会改用中文继续处理；请重新发送你的需求。" };
        }
        if (/rate limit exceeded|too many requests|quota exceeded/i.test(compact)) {
          return { content: "当前请求过于频繁或额度暂不可用，请稍后再试。" };
        }
        if (/timeout|timed out|request aborted|connection (?:reset|refused|failed)/i.test(compact)) {
          return { content: "连接服务超时或中断，请稍后重新发送。" };
        }
        // Tool access remains enabled. Only hide the raw, atmosphere-breaking
        // transport error that some runtimes render as "Exec failed: ...".
        if (/(?:^|\n)\s*(?:⚠\uFE0F?\s*🛠\uFE0F?\s*)?exec failed\s*:/i.test(content)) {
          return {
            content: "我刚才尝试处理这项操作时没有成功，但助手功能仍然可用。我会换一种方式继续；你也可以直接再告诉我希望我做什么。",
          };
        }
        if (/auto-compaction could not recover|context is too large and auto-compaction/i.test(content)) {
          try {
            const state = loadState();
            scheduleSessionReset(state, ctx.sessionKey);
            return {
              content: "⚠️ 上下文压缩失败，正在自动创建新的对话。请在几秒后重新发送刚才的问题。",
            };
          } catch {
            return {
              content: "⚠️ 上下文压缩失败。请发送 /new 开始新对话后，再重新发送刚才的问题。",
            };
          }
        }
        if (/the ai service is temporarily overloaded|experiencing high demand|code=unavailable/i.test(content)) {
          return { content: "⚠️ AI 服务当前繁忙，请稍后再试。" };
        }
        if (/^✅\s*new session started\.?$/i.test(content.trim())) {
          return { content: "✅ 已开始新的对话。" };
        }
        // Normal answers are requested in Chinese by the system context above.
        // If a provider still returns a full English-only answer, do not pass it
        // through as user-visible feedback. Code blocks, URLs and model names
        // are excluded from the language test so valid technical replies stay
        // intact when accompanied by Chinese explanation.
        if (hasUntranslatedEnglishProse(compact)) {
          return { content: "刚才的回复混入了未转换的英文提示。我会用中文重新处理，请把刚才的问题再发一次。" };
        }
      },
      { priority: 100 },
    );
  },
});
EOF

chmod 700 "$plugin_dir"
chmod 600 "$plugin_dir/package.json" "$plugin_dir/openclaw.plugin.json" "$plugin_dir/index.js"

printf '\nInstalling the local WeChat provider-admin plugin...\n'
openclaw plugins install "$plugin_dir" --force
openclaw config set plugins.entries.wechat-ai-provider-admin.enabled true
openclaw config set plugins.entries.wechat-ai-provider-admin.hooks.allowConversationAccess true

# Keep normal agent replies Chinese and make built-in localized strings prefer zh-CN.
mkdir -p /etc/systemd/system/openclaw-gateway.service.d
cat > /etc/systemd/system/openclaw-gateway.service.d/locale.conf <<'EOF'
[Service]
Environment=OPENCLAW_LOCALE=zh-CN
EOF

# OpenClaw 2026.7 still hard-codes several cron prompt templates to English.
# Apply a narrow, idempotent local patch at every Gateway start so reminder
# prompts themselves are Chinese instead of relying on a send-time interceptor.
cat > /usr/local/sbin/openclaw-zh-cron-template-patch.js <<'NODE'
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const childProcess = require("node:child_process");

const distDir = "/usr/lib/node_modules/openclaw/dist";
const backupDir = "/root/.openclaw/backups/zh-cron-template-patch";

function findDistFiles(prefix) {
  const matches = fs.readdirSync(distDir)
    .filter((name) => name.startsWith(prefix) && name.endsWith(".js"))
    .sort()
    .map((name) => path.join(distDir, name));
  if (matches.length === 0) {
    console.warn(`[中文定时提示补丁] 未找到 ${prefix}*.js，跳过该类文件。`);
  }
  return matches;
}

function patchFile(filePath, replacements) {
  const original = fs.readFileSync(filePath, "utf8");
  let updated = original;
  let changed = false;
  let recognized = false;
  for (const [from, to] of replacements) {
    if (updated.includes(from)) {
      updated = updated.split(from).join(to);
      changed = true;
      recognized = true;
    } else if (updated.includes(to)) recognized = true;
  }
  if (!recognized || !changed) return;

  fs.mkdirSync(backupDir, { recursive: true, mode: 0o700 });
  const backupPath = path.join(backupDir, `${path.basename(filePath)}.before-zh-cron`);
  if (!fs.existsSync(backupPath)) fs.writeFileSync(backupPath, original, { mode: 0o600 });

  const tempPath = path.join(path.dirname(filePath), `.${path.basename(filePath)}.zh-cron-tmp.js`);
  fs.writeFileSync(tempPath, updated, { mode: 0o644 });
  try {
    childProcess.execFileSync(process.execPath, ["--check", tempPath], { stdio: "pipe" });
    fs.renameSync(tempPath, filePath);
    console.log(`[中文定时提示补丁] 已更新 ${path.basename(filePath)}`);
  } catch (error) {
    try { fs.unlinkSync(tempPath); } catch {}
    throw new Error(`补丁语法校验失败，未修改 ${path.basename(filePath)}：${error.message}`);
  }
}

function patchDistFiles(prefix, replacements) {
  for (const filePath of findDistFiles(prefix)) patchFile(filePath, replacements);
}

try {
  patchDistFiles("isolated-agent-", [
    ["with an explicit target", "，请明确指定接收人"],
    ["for the current chat", "，发送到当前聊天"],
    ["Use the message tool if you need to notify the user directly ${targetHint}. If you do not send directly, your final plain-text reply will be delivered automatically.", "如需直接通知用户，请使用消息工具${targetHint}。如果不直接发送，最终纯文本回复会自动推送。"],
    ["Return your response as plain text; it will be delivered automatically. If the task explicitly calls for messaging a specific external recipient, note who/where it should go instead of sending it yourself.", "请直接用中文输出回复；最终纯文本会自动推送给用户。如任务明确要求联系特定外部接收人，请说明应发送给谁或发送到哪里，不要自行额外发送。"],
  ]);
  patchDistFiles("date-time-", [
    ["new Intl.DateTimeFormat(\"en-US\", {\n\t\t\ttimeZone,\n\t\t\tweekday: \"long\",", "new Intl.DateTimeFormat(\"zh-CN\", {\n\t\t\ttimeZone,\n\t\t\tweekday: \"long\","],
    ["return `${map.weekday}, ${map.month} ${dayNum}${suffix}, ${map.year} - ${timePart}`;", "return `${map.year}年${map.month}月${dayNum}日 ${map.weekday} ${timePart}`;"],
    ["return `${map.year}年${map.month}${dayNum}日 ${map.weekday} ${timePart}`;", "return `${map.year}年${map.month}月${dayNum}日 ${map.weekday} ${timePart}`;"],
  ]);
  patchDistFiles("current-time-", [
    ["timeLine: `Current time: ${formattedTime} (${userTimezone})\\nReference UTC: ${date.toISOString().replace(\"T\", \" \").slice(0, 16) + \" UTC\"}`", "timeLine: `当前时间：${formattedTime}\\n参考世界协调时间：${date.toISOString().replace(\"T\", \" \").slice(0, 16)}`"],
    ["/^Current time: .+? \\([^)]+\\)\\nReference UTC: \\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2} UTC$/gm", "/^当前时间：.+?\\n参考世界协调时间：\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}$/gm"],
    ["(?=Current time:)", "(?=当前时间：)"],
  ]);
  patchDistFiles("selection-", [
    ["Current time: ", "当前时间："],
  ]);
  patchDistFiles("cron-", [
    ["schedule.at is in the past: ${resolveTimestampMsToIsoString(atMs)} (${Math.floor(-diffMs / ONE_MINUTE_MS)} minutes ago). Current time: ${nowDate}", "计划执行时间已过：${resolveTimestampMsToIsoString(atMs)}（已过去 ${Math.floor(-diffMs / ONE_MINUTE_MS)} 分钟）。当前时间：${nowDate}"],
  ]);
  patchDistFiles("server-cron-", [
    ["const failureMessage = `Cron job \"${params.job.name}\" failed: ${params.evt.error ?? \"unknown error\"}`;", "const failureMessage = \"定时任务本次未完成。系统会按下一次计划继续执行；如持续出现，请检查 AI 服务响应。\";"],
    ["const statusVerb = params.status === \"skipped\" ? \"skipped\" : \"failed\";", "const statusVerb = params.status === \"skipped\" ? \"已跳过\" : \"未完成\";"],
    ["const detailLabel = params.status === \"skipped\" ? \"Skip reason\" : \"Last error\";", "const detailLabel = params.status === \"skipped\" ? \"跳过说明\" : \"异常说明\";"],
    ["`Cron job \"${safeJobName}\" ${statusVerb} ${params.consecutiveErrors} times`,", "`定时任务已连续 ${params.consecutiveErrors} 次${statusVerb}。`,"],
    ["...errorReason ? [`Cause: ${errorReason}`] : [],", "...errorReason ? [\"可能原因已记录，系统会继续按计划执行。\"] : [],"],
    ["`${detailLabel}: ${truncatedError}`", "\"详细原因已记录，未向用户显示。\""],
  ]);
  patchDistFiles("cron-", [
    ["warnings.push(`Cron job \"${jobName}\" still uses legacy notify fallback, but cron.webhook is not a valid HTTP(S) URL so doctor cannot migrate it automatically.`);", "warnings.push(\"有一条定时任务使用了旧通知设置，系统无法自动迁移；详细原因已记录。\");"],
  ]);
  patchDistFiles("jobs-", [
    ["const notifyText = `⚠️ Cron job \"${job.name}\" has been auto-disabled after ${errorCount} consecutive schedule errors. Last error: ${errText}`;", "const notifyText = \"⚠️ 有一条定时任务因连续调度失败已暂停。系统未执行其他操作；如需恢复，请先检查服务状态。\";"],
  ]);
  patchDistFiles("embedded-agent-", [
    ["The model did not produce a response before the model idle timeout. Please try again, or increase `models.providers.<id>.timeoutSeconds` for slow local or self-hosted providers. If `agents.defaults.timeoutSeconds` or a run-specific timeout is lower, raise that ceiling too; provider timeouts cannot extend the whole agent run.", "AI 服务在等待响应时超时，本次任务未完成。请稍后重试；如持续出现，请检查模型服务响应时间。"],
    ["Request timed out before a response was generated. Please try again, or increase `agents.defaults.timeoutSeconds` in your config.", "AI 服务请求超时，本次任务未完成。请稍后重试。"],
  ]);
  patchFile(path.join(distDir, "extensions", "memory-core", "index.js"), [
    ["Current time:", "当前时间："],
  ]);
  console.log("[中文定时提示补丁] 检查完成。");
} catch (error) {
  // A changed upstream bundle must never stop the running Gateway. The warning
  // is visible in journald and can be reviewed before adjusting this installer.
  console.warn(`[中文定时提示补丁] 未完成：${error.message}`);
}
NODE
chmod 700 /usr/local/sbin/openclaw-zh-cron-template-patch.js
cat > /etc/systemd/system/openclaw-gateway.service.d/zh-cron-templates.conf <<'EOF'
[Service]
ExecStartPre=/usr/bin/node /usr/local/sbin/openclaw-zh-cron-template-patch.js
EOF
node /usr/local/sbin/openclaw-zh-cron-template-patch.js
systemctl daemon-reload

# The Gateway hook is helpful but is not the final authority: some system
# deliveries arrive with a channelId-only context and some plugin-generated
# error notices bypass the normal agent path. Patch the Tencent Weixin plugin's
# actual text-send functions before every Gateway start. This is the final
# outbound boundary immediately before the Weixin API request is built.
cat > /usr/local/sbin/openclaw-weixin-chinese-egress-patch.js <<'NODE'
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const childProcess = require("node:child_process");

const projectsDir = "/root/.openclaw/npm/projects";
const backupDir = "/root/.openclaw/backups/weixin-chinese-egress-patch";
const marker = "/* OPENCLAW_WEIXIN_CHINESE_EGRESS_GUARD */";

const guard = [
  marker,
  "function enforceChineseWeixinOutboundText(value) {",
  "    const text = String(value ?? \"\");",
  "    const plain = text.replace(/```[\\s\\S]*?```/g, \"\").replace(/`[^`]*`/g, \"\").replace(/https?:\\/\\/\\S+/g, \"\");",
  "    const hasChinese = /[一-龥]/.test(plain);",
  "    const englishWords = plain.match(/\\b[A-Za-z]{3,}\\b/g) ?? [];",
  "    const rawSystemError = /\\b(?:cron\\s+job|error|failed|failure|timeout|timed out|exception|invalid request|permission denied|unauthorized|forbidden|not found|service unavailable|connection (?:reset|refused|failed)|exec failed|tool call failed|context is too large|auto-compaction|model did not produce a response|request aborted|rate limit|quota exceeded)\\b/i.test(plain);",
  "    if (rawSystemError) return \"⚠️ 系统任务本次未完成，原始技术提示已拦截。其他功能仍可用，请稍后再试；如果连续出现，我会继续检查。\";",
  "    if (!hasChinese && englishWords.length >= 3) return \"⚠️ 收到一条未转换为中文的系统提示，已拦截。请稍后再试。\";",
  "    return text;",
  "}",
].join("\n");

function findTargets() {
  if (!fs.existsSync(projectsDir)) return [];
  return fs.readdirSync(projectsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith("tencent-weixin-openclaw-weixin-"))
    .map((entry) => path.join(projectsDir, entry.name, "node_modules", "@tencent-weixin", "openclaw-weixin", "dist", "src", "messaging", "send.js"))
    .filter((filePath) => fs.existsSync(filePath));
}

function patchTarget(filePath) {
  const original = fs.readFileSync(filePath, "utf8");
  if (original.includes(marker)) return "already patched";
  const anchor = "function buildTextMessageReq(params) {";
  const textBuilder = "    const item_list = text\n        ? [{ type: MessageItemType.TEXT, text_item: { text } }]\n        : [];";
  const safeTextBuilder = "    const safeText = enforceChineseWeixinOutboundText(text);\n    const item_list = safeText\n        ? [{ type: MessageItemType.TEXT, text_item: { text: safeText } }]\n        : [];";
  const itemAnchor = "    const clientId = params.clientId ?? generateClientId();\n    const req = {";
  const safeItemAnchor = "    const clientId = params.clientId ?? generateClientId();\n    const safeItem = item?.type === MessageItemType.TEXT && typeof item?.text_item?.text === \"string\"\n        ? { ...item, text_item: { ...item.text_item, text: enforceChineseWeixinOutboundText(item.text_item.text) } }\n        : item;\n    const req = {";
  const mediaCaption = "    if (text) {\n        items.push({ type: MessageItemType.TEXT, text_item: { text } });\n    }";
  const safeMediaCaption = "    if (text) {\n        const safeText = enforceChineseWeixinOutboundText(text);\n        items.push({ type: MessageItemType.TEXT, text_item: { text: safeText } });\n    }";
  if (!original.includes(anchor) || !original.includes(textBuilder) || !original.includes(itemAnchor) || !original.includes(mediaCaption)) {
    throw new Error("未识别微信发送文件版本，未修改");
  }
  let updated = original.replace(anchor, `${guard}\n${anchor}`)
    .replace(textBuilder, safeTextBuilder)
    .replace(itemAnchor, safeItemAnchor)
    .replace("item_list: [item],", "item_list: [safeItem],")
    .replace(mediaCaption, safeMediaCaption);
  if (updated === original || !updated.includes(marker)) throw new Error("补丁未写入预期标记");
  fs.mkdirSync(backupDir, { recursive: true, mode: 0o700 });
  const backupPath = path.join(backupDir, `${path.basename(path.dirname(filePath))}.before-weixin-chinese-egress.js`);
  if (!fs.existsSync(backupPath)) fs.writeFileSync(backupPath, original, { mode: 0o600 });
  const tempPath = path.join(path.dirname(filePath), `.${path.basename(filePath)}.weixin-chinese-tmp.js`);
  fs.writeFileSync(tempPath, updated, { mode: 0o644 });
  try {
    childProcess.execFileSync(process.execPath, ["--check", tempPath], { stdio: "pipe" });
    fs.renameSync(tempPath, filePath);
  } catch (error) {
    try { fs.unlinkSync(tempPath); } catch {}
    throw error;
  }
  return "patched";
}

try {
  const targets = findTargets();
  if (targets.length === 0) throw new Error("未找到腾讯微信插件的最终发送文件");
  for (const target of targets) console.log(`[微信中文出站拦截] ${patchTarget(target)}：${target}`);
} catch (error) {
  // Do not prevent the Gateway from starting if a future plugin layout changes.
  console.warn(`[微信中文出站拦截] 未完成：${error.message}`);
}
NODE
chmod 700 /usr/local/sbin/openclaw-weixin-chinese-egress-patch.js
cat > /etc/systemd/system/openclaw-gateway.service.d/weixin-chinese-egress.conf <<'EOF'
[Service]
ExecStartPre=/usr/bin/node /usr/local/sbin/openclaw-weixin-chinese-egress-patch.js
EOF
node /usr/local/sbin/openclaw-weixin-chinese-egress-patch.js
systemctl daemon-reload

# The owner explicitly requested natural-language host actions from WeChat
# without per-action approval. This intentionally overrides the restrictive
# policy from the base root installer. On OpenClaw 2026.7 the effective policy
# is controlled by tools.exec plus exec-approvals.json; this build has no
# "allow-all" preset. It is appropriate only for a private, trusted WeChat
# bot because the gateway runs as root.
config_file=/root/.openclaw/openclaw.json
if [[ -f "$config_file" ]]; then
  mkdir -p /root/.openclaw/backups
  cp -pf "$config_file" /root/.openclaw/backups/openclaw.before-unattended-root-exec.json
  chmod 600 /root/.openclaw/backups/openclaw.before-unattended-root-exec.json
fi
openclaw config set tools.exec.host gateway
openclaw config set tools.exec.mode full
openclaw approvals set --stdin <<'EOF'
{
  "version": 1,
  "defaults": {
    "security": "full",
    "ask": "off",
    "askFallback": "full"
  }
}
EOF
printf 'Unattended root command execution is enabled for the Gateway. Use only with a private, trusted WeChat bot.\n'

# Synchronize every configured model that OpenClaw can identify with an
# authoritative native context window. `contextTokens` is set to that same
# value so no old generic 128K/200K runtime cap remains. Models without catalog
# metadata are deliberately skipped instead of being assigned a guessed limit.
sync_file="$(mktemp /tmp/openclaw-context-sync.XXXXXX.mjs)"
cat > "$sync_file" <<'NODE'
import fs from "node:fs";
import { execFileSync } from "node:child_process";

const [openclawBin, configPath] = process.argv.slice(2);
const raw = JSON.parse(fs.readFileSync(0, "utf8"));
const rows = Array.isArray(raw) ? raw : Array.isArray(raw.models) ? raw.models : raw.items;
if (!Array.isArray(rows)) throw new Error("OpenClaw returned an unrecognized models-list JSON shape");
const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
const providers = config.models?.providers ?? {};
const desired = new Map();

for (const [providerId, provider] of Object.entries(providers)) {
  if (!Array.isArray(provider?.models)) continue;
  const catalogProvider = providerId.startsWith("wechat-") ? providerId.slice("wechat-".length) : providerId;
  for (const model of provider.models) {
    if (typeof model?.id !== "string" || !model.id) continue;
    const key = `${catalogProvider}/${model.id}`;
    const row = rows.find((candidate) => candidate?.key === key);
    const contextWindow = Number(row?.contextWindow);
    if (!Number.isFinite(contextWindow) || contextWindow <= 0) {
      console.log(`Skipped ${providerId}/${model.id}: no authoritative context window in the OpenClaw catalog.`);
      continue;
    }
    const entries = desired.get(providerId) ?? [];
    entries.push({ id: model.id, contextWindow, contextTokens: contextWindow });
    desired.set(providerId, entries);
  }
}

let count = 0;
for (const [providerId, models] of desired) {
  execFileSync(
    openclawBin,
    ["config", "set", `models.providers.${providerId}.models`, JSON.stringify(models), "--strict-json", "--merge"],
    { stdio: "inherit", env: { ...process.env, HOME: "/root" } },
  );
  count += models.length;
}
console.log(`Synchronized runtime context caps for ${count} catalog-known configured model(s).`);
NODE
openclaw models list --all --json | "$node_bin" "$sync_file" "$openclaw_bin" /root/.openclaw/openclaw.json
rm -f "$sync_file"

# Free, local keyword memory: this intentionally disables remote vector
# embeddings, so DeepSeek/OpenAI embedding keys are neither needed nor read.
# OpenClaw 2026.7 does not yet expose the top-level memory schema. Detect that
# older build instead of leaving an invalid partial config that stops setup.
if openclaw config set memory.search.provider none; then
  openclaw config set memory.search.enabled true
  openclaw config set memory.search.fallback none
  if ! openclaw memory index --force --verbose; then
    printf 'Warning: free keyword-memory index was not rebuilt; the bot will still work normally.\n' >&2
  fi
else
  "$node_bin" - /root/.openclaw/openclaw.json <<'NODE'
const fs = require("fs");
const path = process.argv[2];
try {
  const config = JSON.parse(fs.readFileSync(path, "utf8"));
  if (Object.hasOwn(config, "memory")) {
    delete config.memory;
    fs.writeFileSync(path, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  }
} catch (error) {
  console.error(`Could not remove unsupported memory config: ${error.message}`);
  process.exit(1);
}
NODE
  printf 'This OpenClaw version does not support free keyword-memory configuration; skipped it without affecting the bot.\n' >&2
fi

# Compaction remains proportional to the active model window. Some 2026.7
# builds compact automatically but reject newer control knobs. Preserve the
# compatible knobs and silently skip unknown ones instead of aborting setup.
if openclaw --version 2>&1 | grep -q 'OpenClaw 2026\.7\.'; then
  "$node_bin" - /root/.openclaw/openclaw.json <<'NODE'
const fs = require("fs");
const path = process.argv[2];
try {
  const config = JSON.parse(fs.readFileSync(path, "utf8"));
  const compaction = config.agents?.defaults?.compaction;
  if (compaction && Object.hasOwn(compaction, "enabled")) {
    delete compaction.enabled;
    fs.writeFileSync(path, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  }
} catch (error) {
  console.error(`Could not repair legacy compaction config: ${error.message}`);
  process.exit(1);
}
NODE
fi

set_compaction_if_supported() {
  local config_path="$1"
  local config_value="$2"
  local output
  if output="$(openclaw config set "$config_path" "$config_value" 2>&1)"; then
    printf '%s\n' "$output"
  else
    printf 'Skipped unsupported compaction setting %s on this OpenClaw version.\n' "$config_path" >&2
  fi
}

set_compaction_if_supported agents.defaults.compaction.mode safeguard
set_compaction_if_supported agents.defaults.compaction.reserveTokens 24000
set_compaction_if_supported agents.defaults.compaction.reserveTokensFloor 24000
set_compaction_if_supported agents.defaults.compaction.keepRecentTokens 16000
set_compaction_if_supported agents.defaults.compaction.recentTurnsPreserve 4
set_compaction_if_supported agents.defaults.compaction.maxHistoryShare 0.70
set_compaction_if_supported agents.defaults.compaction.qualityGuard.enabled true
set_compaction_if_supported agents.defaults.compaction.qualityGuard.maxRetries 1
set_compaction_if_supported agents.defaults.compaction.midTurnPrecheck.enabled true
set_compaction_if_supported agents.defaults.compaction.truncateAfterCompaction true
set_compaction_if_supported agents.defaults.compaction.notifyUser false
systemctl restart openclaw-gateway.service
sleep 4
if ! systemctl is-active --quiet openclaw-gateway.service; then
  systemctl status openclaw-gateway.service --no-pager -l >&2 || true
  printf 'Gateway did not become active. Check: journalctl -u openclaw-gateway.service -n 120 --no-pager\n' >&2
  exit 1
fi

printf '\nInstallation completed.\n'
if [[ -n "$new_claim_code" ]]; then
  printf 'In your private WeChat chat, send this one-time command exactly once:\n'
  printf '  /aikey claim %s\n' "$new_claim_code"
  printf 'The first sender who uses this code becomes the only API administrator.\n'
else
  printf 'An existing administrator claim was preserved.\n'
fi
printf '\nThen send: /aikey help\n'
printf 'Status: systemctl status openclaw-gateway.service --no-pager\n'
