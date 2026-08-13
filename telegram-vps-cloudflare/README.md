# 独立 Cloudflare Telegram VPS 管家

这是 `universe-vps-manager-v4.36.sh` 的 Cloudflare Webhook 后端。它使用独立 Worker
`ejectors-telegram-vps-manager`，不会绑定或修改现有 `ejectors-vps-dashboard` 或状态网页。只有用户在 Telegram 二次确认 `/testsetup` 后，才会为直连 VPS 的现有共享 Caddy 域名增加一个隔离测试路径；原有路由不改写。

## 功能

- Telegram `/ai on`、`/ai off`、单次 `/ai 问题` 和连续上下文
- DeepSeek 余额 `/balance`
- `/model` 查看当前模型；`/models` 从 DeepSeek 读取最新列表并通过二次确认切换
- 模型切换保存在 Cloudflare Durable Object；新模型不兼容时自动退回切换前模型
- VPS 状态、只读诊断、缓存清理、告警暂停/恢复
- 原控制面板按钮与重启流程
- 所有重启操作必须通过 2 分钟二次确认按钮；只读诊断可直接执行
- `/thresholds` 读取 VPS 实际告警阈值
- `/latency` 或“测延迟”生成 10 分钟有效链接，由打开链接的手机/电脑实测该设备到 VPS 的 HTTPS 往返延迟
- `/speedtest` 或“测速”生成独立测速页；只有在页面点击开始后，当前设备才从 VPS 下载 100 MB 并将结果回传 Telegram
- `/testsetup` 为选中 VPS 安全增加独立 `/__ejectors-test/` 路由；必须二次确认、要求域名直连 VPS，并在 Caddy 校验失败时回滚。`/testdisable` 可安全停用
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

升级后，在 Telegram 发送 `/testsetup` 并点击确认。Agent 只会在同时满足以下条件时启用：共享 Caddy 存在独立路由导入点、域名为 DNS-only 并直接解析到该 VPS、本地测试服务健康、完整 Caddy 配置校验通过。任一条件失败都会拒绝或回滚。

入口启用后，每个 Telegram 手机或电脑都可以使用：

1. 在要测试的设备上发送“测延迟”或 `/latency`，点击 10 分钟有效的按钮。
2. 发送“测速”或 `/speedtest`，打开独立页面后再点击“开始下载 100 MB”。
3. 每条链接只能回报一次；要测试另一台设备，请重新发送一次命令生成新链接。

延迟探测和 100 MB 数据均由设备直接访问 VPS，不经过 Worker 传输；Cloudflare 只负责生成短时签名和接收一条小型结果消息，不调用 DeepSeek。

## Worker Secrets

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`
- `TELEGRAM_WEBHOOK_SECRET`
- `DEEPSEEK_API_KEY`
- `VPS_AGENT_SECRET`

后两个通信 Secret 由配置脚本基于 Bot Token 使用 HMAC-SHA256 分域派生；不会写入 Git、Wrangler 配置或网页。
