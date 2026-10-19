# Windows-Debloat — AI Gaming Rig setup

One idempotent, re-runnable script that debloats a fresh Windows 11 install, installs a gaming stack (Steam, Epic, Amazon Games) and an AI dev stack (Chrome, VS Code, Git, GitHub CLI, Claude Code, Grok Bot), then tunes the machine. Spec: [`PLAN.md`](PLAN.md). Guardrails: [`CLAUDE.md`](CLAUDE.md).

> **Test on a disposable Windows 11 VM first.** Nothing here has been run on Windows yet (see *Status*). Take a full image backup before running on a real machine.

## Usage

Run from an elevated prompt (the script re-launches itself elevated if needed). Works on Windows PowerShell 5.1 or PowerShell 7.

```powershell
.\Setup-AIGamingRig.ps1                                  # DRY RUN of everything (default): prints each action, changes nothing
.\Setup-AIGamingRig.ps1 -Apply                           # real run, Lean strip level
.\Setup-AIGamingRig.ps1 -Apply -Level Standard -KeepCopilot -KeepStickyNotes
.\Setup-AIGamingRig.ps1 -Apply -Phase Install -WithNode -WithPython
.\Setup-AIGamingRig.ps1 -Apply -SkipGaming -NoReboot
.\Undo-AIGamingRig.ps1                                   # dry run of the undo
.\Undo-AIGamingRig.ps1 -Apply                            # revert registry/services/power plan/task from the journals
```

Phases (always in this order): `Preflight → Debloat → Tweaks → Install → DevConfig → GamingTune → Maintenance → Verify`. A restore point + registry backup (Preflight) is forced before any change.

| Switch | Effect |
| --- | --- |
| `-Apply` / `-DryRun` | real run / explicit dry run (default) |
| `-Phase a,b` | run only those phases |
| `-SkipDebloat` `-SkipGaming` `-SkipDev` `-NoMaintenance` `-NoReboot` | skip groups / the scheduled task / the reboot prompt |
| `-Level Lean\|Standard` | Lean = allow-list sweep of every non-kept Appx (default); Standard = named list only |
| `-KeepCopilot` `-KeepStickyNotes` `-NoLocation` `-RemoveOneDrive` `-ClassicContextMenu` | per-feature options |
| `-WithNode` `-WithPython` `-WithDocker` `-WithWSL` | optional installs |
| `-ExtraKeep 'Pkg.*'` | extra Appx patterns the Lean sweep must keep |
| `-StrictSecurity` | Verify FAILs (not WARNs) on Secure Boot / TPM / BitLocker / Memory Integrity being off |
| `-Unattended` `-GameProcesses` `-NotifyWebhook <https url>` | scheduled-task mode and its options |

## What lives where

- `config\debloat.psd1` — hard `Protected` keep-list, named removals (each with a `Reason`), Lean extras, services → Manual, startup trimming, maintenance gating.
- `config\apps.psd1` — install matrix (winget id, fallback, verify, date checked).
- `config\tweaks.psd1` — every registry tweak; prior values are journaled so each is reversible.
- `modules\` — `Common` (logging, `Invoke-Step`, journal, registry/service helpers, winget bootstrap), `Preflight`, `Debloat`, `Install`, `DevConfig`, `GamingTune`, `Maintenance`, `Verify`.
- `logs\` — `setup-<ts>.log` transcript, `summary.json`; `backup\<ts>\` — `.reg` exports + `journal.jsonl` (both git-ignored).

## Scheduled re-debloat

`-Apply` (without `-NoMaintenance`) copies the scripts to `C:\ProgramData\AIGamingRig` (ACL: only SYSTEM/Administrators can write), and registers `AIGamingRig-Maintenance` (SYSTEM): weekly Sun 03:00, at startup +10 min, and on Windows Update event 19. It runs `-Apply -Phase Debloat,Tweaks -Unattended -NoReboot`, throttled to once per 6 h, skipped while a game/servicing process runs, with a fresh restore point when the OS build changes. A missing core package or any FAIL halts further changes. `Undo-AIGamingRig.ps1` removes it.

## Deviations from PLAN.md (deliberate)

- **`Invoke-Step -UndoNote`** (string) instead of `-Undo {…}`: scriptblocks can't be persisted, so machine-readable undo data is written to the journal by the helpers.
- **Runs on 5.1 or 7** rather than requiring pwsh first; the Appx cmdlets are actually more reliable in 5.1.
- **`-RemoveOneDrive` is the only OneDrive gate**, even at Lean (the plan lists it in both places).
- **Security posture:** Defender, Firewall, UAC, SmartScreen, Windows Update and Security Center failures are hard FAILs. Secure Boot / TPM / BitLocker / Memory Integrity are WARN by default (a VM legitimately lacks them); use `-StrictSecurity` to FAIL.
- **"Second run = all SKIP"** holds for every state-changing step. Preflight's registry backup and Explorer restart are bookkeeping, and the Chrome-default-browser prompt reports WARN until you pick Chrome.
- **Fullscreen detection** for the maintenance gate isn't possible from a SYSTEM session; it matches processes under game-library paths instead (`MaintenanceGamePaths`) plus `-GameProcesses`.
- **Grok Bot:** the Windows download link wasn't exposed at plan time. Set `DownloadUrl` (and `SilentArgs`) in `apps.psd1` from the x.ai/bot "More downloads" link; until then the step FAILs with the manual URL, as the plan specifies.

## Status

Written and syntax-checked on Linux (PowerShell 7.4 parser); the pure logic (`Invoke-Step`, removal planner, keep-list enforcement, config sanity) was exercised with a minimal Pester-style shim. **Not yet run:** PSScriptAnalyzer, the real Pester suite (PSGallery was unreachable), and anything Windows-specific (winget, Appx, registry, scheduled tasks). Run the checklist in PLAN.md → *Testing and acceptance* on a Hyper-V/Sandbox VM; start with the dry run.

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester .\tests
```
