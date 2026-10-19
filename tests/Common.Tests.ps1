BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\modules\Common.psm1') -Force -DisableNameChecking
}

Describe 'Invoke-Step' {
    BeforeEach { $null = Initialize-Rig -Root $PSScriptRoot -Options @{} }

    It 'reports SKIP and never runs the action when the test passes' {
        $script:ran = $false
        $r = Invoke-Step -Name 'a' -Phase 'T' -Test { $true } -Action { $script:ran = $true }
        $r.Status | Should -Be 'SKIP'
        $script:ran | Should -BeFalse
    }
    It 'does not run the action in a dry run' {
        $script:ran = $false
        $r = Invoke-Step -Name 'b' -Phase 'T' -Test { $false } -Action { $script:ran = $true }
        $r.Status | Should -Be 'DRYRUN'
        $script:ran | Should -BeFalse
    }
    It 'runs the action with -Apply and reports OK' {
        $null = Initialize-Rig -Root $PSScriptRoot -Apply
        $script:ran = $false
        $r = Invoke-Step -Name 'c' -Phase 'T' -Test { $false } -Action { $script:ran = $true }
        $r.Status | Should -Be 'OK'
        $script:ran | Should -BeTrue
    }
    It 'reports FAIL (not a throw) when the action throws' {
        $null = Initialize-Rig -Root $PSScriptRoot -Apply
        $r = Invoke-Step -Name 'd' -Phase 'T' -Action { throw 'boom' }
        $r.Status | Should -Be 'FAIL'
        $r.Message | Should -Be 'boom'
    }
    It 'passes WARN status through from the action' {
        $null = Initialize-Rig -Root $PSScriptRoot -Apply
        (Invoke-Step -Name 'e' -Phase 'T' -Action { @{ Status = 'WARN'; Message = 'm' } }).Status | Should -Be 'WARN'
    }
    It 'skips everything after Stop-Rig' {
        $null = Initialize-Rig -Root $PSScriptRoot -Apply
        Stop-Rig 'test halt'
        $script:ran = $false
        $r = Invoke-Step -Name 'f' -Phase 'T' -Action { $script:ran = $true }
        $r.Status | Should -Be 'SKIP'
        $script:ran | Should -BeFalse
    }
    It 'treats a throwing Test as not-done' {
        $null = Initialize-Rig -Root $PSScriptRoot -Apply
        (Invoke-Step -Name 'g' -Phase 'T' -Test { throw 'x' } -Action { 'ok' }).Status | Should -Be 'OK'
    }
}

Describe 'Test-TweakApplies' {
    It 'honours Level and Flag / NotFlag' {
        $null = Initialize-Rig -Root $PSScriptRoot -Options @{ Level = 'Standard'; KeepCopilot = $true }
        Test-TweakApplies -Tweak @{ Level = 'Lean' } | Should -BeFalse
        Test-TweakApplies -Tweak @{ Level = 'Standard' } | Should -BeTrue
        Test-TweakApplies -Tweak @{ Flag = 'NotKeepCopilot' } | Should -BeFalse
        Test-TweakApplies -Tweak @{ Flag = 'KeepCopilot' } | Should -BeTrue
        Test-TweakApplies -Tweak @{ Flag = 'ClassicContextMenu' } | Should -BeFalse
    }
}

Describe 'Dry run journals nothing' {
    It 'Add-Journal is a no-op in a dry run' {
        $null = Initialize-Rig -Root $TestDrive
        Add-Journal -Type 'registry' -Data @{ key = 'x' }
        Test-Path (Get-RigContext).JournalPath | Should -BeFalse
    }
    It 'Add-Journal writes JSON lines with -Apply' {
        $null = Initialize-Rig -Root $TestDrive -Apply
        Add-Journal -Type 'service' -Data @{ name = 'Fax'; startMode = 'Auto' }
        $line = Get-Content (Get-RigContext).JournalPath | Select-Object -First 1 | ConvertFrom-Json
        $line.type | Should -Be 'service'
        $line.name | Should -Be 'Fax'
    }
}
