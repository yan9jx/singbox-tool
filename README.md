# File Browser VPS 一键安装脚本

在 Linux VPS 上一键安装 File Browser，并自动配置独立端口的 Nginx HTTPS 反向代理和上传限制。

## 功能

- 支持 Debian、Ubuntu、CentOS、Rocky Linux、AlmaLinux
- 交互输入域名、上传限制、管理员账号和存储目录
- File Browser 仅监听 `127.0.0.1:8080`
- 新安装优先使用 `127.0.0.1:8080`，若被占用则自动选择 `8081-8999` 中的空闲端口
- 自动配置 Nginx HTTPS 反向代理
- HTTPS 优先使用 `8443`，被占用时自动选择 `8444-8499` 中的空闲端口
- 始终保留 `443` 给 sing-box 等节点服务
- 复用已有 Let's Encrypt 证书；没有证书时通过 `80` 临时完成 ACME 验证
- 自动配置 UFW、Firewalld 和 SELinux
- 使用隔离的 File Browser Nginx，不修改系统现有 Nginx 配置
- 不检测、不开放、不占用 `443` 端口
- 重复安装时自动备份并禁用当前域名的旧 File Browser `443` Nginx 配置
- 重复安装时自动备份并禁用当前域名的旧 File Browser HTTP Nginx 配置
- 保留已有 Let's Encrypt 证书文件，不删除证书
- 不删除或覆盖其他 Nginx 站点配置
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

先将域名 A/AAAA 记录解析到 VPS。放行 TCP `8443-8499`；首次申请证书时还需要放行 `80`。脚本不会占用 `443`。

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

# 登录失败时重建管理员账号（将 yangjx 和新密码按需替换）
sudo systemctl stop filebrowser
sudo filebrowser users rm yangjx --database /etc/filebrowser/filebrowser.db
sudo filebrowser users add yangjx 'FbReset2026Pass' --perm.admin --database /etc/filebrowser/filebrowser.db
sudo systemctl start filebrowser

# 返回 200 表示账号密码正确
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  -H 'Content-Type: application/json' \
  --data '{"username":"yangjx","password":"FbReset2026Pass"}' \
  http://127.0.0.1:8080/api/login

# 检查并重载 Nginx
nginx -t && systemctl reload nginx
```

File Browser 以 root 身份运行，以便管理所选存储目录。安装完成后请及时修改管理员密码。

## 旧文件看不见时恢复根目录

文件存放在磁盘目录中，不在 File Browser 数据库里。先查看当前和备份数据库记录的根目录：

```bash
sudo filebrowser config cat --database /etc/filebrowser/filebrowser.db | grep -i root

for db in /etc/filebrowser/filebrowser.db.bak.*; do
  echo "=== $db ==="
  sudo filebrowser config cat --database "$db" | grep -i root
done
```

如果出现 `Error: timeout`，先停止服务再读取数据库：

```bash
sudo systemctl stop filebrowser
sudo filebrowser config cat --database /etc/filebrowser/filebrowser.db
sudo systemctl start filebrowser
```

找到旧根目录后恢复，例如旧目录为 `/旧目录`：

```bash
sudo systemctl stop filebrowser
sudo filebrowser config set --root /旧目录 --database /etc/filebrowser/filebrowser.db
sudo systemctl start filebrowser
```
