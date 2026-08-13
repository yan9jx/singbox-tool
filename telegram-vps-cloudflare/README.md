# 独立 Cloudflare Telegram VPS 管家

这是 `universe-vps-manager-v4.36.sh` 的 Cloudflare Webhook 后端。它使用独立 Worker
`ejectors-telegram-vps-manager`，不会绑定或修改现有 `ejectors-vps-dashboard`、状态网页、域名或路由。

## 功能

- Telegram `/ai on`、`/ai off`、单次 `/ai 问题` 和连续上下文
- DeepSeek 余额 `/balance`
- VPS 状态、只读诊断、缓存清理、告警暂停/恢复
- 原控制面板按钮与重启流程
- AI 发起的重启操作必须通过 2 分钟二次确认按钮
- 多 VPS `/nodes`、`/use 节点ID`
- 北京时间 09:00 每日 AI 运维简报
- 公开网页检索工具（DuckDuckGo Instant Answer）

## 安全迁移顺序

1. 部署这个独立 Worker，但先不要设置 Telegram Webhook。
2. 在 Windows 运行 `setup-secrets.ps1`，用隐藏输入写入 Worker Secrets。
3. 在每台 VPS 安装 `cloudflare-telegram-vps-agent.sh`，确认 Worker `/health` 显示在线节点。
4. 在 VPS 运行 `bash /root/cloudflare-telegram-vps-agent.sh activate`。脚本会先预检，再设置 Webhook并停止旧 `getUpdates` 服务。

`activate` 只停止 Telegram 长轮询服务。Universe VPS Manager 的监控 cron、告警发送、流量统计、节点服务和反向代理均保留。回退时运行：

```bash
bash /root/cloudflare-telegram-vps-agent.sh deactivate
```

## Worker Secrets

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`
- `TELEGRAM_WEBHOOK_SECRET`
- `DEEPSEEK_API_KEY`
- `VPS_AGENT_SECRET`

后两个通信 Secret 由配置脚本基于 Bot Token 使用 HMAC-SHA256 分域派生；不会写入 Git、Wrangler 配置或网页。
