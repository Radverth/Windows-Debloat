#Requires -Version 5.1
# Maintenance.psm1 - the AIGamingRig-Maintenance scheduled task: locked-down install under ProgramData, run gating,
# build-change detection, log pruning, toast + webhook reporting.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

$script:TaskName   = 'AIGamingRig-Maintenance'
$script:InstallDir = Join-Path $env:ProgramData 'AIGamingRig'
$script:CopyItems  = @('Setup-AIGamingRig.ps1', 'Undo-AIGamingRig.ps1', 'config', 'modules', 'CLAUDE.md', 'PLAN.md')

function Get-RigInstallDir { return $script:InstallDir }

function Get-RigTreeHash {
    <# Single hash over the files that get copied, so "already installed and current" is a cheap exact test. #>
    param([Parameter(Mandatory)][string]$Root)
    $sb = New-Object System.Text.StringBuilder
    foreach ($i in $script:CopyItems) {
        $p = Join-Path $Root $i
        if (-not (Test-Path $p)) { continue }
        foreach ($f in @(Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            $rel = $f.FullName.Substring($Root.Length)
            [void]$sb.Append($rel).Append((Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash)
        }
        if (Test-Path $p -PathType Leaf) { [void]$sb.Append($i).Append((Get-FileHash -Path $p -Algorithm SHA256).Hash) }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($sb.ToString())
    return ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '')
}

function Copy-RigToProgramData {
    <# Copy, then lock ACLs: only SYSTEM + Administrators can write (a SYSTEM task must never run user-writable code). #>
    param([Parameter(Mandatory)][string]$Source)
    New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
    # Lock BEFORE copying so there is no window where a standard user can drop files in.
    $null = Invoke-Native -File 'icacls.exe' -Arguments @($script:InstallDir, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX')
    foreach ($i in $script:CopyItems) {
        $src = Join-Path $Source $i
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $script:InstallDir $i
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
        Copy-Item -Path $src -Destination $dst -Recurse -Force
    }
    foreach ($d in 'logs', 'backup') { New-Item -ItemType Directory -Path (Join-Path $script:InstallDir $d) -Force | Out-Null }
    # logs/backup stay writable only by SYSTEM/Admins through inheritance of the locked root.
}

function Register-RigMaintenanceTask {
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
    if (-not $pwsh) { $pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $entry = Join-Path $script:InstallDir 'Setup-AIGamingRig.ps1'
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$entry`" -Apply -Phase Debloat,Tweaks -Unattended -NoReboot"
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arg -WorkingDirectory $script:InstallDir

    $weekly = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3:00am
    $boot = New-ScheduledTaskTrigger -AtStartup
    $boot.Delay = 'PT10M'
    $cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $evt = New-CimInstance -CimClass $cls -ClientOnly
    $evt.Enabled = $true
    $evt.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-WindowsUpdateClient/Operational"><Select Path="Microsoft-Windows-WindowsUpdateClient/Operational">*[System[Provider[@Name=''Microsoft-Windows-WindowsUpdateClient''] and EventID=19]]</Select></Query></QueryList>'

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger @($weekly, $boot, $evt) -Principal $principal -Settings $settings `
        -Description 'Re-applies the AIGamingRig Debloat + Tweaks phases after updates. Remove with Undo-AIGamingRig.ps1.' -Force | Out-Null
}

function Install-RigMaintenance {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceRoot)
    # Locals, not $script: - GetNewClosure() rebinds $script: to a dynamic module.
    $task = $script:TaskName; $dir = $script:InstallDir
    $null = Invoke-Step -Name 'Maintenance task (copy to ProgramData + register)' -Phase 'Maintenance' `
        -Test ({
            (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) -and
            (Test-Path (Join-Path $dir 'Setup-AIGamingRig.ps1')) -and
            ((Get-RigTreeHash -Root $dir) -eq (Get-RigTreeHash -Root $SourceRoot))
        }.GetNewClosure()) `
        -Action ({
            Add-Journal -Type 'scheduledtask' -Data @{ name = $task; dir = $dir }
            Copy-RigToProgramData -Source $SourceRoot
            Register-RigMaintenanceTask
        }.GetNewClosure()) -UndoNote "Unregister-ScheduledTask $task; remove $dir"
}

function Uninstall-RigMaintenance {
    <# Used by Undo-AIGamingRig.ps1. Leaves backup\ and logs\ under ProgramData in place unless -RemoveData. #>
    [CmdletBinding()]
    param([switch]$RemoveData)
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($i in $script:CopyItems) {
        $p = Join-Path $script:InstallDir $i
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($RemoveData) { Remove-Item $script:InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
}

#region Run gating, state

function Get-RigBuildId {
    $v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $dv = ''; if ($v -and $v.PSObject.Properties['DisplayVersion']) { $dv = $v.DisplayVersion }
    return "$([Environment]::OSVersion.Version.Build)/$dv"
}

function Get-RigState {
    param([Parameter(Mandatory)][string]$Root)
    $f = Join-Path $Root 'state.json'
    if (Test-Path $f) { try { return (Get-Content $f -Raw | ConvertFrom-Json) } catch { return $null } }
    return $null
}

function Set-RigState {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$BuildId)
    @{ lastBuild = $BuildId; lastRun = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content -Path (Join-Path $Root 'state.json') -Encoding UTF8
}

function Test-MaintenanceThrottled {
    <# True if the last run was < Hours ago and the OS build hasn't changed. #>
    param($State, [string]$BuildId, [int]$Hours = 6)
    if (-not $State -or -not $State.lastRun) { return $false }
    if ($State.lastBuild -ne $BuildId) { return $false }
    return (((Get-Date) - [datetime]$State.lastRun).TotalHours -lt $Hours)
}

function Test-MaintenanceBlocked {
    <# Returns a reason string if the run should be skipped (game running / update installing), else $null. #>
    param([Parameter(Mandatory)][hashtable]$Config)
    foreach ($n in $Config.MaintenanceSkipProcesses) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return "$n is running (Windows Update/servicing in progress)" }
    }
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path })
    foreach ($p in $procs) {
        if ($p.Path -like '*\Epic Games\Launcher\*' -or $p.Path -like '*\Epic Games\Portal\*') { continue }
        foreach ($g in $Config.MaintenanceGamePaths) { if ($p.Path -like $g) { return "game process running: $($p.Name)" } }
    }
    foreach ($n in @(Get-RigOption -Name 'GameProcesses' -Default @())) {
        if ($n -and (Get-Process -Name $n -ErrorAction SilentlyContinue)) { return "configured game process running: $n" }
    }
    return $null
}

function Remove-OldRigFiles {
    <# Logs older than Days; backup dirs older than Days; empty (journal-less) backup dirs from today's unattended run. #>
    param([Parameter(Mandatory)][string]$DataRoot, [int]$Days = 90)
    $cut = (Get-Date).AddDays(-$Days)
    Get-ChildItem -Path (Join-Path $DataRoot 'logs') -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path (Join-Path $DataRoot 'backup') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Remove-EmptyBackup {
    param([Parameter(Mandatory)]$Ctx)
    if ((Test-Path $Ctx.BackupDir) -and -not (Test-Path $Ctx.JournalPath)) { Remove-Item $Ctx.BackupDir -Recurse -Force -ErrorAction SilentlyContinue }
}

#endregion

#region Reporting

function Get-RigChangeSummary {
    $res = Get-RigResults
    [pscustomobject]@{
        removed  = @($res | Where-Object { $_.Status -eq 'OK' -and $_.Name -like 'Remove Appx*' } | ForEach-Object { $_.Name -replace '^Remove Appx (\S+).*', '$1' })
        reapplied = @($res | Where-Object { $_.Status -eq 'OK' -and $_.Name -notlike 'Remove Appx*' } | ForEach-Object Name)
        failures = @($res | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object { "$($_.Name): $($_.Message)" })
        halted   = (Get-RigContext).HaltReason
        computer = $env:COMPUTERNAME
    }
}

function Send-RigToast {
    <# Toast in the signed-in user's session (a SYSTEM task has no desktop of its own). Best effort. #>
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Text)
    if (-not (Get-InteractiveUser)) { return }
    $t = $Title -replace "'", "''"; $x = $Text -replace "'", "''"
    $script = @"
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
`$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
`$n = `$xml.GetElementsByTagName('text'); `$n.Item(0).AppendChild(`$xml.CreateTextNode('$t')) | Out-Null; `$n.Item(1).AppendChild(`$xml.CreateTextNode('$x')) | Out-Null
`$id = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(`$id).Show([Windows.UI.Notifications.ToastNotification]::new(`$xml))
exit 0
"@
    try { $null = Invoke-AsUser -Script $script -TimeoutSec 60 } catch { Write-Log -Level Warn -Message "toast failed: $($_.Exception.Message)" }
}

function Send-RigReport {
    [CmdletBinding()]
    param([string]$WebhookUrl)
    $s = Get-RigChangeSummary
    $changed = ($s.removed.Count + $s.reapplied.Count + $s.failures.Count) -gt 0 -or $s.halted
    if (-not $changed) { return }
    $text = "removed=$($s.removed.Count) reapplied=$($s.reapplied.Count) failures=$($s.failures.Count)"
    if ($s.halted) { $text += " HALTED: $($s.halted)" }
    Send-RigToast -Title 'AIGamingRig maintenance' -Text $text
    if ($WebhookUrl) {
        $u = [uri]$WebhookUrl
        if ($u.Scheme -ne 'https') { Write-Log -Level Warn -Message 'Webhook must be https; not sent.'; return }
        try { Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' -Body ($s | ConvertTo-Json -Depth 4) | Out-Null }
        catch { Write-Log -Level Warn -Message "webhook failed: $($_.Exception.Message)" }
    }
}

#endregion

Export-ModuleMember -Function Get-RigInstallDir, Get-RigTreeHash, Install-RigMaintenance, Uninstall-RigMaintenance,
    Get-RigBuildId, Get-RigState, Set-RigState, Test-MaintenanceThrottled, Test-MaintenanceBlocked, Remove-OldRigFiles, Remove-EmptyBackup,
    Get-RigChangeSummary, Send-RigReport
