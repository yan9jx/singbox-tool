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

function scheduleRestart(state) {
  const unit = `openclaw-ai-provider-admin-${Date.now()}`;
  const child = spawn(
    state.systemdRunBin,
    ["--quiet", `--unit=${unit}`, "--on-active=2s", "--collect", "/bin/systemctl", "restart", "openclaw-gateway.service"],
    { detached: true, stdio: "ignore" },
  );
  child.unref();
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
  const modelEntries = modelNames.map((modelId) => ({
    id: modelId,
    name: `${definition.label} ${modelId}`,
    input: ["text"],
    contextWindow: 128000,
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
    "自然语言：帮我添加 OpenAI API：你的Key，模型：gpt-4.1",
    "删除：帮我删除 Gemini 的 API 配置，然后回复 确认删除 Gemini。",
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

    api.on(
      "before_agent_reply",
      (event, ctx) => {
        if (ctx.channel !== "openclaw-weixin" && ctx.messageProvider !== "openclaw-weixin") return;
        const request = parseNaturalRequest(event.cleanedBody);
        if (!request) return;

        let state;
        try {
          state = loadState();
        } catch {
          return { handled: true, reply: text("AI Key 管理插件状态文件不可用。请在服务器重新运行安装脚本。") };
        }
        const denied = requireOwner(ctx, state);
        if (denied) return { handled: true, reply: denied };

        if (request.kind === "delete-request") {
          return { handled: true, reply: requestProviderDelete(ctx, state, request.platform) };
        }
        if (request.kind === "delete-confirm") {
          const pending = state.pendingDelete;
          if (!pending || pending.platform !== request.platform || pending.senderId !== ctx.senderId || pending.expiresAt < Date.now()) {
            return { handled: true, reply: text("没有可确认的删除操作，或确认已过期。请先重新说“帮我删除该平台的 API 配置”。") };
          }
          try {
            deleteProvider(state, request.platform);
            scheduleRestart(state);
            return {
              handled: true,
              reply: text(`已删除 ${request.platform} 的 API Key 和 Provider 配置；Gateway 将在约 2 秒后重启。`),
            };
          } catch {
            return { handled: true, reply: text("删除失败；原有管理记录已保留，请检查 Gateway 状态后重试。") };
          }
        }

        if (!request.model) {
          return {
            handled: true,
            reply: text("已识别为添加 API，但还缺模型名。请例如发送：帮我添加 OpenAI API：你的Key，模型：gpt-4.1。"),
          };
        }

        if (request.kind === "add") {
          try {
            checkModelAndKey(request.apiKey, request.model);
            const ref = addProvider(state, request.platform, request.apiKey, request.model);
            scheduleRestart(state);
            return {
              handled: true,
              reply: text(`已添加 ${request.platform}/${request.model}，Key 未回显，也不会交给模型。Gateway 将在约 2 秒后重启。`),
            };
          } catch {
            return {
              handled: true,
              reply: text("添加失败。请检查平台、Key 和模型名；Key 未显示也未写入回复。"),
            };
          }
        }

        const record = state.providers[request.platform];
        if (!record || !record.models.includes(request.model)) {
          return {
            handled: true,
            reply: text("该平台或模型尚未添加。请先发送：帮我添加该平台 API：你的Key，模型：模型名。"),
          };
        }
        try {
          const ref = `${providerId(request.platform)}/${request.model}`;
          runOpenClaw(state, ["models", "set", ref]);
          scheduleRestart(state);
          return {
            handled: true,
            reply: text(`默认模型已切换为 ${ref}；Gateway 将在约 2 秒后重启。当前已固定模型的会话可发送 /model default -s 继承新默认值。`),
          };
        } catch {
          return {
            handled: true,
            reply: text("模型切换失败；请稍后发送 /model status 检查。"),
          };
        }
      },
      { eligibleTriggers: ["user"], priority: 100 },
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
