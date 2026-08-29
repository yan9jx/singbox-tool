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
  ["doubao", "doubao"],
  ["月之暗面", "kimi"],
  ["kimi", "kimi"],
  ["gemini", "gemini"],
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

function runOpenClaw(state, args) {
  execFileSync(state.openclawBin, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 30_000,
    env: { ...process.env, HOME: "/root" },
  });
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

function needsHighRiskConfirmation(value) {
  const source = normalizeNaturalText(value).toLowerCase();
  if (!source || source.startsWith("/aikey")) return false;
  return /(?:删除|移除|清空|清除|格式化|重置|恢复出厂|关机|重启|停止|卸载|安装|升级|覆盖|替换|开放端口|防火墙|权限|用户|密码|密钥|令牌|api\s*key|\brm\b|\bchmod\b|\bchown\b|\bcurl\b|\bwget\b|\bapt(?:-get)?\b|\bsystemctl\b|\bdocker\b|\biptables\b|\bufw\b|\bnft\b|\bcrontab\b|openclaw\s+(?:config|approvals|exec-policy)|tools\.exec)/i.test(source);
}

function requestHighRiskConfirmation(ctx, state) {
  if (!ctx.senderId) return text("无法读取当前发送者，不能执行重要操作。");
  state.pendingHighRisk = {
    senderId: ctx.senderId,
    expiresAt: Date.now() + 5 * 60_000,
  };
  saveState(state);
  return text("这是重要操作，暂未执行。请在 5 分钟内单独发送“确认执行”进行二次确认；超时后自动取消。普通查询无需确认。");
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
  return ctx.channel === "openclaw-weixin" || ctx.messageProvider === "openclaw-weixin";
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
  // Do not invent a context limit for newly added third-party models. The
  // installer synchronizes every model for which OpenClaw's catalog has
  // authoritative native metadata; unknown custom models keep no fake cap.
  const modelEntries = modelNames.map((modelId) => ({
    id: modelId,
    name: `${definition.label} ${modelId}`,
    input: ["text"],
    maxTokens: 8192,
  }));
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

function helpMessage() {
  return [
    "AI Key 管理命令（只限认领者）：",
    "/aikey whoami",
    "/aikey claim 一次性认领码",
    "/aikey platforms",
    "/aikey add 平台 API_KEY 模型名",
    "/aikey add custom API_KEY 模型名 https://接口地址/v1 openai-completions",
    "/aikey list",
    "/aikey use 平台 模型名   （改默认模型）",
    "/aikey session 平台 模型名   （只改当前会话）",
    "/aikey fallback add 平台 模型名",
    "/aikey fallback clear",
    "/aikey status [all|compaction|memory|system|searxng|gateway]",
    "自然语言：帮我添加 OpenAI API：你的Key，模型：gpt-4.1",
    "删除：帮我删除 Gemini 的 API 配置，然后回复 确认删除 Gemini。",
    "状态查询：上下文压缩阈值是多少、查内存和 swap、查 SearXNG 状态、查长期记忆索引。",
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
          const entries = Object.entries(state.providers);
          if (entries.length === 0) return text("尚未通过 /aikey 添加 Provider。");
          return text(entries.map(([id, item]) => `${id}：${item.models.join("、")}`).join("\n"));
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
              runOpenClaw(state, ["models", "set", ref]);
              scheduleRestart(state);
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
      (event, ctx) => {
        if (!isWeChatContext(ctx)) return;
        let state;
        try {
          state = loadState();
        } catch {
          return { handled: true, reply: text("重要操作确认组件暂时不可用。请在服务器重新运行安装脚本。") };
        }

        if (isHighRiskConfirmation(event.cleanedBody)) {
          const pending = state.pendingHighRisk;
          if (!pending || pending.senderId !== ctx.senderId || pending.expiresAt < Date.now()) {
            state.pendingHighRisk = null;
            saveState(state);
            return { handled: true, reply: text("没有等待确认的重要操作，或确认已超时。请重新发送需要执行的操作。") };
          }
          state.pendingHighRisk = null;
          saveState(state);
          // Let the Agent receive this second confirmation in the same session.
          // It can then act on the immediately preceding deferred request.
          return;
        }

        if (needsHighRiskConfirmation(event.cleanedBody)) {
          return { handled: true, reply: requestHighRiskConfirmation(ctx, state) };
        }
      },
      { eligibleTriggers: ["user"], priority: 110 },
    );

    api.on(
      "before_prompt_build",
      (_event, ctx) => {
        if (!isWeChatContext(ctx)) return;
        return {
          appendSystemContext:
            "面向用户的最终回复、状态说明、错误解释必须只使用简体中文。不得发送独立英文句子、英文系统提示或英文错误原文；代码、命令、URL、产品名、模型名和用户明确要求保留的原文可以保持原样。若工具或服务返回英文，只保留必要产品名和代码标识，并用中文概述，绝不原样转发。不要向用户输出工具调用的原始失败文本、命令、文件路径、堆栈或错误码；工具失败时用自然中文简述，并在安全可行时换一种方式继续处理。用户以自然语言要求备忘、定时提醒或到点通知时，使用 OpenClaw 的定时任务，并明确选择 announce 推送到当前微信通道；绝不创建 delivery 为 none 的提醒，也不要仅依赖 sessions_send。创建后先核对任务的推送方式和下一次执行时间，再用中文告知用户。重要操作会先由插件提示二次确认；当用户随后单独发送“确认执行”时，根据同一会话中紧邻的已延后操作继续执行，不再要求第三次确认。",
        };
      },
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
        if (!isWeChatContext(ctx) || typeof event.content !== "string") return;
        const content = event.content;
        // Tool access remains enabled. Only hide the raw, atmosphere-breaking
        // transport error that some runtimes render as "Exec failed: ...".
        if (/(?:^|\n)\s*(?:⚠\s*🛠\s*)?exec failed\s*:/i.test(content)) {
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
systemctl daemon-reload

# The owner explicitly requested natural-language host actions from WeChat
# without per-action approval. This intentionally overrides the restrictive
# policy from the base root installer. It is appropriate only for a private,
# trusted WeChat bot because the gateway runs as root.
config_file=/root/.openclaw/openclaw.json
if [[ -f "$config_file" ]]; then
  mkdir -p /root/.openclaw/backups
  cp -pf "$config_file" /root/.openclaw/backups/openclaw.before-unattended-root-exec.json
  chmod 600 /root/.openclaw/backups/openclaw.before-unattended-root-exec.json
fi
openclaw exec-policy preset allow-all
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
