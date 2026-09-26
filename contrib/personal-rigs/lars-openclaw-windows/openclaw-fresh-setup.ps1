#Requires -Version 5.1
<#
  OpenClaw fresh setup - native Windows + local Ollama + Telegram.

  Uses only OpenClaw's own owners, so update/doctor/restart keep working:
    - official installer (install.ps1) provisions a supported Node (24.16+/26.1+)
    - onboard writes gateway.mode=local, loopback bind, token auth and the Ollama model
    - onboard --install-daemon installs the native Scheduled Task (autostart at logon)
    - channels add writes channels.telegram.botToken (NOT "token") and enables it

  Interactive (regular PowerShell, not admin):
    .\openclaw-fresh-setup.ps1
    .\openclaw-fresh-setup.ps1 -Model qwen3.5:9b

  CI / dry run without Ollama:
    .\openclaw-fresh-setup.ps1 -SkipModel -NonInteractive -SkipDashboard -TelegramToken "123456789:AAAA..."
#>

param(
    [string]$Model = "gemma4",
    [string]$TelegramToken = "",
    [switch]$SkipModel,
    [switch]$NonInteractive,
    [switch]$SkipDashboard
)

$ErrorActionPreference = "Stop"

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "FEIL: $msg" -ForegroundColor Red; exit 1 }

function Invoke-Checked {
    param([string]$What, [scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) { Fail "$What feilet (exit $LASTEXITCODE)" }
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

function Test-Port([int]$Port) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect("127.0.0.1", $Port)
        $ok = $c.Connected
        $c.Close()
        return $ok
    } catch { return $false }
}

# --- 1) Ollama ---------------------------------------------------------------
if (-not $SkipModel) {
    Step "1) Sjekker Ollama og modellen '$Model'"
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        Fail "Ollama er ikke installert. Installer fra https://ollama.com/download og kjoer scriptet paa nytt."
    }
    if (-not (Test-Port 11434)) {
        Write-Host "Ollama svarer ikke paa 11434 - starter 'ollama serve'"
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
        Start-Sleep -Seconds 5
        if (-not (Test-Port 11434)) { Fail "Ollama svarer fortsatt ikke paa 127.0.0.1:11434." }
    }
    $installed = (ollama list) -join "`n"
    if ($installed -notmatch [regex]::Escape($Model)) {
        Write-Host "Modellen '$Model' mangler - laster ned (kan ta tid)"
        Invoke-Checked "ollama pull $Model" { ollama pull $Model }
    }
    Write-Host "Ollama OK. Merk: modellen maa stoette tools og minst 16K kontekst."
} else {
    Step "1) Hopper over Ollama/modell (-SkipModel)"
}

# --- 2) OpenClaw via offisiell installer ------------------------------------
Step "2) Installerer/oppdaterer OpenClaw med offisiell installer (inkl. riktig Node)"
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing https://openclaw.ai/install.ps1).Content)) -NoOnboard
Update-SessionPath
if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) {
    Fail "'openclaw' ble ikke funnet etter installasjon. Aapne en ny PowerShell og kjoer scriptet igjen."
}
Invoke-Checked "openclaw --version" { openclaw --version }

# --- 3) Onboarding: config + modell + native autostart ----------------------
Step "3) Onboarding (gateway.mode=local, loopback, token-auth, native Scheduled Task)"
$onboardArgs = @(
    "onboard", "--non-interactive", "--accept-risk",
    "--mode", "local",
    "--gateway-port", "18789",
    "--gateway-bind", "loopback",
    "--install-daemon"
)
if ($SkipModel) {
    $onboardArgs += @("--auth-choice", "skip")
} else {
    $onboardArgs += @("--auth-choice", "ollama", "--custom-model-id", $Model)
}
Invoke-Checked "openclaw onboard" { openclaw @onboardArgs }

# --- 4) Telegram --------------------------------------------------------------
if (-not $TelegramToken -and -not $NonInteractive) {
    $TelegramToken = Read-Host "Lim inn Telegram bot-token fra @BotFather (Enter for aa hoppe over)"
}
if ($TelegramToken) {
    Step "4) Kobler Telegram (skriver channels.telegram.botToken)"
    Invoke-Checked "openclaw channels add" { openclaw channels add --channel telegram --token $TelegramToken }
} else {
    Step "4) Hopper over Telegram (ingen token oppgitt)"
}

# --- 5) Verifisering ----------------------------------------------------------
Step "5) Verifiserer"
openclaw gateway status --json
openclaw doctor
if ($TelegramToken) { openclaw channels status --probe }

if (-not $SkipDashboard) {
    openclaw dashboard
}

Write-Host "`n=== Ferdig ===" -ForegroundColor Green
if ($TelegramToken) {
    Write-Host "Siste steg for Telegram: send en melding til boten, deretter:"
    Write-Host "  openclaw pairing list telegram"
    Write-Host "  openclaw pairing approve telegram <KODE>   (koden utloeper etter 1 time)"
}
