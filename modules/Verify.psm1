#Requires -Version 5.1
# Verify.psm1 - read-only post-run verification, security-posture report, sign-in reminders. Runs in dry run too.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Install.psm1') -DisableNameChecking

function Add-VerifyRow {
    param([string]$Name, [string]$Status, [string]$Message = '')
    $lvl = switch ($Status) { 'PASS' { 'Ok' } 'WARN' { 'Warn' } 'FAIL' { 'Error' } default { 'Info' } }
    Write-Log -Level $lvl -Message ("Verify {0} - {1}" -f $Name, $Message)
    $null = Add-RigResult -Phase 'Verify' -Name $Name -Status $Status -Message $Message
}

function Test-RigAppVerify {
    <# Returns @{Pass; Detail}. Uses the app's Verify command, VerifyPaths or Start Menu shortcut. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App)
    if ($App.ContainsKey('Verify')) {
        $parts = @($App.Verify -split '\s+')
        if (-not (Test-Command $parts[0])) { return @{ Pass = $false; Detail = "$($parts[0]) not found on PATH" } }
        $r = Invoke-Native -File $parts[0] -Arguments @($parts | Select-Object -Skip 1)
        return @{ Pass = ($r.ExitCode -eq 0); Detail = (($r.Output | Select-Object -First 1) -join '') }
    }
    if ($App.Key -eq 'grokbot') {
        $lnk = Get-RigStartMenuEntry -Pattern $App.VerifyShortcut
        if (-not $lnk) { return @{ Pass = $false; Detail = "no Start Menu entry; install manually: $($App.ManualUrl)" } }
        return @{ Pass = $true; Detail = $lnk }
    }
    if (Test-AppInstalled -App $App) { return @{ Pass = $true; Detail = 'path exists' } }
    return @{ Pass = $false; Detail = 'not found' }
}

function Test-RigSecurityPosture {
    <# Reads (never changes) the security items the script must leave alone. -Strict makes hardware/config items FAIL, not WARN. #>
    [CmdletBinding()]
    param([switch]$Strict)
    $soft = if ($Strict) { 'FAIL' } else { 'WARN' }

    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mp) { Add-VerifyRow 'Defender real-time protection' $(if ($mp.RealTimeProtectionEnabled) { 'PASS' } else { 'FAIL' }) "enabled=$($mp.RealTimeProtectionEnabled)" }
    else { Add-VerifyRow 'Defender real-time protection' 'WARN' 'status unavailable (third-party AV?)' }

    $fw = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
    $fwOff = @($fw | Where-Object { -not $_.Enabled }).Count
    Add-VerifyRow 'Firewall (all profiles)' $(if ($fw.Count -gt 0 -and $fwOff -eq 0) { 'PASS' } else { 'FAIL' }) "profiles=$($fw.Count) off=$fwOff"

    $lua = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -ErrorAction SilentlyContinue).EnableLUA
    Add-VerifyRow 'UAC' $(if ($lua -eq 1) { 'PASS' } else { 'FAIL' }) "EnableLUA=$lua"

    $ss = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name SmartScreenEnabled -ErrorAction SilentlyContinue).SmartScreenEnabled
    Add-VerifyRow 'SmartScreen' $(if ($ss -ne 'Off') { 'PASS' } else { 'FAIL' }) "SmartScreenEnabled=$ss"

    foreach ($svcName in @('wuauserv', 'wscsvc', 'WinDefend', 'mpssvc', 'SecurityHealthService')) {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
        $ok = $svc -and $svc.StartMode -ne 'Disabled'
        Add-VerifyRow "Service $svcName" $(if ($ok) { 'PASS' } else { 'FAIL' }) $(if ($svc) { "start=$($svc.StartMode) state=$($svc.State)" } else { 'missing' })
    }

    $hvci = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name Enabled -ErrorAction SilentlyContinue).Enabled
    Add-VerifyRow 'Memory Integrity (HVCI)' $(if ($hvci -eq 1) { 'PASS' } else { $soft }) "Enabled=$hvci (hardware/OS setting; script never changes it)"

    $sb = $null; try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop } catch { $sb = $null }
    Add-VerifyRow 'Secure Boot' $(if ($sb -eq $true) { 'PASS' } else { $soft }) "value=$sb"

    $tpm = Get-Tpm -ErrorAction SilentlyContinue
    Add-VerifyRow 'TPM' $(if ($tpm -and $tpm.TpmPresent -and $tpm.TpmReady) { 'PASS' } else { $soft }) $(if ($tpm) { "present=$($tpm.TpmPresent) ready=$($tpm.TpmReady)" } else { 'unavailable' })

    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
    Add-VerifyRow 'BitLocker / Device Encryption' $(if ($bl -and "$($bl.ProtectionStatus)" -eq 'On') { 'PASS' } else { $soft }) $(if ($bl) { "protection=$($bl.ProtectionStatus)" } else { 'unavailable' })
}

function Test-RigKeepListPresent {
    foreach ($n in @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI')) {
        $p = Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue
        Add-VerifyRow "Keep-list $n" $(if ($p) { 'PASS' } else { 'FAIL' }) $(if ($p) { 'present' } else { 'MISSING' })
    }
    foreach ($n in @('Microsoft.GamingServices', 'Microsoft.GamingApp', 'Microsoft.XboxIdentityProvider')) {
        $p = Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue
        Add-VerifyRow "Keep-list $n" $(if ($p) { 'PASS' } else { 'WARN' }) $(if ($p) { 'present' } else { 'not installed yet (the Store installs it on first Xbox/Game Pass use)' })
    }
}

function Invoke-RigVerify {
    <# Returns the sign-ins still needed. FAIL rows are added to results; the caller decides the exit code. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$AppsConfig, [switch]$StrictSecurity, [switch]$SkipApps)
    Set-RigPhase 'Verify'
    $signIns = New-Object System.Collections.Generic.List[string]
    if (-not $SkipApps) {
        Update-SessionPath
        foreach ($a in $AppsConfig.Apps) {
            $app = $a
            if ($app.Group -eq 'Gaming' -and (Get-RigOption -Name 'SkipGaming' -Default $false)) { continue }
            if ($app.Group -eq 'Dev' -and (Get-RigOption -Name 'SkipDev' -Default $false)) { continue }
            if ($app.Group -eq 'Optional' -and -not (Get-RigOption -Name $app.Switch -Default $false)) { continue }
            $v = Test-RigAppVerify -App $app
            $status = if ($v.Pass) { 'PASS' } elseif ((Get-RigContext).DryRun) { 'SKIP' } else { 'FAIL' }
            Add-VerifyRow "App $($app.Name)" $status $v.Detail
        }
        $claude = @(Get-Command claude -All -ErrorAction SilentlyContinue)
        if ($claude.Count -gt 0) { Add-VerifyRow 'Single claude on PATH' $(if ($claude.Count -eq 1) { 'PASS' } else { 'WARN' }) "$($claude.Count) found" }
    }
    Test-RigKeepListPresent
    Test-RigSecurityPosture -Strict:$StrictSecurity

    foreach ($s in @('Steam', 'Epic Games Launcher', 'Amazon Games (Prime Gaming)', 'Claude Code (run `claude`)', 'Grok Bot')) { $signIns.Add($s) }
    if (-not (Test-GhAuthStatusQuiet)) { $signIns.Insert(0, 'GitHub (gh auth login --web)') }
    return $signIns.ToArray()
}

function Test-GhAuthStatusQuiet {
    if (-not (Test-Command 'gh')) { return $false }
    return ((Invoke-Native -File 'gh' -Arguments @('auth', 'status')).ExitCode -eq 0)
}

Export-ModuleMember -Function Invoke-RigVerify, Test-RigAppVerify, Test-RigSecurityPosture
