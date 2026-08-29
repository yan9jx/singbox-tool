#!/usr/bin/env bash
# 为现有 onedrive-backup rclone 远端创建 OpenClaw 专用加密备份目录。
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash configure-openclaw-onedrive-backup.sh"
  exit 1
fi
for command in rclone openssl; do
  command -v "$command" >/dev/null 2>&1 || { echo "缺少 $command。"; exit 1; }
done
if ! rclone listremotes | grep -qx 'onedrive-backup:'; then
  echo "未找到 onedrive-backup，请先完成 OneDrive 授权。"
  exit 1
fi

base_remote='onedrive-backup:OpenClaw-Backups'
crypt_remote='onedrive-crypt'
rclone mkdir "$base_remote"
if ! rclone listremotes | grep -qx "${crypt_remote}:"; then
  pass_one=$(openssl rand -hex 32)
  pass_two=$(openssl rand -hex 32)
  obscured_one=$(rclone obscure "$pass_one")
  obscured_two=$(rclone obscure "$pass_two")
  unset pass_one pass_two
  rclone config create "$crypt_remote" crypt \
    remote="$base_remote" \
    filename_encryption=standard \
    directory_name_encryption=true \
    password="$obscured_one" \
    password2="$obscured_two" \
    --no-obscure
  unset obscured_one obscured_two
fi

rclone mkdir "${crypt_remote}:"
rclone lsd "${crypt_remote}:" >/dev/null
echo "OneDrive 加密备份目录已就绪：OpenClaw-Backups"
echo "加密配置保存在 /root/.config/rclone/rclone.conf，并会纳入桌面恢复备份；请勿上传或分享该文件。"
