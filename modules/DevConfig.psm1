#Requires -Version 5.1
# DevConfig.psm1 - GitHub sign-in (device flow), Git identity, dev folders/PATH, terminal default, VS Code extensions, WSL.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

function Test-GhAuthenticated {
    if (-not (Test-Command 'gh')) { return $false }
    return ((Invoke-Native -File 'gh' -Arguments @('auth', 'status', '--hostname', 'github.com')).ExitCode -eq 0)
}

function Invoke-GhLogin {
    <# Opens Chrome on the device page, runs `gh auth login --web` as the signed-in user, waits for approval. #>
    [CmdletBinding()]
    param([int]$TimeoutSec = 600)
    $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($chrome) { Start-Process -FilePath $chrome -ArgumentList 'https://github.com/login/device' | Out-Null }
    else { Start-Process 'https://github.com/login/device' | Out-Null }
    Write-Log -Message 'A console window shows a one-time code (also copied to the clipboard). Paste it into the GitHub page and approve.'
    $r = Invoke-AsUser -TimeoutSec $TimeoutSec -Script "gh auth login --hostname github.com --git-protocol https --web --clipboard`nexit `$LASTEXITCODE"
    if ($r.ExitCode -ne 0) { throw "gh auth login exit $($r.ExitCode)" }
    if (-not (Test-GhAuthenticated)) { throw 'gh auth status still failing after login' }
}

function Get-GitConfigValue {
    param([Parameter(Mandatory)][string]$Key)
    $r = Invoke-Native -File 'git' -Arguments @('config', '--global', '--get', $Key)
    return (($r.Output -join '') -replace '\s+$', '')
}

function Set-GitIdentity {
    [CmdletBinding()]
    param()
    $json = Invoke-AsUser -TimeoutSec 60 -Script "gh api user --jq '[.name,.login,.id]|@tsv'"
    if ($json.ExitCode -ne 0) { throw 'gh api user failed' }
    $parts = ($json.Output.Trim() -split "`t")
    $login = $parts[1]; $id = $parts[2]
    $name = if ($parts[0]) { $parts[0] } else { $login }
    $email = "$id+$login@users.noreply.github.com"
    $script = @"
git config --global user.name '$($name -replace "'", "''")'
git config --global user.email '$email'
git config --global core.autocrlf input
git config --global init.defaultBranch main
gh auth setup-git
exit 0
"@
    $r = Invoke-AsUser -Script $script -TimeoutSec 120
    if ($r.ExitCode -ne 0) { throw "git config exit $($r.ExitCode)" }
}

function Invoke-RigDevConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$AppsConfig, [Parameter(Mandatory)][hashtable]$TweaksConfig)
    Set-RigPhase 'DevConfig'
    $c = Get-RigContext

    $ready = (Test-Command 'gh') -and (Test-Command 'git')
    if (-not $ready -and -not $c.DryRun) { Update-SessionPath; $ready = (Test-Command 'gh') -and (Test-Command 'git') }

    if ($c.Unattended) { Write-Log -Level Skip -Message 'DevConfig skipped in unattended mode'; return }

    $null = Invoke-Step -Name 'GitHub sign-in (gh auth login --web)' `
        -Test { Test-GhAuthenticated } `
        -Action { if (-not (Test-Command 'gh')) { throw 'gh is not installed' }; Invoke-GhLogin } `
        -UndoNote 'gh auth logout'
    $null = Invoke-Step -Name 'Git identity + gh credential helper' `
        -Test {
            (Test-Command 'git') -and (Test-GhAuthenticated) -and
            ((Get-GitConfigValue 'user.email') -like '*@users.noreply.github.com') -and ((Get-GitConfigValue 'core.autocrlf') -eq 'input') -and ((Get-GitConfigValue 'init.defaultBranch') -eq 'main')
        } `
        -Action { Set-GitIdentity } -UndoNote 'git config --global --unset user.name / user.email'

    Invoke-TweakGroup -Group @('Dev') -Config $TweaksConfig

    $null = Invoke-Step -Name 'Create C:\dev' -Test { Test-Path 'C:\dev' } -Action { New-Item -ItemType Directory -Path 'C:\dev' | Out-Null } -UndoNote 'directory left in place'

    $localBin = Join-Path $env:USERPROFILE '.local\bin'
    $null = Invoke-Step -Name 'Add ~\.local\bin to user PATH' `
        -Test ({ ([Environment]::GetEnvironmentVariable('Path', 'User') -split ';') -contains $localBin }.GetNewClosure()) `
        -Action ({
            $u = [Environment]::GetEnvironmentVariable('Path', 'User')
            Add-Journal -Type 'env-path' -Data @{ scope = 'User'; before = $u }
            [Environment]::SetEnvironmentVariable('Path', (($u, $localBin | Where-Object { $_ }) -join ';'), 'User')
        }.GetNewClosure()) -UndoNote 'user PATH restored from journal'

    # Default terminal = Windows Terminal (GUID {2EACA947-...}); pwsh as WT default profile is left to WT settings.
    $null = Invoke-Step -Name 'Default terminal = Windows Terminal' `
        -Test {
            $k = Get-ItemProperty -Path 'HKCU:\Console\%%Startup' -ErrorAction SilentlyContinue
            [bool]($k -and $k.PSObject.Properties['DelegationTerminal'] -and $k.DelegationTerminal -eq '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}')
        } `
        -Action {
            $null = Set-RegistryValue -Hive HKCU -Path 'Console\%%Startup' -Name 'DelegationConsole' -Type String -Value '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
            $null = Set-RegistryValue -Hive HKCU -Path 'Console\%%Startup' -Name 'DelegationTerminal' -Type String -Value '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
        } -UndoNote 'registry restored from journal'

    $exts = @($AppsConfig.VSCodeExtensions)
    foreach ($e in $exts) {
        $ext = $e
        $null = Invoke-Step -Name "VS Code extension $ext" `
            -Test ({ (Test-Command 'code') -and ((Invoke-Native -File 'code' -Arguments @('--list-extensions')).Output -contains $ext) }.GetNewClosure()) `
            -Action ({
                if (-not (Test-Command 'code')) { throw 'code not on PATH' }
                $r = Invoke-AsUser -Script "code --install-extension $ext --force`nexit `$LASTEXITCODE" -TimeoutSec 300
                if ($r.ExitCode -ne 0) { throw "code --install-extension exit $($r.ExitCode)" }
            }.GetNewClosure()) -UndoNote "code --uninstall-extension $ext"
    }

    if (Get-RigOption -Name 'WithWSL' -Default $false) {
        $null = Invoke-Step -Name 'WSL Ubuntu' `
            -Test { (Test-Command 'wsl') -and ((Invoke-Native -File 'wsl' -Arguments @('--list', '--quiet')).Output -join '' -replace "`0", '') -match 'Ubuntu' } `
            -Action { $r = Invoke-Native -File 'wsl' -Arguments @('--install', '-d', 'Ubuntu', '--no-launch'); if ($r.ExitCode -ne 0) { throw "wsl --install exit $($r.ExitCode)" }; 'reboot may be required' } `
            -UndoNote 'wsl --unregister Ubuntu'
    }

    $null = Invoke-Step -Name 'Prompt: set Chrome as default browser' `
        -Test {
            $p = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction SilentlyContinue
            [bool]($p -and $p.ProgId -like 'ChromeHTML*')
        } `
        -Action ({ Start-Process 'ms-settings:defaultapps'; @{ Status = 'WARN'; Message = 'pick Chrome in Settings > Default apps (Windows blocks silent changes)' } }.GetNewClosure()) -UndoNote 'manual'
}

Export-ModuleMember -Function Invoke-RigDevConfig, Test-GhAuthenticated, Invoke-GhLogin, Set-GitIdentity
