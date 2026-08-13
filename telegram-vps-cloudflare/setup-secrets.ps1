param()

$ErrorActionPreference = 'Stop'
$WorkerName = 'ejectors-telegram-vps-manager'
$WorkerUrl = 'https://ejectors-telegram-vps-manager.yan9jx-ejectors.workers.dev'
$Wrangler = Join-Path $PSScriptRoot 'node_modules\.bin\wrangler.cmd'

if (-not (Test-Path -LiteralPath $Wrangler)) {
    throw '未找到 Wrangler。请先在 telegram-vps-cloudflare 目录执行 pnpm install。'
}

function Convert-SecureToPlain([Security.SecureString]$Secure) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Get-DerivedSecret([string]$Token, [string]$Purpose) {
    $hmac = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Token))
    try {
        $bytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Purpose))
        -join ($bytes | ForEach-Object { $_.ToString('x2') })
    } finally {
        $hmac.Dispose()
    }
}

function Set-WorkerSecret([string]$Name, [string]$Value) {
    $Value | & $Wrangler secret put $Name --name $WorkerName | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "写入 Cloudflare Secret 失败：$Name" }
}

Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '独立 Cloudflare Telegram VPS 管家 - 安全配置' -ForegroundColor Cyan
Write-Host '不会修改 ejectors-vps-dashboard、网页、域名或路由。'
Write-Host '==================================================' -ForegroundColor Cyan

$BotSecure = Read-Host 'Telegram Bot Token（输入不显示）' -AsSecureString
$ChatId = (Read-Host 'Telegram Chat ID').Trim()
$DeepSeekSecure = Read-Host 'DeepSeek API Key（输入不显示）' -AsSecureString
$BotToken = Convert-SecureToPlain $BotSecure
$DeepSeekKey = Convert-SecureToPlain $DeepSeekSecure

if ([string]::IsNullOrWhiteSpace($BotToken) -or $BotToken -notmatch '^\d{6,12}:[A-Za-z0-9_-]{20,}$') {
    throw 'Bot Token 格式不正确。'
}
if ([string]::IsNullOrWhiteSpace($ChatId) -or $ChatId -notmatch '^-?\d+$') {
    throw 'Chat ID 格式不正确。'
}
if ([string]::IsNullOrWhiteSpace($DeepSeekKey)) {
    throw 'DeepSeek API Key 不能为空。'
}

$WebhookSecret = Get-DerivedSecret $BotToken 'ejectors-telegram-webhook-v1'
$AgentSecret = Get-DerivedSecret $BotToken 'ejectors-vps-agent-v1'

try {
    Set-WorkerSecret 'TELEGRAM_BOT_TOKEN' $BotToken
    Set-WorkerSecret 'TELEGRAM_CHAT_ID' $ChatId
    Set-WorkerSecret 'TELEGRAM_WEBHOOK_SECRET' $WebhookSecret
    Set-WorkerSecret 'DEEPSEEK_API_KEY' $DeepSeekKey
    Set-WorkerSecret 'VPS_AGENT_SECRET' $AgentSecret

    $health = Invoke-RestMethod -Uri "$WorkerUrl/health" -TimeoutSec 30
    if (-not $health.ok -or @($health.configured.PSObject.Properties.Value) -contains $false) {
        throw 'Worker 健康检查显示仍有 Secret 未配置。'
    }

    $me = Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$BotToken/getMe" -TimeoutSec 20
    if (-not $me.ok) { throw 'Telegram Bot Token 验证失败。' }

    $commands = @(
        @{ command = 'start'; description = '打开 VPS 控制面板' },
        @{ command = 'status'; description = '查看当前 VPS 状态' },
        @{ command = 'nodes'; description = '查看和切换 VPS' },
        @{ command = 'ai'; description = 'AI 模式与单次提问' },
        @{ command = 'balance'; description = '查看 DeepSeek 余额' },
        @{ command = 'brief'; description = '生成 AI 运维简报' },
        @{ command = 'clean'; description = '清理缓存' },
        @{ command = 'pause10'; description = '暂停告警 10 分钟' },
        @{ command = 'resume'; description = '恢复告警' }
    ) | ConvertTo-Json -Compress
    $setCommands = Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$BotToken/setMyCommands" -ContentType 'application/json' -Body (@{ commands = ($commands | ConvertFrom-Json) } | ConvertTo-Json -Depth 5)
    if (-not $setCommands.ok) { throw 'Telegram 命令菜单设置失败。' }

    $deepSeek = Invoke-RestMethod -Uri 'https://api.deepseek.com/user/balance' -Headers @{ Authorization = "Bearer $DeepSeekKey" } -TimeoutSec 20
    if ($null -eq $deepSeek.is_available) { throw 'DeepSeek API Key 验证失败。' }

    $install = 'curl -fsSL https://raw.githubusercontent.com/yan9jx/singbox-tool/main/cloudflare-telegram-vps-agent.sh -o /root/cloudflare-telegram-vps-agent.sh && chmod 700 /root/cloudflare-telegram-vps-agent.sh && bash /root/cloudflare-telegram-vps-agent.sh install'
    Set-Clipboard -Value $install
    Write-Host ''
    Write-Host '✅ Cloudflare Secrets、Telegram Bot 和 DeepSeek 均验证成功。' -ForegroundColor Green
    Write-Host 'VPS Agent 安装命令已复制到剪贴板：' -ForegroundColor Yellow
    Write-Host $install
    Write-Host ''
    Write-Host "安装时 Worker 地址填写：$WorkerUrl"
    Write-Host 'Agent 会从 VPS 现有 Bot Token 自动派生通信密钥，不需要再复制 Secret。'
    Write-Host '安装后先不要手工改网页；确认 Agent 在线后运行：bash /root/cloudflare-telegram-vps-agent.sh activate'
} finally {
    $BotToken = $null
    $DeepSeekKey = $null
    $WebhookSecret = $null
    $AgentSecret = $null
}

Read-Host '按回车关闭此窗口'
