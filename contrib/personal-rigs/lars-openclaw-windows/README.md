# Lars' OpenClaw Windows rig (personal, not shipped product)

Personal setup for OpenClaw on native Windows 11 with a local Ollama model and a
Telegram bot. It lives under `contrib/personal-rigs/` so it never mixes with
product source. It only calls OpenClaw's own commands, so `openclaw update`,
`openclaw doctor` and `openclaw gateway restart` keep full control.

## Usage

Prerequisite: [Ollama for Windows](https://ollama.com/download) installed.

```powershell
# regular PowerShell, not admin. Bypass is needed because Windows 11 blocks
# local .ps1 files by default (execution policy "Restricted").
powershell -ExecutionPolicy Bypass -File .\openclaw-fresh-setup.ps1                  # default model: gemma4
powershell -ExecutionPolicy Bypass -File .\openclaw-fresh-setup.ps1 -Model qwen3.5:9b
```

Then send any message to the bot in Telegram and approve it:

```powershell
openclaw pairing list telegram
openclaw pairing approve telegram <CODE>
```

## What the script does

1. Checks Ollama answers on `127.0.0.1:11434` and pulls the model if missing.
2. Installs or updates OpenClaw with the official `install.ps1 -NoOnboard`,
   which also installs a supported Node (24.16+ or 26.1+).
3. `openclaw onboard --non-interactive --mode local --auth-choice ollama
   --install-daemon`: writes `gateway.mode=local`, loopback bind, token auth,
   the Ollama model, and installs the native Scheduled Task (autostart at logon).
4. `openclaw channels add --channel telegram --token <token>`.
5. Verifies with `gateway status`, `doctor` and `channels status --probe`.

## Root causes of the earlier friction

Verified against this repo's source and docs:

| Symptom | Cause | Fix |
| --- | --- | --- |
| Telegram never connects | Config used `channels.telegram.token`; the real key is `botToken`, and `enabled: true` is required | `openclaw channels add --channel telegram --token …` writes it correctly |
| Bot is connected but never answers | Default Telegram DM policy is `pairing`; the first DM needs approval | `openclaw pairing approve telegram <CODE>` |
| Gateway refuses to start | `gateway.mode` missing, or `bind` set to an IP | Onboarding writes both. Current versions also migrate `localhost` → `loopback` and `0.0.0.0` → `lan` automatically at startup |
| Crashes and odd errors | Node 22/23/25 is unsupported | Official installer provisions Node 24.16+/26.1+ |
| Update/restart fights the gateway | A self-started gateway or custom Scheduled Task is an unverified listener that native restart/update will not kill | Use only `--install-daemon` / `openclaw gateway install`; manage it with `openclaw gateway start/stop/restart` |
| Agent runs but gives no useful answers | Model lacks tool support or has under 16K context | Pick a tools-capable model, e.g. `gemma4` |
| Tool calls show up as raw JSON | Ollama `baseUrl` pointed at `/v1` | Use `http://127.0.0.1:11434` without `/v1` (onboarding does this) |

## Troubleshooting commands

```powershell
openclaw gateway status --json
openclaw doctor --fix
openclaw channels status --probe
openclaw models list --provider ollama
openclaw logs --follow
openclaw gateway restart
```

## CI

`.github/workflows/lars-openclaw-rig-test.yml` runs the script on a real
`windows-latest` GitHub Actions VM whenever this directory changes. It uses
`-SkipModel` (no Ollama on the runner) and a format-valid dummy Telegram token,
then checks that the native service is installed, the gateway listens on 18789,
and the config holds `gateway.mode=local`, `bind=loopback` and
`channels.telegram.botToken`. It does not prove real Ollama or Telegram traffic.
