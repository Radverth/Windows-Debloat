BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\modules\Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..\modules\Preflight.psm1') -Force -DisableNameChecking
}

Describe 'Invoke-RigPreflight' {
    It 'halts the run when the restore point fails, so no later step can change anything' {
        $null = Initialize-Rig -Root $TestDrive -Apply
        Mock -ModuleName Preflight Test-RigEnvironment { @() }
        Mock -ModuleName Preflight Test-Command { $true }
        Mock -ModuleName Preflight Assert-Winget { $true }
        Mock -ModuleName Preflight Invoke-RigRestorePoint { [pscustomobject]@{ Name = 'System Restore point'; Status = 'FAIL'; Message = 'denied' } }
        Mock -ModuleName Preflight Export-RigRegistryBackup { [pscustomobject]@{ Name = 'Registry backup'; Status = 'OK'; Message = '' } }
        Invoke-RigPreflight -TweaksConfig @{ Tweaks = @() }
        (Get-RigContext).Halted | Should -BeTrue
        (Invoke-Step -Name 'later' -Phase 'Debloat' -Action { 'changed' }).Status | Should -Be 'SKIP'
    }
    It 'halts when an environment check fails in -Apply mode' {
        $null = Initialize-Rig -Root $TestDrive -Apply
        Mock -ModuleName Preflight Test-RigEnvironment { @([pscustomobject]@{ Status = 'FAIL' }) }
        Invoke-RigPreflight -TweaksConfig @{ Tweaks = @() }
        (Get-RigContext).Halted | Should -BeTrue
    }
}
