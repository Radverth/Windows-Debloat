#Requires -Version 5.1
<#
.SYNOPSIS
    Debloats Windows 11 and sets up an AI dev + gaming stack. Idempotent and re-runnable.
.DESCRIPTION
    DRY RUN BY DEFAULT: prints every action it would take. Pass -Apply to make changes.
    Runs on Windows PowerShell 5.1 or PowerShell 7 (the modules avoid 7-only syntax so Preflight works before pwsh is installed).
.PARAMETER Apply            Make real changes. Without it the run is a dry run.
.PARAMETER DryRun           Explicit dry run (the default). Cannot be combined with -Apply.
.PARAMETER Phase            Run only these phases: Preflight, Debloat, Tweaks, Install, DevConfig, GamingTune, Maintenance, Verify.
                            Preflight (restore point + registry backup) is added automatically before any change.
.PARAMETER Level            Lean (default; allow-list sweep) or Standard (named removal list only).
.PARAMETER Unattended       Scheduled-task mode: Debloat + Tweaks only, never prompts, never installs apps.
.EXAMPLE
    .\Setup-AIGamingRig.ps1                      # dry run of everything
.EXAMPLE
    .\Setup-AIGamingRig.ps1 -Apply -Level Standard -KeepCopilot -NoReboot
.EXAMPLE
    .\Setup-AIGamingRig.ps1 -Apply -Phase Install -WithNode
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$DryRun,
    [ValidateSet('Preflight', 'Debloat', 'Tweaks', 'Install', 'DevConfig', 'GamingTune', 'Maintenance', 'Verify')]
    [string[]]$Phase,
    [switch]$SkipDebloat,
    [switch]$SkipGaming,
    [switch]$SkipDev,
    [switch]$NoReboot,
    [ValidateSet('Lean', 'Standard')][string]$Level = 'Lean',
    [switch]$KeepCopilot,
    [switch]$KeepStickyNotes,
    [switch]$NoLocation,
    [switch]$RemoveOneDrive,
    [switch]$ClassicContextMenu,
    [switch]$WithNode,
    [switch]$WithPython,
    [switch]$WithDocker,
    [switch]$WithWSL,
    [switch]$NoMaintenance,
    [switch]$StrictSecurity,
    [switch]$Unattended,
    [string[]]$ExtraKeep = @(),
    [string[]]$GameProcesses = @(),
    [string]$NotifyWebhook
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if ($Apply -and $DryRun) { throw '-Apply and -DryRun are mutually exclusive.' }

Import-Module (Join-Path $root 'modules\Common.psm1') -Force -DisableNameChecking

#region Elevation (needed for a meaningful dry run too: Appx -AllUsers and Defender status need admin)
if (-not (Test-Admin)) {
    Write-Host 'Not elevated; relaunching as administrator...' -ForegroundColor Yellow
    $argList = New-Object System.Collections.Generic.List[string]
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value.IsPresent) { $argList.Add("-$($kv.Key)") } }
        elseif ($kv.Value -is [array]) { $argList.Add("-$($kv.Key)"); $argList.Add((($kv.Value | ForEach-Object { "`"$_`"" }) -join ',')) }
        else { $argList.Add("-$($kv.Key)"); $argList.Add("`"$($kv.Value)`"") }
    }
    $exe = (Get-Process -Id $PID).Path
    $p = Start-Process -FilePath $exe -Verb RunAs -Wait -PassThru -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") + $argList.ToArray())
    exit $p.ExitCode
}
#endregion

foreach ($m in 'Preflight', 'Debloat', 'Install', 'DevConfig', 'GamingTune', 'Verify', 'Maintenance') {
    Import-Module (Join-Path $root "modules\$m.psm1") -DisableNameChecking
}
$debloatCfg = Import-PowerShellDataFile -Path (Join-Path $root 'config\debloat.psd1')
$appsCfg    = Import-PowerShellDataFile -Path (Join-Path $root 'config\apps.psd1')
$tweaksCfg  = Import-PowerShellDataFile -Path (Join-Path $root 'config\tweaks.psd1')

$options = @{
    Level = $Level; KeepCopilot = $KeepCopilot.IsPresent; KeepStickyNotes = $KeepStickyNotes.IsPresent; NoLocation = $NoLocation.IsPresent
    RemoveOneDrive = $RemoveOneDrive.IsPresent; ClassicContextMenu = $ClassicContextMenu.IsPresent
    WithNode = $WithNode.IsPresent; WithPython = $WithPython.IsPresent; WithDocker = $WithDocker.IsPresent; WithWSL = $WithWSL.IsPresent
    SkipGaming = $SkipGaming.IsPresent; SkipDev = $SkipDev.IsPresent; ExtraKeep = $ExtraKeep; GameProcesses = $GameProcesses
}
$ctx = Initialize-Rig -Root $root -Apply:$Apply -Unattended:$Unattended -Options $options

#region Phase selection
$order = @('Preflight', 'Debloat', 'Tweaks', 'Install', 'DevConfig', 'GamingTune', 'Maintenance', 'Verify')
$selected = if ($Phase) { @($order | Where-Object { $Phase -contains $_ }) } else { @($order) }
if ($Unattended) { $selected = @($selected | Where-Object { $_ -in 'Debloat', 'Tweaks' }) }
if ($SkipDebloat) { $selected = @($selected | Where-Object { $_ -notin 'Debloat', 'Tweaks' }) }
if ($SkipGaming)  { $selected = @($selected | Where-Object { $_ -ne 'GamingTune' }) }
if ($SkipDev)     { $selected = @($selected | Where-Object { $_ -ne 'DevConfig' }) }
if ($NoMaintenance -or $Unattended) { $selected = @($selected | Where-Object { $_ -ne 'Maintenance' }) }
$mutating = @($selected | Where-Object { $_ -in 'Debloat', 'Tweaks', 'Install', 'DevConfig', 'GamingTune', 'Maintenance' })
if ($Apply -and $mutating.Count -gt 0 -and $selected -notcontains 'Preflight') { $selected = @('Preflight') + $selected }
#endregion

#region Transcript
if (-not (Test-Path $ctx.LogDir)) { New-Item -ItemType Directory -Path $ctx.LogDir -Force | Out-Null }
$logName = if ($Unattended) { "maintenance-$(Get-Date -Format 'yyyyMMdd').log" } else { "setup-$($ctx.Timestamp).log" }
Start-Transcript -Path (Join-Path $ctx.LogDir $logName) -Append | Out-Null
#endregion

$exitCode = 0
$signIns = @()
try {
    $mode = if ($ctx.DryRun) { 'DRY RUN (no changes will be made; pass -Apply to apply)' } else { 'APPLY' }
    Write-Log -Level Phase -Message "AIGamingRig - $mode - Level=$Level - phases: $($selected -join ', ')"

    $buildId = Get-RigBuildId
    $forceRp = $false
    if ($Unattended) {
        $state = Get-RigState -Root $root
        $forceRp = ($state -and $state.lastBuild -and $state.lastBuild -ne $buildId)
        if ($forceRp) { Write-Log -Level Warn -Message "OS build changed ($($state.lastBuild) -> $buildId): taking a fresh restore point + backup" }
        if (-not $forceRp -and (Test-MaintenanceThrottled -State $state -BuildId $buildId)) {
            Write-Log -Level Skip -Message 'Throttled: last maintenance run was < 6 hours ago.'; $selected = @()
        }
        else {
            $blocked = Test-MaintenanceBlocked -Config $debloatCfg
            if ($blocked) { Write-Log -Level Skip -Message "Maintenance skipped: $blocked"; $selected = @() }
        }
    }

    foreach ($ph in $selected) {
        if ($ctx.Halted) { Write-Log -Level Error -Message "Halted: $($ctx.HaltReason). Skipping remaining phases."; break }
        Write-Log -Level Phase -Message "=== $ph ==="
        switch ($ph) {
            'Preflight' {
                if ($Unattended) { Invoke-RigPreflight -TweaksConfig $tweaksCfg -SkipChecks -SkipRestorePoint:(-not $forceRp) -ForceRestorePoint:$forceRp }
                else { Invoke-RigPreflight -TweaksConfig $tweaksCfg }
            }
            'Debloat'     { Invoke-RigDebloat -Config $debloatCfg }
            'Tweaks'      { Invoke-RigTweaks -TweaksConfig $tweaksCfg }
            'Install'     { Invoke-RigInstall -Config $appsCfg }
            'DevConfig'   { Invoke-RigDevConfig -AppsConfig $appsCfg -TweaksConfig $tweaksCfg }
            'GamingTune'  { Invoke-RigGamingTune -TweaksConfig $tweaksCfg }
            'Maintenance' { Set-RigPhase 'Maintenance'; Install-RigMaintenance -SourceRoot $root }
            'Verify'      { $signIns = Invoke-RigVerify -AppsConfig $appsCfg -StrictSecurity:$StrictSecurity }
        }
    }

    if ($Unattended -and $selected.Count -gt 0) {
        if (-not $ctx.DryRun) { Set-RigState -Root $root -BuildId $buildId }
        Remove-EmptyBackup -Ctx $ctx
        Remove-OldRigFiles -DataRoot $root -Days 90
        Send-RigReport -WebhookUrl $NotifyWebhook
    }
}
finally {
    $fails = Write-RigSummary -SignInsNeeded $signIns
    if ($fails -gt 0 -or $ctx.Halted) { $exitCode = 1 }

    if (-not $ctx.DryRun -and -not $NoReboot -and -not $Unattended) {
        $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                   (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                   [bool](@($ctx.Results | Where-Object { $_.Name -like 'Tweak hags*' -and $_.Status -eq 'OK' }).Count)
        if ($pending) {
            Write-Log -Level Warn -Message 'A reboot is needed to finish (GPU scheduling / feature changes).'
            if ((Read-Host 'Reboot now? (y/N)') -match '^[yY]') { Stop-Transcript | Out-Null; Restart-Computer -Force }
        }
    }
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
}
exit $exitCode
