# 独立 Cloudflare Telegram VPS 管家

这是 `universe-vps-manager-v4.36.sh` 的 Cloudflare Webhook 后端。它使用独立 Worker
`ejectors-telegram-vps-manager`，不会绑定或修改现有 `ejectors-vps-dashboard`、状态网页、域名或路由。

## 功能

- Telegram `/ai on`、`/ai off`、单次 `/ai 问题` 和连续上下文
- DeepSeek 余额 `/balance`
- `/model` 查看当前模型；`/models` 从 DeepSeek 读取最新列表并通过二次确认切换
- 模型切换保存在 Cloudflare Durable Object；新模型不兼容时自动退回切换前模型
- VPS 状态、只读诊断、缓存清理、告警暂停/恢复
- 原控制面板按钮与重启流程
- 所有重启操作必须通过 2 分钟二次确认按钮；只读诊断可直接执行
- `/thresholds` 读取 VPS 实际告警阈值；`/latency` 通过 `cp.cloudflare.com` 测试 VPS 到 Cloudflare 的延迟
- `/speedtest` 下载 Cloudflare 100 MB 测试文件并计算 VPS 下载速度；执行前需要二次确认
- 多 VPS `/nodes`、`/use 节点ID`
- Cloudflare 每小时状态播报，以及资源、服务、端口和离线上报告警（不调用 DeepSeek）
- 北京时间 09:00 每日 AI 运维简报
- 北京时间每周日 04:00 自动清理在线 VPS 缓存
- 公开网页检索工具（DuckDuckGo Instant Answer）

## 安全迁移顺序

1. 部署这个独立 Worker，但先不要设置 Telegram Webhook。
2. 在 Windows 运行 `setup-secrets.ps1`，用隐藏输入写入 Worker Secrets。
3. 在每台 VPS 安装 `cloudflare-telegram-vps-agent.sh`，确认 Worker `/health` 显示在线节点。
4. 在 VPS 运行 `bash /root/cloudflare-telegram-vps-agent.sh activate`。脚本会先预检，再设置 Webhook并停止旧 `getUpdates` 服务。

`activate` 会停止本地 Telegram 长轮询、整点播报、本地异常告警和本地 AI 简报。Universe VPS Manager 仍保留，用于状态采集、流量累计、原自动重启及安全命令执行；节点服务和反向代理不受影响。脚本只为本地 `send_message` 增加可回退的静默保护，`deactivate` 会恢复原文件。回退时运行：

```bash
bash /root/cloudflare-telegram-vps-agent.sh deactivate
```

已安装旧版 Agent 时，可无交互升级：

```bash
bash /root/cloudflare-telegram-vps-agent.sh upgrade
```

## Worker Secrets

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`
- `TELEGRAM_WEBHOOK_SECRET`
- `DEEPSEEK_API_KEY`
- `VPS_AGENT_SECRET`

后两个通信 Secret 由配置脚本基于 Bot Token 使用 HMAC-SHA256 分域派生；不会写入 Git、Wrangler 配置或网页。
