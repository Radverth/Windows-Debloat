#Requires -Version 5.1
# Preflight.psm1 - environment checks, winget bootstrap, restore point, registry backup. Runs on Windows PowerShell 5.1.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

function Add-PreflightCheck {
    # Checks are read-only, so they run (and report) in dry run too.
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $status = if ($Pass) { 'OK' } else { 'FAIL' }
    $lvl = if ($Pass) { 'Ok' } else { 'Error' }
    Write-Log -Level $lvl -Message "Check $Name - $Detail"
    return (Add-RigResult -Phase 'Preflight' -Name "Check: $Name" -Status $status -Message $Detail)
}

function Test-RigEnvironment {
    [CmdletBinding()]
    param([int]$MinBuild = 22631, [int]$MinFreeGB = 30)
    $r = @()
    $build = [Environment]::OSVersion.Version.Build
    $r += Add-PreflightCheck 'Windows 11 build' ($build -ge $MinBuild) "build $build (need >= $MinBuild)"
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $r += Add-PreflightCheck 'x64' ($arch -eq 'AMD64') "architecture $arch"
    $admin = Test-Admin
    $r += Add-PreflightCheck 'Elevated' $admin $(if ($admin) { 'running as administrator' } else { 'not elevated' })
    $net = $false
    try { $net = (New-Object Net.Sockets.TcpClient).ConnectAsync('github.com', 443).Wait(5000) } catch { $net = $false }
    $r += Add-PreflightCheck 'Internet' $net 'github.com:443'
    $free = 0
    try { $free = [math]::Round((Get-PSDrive -Name C -ErrorAction Stop).Free / 1GB, 1) } catch { $free = 0 }
    $r += Add-PreflightCheck 'Free space on C:' ($free -ge $MinFreeGB) "$free GB free (need >= $MinFreeGB)"
    return $r
}

function Invoke-RigRestorePoint {
    [CmdletBinding()]
    param([switch]$Force)
    Invoke-Step -Name 'System Restore point' -Phase 'Preflight' `
        -UndoNote 'Roll back via System Restore' `
        -Test ({
            if ($Force) { return $false }
            $since = (Get-Date).AddHours(-24)
            [bool](Get-ComputerRestorePoint -ErrorAction SilentlyContinue |
                Where-Object { $_.Description -like 'AIGamingRig*' -and [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime) -gt $since })
        }.GetNewClosure()) `
        -Action {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
            # Windows throttles restore points to one per 24h unless the frequency value is 0.
            $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
            $old = (Get-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
            Set-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -Type DWord -Value 0
            try { Checkpoint-Computer -Description ('AIGamingRig ' + (Get-RigContext).Timestamp) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop }
            finally {
                if ($null -eq $old) { Remove-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
                else { Set-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -Type DWord -Value $old }
            }
        }
}

function Export-RigRegistryBackup {
    <# reg-exports every key the tweaks touch into backup\<ts>\. Missing keys are fine; an unwritable folder is a failure. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$TweaksConfig)
    Invoke-Step -Name 'Registry backup' -Phase 'Preflight' -UndoNote 'reg import backup\<ts>\*.reg (journal.jsonl is the precise undo)' `
        -Action ({
            $c = Get-RigContext
            New-Item -ItemType Directory -Path $c.BackupDir -Force | Out-Null
            $probe = Join-Path $c.BackupDir '.write-test'
            Set-Content -Path $probe -Value 'ok' -ErrorAction Stop; Remove-Item $probe -Force
            $n = 0
            foreach ($key in (Get-TweakRegKeys -Config $TweaksConfig)) {
                $hive, $rest = $key -split '\\', 2
                $targets = @()
                if ($hive -eq 'HKLM') { $targets += ,@('HKLM', "HKLM\$rest") }
                else {
                    foreach ($root in (Get-HiveRoots -Hive 'HKCU')) {
                        if ($root -like '*HKEY_USERS*') { $sid = Split-Path $root -Leaf; $targets += ,@("HKU-$sid", "HKU\$sid\$rest") }
                        else { $targets += ,@('HKCU', "HKCU\$rest") }
                    }
                }
                foreach ($t in $targets) {
                    $file = Join-Path $c.BackupDir (('{0}_{1}.reg' -f $t[0], ($rest -replace '[\\/:*?"<>| ]', '_')))
                    $res = Invoke-Native -File 'reg.exe' -Arguments @('export', $t[1], $file, '/y')
                    if ($res.ExitCode -eq 0) { $n++ }   # exit 1 = key does not exist yet; nothing to back up
                }
            }
            "exported $n keys to $($c.BackupDir)"
        }.GetNewClosure())
}

function Invoke-RigPreflight {
    <# Full Preflight phase. In -Apply mode a failed check, restore point or backup halts the run (nothing later changes). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$TweaksConfig, [switch]$ForceRestorePoint, [switch]$SkipRestorePoint, [switch]$SkipChecks)
    Set-RigPhase 'Preflight'
    $c = Get-RigContext
    if (-not $SkipChecks) {
        $checks = Test-RigEnvironment
        if (@($checks | Where-Object Status -eq 'FAIL').Count -gt 0 -and -not $c.DryRun) { Stop-Rig 'preflight checks failed'; return }
    }
    $null = Invoke-Step -Name 'winget available' -Test { Test-Command 'winget' } -Action { $null = Assert-Winget } -UndoNote 'none'
    if (-not $c.DryRun) { try { $null = Assert-Winget } catch { Write-Log -Level Warn -Message $_.Exception.Message } }

    $steps = @()
    if (-not $SkipRestorePoint) { $steps += Invoke-RigRestorePoint -Force:$ForceRestorePoint }
    $steps += Export-RigRegistryBackup -TweaksConfig $TweaksConfig
    foreach ($x in $steps) {
        if ($x.Status -eq 'FAIL') { Stop-Rig "$($x.Name) failed: $($x.Message)"; return }
    }
}

Export-ModuleMember -Function Test-RigEnvironment, Invoke-RigRestorePoint, Export-RigRegistryBackup, Invoke-RigPreflight
