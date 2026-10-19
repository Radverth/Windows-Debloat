#Requires -Version 5.1
# GamingTune.psm1 - power plan, Game Mode, HAGS, Game Bar capture off, mouse acceleration off, launcher autostart off.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

$script:HighPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:Ultimate        = 'e9a42b02-d5df-448d-aa00-03f14749eb61'

function Get-ActivePowerScheme {
    <# Returns @{Guid; Name} of the active scheme. #>
    $r = Invoke-Native -File 'powercfg.exe' -Arguments @('/getactivescheme')
    $text = ($r.Output -join ' ')
    if ($text -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})\s*(?:\(([^)]*)\))?') { return @{ Guid = $Matches[1].ToLower(); Name = "$($Matches[2])" } }
    return @{ Guid = $null; Name = '' }
}

function Test-IsDesktop { return -not [bool](Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue) }

function Set-RigPowerPlan {
    [CmdletBinding()]
    param()
    $w = $script:HighPerformance
    $label = 'High Performance'
    $namePattern = 'High performance'
    if (Test-IsDesktop) { $w = $script:Ultimate; $label = 'Ultimate Performance (desktop)'; $namePattern = 'Ultimate Performance' }
    $null = Invoke-Step -Name "Power plan: $label" -Phase 'GamingTune' `
        -Test ({ (Get-ActivePowerScheme).Name -like "*$namePattern*" }.GetNewClosure()) `
        -Action ({
            Add-Journal -Type 'powerplan' -Data @{ scheme = (Get-ActivePowerScheme).Guid }
            $list = (Invoke-Native -File 'powercfg.exe' -Arguments @('/list')).Output -join ' '
            if ($list -notmatch $w) {
                $d = Invoke-Native -File 'powercfg.exe' -Arguments @('-duplicatescheme', $w)
                if ($d.ExitCode -ne 0) { throw "powercfg -duplicatescheme exit $($d.ExitCode)" }
                $list = (Invoke-Native -File 'powercfg.exe' -Arguments @('/list')).Output -join ' '
            }
            # duplicatescheme assigns a new GUID for Ultimate on some builds; activate whatever the list says.
            $target = $w
            if ($list -notmatch $w -and $list -match 'Ultimate Performance') { $target = (([regex]::Matches($list, '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})\s+\(Ultimate Performance') | Select-Object -First 1).Groups[1].Value) }
            $s = Invoke-Native -File 'powercfg.exe' -Arguments @('/setactive', $target)
            if ($s.ExitCode -ne 0) { throw "powercfg /setactive exit $($s.ExitCode)" }
        }.GetNewClosure()) -UndoNote 'powercfg /setactive <previous scheme from journal>'
}

function Invoke-RigGamingTune {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$TweaksConfig)
    Set-RigPhase 'GamingTune'
    Set-RigPowerPlan
    Invoke-TweakGroup -Group @('Gaming') -Config $TweaksConfig
    Invoke-StartupDisable -Pattern @('Steam', 'EpicGamesLauncher', 'Amazon Games*', 'AmazonGames*')
    Write-Log -Level Warn -Message 'Reminder: install the GPU driver yourself from NVIDIA or AMD (not automated). HAGS needs a reboot and a supported driver.'
}

Export-ModuleMember -Function Invoke-RigGamingTune, Set-RigPowerPlan, Get-ActivePowerScheme
