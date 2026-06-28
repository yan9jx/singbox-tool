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
- 启用 Telegram 后，会在到期前 30、7、3、1 天以及到期当天通知；普通提醒可统一设置每 N 分钟、共 N 次。
- VPS 单次提醒可选持续截止时间；填写后从开始时间起每小时提醒一次，到截止时间或清除提醒为止。
- Telegram 凭据必须配置为 Worker Secret，不能写入代码或上传 GitHub：

```bash
npx wrangler secret put TELEGRAM_BOT_TOKEN
npx wrangler secret put TELEGRAM_CHAT_ID
```

- Windows 可直接运行 `.\setup-secrets.ps1`。脚本会自动复用 `.dashboard-secrets.local.json` 中已有的本机私密配置，只询问缺少的项目；敏感输入不回显，成功后保存到该 Git 忽略文件供以后复用，不写入公开脚本。
- 定时检查使用 Cloudflare Cron Trigger，每 1 分钟执行一次，以支持最短 1 分钟的重复间隔；整个项目只使用 Workers Free 可用能力。

## 全局备忘

- 首页“全局备忘”可创建不关联 VPS 的提醒事项，名称、内容和时间均可编辑。
- 支持单次、每天、每周、每月、每年、自选每 N 个月，以及开始至结束时间内每小时持续提醒；可暂停、重新启用或删除。
- 单次提醒发送后自动标记完成，循环提醒会按计划继续执行。
- 全局备忘标题旁提供独立的 Telegram 测试按钮，可随时确认推送连接。

## 离线节点清理

- 离线或已关机的节点卡片会出现“删除”按钮；在线节点前端不显示按钮，后端也会拒绝删除。
- “离线自动清理”可选择关闭、7 天、30 天或 90 天，默认关闭。
- 自动清理按最后上报时间计算，并由现有 Cron 定时执行，不增加 Cloudflare 付费项目。

## 节点管理

- 点击节点名称可打开独立的“节点信息”窗口，修改显示名称、服务商、地区、用途、分组和维护时间。
- 节点卡片支持拖动排序；分组内按保存的顺序显示。
- 可设置维护结束时间。维护期间节点显示“维护中”，并暂停该节点由面板发送的 Telegram 提醒。
- 卡片会显示 Agent 版本；低于面板当前版本时提示更新。

## 配置备份

- “导出配置”下载 JSON，包含节点展示设置、分组排序、维护时间、到期与备忘、全局提醒和自动清理设置。
- 备份不包含查看密码、上报密钥、Cloudflare API Token、Telegram Token，也不包含实时 CPU、RAM 和流量数据。
- “恢复配置”只恢复当前已上报节点的设置；尚不存在的节点会跳过，等该 VPS 上报后可再次导入。

## 安全保护

- 所有查看接口按来源 IP 统计失败次数：10 分钟内连续输错 5 次，锁定 10 分钟。
- Agent 心跳和关机上报继续使用独立上报密钥，不受查看密码限速影响。
- 静态页面启用 CSP、禁止 iframe 嵌套、MIME 嗅探、外部引用和搜索引擎收录等安全响应头。

## VPS 安装

```bash
curl -fsSL https://status.example.com/agent.sh -o /tmp/ejectors-agent.sh
sudo bash /tmp/ejectors-agent.sh
```

已安装旧版 Agent 的 VPS 重新运行一次上述安装命令即可升级并安装自动更新定时器；现有配置会自动复用，不再重复询问。此后每天北京时间 04:00 检查 GitHub，仅在远程版本较新时更新并重启 Agent。

查看自动更新时间：

```bash
systemctl list-timers ejectors-vps-agent-update.timer --no-pager
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
