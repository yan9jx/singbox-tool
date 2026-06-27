# Ejectors VPS 状态面板

部署在 Cloudflare Worker + Durable Objects 的私人 VPS 状态首页。域名、云盘入口和两组密钥均由部署者自行配置。

## 状态规则

- 正常：150 秒内收到心跳，且已安装的监控服务均正常。
- 异常：心跳正常，但检测到已安装的 xray、sing-box 或 filebrowser 停止。
- 离线：超过 150 秒没有心跳，保留最后一次资源数据。
- 已关机：systemd 在正常关机/重启时主动上报；重新开机并收到心跳后恢复正常。
- IP/端口被墙：单台 VPS 无法从服务器内部准确判断，当前显示为待外部探针；后续可接入中国大陆探针。

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
