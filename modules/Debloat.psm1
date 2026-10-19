#Requires -Version 5.1
# Debloat.psm1 - Appx removal (all users + provisioned), optional capabilities/features, services -> Manual,
# startup trimming, privacy/UI registry tweaks. Everything is list-driven from config\debloat.psd1 / tweaks.psd1.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

# Provisioned packages under these prefixes are never swept, whatever the lists say.
$script:ProvisionedNeverSweep = @('Microsoft.Windows*', 'MicrosoftWindows.*', 'Windows.*', 'windows.*', 'Microsoft.NET*', 'Microsoft.VCLibs*', 'Microsoft.UI.Xaml*')
# Must still be installed for an unattended run to continue (safety valve).
$script:CoreRequired = @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI')

function Get-RigKeepPatterns {
    <# Hard keep-list + switch-driven keeps + user ExtraKeep. Never shrinks below config.Protected. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($e in $Config.Protected) { $p.Add([string]$e.Pattern) }
    if (Get-RigOption -Name 'KeepCopilot' -Default $false) { $p.Add('Microsoft.Copilot*'); $p.Add('Microsoft.Windows.Ai.Copilot*') }
    if (Get-RigOption -Name 'KeepStickyNotes' -Default $false) { $p.Add('Microsoft.MicrosoftStickyNotes') }
    foreach ($k in @(Get-RigOption -Name 'ExtraKeep' -Default @())) { if ($k) { $p.Add([string]$k) } }
    return $p.ToArray()
}

function Test-RigProtected {
    <# $true when Name matches the HARD Protected list (not just the optional keeps). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Config)
    foreach ($e in $Config.Protected) { if ($Name -like [string]$e.Pattern) { return $true } }
    return $false
}

function Test-NameMatch {
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
    return $false
}

function Get-RigRemovalPlan {
    <#
    .SYNOPSIS Pure planner: which package Names to remove, and why.
    .PARAMETER Installed  Objects with Name, IsFramework, NonRemovable, SignatureKind (Get-AppxPackage -AllUsers shape).
    .PARAMETER Provisioned Objects with DisplayName (Get-AppxProvisionedPackage shape).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [ValidateSet('Standard', 'Lean')][string]$Level = 'Lean',
        [object[]]$Installed = @(), [object[]]$Provisioned = @()
    )
    $keep = Get-RigKeepPatterns -Config $Config
    $plan = [ordered]@{}   # Name -> Reason

    $named = @($Config.Remove)
    if ($Level -eq 'Lean') { $named += @($Config.LeanRemove) }
    $allNames = @(@($Installed | ForEach-Object { $_.Name }) + @($Provisioned | ForEach-Object { $_.DisplayName }) | Where-Object { $_ } | Sort-Object -Unique)

    foreach ($e in $named) {
        if ($e.ContainsKey('Flag') -and (Get-RigOption -Name $e.Flag -Default $false)) { continue }
        foreach ($n in $allNames) {
            if ($n -like [string]$e.Pattern -and -not (Test-NameMatch $n $keep)) { $plan[$n] = [string]$e.Reason }
        }
    }

    if ($Level -eq 'Lean') {
        $safe = @($Config.LeanSafetyKeep)
        foreach ($p in $Installed) {
            if ($p.IsFramework -or $p.NonRemovable -or "$($p.SignatureKind)" -eq 'System') { continue }
            if ((Test-NameMatch $p.Name $keep) -or (Test-NameMatch $p.Name $safe)) { continue }
            if (-not $plan.Contains($p.Name)) { $plan[$p.Name] = 'Lean sweep: not on keep-list' }
        }
        foreach ($p in $Provisioned) {
            $n = [string]$p.DisplayName
            if ((Test-NameMatch $n $keep) -or (Test-NameMatch $n $safe) -or (Test-NameMatch $n $script:ProvisionedNeverSweep)) { continue }
            if (-not $plan.Contains($n)) { $plan[$n] = 'Lean sweep: provisioned, not on keep-list' }
        }
    }
    return $plan
}

function Remove-RigAppx {
    <# Removes one package Name for all users + the provisioned copy. Refuses anything on the hard Protected list. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Config)
    if (Test-RigProtected -Name $Name -Config $Config) { throw "Refusing to remove protected package '$Name'." }
    foreach ($pkg in @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue)) {
        if ($pkg.NonRemovable -or $pkg.IsFramework) { continue }
        Add-Journal -Type 'appx' -Data @{
            name = $pkg.Name; fullName = $pkg.PackageFullName; family = $pkg.PackageFamilyName; version = "$($pkg.Version)"
            reinstall = "Start-Process 'ms-windows-store://pdp/?PFN=$($pkg.PackageFamilyName)'   # or: winget install --name `"$($pkg.Name)`" --source msstore"
        }
        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
    }
    foreach ($prov in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Name })) {
        Add-Journal -Type 'appx-provisioned' -Data @{ name = $prov.DisplayName; packageName = $prov.PackageName }
        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
    }
}

function Test-RigAppxGone {
    param([Parameter(Mandatory)][string]$Name)
    $inst = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue)
    $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Name })
    return ($inst.Count -eq 0 -and $prov.Count -eq 0)
}

function Stop-OnFailure {
    param($Result)
    if ($Result -and $Result.Status -eq 'FAIL' -and (Get-RigContext).Unattended) { Stop-Rig "step failed in unattended run: $($Result.Name)" }
}

function Invoke-RigDebloat {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    Set-RigPhase 'Debloat'
    $c = Get-RigContext
    $level = Get-RigOption -Name 'Level' -Default 'Lean'

    # Safety valve for unattended runs: core packages must still be there.
    if ($c.Unattended -and -not $c.DryRun) {
        foreach ($core in $script:CoreRequired) {
            if (-not (Get-AppxPackage -AllUsers -Name $core -ErrorAction SilentlyContinue)) { Stop-Rig "keep-list package missing: $core"; return }
        }
    }

    $installed = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
    $plan = Get-RigRemovalPlan -Config $Config -Level $level -Installed $installed -Provisioned $prov
    foreach ($name in $plan.Keys) {
        $n = $name
        $r = Invoke-Step -Name "Remove Appx $n ($($plan[$n]))" `
            -Test ({ Test-RigAppxGone -Name $n }.GetNewClosure()) `
            -Action ({ Remove-RigAppx -Name $n -Config $Config }.GetNewClosure()) `
            -UndoNote 'Reinstall from Microsoft Store (see journal)'
        Stop-OnFailure $r
    }

    if ($level -eq 'Lean') {
        foreach ($cap in $Config.Capabilities) {
            $cn = [string]$cap.Name
            $r = Invoke-Step -Name "Remove capability $cn ($($cap.Reason))" `
                -Test ({ -not (Get-WindowsCapability -Online -Name $cn -ErrorAction SilentlyContinue | Where-Object State -eq 'Installed') }.GetNewClosure()) `
                -Action ({
                    foreach ($w in @(Get-WindowsCapability -Online -Name $cn | Where-Object State -eq 'Installed')) {
                        Add-Journal -Type 'capability' -Data @{ name = $w.Name }
                        $null = Remove-WindowsCapability -Online -Name $w.Name -ErrorAction Stop
                    }
                }.GetNewClosure()) -UndoNote 'Add-WindowsCapability -Online -Name <name>'
            Stop-OnFailure $r
        }
        foreach ($feat in $Config.OptionalFeatures) {
            $fn = [string]$feat.Name
            $r = Invoke-Step -Name "Disable feature $fn ($($feat.Reason))" `
                -Test ({ $f = Get-WindowsOptionalFeature -Online -FeatureName $fn -ErrorAction SilentlyContinue; (-not $f) -or $f.State -ne 'Enabled' }.GetNewClosure()) `
                -Action ({ Add-Journal -Type 'feature' -Data @{ name = $fn }; $null = Disable-WindowsOptionalFeature -Online -FeatureName $fn -NoRestart -ErrorAction Stop }.GetNewClosure()) `
                -UndoNote 'Enable-WindowsOptionalFeature -Online -FeatureName <name>'
            Stop-OnFailure $r
        }
    }

    foreach ($svc in $Config.ServicesManual) {
        if ($svc.Level -eq 'Lean' -and $level -ne 'Lean') { continue }
        if ($svc.ContainsKey('Flag') -and -not (Get-RigOption -Name $svc.Flag -Default $false)) { continue }
        $sn = [string]$svc.Name
        $r = Invoke-Step -Name "Service $sn -> Manual ($($svc.Reason))" `
            -Test ({ Test-ServiceNotAuto -Name $sn }.GetNewClosure()) `
            -Action ({ $null = Set-ServiceManual -Name $sn }.GetNewClosure()) `
            -UndoNote 'Start mode restored from journal'
        Stop-OnFailure $r
    }

    if ($level -eq 'Lean') { Invoke-StartupDisable -Pattern @($Config.StartupDisable) }

    if (Get-RigOption -Name 'RemoveOneDrive' -Default $false) {
        $r = Invoke-Step -Name 'Uninstall OneDrive' `
            -Test {
                -not ((Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe") -or (Test-Path "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe") -or (Test-Path "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe"))
            } `
            -Action {
                Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force
                $setup = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"; if (-not (Test-Path $setup)) { $setup = "$env:SystemRoot\System32\OneDriveSetup.exe" }
                Add-Journal -Type 'note' -Data @{ text = 'OneDrive uninstalled. Reinstall: winget install --id Microsoft.OneDrive -e' }
                $p = Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -PassThru
                if ($p.ExitCode -ne 0) { throw "OneDriveSetup exit $($p.ExitCode)" }
            } -UndoNote 'winget install --id Microsoft.OneDrive -e'
        Stop-OnFailure $r
    }
}

function Invoke-RigTweaks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$TweaksConfig)
    Set-RigPhase 'Tweaks'
    $c = Get-RigContext
    Invoke-TweakGroup -Group @('Privacy', 'Explorer') -Config $TweaksConfig
    # One Explorer restart (not a reboot) when something changed. Skipped unattended so a running session isn't disturbed.
    $changed = @($c.Results | Where-Object { $_.Status -eq 'OK' -and $_.Phase -in @('Debloat', 'Tweaks') }).Count -gt 0
    $null = Invoke-Step -Name 'Restart Explorer' -Phase 'Tweaks' -UndoNote 'none' `
        -Test ({ $c.Unattended -or -not $changed }.GetNewClosure()) `
        -Action { Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force }
}

Export-ModuleMember -Function Get-RigKeepPatterns, Test-RigProtected, Get-RigRemovalPlan, Remove-RigAppx, Invoke-RigDebloat, Invoke-RigTweaks
