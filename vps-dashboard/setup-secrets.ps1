$ErrorActionPreference = "Stop"

function Read-RequiredSecret {
    param([Parameter(Mandatory)][string]$Prompt)

    $secure = Read-Host $Prompt -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Prompt cannot be empty."
    }
    return $value
}

function Set-WorkerSecret {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$WranglerPath
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $NodePath
    $startInfo.Arguments = "`"$WranglerPath`" secret put $Name"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $process.StandardInput.WriteLine($Value)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($stdout) { Write-Host $stdout.TrimEnd() }
    if ($stderr) { Write-Host $stderr.TrimEnd() }
    if ($process.ExitCode -ne 0) {
        throw "Failed to save $Name."
    }
}

$wrangler = Join-Path $PSScriptRoot "node_modules\wrangler\bin\wrangler.js"
if (-not (Test-Path -LiteralPath $wrangler)) {
    throw "Wrangler was not found. Run pnpm install in this project first."
}

$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
$nodeCandidates = @(
    (Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"),
    (Join-Path $env:ProgramFiles "nodejs\node.exe"),
    $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "nodejs\node.exe" }),
    $(if ($nodeCommand) { $nodeCommand.Source })
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

if (-not $nodeCandidates) {
    throw "Node.js was not found. Install Node.js or add node.exe to PATH."
}
$node = @($nodeCandidates)[0]

$localConfigPath = Join-Path $PSScriptRoot ".dashboard-secrets.local.json"
$localConfig = $null
if (Test-Path -LiteralPath $localConfigPath) {
    try {
        $localConfig = Get-Content -LiteralPath $localConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "The local private configuration file is invalid: $localConfigPath"
    }
}

$cloudflareToken = if ($localConfig.cloudflare_api_token) { $localConfig.cloudflare_api_token } else { Read-RequiredSecret "Cloudflare API Token" }
$accountId = if ($localConfig.cloudflare_account_id) { $localConfig.cloudflare_account_id } else { Read-Host "Cloudflare Account ID" }
$viewToken = if ($localConfig.view_token) { $localConfig.view_token } else { Read-RequiredSecret "Dashboard view password" }
$ingestToken = if ($localConfig.ingest_token) { $localConfig.ingest_token } else { Read-RequiredSecret "VPS ingest token" }
$telegramBotToken = if ($localConfig.telegram_bot_token) { $localConfig.telegram_bot_token } else { Read-RequiredSecret "Telegram Bot Token" }
$telegramChatId = if ($localConfig.telegram_chat_id) { $localConfig.telegram_chat_id } else { Read-RequiredSecret "Telegram Chat ID" }

if ([string]::IsNullOrWhiteSpace($accountId)) {
    throw "Cloudflare Account ID cannot be empty."
}

$env:CLOUDFLARE_API_TOKEN = $cloudflareToken
$env:CLOUDFLARE_ACCOUNT_ID = $accountId

[ordered]@{
    cloudflare_api_token = $cloudflareToken
    cloudflare_account_id = $accountId
    view_token = $viewToken
    ingest_token = $ingestToken
    telegram_bot_token = $telegramBotToken
    telegram_chat_id = $telegramChatId
} | ConvertTo-Json | Set-Content -LiteralPath $localConfigPath -Encoding UTF8

try {
    Set-WorkerSecret -Name "VIEW_TOKEN" -Value $viewToken -NodePath $node -WranglerPath $wrangler
    Set-WorkerSecret -Name "INGEST_TOKEN" -Value $ingestToken -NodePath $node -WranglerPath $wrangler
    Set-WorkerSecret -Name "TELEGRAM_BOT_TOKEN" -Value $telegramBotToken -NodePath $node -WranglerPath $wrangler
    Set-WorkerSecret -Name "TELEGRAM_CHAT_ID" -Value $telegramChatId -NodePath $node -WranglerPath $wrangler

    Write-Host ""
    Write-Host "All secrets were saved to Cloudflare." -ForegroundColor Green
    Write-Host "A private local copy was saved to .dashboard-secrets.local.json for future reuse." -ForegroundColor Green
}
finally {
    $env:CLOUDFLARE_API_TOKEN = $null
    $cloudflareToken = $null
    $viewToken = $null
    $ingestToken = $null
    $telegramBotToken = $null
    $telegramChatId = $null
}
