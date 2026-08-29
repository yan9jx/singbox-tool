[CmdletBinding()]
param(
  [string]$HostName = "43.128.229.27",
  [string]$UserName = "ubuntu",
  [string]$IdentityFile = "D:\key\WeChat_AI.pem",
  [string]$DestinationRoot = "D:\360MoveData\Users\yjxv\Desktop\VPS\GitHub脚本本地备份\OpenClaw",
  [switch]$Consistent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) {
  throw "找不到 SSH 私钥：$IdentityFile"
}

$ssh = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
$scp = Join-Path $env:WINDIR "System32\OpenSSH\scp.exe"
if (-not (Test-Path -LiteralPath $ssh) -or -not (Test-Path -LiteralPath $scp)) {
  throw "找不到 Windows OpenSSH 的 ssh.exe 或 scp.exe。"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$archiveName = "openclaw-backup-$stamp.tgz"
$remoteStage = "/home/$UserName/.openclaw-transfer-$archiveName"
$localArchive = Join-Path $DestinationRoot $archiveName
$remoteTarget = "$UserName@$HostName"
$mode = if ($Consistent) { "consistent" } else { "hot" }
New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
$knownHosts = Join-Path $DestinationRoot "ssh_known_hosts"
$sshOptions = @("-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=$knownHosts", "-o", "ConnectTimeout=15")

$remoteScript = @"
set -Eeuo pipefail
umask 077
archive_name='$archiveName'
transfer_path='$remoteStage'
backup_dir='/root/.openclaw/backups/manual'
stage=`$(mktemp -d /root/.openclaw/.backup-stage.XXXXXX)
stopped=0
cleanup() {
  rm -rf "`$stage"
  if [ "`$stopped" = 1 ]; then systemctl start openclaw-gateway.service; fi
}
trap cleanup EXIT
if [ '$mode' = 'consistent' ]; then
  systemctl stop openclaw-gateway.service
  stopped=1
fi
mkdir -p "`$backup_dir" "`$stage/root/.config" "`$stage/opt" "`$stage/usr/local/sbin" "`$(dirname "`$transfer_path")"
tar -C /root \
  --exclude='.openclaw/backups' \
  --exclude='.openclaw/.backup-stage*' \
  -cf - .openclaw | tar -C "`$stage/root" -xf -
if [ -d /root/.config/rclone ]; then
  cp -a /root/.config/rclone "`$stage/root/.config/"
fi
for path in /opt/openclaw-wechat-ai-provider-admin /opt/openclaw-searxng; do
  if [ -e "`$path" ]; then cp -a "`$path" "`$stage/opt/"; fi
done
for path in /root/install-wechat-ai-root.sh /root/install-wechat-ai-provider-admin.sh /root/install-openclaw-searxng.sh /root/install-openclaw-long-memory.sh /root/install-openclaw-operations.sh /root/configure-openclaw-onedrive-backup.sh; do
  if [ -f "`$path" ]; then cp -a "`$path" "`$stage/root/"; fi
done
find /usr/local/sbin -maxdepth 1 -type f -name 'openclaw-*' -exec cp -a {} "`$stage/usr/local/sbin/" \;
if [ -f /etc/systemd/system/openclaw-gateway.service ]; then
  mkdir -p "`$stage/etc/systemd/system"
  cp -a /etc/systemd/system/openclaw-gateway.service "`$stage/etc/systemd/system/"
fi
if [ -d /etc/systemd/system/openclaw-gateway.service.d ]; then
  mkdir -p "`$stage/etc/systemd/system"
  cp -a /etc/systemd/system/openclaw-gateway.service.d "`$stage/etc/systemd/system/"
fi
tar -C "`$stage" -czf "`$backup_dir/`$archive_name" root opt etc usr
sha256sum "`$backup_dir/`$archive_name" > "`$backup_dir/`$archive_name.sha256"
install -m 600 -o '$UserName' -g '$UserName' "`$backup_dir/`$archive_name" "`$transfer_path"
sha256sum "`$backup_dir/`$archive_name"
"@

$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript))
$remoteCommand = "echo $encoded | base64 -d | sudo -n bash -s"

try {
  $remoteHashLine = & $ssh -i $IdentityFile @sshOptions $remoteTarget $remoteCommand
  if ($LASTEXITCODE -ne 0) { throw "VPS 打包失败。" }
  $remoteHash = ($remoteHashLine | Select-Object -Last 1).Split()[0]
  if ($remoteHash -notmatch '^[a-f0-9]{64}$') { throw "VPS 未返回有效 SHA-256。" }

  & $scp -i $IdentityFile @sshOptions "${remoteTarget}:$remoteStage" $localArchive
  if ($LASTEXITCODE -ne 0) { throw "下载备份失败。" }

  $localHash = (Get-FileHash -LiteralPath $localArchive -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($localHash -ne $remoteHash) {
    Remove-Item -LiteralPath $localArchive -Force -ErrorAction SilentlyContinue
    throw "SHA-256 不一致，已删除本地不完整备份。"
  }
  Write-Host "备份完成：$localArchive"
  Write-Host "SHA-256：$localHash"
  Write-Host "模式：$mode（consistent 会短暂停止并自动恢复 Gateway）"
}
finally {
  & $ssh -i $IdentityFile @sshOptions $remoteTarget "rm -f '$remoteStage'" 2>$null
}
