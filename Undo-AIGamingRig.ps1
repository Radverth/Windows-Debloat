#Requires -Version 5.1
<#
.SYNOPSIS
    Reverses what Setup-AIGamingRig.ps1 changed, using the journals in backup\<timestamp>\journal.jsonl.
.DESCRIPTION
    DRY RUN BY DEFAULT: lists what would be reverted. Pass -Apply to revert.
    Journals from every run are replayed newest -> oldest, so the oldest prior value (the original) wins.
    Registry values, service start modes, the power plan, removed capabilities/features, user PATH and the
    maintenance task are restored. Removed Appx packages cannot be restored offline: their Microsoft Store
    reinstall commands are written to logs\undo-appx-reinstall.txt.
    The raw per-key .reg exports in each backup folder remain for manual `reg import` if you ever need them.
.PARAMETER Apply            Actually revert.
.PARAMETER BackupRoot       Folder(s) containing backup\<timestamp> dirs. Default: this folder and C:\ProgramData\AIGamingRig.
.PARAMETER KeepMaintenance  Do not remove the AIGamingRig-Maintenance scheduled task / ProgramData copy.
.PARAMETER RemoveData       Also delete C:\ProgramData\AIGamingRig entirely (logs and backups included).
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string[]]$BackupRoot = @($PSScriptRoot, (Join-Path $env:ProgramData 'AIGamingRig')),
    [switch]$KeepMaintenance,
    [switch]$RemoveData
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Import-Module (Join-Path $root 'modules\Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\Maintenance.psm1') -Force -DisableNameChecking

if (-not (Test-Admin)) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Apply) { $a += '-Apply' }
    if ($KeepMaintenance) { $a += '-KeepMaintenance' }
    if ($RemoveData) { $a += '-RemoveData' }
    $a += '-BackupRoot'; $a += (($BackupRoot | ForEach-Object { "`"$_`"" }) -join ',')
    $p = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -Wait -PassThru -ArgumentList $a
    exit $p.ExitCode
}

$ctx = Initialize-Rig -Root $root -Apply:$Apply -Timestamp ("undo-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
Set-RigPhase 'Undo'
New-Item -ItemType Directory -Path $ctx.LogDir -Force | Out-Null
Start-Transcript -Path (Join-Path $ctx.LogDir "undo-$(Get-Date -Format 'yyyyMMdd-HHmmss').log") | Out-Null

function global:Restore-RegistryRecord {
    param($r)
    $key = [string]$r.key
    $n = [string]$r.name; if ($n -eq '') { $n = '(Default)' }
    if ($r.existed) {
        $val = $r.value
        if ($r.kind -eq 'Binary') { $val = [byte[]]@($val) }
        elseif ($r.kind -eq 'MultiString') { $val = [string[]]@($val) }
        elseif ($r.kind -in 'DWord') { $val = [int]$val }
        elseif ($r.kind -eq 'QWord') { $val = [long]$val }
        if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -LiteralPath $key -Name $n -Type $r.kind -Value $val -Force
    }
    else {
        if (Test-Path -LiteralPath $key) { Remove-ItemProperty -LiteralPath $key -Name $n -ErrorAction SilentlyContinue }
        if (-not $r.keyExisted -and (Test-Path -LiteralPath $key)) {
            $k = Get-Item -LiteralPath $key
            if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) {
                Remove-Item -LiteralPath $key -Force
                if ($r.removeKeyOnUndo) {
                    $parent = Split-Path $key -Parent
                    if ((Test-Path -LiteralPath $parent) -and (Get-Item -LiteralPath $parent).SubKeyCount -eq 0 -and (Get-Item -LiteralPath $parent).ValueCount -eq 0) { Remove-Item -LiteralPath $parent -Force }
                }
            }
        }
    }
}

try {
    # Collect journals: oldest dir first, then reverse the whole record list so the newest change is undone first.
    $files = @()
    foreach ($b in $BackupRoot) {
        $dir = Join-Path $b 'backup'
        if (Test-Path $dir) { $files += Get-ChildItem -Path $dir -Directory | Sort-Object Name | ForEach-Object { Join-Path $_.FullName 'journal.jsonl' } | Where-Object { Test-Path $_ } }
    }
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($f in ($files | Sort-Object { (Split-Path (Split-Path $_ -Parent) -Leaf) })) {
        foreach ($line in (Get-Content -Path $f -Encoding UTF8)) { if ($line.Trim()) { $records.Add(($line | ConvertFrom-Json)) } }
    }
    $records.Reverse()
    Write-Log -Level Phase -Message ("{0} journal record(s) from {1} file(s). Mode: {2}" -f $records.Count, @($files).Count, $(if ($Apply) { 'APPLY' } else { 'DRY RUN (pass -Apply to revert)' }))

    $appx = New-Object System.Collections.Generic.List[string]
    foreach ($rec in $records) {
        $r = $rec
        switch ($r.type) {
            'registry'  { $null = Invoke-Step -Name "Restore registry $($r.key) [$($r.name)]" -Action ({ Restore-RegistryRecord $r }.GetNewClosure()) }
            'service'   {
                $mode = switch ($r.startMode) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } 'Disabled' { 'Disabled' } default { 'Automatic' } }
                $null = Invoke-Step -Name "Restore service $($r.name) -> $mode" -Action ({ Set-Service -Name $r.name -StartupType $mode }.GetNewClosure())
            }
            'powerplan' { if ($r.scheme) { $null = Invoke-Step -Name "Restore power plan $($r.scheme)" -Action ({ $x = Invoke-Native -File 'powercfg.exe' -Arguments @('/setactive', $r.scheme); if ($x.ExitCode -ne 0) { throw "powercfg exit $($x.ExitCode)" } }.GetNewClosure()) } }
            'capability' { $null = Invoke-Step -Name "Re-add capability $($r.name)" -Action ({ $null = Add-WindowsCapability -Online -Name $r.name }.GetNewClosure()) }
            'feature'   { $null = Invoke-Step -Name "Re-enable feature $($r.name)" -Action ({ $null = Enable-WindowsOptionalFeature -Online -FeatureName $r.name -NoRestart }.GetNewClosure()) }
            'env-path'  { $null = Invoke-Step -Name 'Restore user PATH' -Action ({ [Environment]::SetEnvironmentVariable('Path', [string]$r.before, [string]$r.scope) }.GetNewClosure()) }
            'scheduledtask' { }   # handled once below
            'appx'      { $appx.Add("# $($r.name) $($r.version)`r`n$($r.reinstall)") }
            'appx-provisioned' { }
            'note'      { Write-Log -Message "Note: $($r.text)" }
        }
    }

    if (-not $KeepMaintenance) {
        $null = Invoke-Step -Name 'Remove maintenance scheduled task + ProgramData copy' `
            -Test { -not (Get-ScheduledTask -TaskName 'AIGamingRig-Maintenance' -ErrorAction SilentlyContinue) -and -not (Test-Path (Join-Path (Get-RigInstallDir) 'Setup-AIGamingRig.ps1')) } `
            -Action ({ Uninstall-RigMaintenance -RemoveData:$RemoveData }.GetNewClosure())
    }

    if ($appx.Count -gt 0) {
        $out = Join-Path $ctx.LogDir 'undo-appx-reinstall.txt'
        Write-Log -Level Warn -Message "$($appx.Count) removed Appx package(s) cannot be restored automatically. Reinstall commands: $out"
        if ($Apply) { "# Reinstall removed packages from the Microsoft Store (opens the store page for each)`r`n" + ($appx -join "`r`n`r`n") | Set-Content -Path $out -Encoding UTF8 }
    }
    Write-Log -Message 'Spot-check after an applied undo: Widgets button and Start recommendations should be back (sign out/in or restart Explorer).'
}
finally {
    $fails = Write-RigSummary
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
}
if ($fails -gt 0) { exit 1 }
