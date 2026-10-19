#Requires -Version 5.1
# Install.psm1 - drives config\apps.psd1: installed? -> winget -> fallback -> refresh PATH -> verify.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

# winget exit codes that mean "nothing to do / already there".
$script:WingetOk = @(0, -1978335189, -1978335135)

function Resolve-RigPath { param([string]$Path) return [Environment]::ExpandEnvironmentVariables($Path) }

function Test-AppInstalled {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App)
    if ($App.ContainsKey('VerifyPaths')) {
        foreach ($p in $App.VerifyPaths) { if (Test-Path (Resolve-RigPath $p)) { return $true } }
        return $false
    }
    if ($App.Key -eq 'claude' -and (Test-Path (Join-Path $env:USERPROFILE '.local\bin\claude.exe'))) { return $true }
    if ($App.Key -eq 'grokbot') { return [bool](Get-RigStartMenuEntry -Pattern $App.VerifyShortcut) }
    if ($App.ContainsKey('Command')) { return (Test-Command $App.Command) }
    return $false
}

function Get-RigStartMenuEntry {
    param([Parameter(Mandatory)][string]$Pattern)
    $roots = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs")
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        $hit = Get-ChildItem -Path $r -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -like $Pattern } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Invoke-WingetInstall {
    <# Returns $true on success. Retries once without --scope when the package has no installer for that scope. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [string]$Scope = 'machine', [switch]$AsUser)
    $verify = Invoke-Native -File 'winget' -Arguments @('show', '--id', $Id, '-e', '--accept-source-agreements')
    if ($verify.ExitCode -ne 0) { Write-Log -Level Warn -Message "winget cannot resolve id '$Id' (re-verify it with: winget show --id $Id -e)"; return $false }
    $base = @('install', '--id', $Id, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    foreach ($withScope in @($true, $false)) {
        $argv = $base; if ($withScope -and $Scope) { $argv = $base + @('--scope', $Scope) }
        if ($AsUser) {
            $r = Invoke-AsUser -Script ("winget " + ($argv -join ' ') + "`nexit `$LASTEXITCODE")
        }
        else { $r = Invoke-Native -File 'winget' -Arguments $argv }
        if ($script:WingetOk -contains $r.ExitCode) { Update-SessionPath; return $true }
        Write-Log -Level Warn -Message "winget install $Id (scope=$withScope) exit $($r.ExitCode)"
        if (-not $Scope) { break }
    }
    return $false
}

function Install-GitHubMsi {
    <# Latest release MSI from a GitHub repo. Authenticode must be Valid. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$AssetPattern)
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'AIGamingRig' }
    $asset = $rel.assets | Where-Object { $_.name -like $AssetPattern } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching $AssetPattern in $Repo latest release" }
    $dir = Join-Path $env:TEMP ('rig-dl-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $file = Join-Path $dir $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $file -UseBasicParsing
        $sig = Get-AuthenticodeSignature -FilePath $file
        if ($sig.Status -ne 'Valid') { throw "Signature check failed for $($asset.name): $($sig.Status)" }
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$file`"", '/qn', '/norestart') -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { throw "msiexec exit $($p.ExitCode)" }
        Update-SessionPath
    }
    finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-ClaudeCode {
    <# Native per-user installer, non-elevated. Never also installs the winget package (PATH conflict, claude-code #31980). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App)
    $r = Invoke-AsUser -Script "irm $($App.NativeUrl) | iex`nexit 0"
    if ($r.ExitCode -ne 0) { throw "Claude Code native installer exit $($r.ExitCode)" }
    $bin = Join-Path $env:USERPROFILE '.local\bin'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $bin) { [Environment]::SetEnvironmentVariable('Path', (($userPath, $bin | Where-Object { $_ }) -join ';'), 'User') }
    Update-SessionPath
    $all = @(Get-Command claude -All -ErrorAction SilentlyContinue)
    if ($all.Count -gt 1) { return @{ Status = 'WARN'; Message = "multiple claude on PATH: $(($all | ForEach-Object Source) -join '; ')" } }
}

function Install-GrokBot {
    <# winget (xAI publisher) first; else signed installer from the official download URL in apps.psd1; else FAIL with the manual URL. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App)
    $s = Invoke-Native -File 'winget' -Arguments @('search', $App.WingetSearch, '--accept-source-agreements')
    $hit = $s.Output | Where-Object { $_ -match '\b(?:xAI|SpaceXAI)\.[A-Za-z0-9.]+\b' } | Select-Object -First 1
    if ($hit -and ($hit -match '\b((?:xAI|SpaceXAI)\.[A-Za-z0-9.]+)\b')) {
        $id = $Matches[1]
        if (Invoke-WingetInstall -Id $id -Scope '') { return "winget $id" }
    }
    if (-not $App.DownloadUrl) { throw "No automated source for $($App.Name). Install manually from $($App.ManualUrl), then re-run." }
    $uri = [uri]$App.DownloadUrl
    if ($uri.Scheme -ne 'https' -or $uri.Host -notin 'x.ai', 'www.x.ai', 'api2.cursor.sh') { throw "Download host '$($uri.Host)' is not an allowed vendor host." }
    $dir = Join-Path $env:TEMP ('rig-dl-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $file = Join-Path $dir 'GrokBotSetup.exe'
        Invoke-WebRequest -Uri $App.DownloadUrl -OutFile $file -UseBasicParsing
        $sig = Get-AuthenticodeSignature -FilePath $file
        $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
        Write-Log -Message "Grok Bot installer signature: $($sig.Status) / $signer"
        if ($sig.Status -ne 'Valid') { throw "Installer signature is $($sig.Status)" }
        $ok = $false; foreach ($n in $App.AllowedSigners) { if ($signer -like "*$n*") { $ok = $true } }
        if (-not $ok) { throw "Signer '$signer' is not in AllowedSigners." }
        $r = Invoke-AsUser -Script ("`$p = Start-Process -FilePath '$file' " + $(if ($App.SilentArgs) { "-ArgumentList '$($App.SilentArgs)' " } else { '' }) + "-Wait -PassThru`nexit `$p.ExitCode")
        if ($r.ExitCode -ne 0) { throw "Installer exit $($r.ExitCode)" }
    }
    finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    return "signature Valid ($signer)"
}

function Install-RigApp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$App)
    $asUser = $App.ContainsKey('AsUser') -and $App.AsUser
    if ($App.ContainsKey('Installer')) {
        switch ($App.Installer) {
            'ClaudeNative' {
                try { return (Install-ClaudeCode -App $App) }
                catch {
                    if (-not $App.ContainsKey('Fallback')) { throw }
                    Write-Log -Level Warn -Message "Claude native install failed ($($_.Exception.Message)); trying winget fallback"
                    if (Invoke-WingetInstall -Id $App.Fallback.WingetId -Scope '') { return }
                    throw
                }
            }
            'GrokBot' { return (Install-GrokBot -App $App) }
        }
        return
    }
    $scope = if ($App.ContainsKey('Scope')) { $App.Scope } else { 'machine' }
    if (Invoke-WingetInstall -Id $App.WingetId -Scope $scope -AsUser:$asUser) { return }
    if ($App.ContainsKey('Fallback')) {
        $f = $App.Fallback
        Write-Log -Level Warn -Message "Primary install failed for $($App.Name); trying fallback ($($f.Type))"
        if ($f.Type -eq 'Winget') {
            $fs = if ($f.ContainsKey('Scope')) { $f.Scope } else { $scope }
            if (Invoke-WingetInstall -Id $f.WingetId -Scope $fs -AsUser:$asUser) { return }
        }
        elseif ($f.Type -eq 'GitHubMsi') { Install-GitHubMsi -Repo $f.Repo -AssetPattern $f.AssetPattern; return }
    }
    throw "Could not install $($App.Name)."
}

function Invoke-RigInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    Set-RigPhase 'Install'
    foreach ($a in $Config.Apps) {
        $app = $a
        if ($app.Group -eq 'Gaming' -and (Get-RigOption -Name 'SkipGaming' -Default $false)) { continue }
        if ($app.Group -eq 'Dev' -and (Get-RigOption -Name 'SkipDev' -Default $false)) { continue }
        if ($app.Group -eq 'Optional' -and -not (Get-RigOption -Name $app.Switch -Default $false)) { continue }
        $null = Invoke-Step -Name "Install $($app.Name)" `
            -Test ({ Update-SessionPath; Test-AppInstalled -App $app }.GetNewClosure()) `
            -Action ({
                $msg = Install-RigApp -App $app
                Update-SessionPath
                if (-not (Test-AppInstalled -App $app)) { throw "$($app.Name) installed but verification failed" }
                $msg
            }.GetNewClosure()) `
            -UndoNote "winget uninstall $(if ($app.ContainsKey('WingetId')) { $app.WingetId } else { $app.Name })"
    }
}

Export-ModuleMember -Function Test-AppInstalled, Invoke-WingetInstall, Install-RigApp, Invoke-RigInstall, Resolve-RigPath, Get-RigStartMenuEntry
