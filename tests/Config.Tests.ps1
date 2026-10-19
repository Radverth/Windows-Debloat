BeforeAll {
    $script:cfgDir = Join-Path $PSScriptRoot '..\config'
    $script:debloat = Import-PowerShellDataFile (Join-Path $script:cfgDir 'debloat.psd1')
    $script:tweaks  = Import-PowerShellDataFile (Join-Path $script:cfgDir 'tweaks.psd1')
    $script:apps    = Import-PowerShellDataFile (Join-Path $script:cfgDir 'apps.psd1')
}

Describe 'debloat.psd1' {
    It 'gives every removal a Reason' {
        foreach ($e in @($script:debloat.Remove) + @($script:debloat.LeanRemove) + @($script:debloat.Protected)) { $e.Reason | Should -Not -BeNullOrEmpty -Because $e.Pattern }
    }
    It 'protects the plan''s must-keep packages' {
        $must = 'Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI', 'Microsoft.GamingApp', 'Microsoft.GamingServices', 'Microsoft.XboxIdentityProvider', 'Microsoft.WindowsTerminal'
        foreach ($m in $must) { (@($script:debloat.Protected | Where-Object { $m -like $_.Pattern }).Count) | Should -BeGreaterThan 0 -Because $m }
    }
    It 'never lists a protected package for removal' {
        foreach ($e in @($script:debloat.Remove) + @($script:debloat.LeanRemove)) {
            foreach ($p in $script:debloat.Protected) { $e.Pattern | Should -Not -Be $p.Pattern }
        }
    }
    It 'never sets a service to Disabled (only Manual lists exist)' {
        $script:debloat.Keys | Should -Not -Contain 'ServicesDisabled'
    }
}

Describe 'tweaks.psd1' {
    It 'has unique ids, a Reason and a valid hive/type for every tweak' {
        $ids = @($script:tweaks.Tweaks | ForEach-Object Id)
        ($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        foreach ($t in $script:tweaks.Tweaks) {
            $t.Reason | Should -Not -BeNullOrEmpty -Because $t.Id
            $t.Hive | Should -BeIn 'HKCU', 'HKLM'
            $t.Type | Should -BeIn 'DWord', 'String'
        }
    }
    It 'never touches Defender, UAC or SmartScreen' {
        foreach ($t in $script:tweaks.Tweaks) { "$($t.Path)\$($t.Name)" | Should -Not -Match 'Windows Defender|EnableLUA|SmartScreen|ConsentPromptBehavior' }
    }
}

Describe 'apps.psd1' {
    It 'has a unique key, a name and an install source for every app' {
        $keys = @($script:apps.Apps | ForEach-Object Key)
        ($keys | Select-Object -Unique).Count | Should -Be $keys.Count
        foreach ($a in $script:apps.Apps) { ($a.WingetId -or $a.Installer) | Should -BeTrue -Because $a.Key }
    }
    It 'uses the native Claude Code installer, not the winget package, as primary' {
        $c = $script:apps.Apps | Where-Object Key -eq 'claude'
        $c.Installer | Should -Be 'ClaudeNative'
        $c.ContainsKey('WingetId') | Should -BeFalse
    }
}
