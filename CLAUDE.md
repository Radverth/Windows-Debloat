# CLAUDE.md — AI Gaming Rig setup

PowerShell script suite that debloats Windows 11 and installs an AI dev + gaming stack. See `PLAN.md` for the full spec.

## Guardrails (non-negotiable — never weaken one to make a step pass)

- **Restore point first.** Create a System Restore point and export the registry keys the script touches to `.\backup\<timestamp>\` before any change. Abort if either fails.
- **Dry run by default.** Real changes need `-Apply`. Dry run prints every action it would take.
- **Never remove:** Microsoft Store, App Installer (winget), Windows Security/Defender, Windows Update, Edge WebView2, Xbox Identity Provider, Gaming Services, Xbox app, .NET and VC++ runtimes. Enforced by the hard-coded `Protected` list in `config\debloat.psd1`, re-checked inside `Remove-RigAppx`.
- **No third-party debloat scripts, no `irm | iex`** except the vendor installers named in the matrix in `config\apps.psd1`. Every removal is an explicit, reviewed entry with a `Reason`.
- **Idempotent.** Each step checks state first and reports `SKIP` when there is nothing to do.
- **Never disable Defender, UAC or SmartScreen**, no hosts-file telemetry blocking, no service deletion. Services go to Manual, never Disabled, unless listed.
- **Logged.** Transcript to `logs\setup-<timestamp>.log` plus a JSON summary.
- **Reversible.** Every change journals its prior value to `backup\<timestamp>\journal.jsonl`; `Undo-AIGamingRig.ps1` replays it.

## Conventions

- Lists live in `config\*.psd1`; logic lives in `modules\*.psm1`. Changing a list must never need a logic change.
- Every action goes through `Invoke-Step` (dry run, logging, SKIP/OK/FAIL live there).
- Modules stay compatible with Windows PowerShell 5.1 syntax (no `?:`, `??`, `&&`) so Preflight can run before PowerShell 7 exists.
- Verify every winget ID with `winget show --id <id> -e` and record the date in `apps.psd1`.
- Run `Invoke-ScriptAnalyzer -Path . -Recurse -Settings PSScriptAnalyzerSettings.psd1` and `Invoke-Pester ./tests` before committing.
