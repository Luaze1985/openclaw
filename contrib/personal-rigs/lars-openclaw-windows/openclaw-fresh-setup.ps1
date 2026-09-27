#Requires -Version 5.1
<#
  OpenClaw fresh setup - native Windows + local Ollama + Telegram.

  Uses only OpenClaw's own owners, so update/doctor/restart keep working:
    - official installer (install.ps1) provisions a supported Node (24.16+/26.1+)
    - onboard writes gateway.mode=local, loopback bind, token auth and the Ollama model
    - onboard --install-daemon installs the native Scheduled Task (autostart at logon)
    - channels add writes channels.telegram.botToken (NOT "token") and enables it

  Also:
    - finds and removes the old hand-made rig (legacy Scheduled Tasks, C:\LocalCRM,
      old ~\.openclaw); folders are renamed to *.backup-<timestamp>, never deleted
    - installs Ollama with winget when it is missing
    - gives the agent exactly one folder, Documents\OpenClaw, with tools.fs.workspaceOnly
    - requires your approval for shell commands (tools.exec.mode=ask)
    - waits for your first Telegram message and approves the pairing itself

  Interactive (regular PowerShell, not admin):
    powershell -ExecutionPolicy Bypass -File .\openclaw-fresh-setup.ps1
    powershell -ExecutionPolicy Bypass -File .\openclaw-fresh-setup.ps1 -Model qwen3.5:9b

  CI / dry run without Ollama:
    .\openclaw-fresh-setup.ps1 -SkipModel -NonInteractive -SkipDashboard -TelegramToken "123456789:AAAA..."
#>

param(
    [string]$Model = "gemma4",
    [string]$TelegramToken = "",
    [switch]$SkipModel,
    [switch]$NonInteractive,
    [switch]$SkipDashboard,
    # Internal: elevated re-launch that only removes legacy Scheduled Tasks.
    [switch]$CleanupTasksOnly
)

$ErrorActionPreference = "Stop"

$NativeTaskName = "OpenClaw Gateway"
$RigStateDir    = Join-Path $env:LOCALAPPDATA "lars-openclaw-rig"
$RigMarker      = Join-Path $RigStateDir "installed.txt"
$StateDir       = Join-Path $env:USERPROFILE ".openclaw"
$LegacyRoot     = "C:\LocalCRM"
$Workspace      = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "OpenClaw"
$Stamp          = Get-Date -Format "yyyyMMdd-HHmmss"

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "FEIL: $msg" -ForegroundColor Red; exit 1 }

# Windows PowerShell 5.1 throws on redirected native stderr when ErrorActionPreference is Stop.
function Invoke-Quiet([scriptblock]$Command) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Command 2>$null } finally { $ErrorActionPreference = $previous }
}

# Old rigs registered their own tasks that launched LocalCRM scripts or openclaw directly.
# The native task is removed through `openclaw gateway uninstall` instead.
function Get-LegacyTasks {
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -ne $NativeTaskName -and (
            (($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join " ") -match "LocalCRM|openclaw" -or
            $_.TaskName -match "openclaw|localcrm"
        )
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($CleanupTasksOnly) {
    Get-LegacyTasks | ForEach-Object {
        Write-Host "Fjerner gammel oppgave: $($_.TaskName)"
        Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false
    }
    exit 0
}

function Invoke-Checked {
    param([string]$What, [scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) { Fail "$What feilet (exit $LASTEXITCODE)" }
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

# --- 0) Remove the old rig ----------------------------------------------------
# The marker is written only after a successful run of this script, so a re-run
# never backs up the config it created itself.
$legacyTasks = @(Get-LegacyTasks)
$hasOldState = (Test-Path $StateDir) -and -not (Test-Path $RigMarker)
if ($legacyTasks.Count -gt 0 -or (Test-Path $LegacyRoot) -or $hasOldState) {
    Step "0) Fjerner gammel rigg (mapper flyttes til backup, ingenting slettes)"

    if (Get-Command openclaw -ErrorAction SilentlyContinue) {
        Write-Host "Avinstallerer gammel gateway-tjeneste"
        Invoke-Quiet { openclaw gateway uninstall --json } | Out-Null
    }

    Get-NetTCPConnection -LocalPort 18789 -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Stopper prosess $($_.OwningProcess) som holder port 18789"
        Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
    }

    if ($legacyTasks.Count -gt 0) {
        if (Test-IsAdmin) {
            foreach ($t in $legacyTasks) {
                Write-Host "Fjerner gammel oppgave: $($t.TaskName)"
                Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false
            }
        } else {
            Write-Host "Gamle autostart-oppgaver trenger administrator. Godkjenn Windows-spoersmaalet som dukker opp."
            $hostExe = (Get-Process -Id $PID).Path
            Start-Process -FilePath $hostExe -Verb RunAs -Wait -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-CleanupTasksOnly"
            )
            $left = @(Get-LegacyTasks)
            if ($left.Count -gt 0) {
                Fail "Klarte ikke aa fjerne: $(($left.TaskName) -join ', '). Kjoer scriptet som administrator."
            }
        }
    }

    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Invoke-Quiet { npm uninstall -g openclaw } | Out-Null
    }

    foreach ($dir in @($StateDir, $LegacyRoot)) {
        if (Test-Path $dir) {
            $backup = "$dir.backup-$Stamp"
            Rename-Item -Path $dir -NewName (Split-Path $backup -Leaf)
            Write-Host "Flyttet $dir -> $backup"
        }
    }
} else {
    Step "0) Ingen gammel rigg funnet"
}

# --- 1) Ollama ---------------------------------------------------------------
if (-not $SkipModel) {
    Step "1) Sjekker Ollama og modellen '$Model'"
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Fail "Ollama mangler og winget finnes ikke. Installer fra https://ollama.com/download og kjoer scriptet paa nytt."
        }
        Write-Host "Installerer Ollama med winget"
        Invoke-Checked "winget install Ollama" {
            winget install --exact --id Ollama.Ollama --accept-package-agreements --accept-source-agreements --silent
        }
        $env:Path = "$env:Path;$env:LOCALAPPDATA\Programs\Ollama"
        if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
            Fail "Ollama ble installert, men 'ollama' finnes ikke i PATH ennaa. Aapne en ny PowerShell og kjoer scriptet igjen."
        }
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
# PowerShell 7 returns .Content as byte[] for this response; decode it before parsing.
$installer = (Invoke-WebRequest -UseBasicParsing https://openclaw.ai/install.ps1).Content
if ($installer -is [byte[]]) { $installer = [Text.Encoding]::UTF8.GetString($installer) }
# The installer runs in this process and puts its Node/npm directories on $env:Path itself.
& ([scriptblock]::Create($installer.TrimStart([char]0xFEFF))) -NoOnboard
if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) {
    Fail "'openclaw' ble ikke funnet etter installasjon. Aapne en ny PowerShell og kjoer scriptet igjen."
}
Invoke-Checked "openclaw --version" { openclaw --version }

# --- 3) Onboarding: config + modell + native autostart ----------------------
Step "3) Onboarding (gateway.mode=local, loopback, token-auth, native Scheduled Task)"
New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
$onboardArgs = @(
    "onboard", "--non-interactive", "--accept-risk",
    "--mode", "local",
    "--gateway-port", "18789",
    "--gateway-bind", "loopback",
    "--workspace", $Workspace,
    "--install-daemon"
)
if ($SkipModel) {
    $onboardArgs += @("--auth-choice", "skip")
} else {
    $onboardArgs += @("--auth-choice", "ollama", "--custom-model-id", $Model)
}
Invoke-Checked "openclaw onboard" { openclaw @onboardArgs }

Step "3b) Laaser agenten til $Workspace og krever godkjenning for shell-kommandoer"
# workspaceOnly confines read/write/edit/apply_patch to the workspace; links out of it are
# rejected. Shell commands are not covered by it, so they need approval (exec mode "ask").
Invoke-Checked "config set tools.fs.workspaceOnly" { openclaw config set tools.fs.workspaceOnly true }
Invoke-Checked "config set tools.exec.mode" { openclaw config set tools.exec.mode ask }

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

openclaw gateway restart
if ($LASTEXITCODE -ne 0) {
    Write-Host "Advarsel: 'gateway restart' meldte exit $LASTEXITCODE. Sjekk 'openclaw gateway status' hvis noe ikke virker." -ForegroundColor Yellow
}

# The first approved pairing also becomes the command owner, which lets you
# approve shell commands from Telegram.
$paired = $false
if ($TelegramToken -and -not $NonInteractive) {
    Step "4b) Kobler deg til boten"
    Write-Host "Aapne Telegram og send en melding (f.eks. 'hei') til den nye boten din. Venter i opptil 5 minutter ..."
    $deadline = (Get-Date).AddMinutes(5)
    while (-not $paired -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $raw = (Invoke-Quiet { openclaw pairing list telegram --json }) -join "`n"
        try { $pending = @((ConvertFrom-Json $raw).requests) } catch { continue }
        if ($pending.Count -gt 0) {
            $code = $pending[0].code
            Invoke-Checked "openclaw pairing approve" { openclaw pairing approve telegram $code --notify }
            $paired = $true
            Write-Host "Godkjent. Du er registrert som eier og kan godkjenne shell-kommandoer i Telegram." -ForegroundColor Green
        }
    }
    if (-not $paired) {
        Write-Host "Fikk ingen melding innen 5 minutter. Send en melding til boten og kjoer:" -ForegroundColor Yellow
        Write-Host "  openclaw pairing list telegram"
        Write-Host "  openclaw pairing approve telegram <KODE>"
    }
}

# --- 5) Verifisering ----------------------------------------------------------
Step "5) Verifiserer"
openclaw gateway status --json
if ($NonInteractive) { openclaw doctor --lint } else { openclaw doctor }
if ($TelegramToken) { openclaw channels status --probe }

New-Item -ItemType Directory -Force -Path $RigStateDir | Out-Null
Set-Content -Path $RigMarker -Value "installed $Stamp workspace=$Workspace" -Encoding UTF8

if (-not $SkipDashboard) {
    openclaw dashboard
}

Write-Host "`n=== Ferdig ===" -ForegroundColor Green
Write-Host "Agentens mappe: $Workspace  (legg det den skal jobbe med her)"
Write-Host "Shell-kommandoer maa godkjennes av deg i Telegram eller dashboardet."
