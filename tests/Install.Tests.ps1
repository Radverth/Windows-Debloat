BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\modules\Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..\modules\Install.psm1') -Force -DisableNameChecking
}

Describe 'Invoke-WingetInstall' {
    It 'returns $false and installs nothing when the id does not resolve' {
        Mock -ModuleName Install Invoke-Native { [pscustomobject]@{ ExitCode = 1; Output = @() } }
        Invoke-WingetInstall -Id 'No.Such.Id' | Should -BeFalse
        Should -Invoke -ModuleName Install Invoke-Native -Times 1 -ParameterFilter { $Arguments[0] -eq 'show' }
    }
    It 'treats "already installed" exit code as success' {
        Mock -ModuleName Install Update-SessionPath { }
        Mock -ModuleName Install Invoke-Native {
            if ($Arguments[0] -eq 'show') { [pscustomobject]@{ ExitCode = 0; Output = @() } } else { [pscustomobject]@{ ExitCode = -1978335189; Output = @() } }
        }
        Invoke-WingetInstall -Id 'Git.Git' | Should -BeTrue
    }
    It 'retries without --scope when the scoped install fails' {
        Mock -ModuleName Install Update-SessionPath { }
        $script:calls = 0
        Mock -ModuleName Install Invoke-Native {
            if ($Arguments[0] -eq 'show') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            $script:calls++
            [pscustomobject]@{ ExitCode = $(if ($Arguments -contains '--scope') { 1 } else { 0 }); Output = @() }
        }
        Invoke-WingetInstall -Id 'X.Y' -Scope machine | Should -BeTrue
    }
}

Describe 'Test-AppInstalled' {
    It 'uses VerifyPaths with environment expansion' {
        $env:RIG_TEST_DIR = $TestDrive
        New-Item -ItemType File -Path (Join-Path $TestDrive 'app.exe') | Out-Null
        Test-AppInstalled -App @{ Key = 'x'; VerifyPaths = @('%RIG_TEST_DIR%\app.exe') } | Should -BeTrue
        Test-AppInstalled -App @{ Key = 'x'; VerifyPaths = @('%RIG_TEST_DIR%\missing.exe') } | Should -BeFalse
    }
}
