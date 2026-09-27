# Lars' OpenClaw Windows rig (personal, not shipped product)

Personal setup for OpenClaw on native Windows 11 with a local Ollama model and a
Telegram bot. It lives under `contrib/personal-rigs/` so it never mixes with
product source. It only calls OpenClaw's own commands, so `openclaw update`,
`openclaw doctor` and `openclaw gateway restart` keep full control.

## Usage

Have a new bot token from `@BotFather` ready, then in regular PowerShell (not admin):

```powershell
# Bypass is needed because Windows 11 blocks local .ps1 files by default.
powershell -ExecutionPolicy Bypass -File .\openclaw-fresh-setup.ps1                  # default model: gemma4
powershell -ExecutionPolicy Bypass -File .\openclaw-fresh-setup.ps1 -Model qwen3.5:9b
```

Paste the bot token when asked, then send the bot any message in Telegram. The
script approves that first pairing itself. Re-running the script is safe: it
updates OpenClaw and leaves the setup it created alone.

## What the script does

0. Removes the old hand-made rig if it finds one: uninstalls the old Gateway
   service, removes Scheduled Tasks that launch `LocalCRM`/`openclaw` scripts
   (asks for administrator once if needed), and renames `C:\LocalCRM` and
   `~\.openclaw` to `*.backup-<timestamp>`. Nothing is deleted.
1. Installs Ollama with winget if missing, checks it answers on
   `127.0.0.1:11434`, and pulls the model if missing.
2. Installs or updates OpenClaw with the official `install.ps1 -NoOnboard`,
   which also installs a supported Node (24.16+ or 26.1+).
3. `openclaw onboard --non-interactive --mode local --auth-choice ollama
   --workspace Documents\OpenClaw --install-daemon`: writes `gateway.mode=local`,
   loopback bind, token auth, the Ollama model and the agent workspace, and
   installs the native Scheduled Task (autostart at logon).
4. Locks the agent to its folder: `tools.fs.workspaceOnly=true` and
   `tools.exec.mode=ask`.
5. `openclaw channels add --channel telegram --token <token>`, then waits up to
   5 minutes for your first message and runs `openclaw pairing approve … --notify`.
   The first approved pairing becomes the command owner, so you can approve
   shell commands from Telegram.
6. Verifies with `gateway status`, `doctor` and `channels status --probe`.

## Folder access

The agent only sees `Documents\OpenClaw`. Copy in what it should work on.

- OpenClaw can confine file tools to exactly one folder (`tools.fs.workspaceOnly`).
  It has no list of extra allowed folders, and links (junctions/symlinks) that
  point outside the workspace are rejected, so other Documents folders cannot be
  linked in.
- `workspaceOnly` does not cover shell commands. They run only after you approve
  them (`tools.exec.mode=ask`), in Telegram or the dashboard.
- If Documents is synced by OneDrive, the workspace syncs too.

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
| `.ps1` refuses to run | Windows 11 execution policy `Restricted` blocks local scripts | Run with `powershell -ExecutionPolicy Bypass -File …` |

Found by the Windows VM CI while building this rig (fixed in the script):

| Symptom | Cause | Fix |
| --- | --- | --- |
| Installer step fails with `Unexpected token '32'` | `openclaw.ai/install.ps1` is served as `application/octet-stream`, so PowerShell 7 returns `.Content` as `byte[]` | Decode the bytes to UTF-8 text before `[scriptblock]::Create` |
| Onboarding refuses with `unsupported Node (22.x)` | Rebuilding `$env:Path` from the registry dropped the supported Node the installer had put on the process PATH | Don't touch PATH; the installer updates the process PATH itself |

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
