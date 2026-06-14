# File Browser VPS 一键安装脚本

在 Linux VPS 上一键安装 File Browser，并自动配置 Nginx 反向代理、上传限制和 HTTPS。

## 功能

- 支持 Debian、Ubuntu、CentOS、Rocky Linux、AlmaLinux
- 交互输入域名、上传限制、管理员账号和存储目录
- File Browser 仅监听 `127.0.0.1:8080`
- 自动配置 Nginx 反向代理
- 可选申请 Let's Encrypt HTTPS 证书
- 自动配置 UFW、Firewalld 和 SELinux
- 随机生成管理员密码，并在安装结束时显示
- 凭据保存至仅 root 可读的 `/root/filebrowser-credentials.txt`

## 上传至 GitHub

创建一个公开 GitHub 仓库，将本仓库中的以下文件上传到默认分支：

```text
install.sh
README.md
LICENSE
```

假设 GitHub 用户名为 `YOUR_GITHUB_NAME`，仓库名为 `filebrowser-installer`，安装脚本 Raw 地址为：

```text
https://raw.githubusercontent.com/YOUR_GITHUB_NAME/filebrowser-installer/main/install.sh
```

## 一键安装

先将域名 A/AAAA 记录解析到 VPS，并放行 TCP `80`、`443` 端口。

将命令中的 `YOUR_GITHUB_NAME` 替换为你的 GitHub 用户名，然后使用 root 用户运行：

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_NAME/filebrowser-installer/main/install.sh -o /tmp/install-filebrowser.sh && sudo bash /tmp/install-filebrowser.sh
```

脚本需要交互输入，因此不要使用 `curl ... | bash`。

## 常用命令

```bash
# 查看服务状态
systemctl status filebrowser

# 查看实时日志
journalctl -u filebrowser -f

# 重启服务
systemctl restart filebrowser

# 查看安装时生成的凭据
sudo cat /root/filebrowser-credentials.txt

# 检查并重载 Nginx
nginx -t && systemctl reload nginx
```

File Browser 以 root 身份运行，以便管理所选存储目录。安装完成后请及时修改管理员密码。
