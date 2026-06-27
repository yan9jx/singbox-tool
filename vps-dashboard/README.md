# Ejectors VPS 状态面板

部署在 Cloudflare Worker + Durable Objects 的私人 VPS 状态首页。域名、云盘入口和两组密钥均由部署者自行配置。

## 状态规则

- 正常：150 秒内收到心跳，且已安装的监控服务均正常。
- 异常：心跳正常，但检测到已安装的 xray、sing-box 或 filebrowser 停止。
- 离线：超过 150 秒没有心跳，保留最后一次资源数据。
- 已关机：systemd 在正常关机/重启时主动上报；重新开机并收到心跳后恢复正常。
- IP/端口被墙：单台 VPS 无法从服务器内部准确判断，当前显示为待外部探针；后续可接入中国大陆探针。

## 到期与备忘提醒

- 在节点卡片点击“到期与备忘”，可设置到期日期、备忘录和一次性提醒时间。
- 到期倒计时会直接显示在节点卡片。
- 启用 Telegram 后，会在到期前 30、7、3、1 天以及到期当天通知；单次备忘到点通知一次。
- Telegram 凭据必须配置为 Worker Secret，不能写入代码或上传 GitHub：

```bash
npx wrangler secret put TELEGRAM_BOT_TOKEN
npx wrangler secret put TELEGRAM_CHAT_ID
```

- Windows 可直接运行 `.\setup-secrets.ps1`。脚本会自动复用 `.dashboard-secrets.local.json` 中已有的本机私密配置，只询问缺少的项目；敏感输入不回显，成功后保存到该 Git 忽略文件供以后复用，不写入公开脚本。
- 定时检查使用 Cloudflare Cron Trigger，每 5 分钟执行一次；整个项目只使用 Workers Free 可用能力。

## VPS 安装

```bash
curl -fsSL https://status.example.com/agent.sh -o /tmp/ejectors-agent.sh
sudo bash /tmp/ejectors-agent.sh
```

卸载：

```bash
sudo bash /tmp/ejectors-agent.sh uninstall
```

查看服务：

```bash
systemctl status ejectors-vps-agent --no-pager
journalctl -u ejectors-vps-agent -n 50 --no-pager
```

配置保存在 `/etc/ejectors-vps-agent.conf`，权限为 `600`。
