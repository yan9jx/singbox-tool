param()

$ErrorActionPreference = 'Stop'
$ResumeAfterSecretUpload = @($args) -contains 'resume'
$WorkerName = 'ejectors-telegram-vps-manager'
$WorkerUrl = 'https://ejectors-telegram-vps-manager.yan9jx-ejectors.workers.dev'
$Wrangler = Join-Path $PSScriptRoot 'node_modules\.bin\wrangler.cmd'

if (-not (Test-Path -LiteralPath $Wrangler)) {
    throw '未找到 Wrangler。请先在 telegram-vps-cloudflare 目录执行 pnpm install。'
}

$NodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
$Node = if ($NodeCommand) { $NodeCommand.Source } else { $null }
if (-not $Node) {
    $BundledNode = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
    if (Test-Path -LiteralPath $BundledNode) { $Node = $BundledNode }
}
if (-not $Node) {
    throw '未找到 Node.js。请安装 Node.js 22 或从 Codex 环境运行此脚本。'
}
$NodeDirectory = Split-Path -Parent $Node
if (-not (($env:PATH -split ';') -contains $NodeDirectory)) {
    $env:PATH = "$NodeDirectory;$env:PATH"
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
    $Value | & $Wrangler secret put $Name --name $WorkerName --install-skills=false | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "写入 Cloudflare Secret 失败：$Name" }
}

function Test-CloudflareLogin {
    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $WhoAmIOutput = @(& $Wrangler whoami --install-skills=false 2>&1)
        $WhoAmIExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    $WhoAmIText = $WhoAmIOutput | Out-String
    return ($WhoAmIExitCode -eq 0 -and $WhoAmIText -notmatch '(?i)not authenticated|not logged in')
}

Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '独立 Cloudflare Telegram VPS 管家 - 安全配置' -ForegroundColor Cyan
Write-Host '不会修改 ejectors-vps-dashboard、网页、域名或路由。'
Write-Host '==================================================' -ForegroundColor Cyan

Write-Host '正在检查 Cloudflare 登录状态...' -ForegroundColor Yellow
$LoggedIn = Test-CloudflareLogin
if (-not $LoggedIn) {
    Write-Host '尚未登录 Cloudflare，即将打开浏览器授权。授权完成后返回此窗口。' -ForegroundColor Yellow
    & $Wrangler login --install-skills=false
    if ($LASTEXITCODE -ne 0) { throw 'Cloudflare 登录失败。' }
    if (-not (Test-CloudflareLogin)) { throw 'Cloudflare 登录状态验证失败。' }
}
Write-Host 'Cloudflare 登录状态正常。' -ForegroundColor Green

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
    if ($ResumeAfterSecretUpload) {
        Write-Host '续跑模式：保留现有 Cloudflare Secrets，不重复上传。' -ForegroundColor Yellow
    } else {
        Set-WorkerSecret 'TELEGRAM_BOT_TOKEN' $BotToken
        Set-WorkerSecret 'TELEGRAM_CHAT_ID' $ChatId
        Set-WorkerSecret 'TELEGRAM_WEBHOOK_SECRET' $WebhookSecret
        Set-WorkerSecret 'DEEPSEEK_API_KEY' $DeepSeekKey
        Set-WorkerSecret 'VPS_AGENT_SECRET' $AgentSecret
    }

    # Wrangler 每次写入 Secret 都会创建新 Worker 版本，边缘节点可能需要短暂时间完成传播。
    $health = $null
    foreach ($attempt in 1..12) {
        $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $health = Invoke-RestMethod -Uri "$WorkerUrl/health?ts=$cacheBust" -TimeoutSec 30
        if ($health.ok -and -not (@($health.configured.PSObject.Properties.Value) -contains $false)) { break }
        if ($attempt -lt 12) {
            Write-Host "等待 Cloudflare Secret 生效（$attempt/12）..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }
    if (-not $health.ok -or @($health.configured.PSObject.Properties.Value) -contains $false) {
        throw 'Worker 健康检查显示仍有 Secret 未配置。'
    }

    $me = Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$BotToken/getMe" -TimeoutSec 20
    if (-not $me.ok) { throw 'Telegram Bot Token 验证失败。' }

    $commands = @(
        @{ command = 'start'; description = '打开 VPS 控制面板' },
        @{ command = 'status'; description = '查看当前 VPS 状态' },
        @{ command = 'thresholds'; description = '查看真实告警阈值' },
        @{ command = 'latency'; description = '测试 VPS 网络延迟' },
        @{ command = 'nodes'; description = '查看和切换 VPS' },
        @{ command = 'ai'; description = 'AI 模式与单次提问' },
        @{ command = 'balance'; description = '查看 DeepSeek 余额' },
        @{ command = 'models'; description = '刷新并选择 DeepSeek 模型' },
        @{ command = 'model'; description = '查看当前 DeepSeek 模型' },
        @{ command = 'brief'; description = '生成 AI 运维简报' },
        @{ command = 'pause10'; description = '暂停告警 10 分钟' },
        @{ command = 'resume'; description = '恢复告警' }
    )
    $commandsBody = ConvertTo-Json -InputObject @{ commands = $commands } -Depth 5 -Compress
    if ($commandsBody -notmatch '^\{"commands":\[') { throw 'Telegram 命令菜单 JSON 生成失败。' }
    $commandsBodyBytes = [Text.Encoding]::UTF8.GetBytes($commandsBody)
    $setCommands = Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$BotToken/setMyCommands" -ContentType 'application/json; charset=utf-8' -Body $commandsBodyBytes
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
