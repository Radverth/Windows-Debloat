BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\modules\Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..\modules\Debloat.psm1') -Force -DisableNameChecking
    $script:cfg = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\config\debloat.psd1')
    function global:New-Pkg($n, $fw = $false, $nr = $false, $sig = 'Store') { [pscustomobject]@{ Name = $n; IsFramework = $fw; NonRemovable = $nr; SignatureKind = $sig } }
}

Describe 'Protected keep-list' {
    BeforeEach { $null = Initialize-Rig -Root $PSScriptRoot -Options @{ Level = 'Lean' } }

    It 'is never planned for removal, at either level' {
        $protected = 'Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI', 'Microsoft.GamingApp', 'Microsoft.GamingServices',
            'Microsoft.XboxIdentityProvider', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxGamingOverlay', 'Microsoft.WindowsTerminal', 'Microsoft.VCLibs.140.00',
            'Microsoft.UI.Xaml.2.8', 'Microsoft.NET.Native.Runtime.2.2', 'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.ScreenSketch',
            'Microsoft.WindowsNotepad', 'Microsoft.Paint', 'Microsoft.WebView2Runtime'
        $installed = $protected | ForEach-Object { New-Pkg $_ }
        foreach ($level in 'Standard', 'Lean') {
            $plan = Get-RigRemovalPlan -Config $script:cfg -Level $level -Installed $installed -Provisioned ($protected | ForEach-Object { [pscustomobject]@{ DisplayName = $_ } })
            $plan.Count | Should -Be 0 -Because "level $level removed: $($plan.Keys -join ', ')"
        }
    }
    It 'makes Remove-RigAppx throw for protected names before touching anything' {
        { Remove-RigAppx -Name 'Microsoft.WindowsStore' -Config $script:cfg } | Should -Throw '*protected*'
        { Remove-RigAppx -Name 'Microsoft.XboxIdentityProvider' -Config $script:cfg } | Should -Throw '*protected*'
    }
}

Describe 'Get-RigRemovalPlan' {
    BeforeEach { $null = Initialize-Rig -Root $PSScriptRoot -Options @{ Level = 'Lean' } }

    It 'Standard removes only the named list' {
        $inst = @((New-Pkg 'Microsoft.BingNews'), (New-Pkg 'SomeRandom.App'))
        $plan = Get-RigRemovalPlan -Config $script:cfg -Level Standard -Installed $inst
        $plan.Keys | Should -Contain 'Microsoft.BingNews'
        $plan.Keys | Should -Not -Contain 'SomeRandom.App'
    }
    It 'Lean also sweeps unlisted store apps but not frameworks, NonRemovable, System-signed or safety-keep packages' {
        $inst = @((New-Pkg 'SomeRandom.App'), (New-Pkg 'Some.Framework' $true), (New-Pkg 'Some.Core' $false $true), (New-Pkg 'Some.Sys' $false $false 'System'),
            (New-Pkg 'NVIDIACorp.NVIDIAControlPanel'), (New-Pkg 'Microsoft.MicrosoftEdge.Stable'))
        $plan = Get-RigRemovalPlan -Config $script:cfg -Level Lean -Installed $inst
        $plan.Keys | Should -Be @('SomeRandom.App')
    }
    It 'honours -KeepCopilot' {
        $null = Initialize-Rig -Root $PSScriptRoot -Options @{ Level = 'Lean'; KeepCopilot = $true }
        $plan = Get-RigRemovalPlan -Config $script:cfg -Level Lean -Installed @((New-Pkg 'Microsoft.Copilot'))
        $plan.Count | Should -Be 0
    }
    It 'honours ExtraKeep' {
        $null = Initialize-Rig -Root $PSScriptRoot -Options @{ Level = 'Lean'; ExtraKeep = @('SomeRandom.*') }
        (Get-RigRemovalPlan -Config $script:cfg -Level Lean -Installed @((New-Pkg 'SomeRandom.App'))).Count | Should -Be 0
    }
    It 'never sweeps system-looking provisioned packages' {
        $plan = Get-RigRemovalPlan -Config $script:cfg -Level Lean -Provisioned @([pscustomobject]@{ DisplayName = 'Microsoft.Windows.CloudExperienceHost' }, [pscustomobject]@{ DisplayName = 'Foo.Bar' })
        $plan.Keys | Should -Be @('Foo.Bar')
    }
}
