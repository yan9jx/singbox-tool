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

$wrangler = Join-Path $PSScriptRoot "node_modules\.bin\wrangler.cmd"
if (-not (Test-Path -LiteralPath $wrangler)) {
    throw "Wrangler was not found. Run pnpm install in this project first."
}

$cloudflareToken = Read-RequiredSecret "Cloudflare API Token"
$accountId = Read-Host "Cloudflare Account ID"
if ([string]::IsNullOrWhiteSpace($accountId)) {
    throw "Cloudflare Account ID cannot be empty."
}

$viewToken = Read-RequiredSecret "Dashboard view password"
$ingestToken = Read-RequiredSecret "VPS ingest token"
$telegramBotToken = Read-RequiredSecret "Telegram Bot Token"
$telegramChatId = Read-RequiredSecret "Telegram Chat ID"

$env:CLOUDFLARE_API_TOKEN = $cloudflareToken
$env:CLOUDFLARE_ACCOUNT_ID = $accountId

try {
    $viewToken | & $wrangler secret put VIEW_TOKEN
    if ($LASTEXITCODE -ne 0) { throw "Failed to save VIEW_TOKEN." }

    $ingestToken | & $wrangler secret put INGEST_TOKEN
    if ($LASTEXITCODE -ne 0) { throw "Failed to save INGEST_TOKEN." }

    $telegramBotToken | & $wrangler secret put TELEGRAM_BOT_TOKEN
    if ($LASTEXITCODE -ne 0) { throw "Failed to save TELEGRAM_BOT_TOKEN." }

    $telegramChatId | & $wrangler secret put TELEGRAM_CHAT_ID
    if ($LASTEXITCODE -ne 0) { throw "Failed to save TELEGRAM_CHAT_ID." }

    Write-Host ""
    Write-Host "All secrets were saved to Cloudflare. No entered values were stored by this script." -ForegroundColor Green
}
finally {
    $env:CLOUDFLARE_API_TOKEN = $null
    $cloudflareToken = $null
    $viewToken = $null
    $ingestToken = $null
    $telegramBotToken = $null
    $telegramChatId = $null
}
