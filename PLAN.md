# Win11 AI Dev & Gaming Setup — Claude Code Plan

Oct 19, 2026 · @Tom

## Goal

Build `Setup-AIGamingRig.ps1`: one idempotent, re-runnable PowerShell 7 script that debloats a fresh Windows 11 install, installs a gaming stack (Steam, Epic Games Launcher, Amazon Games for Prime Gaming) and an AI dev stack (Chrome, VS Code, Git, GitHub CLI, Claude Code, Grok Bot), then tunes the machine for both.

How to use this plan: create an empty repo, export this doc as Markdown into it as `PLAN.md`, open Claude Code in that folder and paste the kickoff prompt from the last section. Claude Code builds phase by phase and stops for your review after each one.

Definition of done: on a clean Windows 11 24H2/25H2 VM, one elevated run finishes with zero errors, every app in the matrix launches, and a second run changes nothing.

## Guardrails

These are non-negotiable and go into the repo's `CLAUDE.md` so every session sees them.

- **Restore point first.** Create a System Restore point and export the registry keys the script will touch to `.\backup\<timestamp>\` before any change. Abort if either fails.
- **Dry run by default.** `-WhatIf` style `-DryRun` switch is the default; real changes need `-Apply`. Dry run prints every action it would take.
- **Never remove:** Microsoft Store, App Installer (winget), Windows Security/Defender, Windows Update, Edge WebView2 runtime, Xbox Identity Provider, Gaming Services, Xbox app (Game Pass + many PC titles need these), .NET and VC++ runtimes.
- **No third-party debloat scripts piped from the internet.** Every removal is an explicit, reviewed list in `config\debloat.psd1`. No `irm | iex` except the vendor installers named in the matrix.
- **Idempotent.** Each step checks state before acting (installed? already set?) and logs `SKIP` when nothing to do.
- **No Defender, UAC or SmartScreen disabling**, no hosts-file telemetry blocking, no service deletions. Services are set to Manual, never Disabled, unless listed.
- **Logged.** Transcript to `logs\setup-<timestamp>.log` plus a JSON summary of every action and result.
- **Reversible.** `Undo-AIGamingRig.ps1` re-applies the registry backup and lists removed Appx packages with their Store reinstall commands.

## Repo layout

One entry script orchestrates small modules; all lists live in data files so changes never touch logic.

```
ai-gaming-rig/
├─ CLAUDE.md                  # guardrails + conventions for Claude Code
├─ PLAN.md                    # this doc
├─ Setup-AIGamingRig.ps1      # entry: params, elevation, phase runner
├─ Undo-AIGamingRig.ps1
├─ config/
│  ├─ apps.psd1               # install matrix (id, source, fallback, verify cmd)
│  ├─ debloat.psd1            # Appx removals + keep-list
│  └─ tweaks.psd1             # registry/service tweaks, each with undo value
├─ modules/
│  ├─ Common.psm1             # Write-Log, Invoke-Step, Test-Admin, Assert-Winget
│  ├─ Preflight.psm1
│  ├─ Debloat.psm1
│  ├─ Install.psm1
│  ├─ DevConfig.psm1
│  ├─ GamingTune.psm1
│  └─ Verify.psm1
├─ tests/                     # Pester 5 tests per module
├─ logs/  backup/             # git-ignored
```

Parameters on the entry script: `-Apply`, `-Phase <name[]>` (run selected phases only), `-SkipDebloat`, `-SkipGaming`, `-SkipDev`, `-NoReboot`. Every action goes through `Invoke-Step -Name -Test {…} -Action {…} -Undo {…}` so dry run, logging and idempotency live in one place.

## Phase plan

Six phases, built and reviewed in this order. Claude Code stops after each phase with a dry-run log for you to check.

1. **Preflight** — runs on the built-in Windows PowerShell 5.1, so nothing needs installing first. Confirm Windows 11 build ≥ 22631, x64, elevated, internet reachable, ≥ 30 GB free on C:. **winget is required** for installs: if `winget` isn't found (common on a fresh install before the Store updates), register App Installer with `Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe`; if that fails, install the `Microsoft.WinGet.Client` module and run `Repair-WinGetPackageManager`. Then `winget source update`. Create restore point (enable System Protection on C: if off). Back up registry keys from `tweaks.psd1`.
2. **Debloat** — remove listed Appx packages for all users plus provisioned packages (so new profiles stay clean), apply privacy/UI tweaks, set listed services to Manual. Details in the Debloat spec.
3. **Install** — loop `apps.psd1`: test installed → `winget install --id <id> -e --silent --accept-package-agreements --accept-source-agreements --scope machine` (user scope where the package requires it) → on failure try the listed fallback → refresh PATH in-session → run the verify command.
4. **Dev config + GitHub sign-in** — runs once Chrome, Git and GitHub CLI are installed.
   1. Open Chrome straight to `https://github.com/login/device`, then run `gh auth login --hostname github.com --git-protocol https --web` as the signed-in user (non-elevated). You copy the one-time code from the console into Chrome and approve; the script waits until `gh auth status` succeeds (retry or skip on timeout).
   2. `gh auth setup-git` so `git push` uses that login with no extra credential prompts.
   3. Set Git identity from your account with no typing: `user.name` from `gh api user --jq .name`, `user.email` as your GitHub noreply address (`<id>+<login>@users.noreply.github.com`). Also `core.autocrlf=input`, `init.defaultBranch=main`.
   4. Enable long paths, add `%USERPROFILE%\.local\bin` to user PATH if missing, set Windows Terminal + PowerShell 7 as default terminal, create `C:\dev`, install VS Code extensions (Claude Code, PowerShell, GitLens, GitHub Pull Requests).
   5. Windows 11 blocks setting the default browser silently, so finish by opening `ms-settings:defaultapps` with a prompt to pick Chrome. Optional `-WithWSL` runs `wsl --install -d Ubuntu`.
5. **Gaming tune** — High Performance power plan (Ultimate on desktops only), Game Mode on, Hardware-accelerated GPU scheduling on, disable Xbox Game Bar background capture (keep the Game Bar app), disable mouse acceleration, stop Steam/Epic/Amazon autostarting. Remind you to install the GPU driver from NVIDIA/AMD; don't automate it.
6. **Verify & report** — run every verify command, write `logs\summary.json` and a coloured console table (PASS/SKIP/FAIL per step), list sign-ins still needed (Steam, Epic, Amazon, Claude Code via `claude`, Grok Bot), prompt for reboot unless `-NoReboot`.

## App install matrix

winget is the primary source for everything; Claude Code must confirm each ID with `winget show --id <id> -e` before hard-coding it, because IDs occasionally change.

| App | Primary install | Fallback | Verify |
| --- | --- | --- | --- |
| PowerShell 7 | `Microsoft.PowerShell` | MSI from GitHub releases | `pwsh -v` |
| Git for Windows | `Git.Git` | — | `git --version` |
| GitHub CLI | `GitHub.cli` | MSI from GitHub releases | `gh --version`, `gh auth status` |
| Google Chrome | `Google.Chrome` | `Google.Chrome.EXE` | path exists |
| VS Code | `Microsoft.VisualStudioCode` (machine scope) | user scope | `code --version` |
| Claude Code | `irm https://claude.ai/install.ps1 \| iex` (native, run as the logged-in user, not elevated) | `Anthropic.ClaudeCode` | `claude --version` |
| Grok Bot (desktop app) | `winget search "Grok Bot"` first; if no xAI package, download the Windows installer from the official [x.ai/bot](https://x.ai/bot#download) "More downloads" link | none — log FAIL with the download page URL for manual install | Start Menu entry + signed exe exists |
| Steam | `Valve.Steam` | — | path exists |
| Epic Games Launcher | `EpicGames.EpicGamesLauncher` | — | path exists |
| Amazon Games (Prime Gaming) | `Amazon.Games` (user scope) | — | path exists |
| Node.js LTS (optional `-WithNode`) | `OpenJS.NodeJS.LTS` | — | `node -v` |
| Python 3 (optional `-WithPython`) | `Python.Python.3.13` (check latest) | — | `py -V` |
| Docker Desktop (optional `-WithDocker`) | `Docker.DockerDesktop` | — | `docker -v` |

Windows Terminal ships with Windows 11, so it's updated by the Store, not installed. Claude Code's native installer needs no Node, so Node, Python and Docker are opt-in to keep the footprint small.

Three install quirks Claude Code must handle:

- **Claude Code:** don't install both native and winget versions; they land in different folders and the older one can win on PATH ([issue #31980](https://github.com/anthropics/claude-code/issues/31980)). Pick native, then check `Get-Command claude -All` shows one result. The native install is per-user, so run it via a non-elevated child process for the signed-in user.
- **Grok Bot:** xAI's AI-teammate desktop app; the FAQ lists macOS and Windows desktops plus iOS, and it's included with Grok Premium ($30/month) and higher plans ([x.ai/bot](https://x.ai/bot)). Downloads are served from Cursor's update server (`api2.cursor.sh/updates/download/stable/...`), and the page only exposes the macOS link directly. Claude Code must find the Windows link on the download page while building, store it in `apps.psd1` with the date checked, then at run time: download to `%TEMP%`, check `Get-AuthenticodeSignature` is Valid and the signer is xAI/SpaceXAI or Anysphere (Cursor), discover the silent-install switch by testing on the VM, and install per-user (not elevated). Never pull from third-party mirrors or the unofficial "Grok Desktop" wrapper apps on GitHub.
- **Amazon Games** is the launcher for claimed Prime Gaming PC titles ([Amazon](https://gaming.amazon.com/amazon-games-app)); its winget package is `Amazon.Games` ([wingetgui](https://wingetgui.com/apps/Amazon-Games)).

## Debloat spec

Remove consumer filler and ads; keep anything a game, launcher or dev tool depends on. Each item in `debloat.psd1` gets a `Reason` field.

**Remove (Appx, all users + provisioned)**

- Clipchamp, Microsoft News, Weather, Get Help, Tips, Feedback Hub, Solitaire Collection, To Do, People, Maps, Power Automate Desktop, Family, Quick Assist, Bing Search, Sticky Notes (optional), Mixed Reality Portal, Microsoft Teams (personal), new Outlook for Windows, Copilot app (optional flag `-KeepCopilot`)
- OEM and promoted installs: Spotify, Disney+, TikTok, Instagram, LinkedIn, Candy Crush and any `*king.com*`, `*Facebook*` stubs
- OneDrive: uninstall only with `-RemoveOneDrive` (default keep; you may sync dev work)

**Keep (hard-coded keep-list; the script refuses to remove these)**

- `Microsoft.WindowsStore`, `Microsoft.DesktopAppInstaller`, `Microsoft.SecHealthUI`, `Microsoft.GamingApp`, `Microsoft.GamingServices`, `Microsoft.XboxIdentityProvider`, `Microsoft.Xbox.TCUI`, `Microsoft.XboxGamingOverlay`, `Microsoft.WindowsTerminal`, `Microsoft.VCLibs*`, `Microsoft.UI.Xaml*`, `Microsoft.NET*`, `Microsoft.WindowsCalculator`, `Microsoft.Windows.Photos`, `Microsoft.ScreenSketch`, `Microsoft.WindowsNotepad`, `Microsoft.Paint`

**Tweaks (registry, each with an undo value)**

- Turn off: Start menu recommendations/ads, lock-screen tips, Settings suggestions, Widgets, taskbar Search box (icon only), Chat/Teams icon, Bing results in Start search, advertising ID, tailored experiences, "finish setting up" nags
- Telemetry: set diagnostic data to Required (minimum supported on Home/Pro); `DiagTrack` service to Manual
- Explorer: show file extensions and hidden files, open to This PC, classic right-click menu (optional `-ClassicContextMenu`)
- Recall / Click to Do: disable if present

After debloat, restart Explorer once rather than rebooting.

**Strip levels (`-Level Standard|Lean`)**

- **Lean (default):** allow-list approach: every Appx package not on the keep-list is removed, plus Widgets platform, Copilot, OneDrive, Phone Link, Cortana remnants, optional features (legacy Windows Media Player, WordPad, Steps Recorder, Internet Explorer mode, Work Folders), and extra consumer services set to Manual (Fax, Retail Demo, Maps Broker; Geolocation only with `-NoLocation`). Startup apps and background app permissions are trimmed so only security, drivers and anything you've allowed run at boot.
- **Standard (`-Level Standard`):** the named removal list above only, for a gentler pass.
- **Security stays on and untouched, at every level, including the scheduled run:** Windows Security app, Defender antivirus and real-time protection, Firewall, SmartScreen, UAC, Windows Update, BitLocker/Device Encryption, Memory Integrity (VBS/HVCI), TPM, Secure Boot, and the Windows Security Center service. The script only reads these to report their status in the summary; Verify fails the run if any are off.
- **Never, at any level:** DISM removal of core Windows components, deleting services, removing Edge or WebView2, or touching Store/winget/Xbox Gaming Services. Anti-cheat such as Vanguard and Easy Anti-Cheat relies on several of the security items above.

## Scheduled re-debloat

Install a Scheduled Task, `AIGamingRig-Maintenance`, that re-runs only the Debloat and Tweaks phases so updates can't quietly put things back.

- **Install:** `Setup-AIGamingRig.ps1 -Apply` copies the scripts and config to `C:\ProgramData\AIGamingRig\` and sets ACLs so only Administrators and SYSTEM can write there (a SYSTEM task running a user-writable script is a privilege-escalation hole). Register with `Register-ScheduledTask`, principal SYSTEM, highest privileges, and uninstall it in `Undo-AIGamingRig.ps1`.
- **Triggers:** weekly (Sunday 03:00, run if missed); at startup with a 10-minute delay; and on event — Windows Update install success (`Microsoft-Windows-WindowsUpdateClient/Operational`, Event ID 19). Throttle to once per 6 hours so a batch of updates causes one run.
- **Runs:** `Setup-AIGamingRig.ps1 -Apply -Phase Debloat,Tweaks -Unattended -NoReboot`. Unattended mode never prompts, never installs apps, and skips if a game process from a configurable list (`steam.exe` child games, `EpicGamesLauncher` games, anything in full-screen) or Windows Update is mid-install.
- **Feature updates:** detect a build-number change since the last run (stored in `state.json`). On a change, take a fresh restore point and back up registry first, because annual feature updates reprovision the most apps.
- **Reporting:** write `logs\maintenance-<date>.log`, prune logs older than 90 days, and show a Windows toast only when something was removed or re-set. Optional `-NotifyWebhook <url>` posts a JSON summary (removed packages, re-applied tweaks, failures) for an n8n → Telegram alert.
- **Safety valve:** if a run sees a package on the keep-list missing or a FAIL, it stops further changes and flags it rather than continuing.

## Testing and acceptance

Nothing runs on your real PC until it passes on a disposable VM.

- [ ] PSScriptAnalyzer clean (no warnings) on every file
- [ ] Pester tests per module, mocking `winget`, `Get-AppxPackage` and registry calls; keep-list test proves protected packages can never be removed
- [ ] Dry run on a Hyper-V or Windows Sandbox VM prints the full plan with no changes made
- [ ] `-Apply` on a fresh Windows 11 VM checkpoint: zero FAIL rows in `summary.json`
- [ ] Second `-Apply` run: every step reports SKIP
- [ ] `Undo-AIGamingRig.ps1` restores registry tweaks; spot-check Widgets and Start recommendations return
- [ ] Steam, Epic and Amazon Games open and reach their sign-in screen; Xbox app still launches
- [ ] Grok Bot launches and reaches its sign-in screen; installer signature check logged as Valid
- [ ] `claude --version`, `code --version`, `git --version` all work in a new Windows Terminal tab
- [ ] Only then: run on the real machine, after a full image backup

## Kickoff prompt for Claude Code

Paste this into Claude Code from the repo root once `PLAN.md` is in place.

```
Read PLAN.md fully. It specifies a PowerShell 7 script, Setup-AIGamingRig.ps1, that debloats Windows 11 and installs an AI dev + gaming stack.

1. First, write CLAUDE.md from the Guardrails section, and a .gitignore for logs/ and backup/.
2. Enter plan mode and propose the module APIs (function names, params, return objects) for Common.psm1 and Invoke-Step. Wait for my approval.
3. Then build ONE phase at a time in the order in PLAN.md: config data file(s), module, Pester tests. After each phase run PSScriptAnalyzer and Pester, show me the dry-run output, and stop for review.
4. Before hard-coding any winget ID, verify it with `winget show --id <id> -e` or web search and note the date checked in apps.psd1.
5. Never weaken a guardrail to make a step pass. If something in the plan is wrong or unsafe, say so and propose a fix instead of working around it.
6. Finish with Undo-AIGamingRig.ps1 and a README with usage examples.
```

Sources: [Grok Bot](https://x.ai/bot) · [Amazon Games app](https://gaming.amazon.com/amazon-games-app) · [Amazon.Games winget](https://wingetgui.com/apps/Amazon-Games) · [Claude Code install paths issue](https://github.com/anthropics/claude-code/issues/31980) · [Claude Code native install on Windows](https://evezone.evetech.co.za/build-lab/how-to-run-first-time-claude-code-setup-on-windows-without-wsl)
