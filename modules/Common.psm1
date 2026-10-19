#Requires -Version 5.1
# Common.psm1 - logging, step runner (dry run / idempotency / results), registry + service helpers with journaling,
# winget bootstrap, run-as-user. Syntax stays 5.1-compatible so Preflight can run before PowerShell 7 exists.

Set-StrictMode -Version 2.0

$script:Ctx = $null

#region Context

function Initialize-Rig {
    <# Creates the run context every other module reads through Get-RigContext. Returns it. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$Apply,
        [switch]$Unattended,
        [hashtable]$Options = @{},
        [string]$DataRoot,       # where logs\ and backup\ live (defaults to $Root)
        [string]$Timestamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    )
    if (-not $DataRoot) { $DataRoot = $Root }
    $script:Ctx = [pscustomobject]@{
        Root         = $Root
        DataRoot     = $DataRoot
        DryRun       = -not $Apply.IsPresent
        Unattended   = $Unattended.IsPresent
        Options      = $Options
        Timestamp    = $Timestamp
        LogDir       = Join-Path $DataRoot 'logs'
        BackupDir    = Join-Path (Join-Path $DataRoot 'backup') $Timestamp
        JournalPath  = Join-Path (Join-Path (Join-Path $DataRoot 'backup') $Timestamp) 'journal.jsonl'
        Phase        = ''
        Halted       = $false
        HaltReason   = ''
        Results      = New-Object System.Collections.Generic.List[object]
        Started      = Get-Date
    }
    return $script:Ctx
}

function Get-RigContext {
    if (-not $script:Ctx) { throw 'Rig context not initialised. Call Initialize-Rig first.' }
    return $script:Ctx
}

function Set-RigPhase { param([Parameter(Mandatory)][string]$Name) (Get-RigContext).Phase = $Name }

function Stop-Rig {
    <# Safety valve: later Invoke-Step calls report SKIP (halted) instead of changing anything. #>
    param([Parameter(Mandatory)][string]$Reason)
    $c = Get-RigContext
    $c.Halted = $true
    $c.HaltReason = $Reason
    Write-Log -Level Error -Message "HALT: $Reason"
}

function Get-RigOption {
    param([Parameter(Mandatory)][string]$Name, $Default = $false)
    $c = Get-RigContext
    if ($c.Options.ContainsKey($Name)) { return $c.Options[$Name] }
    return $Default
}

#endregion

#region Logging

function Write-Log {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI; captured by transcript')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('Info', 'Ok', 'Skip', 'DryRun', 'Warn', 'Error', 'Phase')][string]$Level = 'Info'
    )
    $colors = @{ Info = 'Gray'; Ok = 'Green'; Skip = 'DarkGray'; DryRun = 'Cyan'; Warn = 'Yellow'; Error = 'Red'; Phase = 'Magenta' }
    $tag = $Level.ToUpper().PadRight(6)
    Write-Host ("[{0}] {1} {2}" -f (Get-Date -Format 'HH:mm:ss'), $tag, $Message) -ForegroundColor $colors[$Level]
}

#endregion

#region Step runner

function Add-RigResult {
    param([string]$Phase, [string]$Name, [string]$Status, [string]$Message = '')
    $c = Get-RigContext
    $r = [pscustomobject]@{ Phase = $Phase; Name = $Name; Status = $Status; Message = $Message; Time = (Get-Date).ToString('s') }
    $c.Results.Add($r)
    return $r
}

function Invoke-Step {
    <#
    .SYNOPSIS  The single place where dry run, logging, idempotency and failure handling live.
    .PARAMETER Test    Returns $true when the desired state already holds -> SKIP. Read-only; also runs in dry run.
    .PARAMETER Action  Makes the change. Throw to fail. May return a string (message) or @{Status='WARN';Message='..'}.
    .PARAMETER UndoNote Human-readable undo hint stored in the summary. Machine-readable undo data is written to the
                       journal by the helpers (Set-RegistryValue, Set-ServiceManual, Remove-RigAppx ...).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Phase,
        [scriptblock]$Test,
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$UndoNote = ''
    )
    $c = Get-RigContext
    if (-not $Phase) { $Phase = $c.Phase }

    if ($c.Halted) {
        Write-Log -Level Skip -Message "$Name (halted: $($c.HaltReason))"
        return Add-RigResult $Phase $Name 'SKIP' "halted: $($c.HaltReason)"
    }

    if ($Test) {
        $done = $false
        try { $done = [bool](& $Test) } catch { Write-Log -Level Warn -Message "${Name}: state check failed ($($_.Exception.Message)); assuming not done" }
        if ($done) {
            Write-Log -Level Skip -Message $Name
            return Add-RigResult $Phase $Name 'SKIP' 'already in desired state'
        }
    }

    if ($c.DryRun) {
        Write-Log -Level DryRun -Message "would: $Name"
        return Add-RigResult $Phase $Name 'DRYRUN' $UndoNote
    }

    try {
        $out = & $Action
        $status = 'OK'; $msg = ''
        if ($out -is [hashtable] -and $out.ContainsKey('Status')) { $status = [string]$out.Status; $msg = [string]$out.Message }
        elseif ($out -is [string]) { $msg = $out }
        $lvl = 'Ok'; if ($status -eq 'WARN') { $lvl = 'Warn' }
        Write-Log -Level $lvl -Message ($Name + $(if ($msg) { " - $msg" } else { '' }))
        return Add-RigResult $Phase $Name $status $msg
    }
    catch {
        Write-Log -Level Error -Message "$Name - $($_.Exception.Message)"
        return Add-RigResult $Phase $Name 'FAIL' $_.Exception.Message
    }
}

function Get-RigResults { return (Get-RigContext).Results.ToArray() }

function Write-RigSummary {
    <# Colour table + logs\summary.json (and a timestamped copy). Returns the FAIL count. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI')]
    [CmdletBinding()]
    param([string[]]$SignInsNeeded = @())
    $c = Get-RigContext
    $res = Get-RigResults
    $colors = @{ OK = 'Green'; SKIP = 'DarkGray'; DRYRUN = 'Cyan'; WARN = 'Yellow'; FAIL = 'Red'; PASS = 'Green' }
    Write-Host ''
    Write-Host ('{0,-10} {1,-8} {2}' -f 'PHASE', 'STATUS', 'STEP') -ForegroundColor White
    foreach ($r in $res) {
        $col = 'Gray'; if ($colors.ContainsKey($r.Status)) { $col = $colors[$r.Status] }
        Write-Host ('{0,-10} {1,-8} {2}' -f $r.Phase, $r.Status, $r.Name) -ForegroundColor $col
    }
    $counts = @{}
    foreach ($r in $res) { if ($counts.ContainsKey($r.Status)) { $counts[$r.Status]++ } else { $counts[$r.Status] = 1 } }
    $fail = 0; if ($counts.ContainsKey('FAIL')) { $fail = $counts['FAIL'] }
    Write-Host ''
    Write-Host ('Totals: ' + (($counts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ')) -ForegroundColor White
    if ($SignInsNeeded.Count) {
        Write-Host 'Sign-ins still needed:' -ForegroundColor Yellow
        $SignInsNeeded | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
    if (-not (Test-Path $c.LogDir)) { New-Item -ItemType Directory -Path $c.LogDir -Force | Out-Null }
    $summary = [ordered]@{
        started = $c.Started.ToString('s'); finished = (Get-Date).ToString('s'); dryRun = $c.DryRun
        haltReason = $c.HaltReason; counts = $counts; signInsNeeded = $SignInsNeeded; results = $res
    }
    $json = $summary | ConvertTo-Json -Depth 6
    $json | Set-Content -Path (Join-Path $c.LogDir 'summary.json') -Encoding UTF8
    $json | Set-Content -Path (Join-Path $c.LogDir "summary-$($c.Timestamp).json") -Encoding UTF8
    return $fail
}

#endregion

#region Environment helpers

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-RunningAsSystem {
    return ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
}

function Test-Command { param([Parameter(Mandatory)][string]$Name) return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Update-SessionPath {
    <# Pull machine + user PATH into this session so freshly installed tools resolve. #>
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
}

function Invoke-Native {
    <# Thin wrapper over external programs so tests can mock them. Returns ExitCode + merged Output lines. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @())
    $out = & $File @Arguments 2>&1 | ForEach-Object { "$_" }
    $code = 0; if (Test-Path variable:LASTEXITCODE) { $code = $LASTEXITCODE }
    return [pscustomobject]@{ ExitCode = $code; Output = @($out) }
}

function Assert-Winget {
    <# Ensure winget works: register App Installer, else repair via Microsoft.WinGet.Client; then refresh sources. #>
    [CmdletBinding()]
    param()
    if (-not (Test-Command 'winget')) {
        Write-Log -Level Warn -Message 'winget not found; registering App Installer'
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop } catch { Write-Log -Level Warn -Message "Register failed: $($_.Exception.Message)" }
        Update-SessionPath
        if (-not (Test-Command 'winget')) {
            Write-Log -Level Warn -Message 'Falling back to Microsoft.WinGet.Client + Repair-WinGetPackageManager'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
            Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Scope AllUsers | Out-Null
            Import-Module Microsoft.WinGet.Client
            Repair-WinGetPackageManager -AllUsers
            Update-SessionPath
        }
    }
    if (-not (Test-Command 'winget')) { throw 'winget is unavailable and could not be repaired.' }
    $r = Invoke-Native -File 'winget' -Arguments @('source', 'update')
    if ($r.ExitCode -ne 0) { Write-Log -Level Warn -Message "winget source update exit $($r.ExitCode)" }
    return $true
}

function Get-InteractiveUser {
    $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    return $u
}

function Invoke-AsUser {
    <#
    .SYNOPSIS Run PowerShell text as the signed-in desktop user, NON-elevated (needed for Claude native install, gh login, per-user apps).
    .DESCRIPTION From an elevated session this registers a one-shot scheduled task with a limited-token interactive principal.
                 From a non-elevated session it just runs a child powershell.exe. The script should end with `exit <code>` if it needs one.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Script, [int]$TimeoutSec = 900)

    $dir = Join-Path $env:TEMP ('rig-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $inner = Join-Path $dir 'inner.ps1'; $wrap = Join-Path $dir 'wrap.ps1'; $outF = Join-Path $dir 'out.txt'
    Set-Content -Path $inner -Value $Script -Encoding UTF8
    Set-Content -Path $wrap -Encoding UTF8 -Value @"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$inner' *>&1 | Tee-Object -FilePath '$outF'
exit `$LASTEXITCODE
"@
    try {
        if (-not (Test-Admin)) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrap | Out-Null
            $code = $LASTEXITCODE
        }
        else {
            $user = Get-InteractiveUser
            if (-not $user) { throw 'No interactive user is signed in; cannot run a per-user step.' }
            $name = 'AIGamingRig-Once-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrap`""
            $pri = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $name -Action $act -Principal $pri -Force | Out-Null
            try {
                Start-ScheduledTask -TaskName $name
                $sw = [Diagnostics.Stopwatch]::StartNew()
                Start-Sleep -Seconds 2
                while ((Get-ScheduledTask -TaskName $name).State -eq 'Running') {
                    if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { Stop-ScheduledTask -TaskName $name; throw "Per-user step timed out after $TimeoutSec s" }
                    Start-Sleep -Seconds 2
                }
                $code = (Get-ScheduledTaskInfo -TaskName $name).LastTaskResult
            }
            finally { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
        }
        $text = ''; if (Test-Path $outF) { $text = (Get-Content $outF -Raw) }
        return [pscustomobject]@{ ExitCode = [int]$code; Output = $text }
    }
    finally { Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

#endregion

#region Journal + registry + services

function Add-Journal {
    <# Append one machine-readable undo record. Only called when something is really about to change. #>
    param([Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)][hashtable]$Data)
    $c = Get-RigContext
    if ($c.DryRun) { return }
    if (-not (Test-Path $c.BackupDir)) { New-Item -ItemType Directory -Path $c.BackupDir -Force | Out-Null }
    $rec = [ordered]@{ ts = (Get-Date).ToString('s'); type = $Type }
    foreach ($k in $Data.Keys) { $rec[$k] = $Data[$k] }
    ($rec | ConvertTo-Json -Compress -Depth 6) | Add-Content -Path $c.JournalPath -Encoding UTF8
}

function Get-HiveRoots {
    <# PSPath roots for a logical hive. HKCU under SYSTEM (scheduled task) means every loaded user hive. #>
    param([Parameter(Mandatory)][ValidateSet('HKCU', 'HKLM')][string]$Hive)
    if ($Hive -eq 'HKLM') { return @('Registry::HKEY_LOCAL_MACHINE') }
    if (Test-RunningAsSystem) {
        $sids = Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' } | ForEach-Object { $_.PSChildName }
        return @($sids | ForEach-Object { "Registry::HKEY_USERS\$_" })
    }
    return @('Registry::HKEY_CURRENT_USER')
}

function Get-RegValueState {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $keyItem = Get-Item -LiteralPath $Key -ErrorAction SilentlyContinue
    if (-not $keyItem) { return [pscustomobject]@{ KeyExists = $false; Exists = $false; Kind = $null; Value = $null } }
    $n = $Name; if ($n -eq '(Default)') { $n = '' }
    if ($keyItem.GetValueNames() -notcontains $n) { return [pscustomobject]@{ KeyExists = $true; Exists = $false; Kind = $null; Value = $null } }
    $kind = $keyItem.GetValueKind($n).ToString()
    $val = $keyItem.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return [pscustomobject]@{ KeyExists = $true; Exists = $true; Kind = $kind; Value = $val }
}

function ConvertTo-RegComparable { param($v) if ($v -is [byte[]]) { return ($v -join ',') } return [string]$v }

function Test-RegistryValue {
    <# $true if every root already holds Value (a missing HKCU root list, e.g. nobody loaded, counts as done). #>
    param([Parameter(Mandatory)][string]$Hive, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Name, [Parameter(Mandatory)][AllowEmptyString()]$Value)
    foreach ($root in (Get-HiveRoots -Hive $Hive)) {
        $s = Get-RegValueState -Key (Join-Path $root $Path) -Name $Name
        if (-not $s.Exists) { return $false }
        if ((ConvertTo-RegComparable $s.Value) -ne (ConvertTo-RegComparable $Value)) { return $false }
    }
    return $true
}

function Set-RegistryValue {
    <# Journal the prior state of each root, then write. Returns $true if anything changed. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Hive, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)][AllowEmptyString()]$Value, [switch]$RemoveKeyOnUndo
    )
    $changed = $false
    foreach ($root in (Get-HiveRoots -Hive $Hive)) {
        $key = Join-Path $root $Path
        $s = Get-RegValueState -Key $key -Name $Name
        if ($s.Exists -and ((ConvertTo-RegComparable $s.Value) -eq (ConvertTo-RegComparable $Value))) { continue }
        $prior = $s.Value; if ($prior -is [byte[]]) { $prior = @($prior) }
        Add-Journal -Type 'registry' -Data @{
            key = $key; name = $Name; keyExisted = $s.KeyExists; existed = $s.Exists; kind = $s.Kind; value = $prior; removeKeyOnUndo = $RemoveKeyOnUndo.IsPresent
        }
        if (-not $s.KeyExists) { New-Item -Path $key -Force | Out-Null }
        $n = $Name; if ($n -eq '') { $n = '(Default)' }
        Set-ItemProperty -LiteralPath $key -Name $n -Type $Type -Value $Value -Force
        $changed = $true
    }
    return $changed
}

function Test-TweakApplies {
    param([Parameter(Mandatory)][hashtable]$Tweak)
    $level = Get-RigOption -Name 'Level' -Default 'Lean'
    if ($Tweak.ContainsKey('Level') -and $Tweak.Level -ne $level -and -not ($Tweak.Level -eq 'Standard')) { return $false }
    if ($Tweak.ContainsKey('Flag')) {
        $f = [string]$Tweak.Flag
        if ($f.StartsWith('Not')) { if (Get-RigOption -Name $f.Substring(3) -Default $false) { return $false } }
        elseif (-not (Get-RigOption -Name $f -Default $false)) { return $false }
    }
    return $true
}

function Invoke-TweakGroup {
    <# Apply every tweak in the given groups through Invoke-Step. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Group, [Parameter(Mandatory)][hashtable]$Config)
    foreach ($t in $Config.Tweaks) {
        if ($Group -notcontains $t.Group) { continue }
        if (-not (Test-TweakApplies -Tweak $t)) { continue }
        $tw = $t
        $isDefault = ($tw.Name -eq '(Default)')
        $name = if ($isDefault) { '' } else { $tw.Name }
        $null = Invoke-Step -Name "Tweak $($tw.Id): $($tw.Reason)" `
            -Test ({ Test-RegistryValue -Hive $tw.Hive -Path $tw.Path -Name $name -Value $tw.Value }.GetNewClosure()) `
            -Action ({ $null = Set-RegistryValue -Hive $tw.Hive -Path $tw.Path -Name $name -Type $tw.Type -Value $tw.Value -RemoveKeyOnUndo:([bool]$tw.RemoveKeyOnUndo) }.GetNewClosure()) `
            -UndoNote "registry $($tw.Hive)\$($tw.Path)\$($tw.Name)"
    }
}

function Get-TweakRegKeys {
    <# Unique key paths (HKCU\..., HKLM\...) for backup export. #>
    param([Parameter(Mandatory)][hashtable]$Config)
    $keys = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $Config.Tweaks) { [void]$keys.Add("$($t.Hive)\$($t.Path)") }
    return @($keys)
}

function Set-ServiceManual {
    <# Automatic -> Manual. Disabled/Manual services are left alone. Journals the prior start mode. #>
    param([Parameter(Mandatory)][string]$Name)
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.StartMode -ne 'Auto') { return $false }
    Add-Journal -Type 'service' -Data @{ name = $Name; startMode = $svc.StartMode }
    Set-Service -Name $Name -StartupType Manual
    return $true
}

function Test-ServiceNotAuto {
    param([Parameter(Mandatory)][string]$Name)
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    return (-not $svc) -or ($svc.StartMode -ne 'Auto')
}

function Get-StartupEntries {
    <# Run-key values with their StartupApproved location. #>
    param([string[]]$Pattern)
    $locs = @(
        @{ Run = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run';             App = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';   Hive = 'HKCU' }
        @{ Run = 'Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run';            App = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';   Hive = 'HKLM' }
        @{ Run = 'Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; App = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Hive = 'HKLM' }
    )
    foreach ($l in $locs) {
        $k = Get-Item -LiteralPath $l.Run -ErrorAction SilentlyContinue
        if (-not $k) { continue }
        foreach ($vn in $k.GetValueNames()) {
            foreach ($p in $Pattern) {
                if ($vn -like $p) { [pscustomobject]@{ Name = $vn; Hive = $l.Hive; ApprovedPath = $l.App }; break }
            }
        }
    }
}

function Test-StartupDisabled {
    param([Parameter(Mandatory)]$Entry)
    $root = (Get-HiveRoots -Hive $Entry.Hive)[0]
    $s = Get-RegValueState -Key (Join-Path $root $Entry.ApprovedPath) -Name $Entry.Name
    return ($s.Exists -and $s.Value -is [byte[]] -and ($s.Value[0] -band 1) -eq 1)
}

function Disable-StartupEntry {
    <# Hide from startup via StartupApproved (what Task Manager does); reversible, nothing deleted. #>
    param([Parameter(Mandatory)]$Entry)
    $bytes = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    return (Set-RegistryValue -Hive $Entry.Hive -Path $Entry.ApprovedPath -Name $Entry.Name -Type 'Binary' -Value $bytes)
}

function Invoke-StartupDisable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Pattern)
    foreach ($e in @(Get-StartupEntries -Pattern $Pattern)) {
        $entry = $e
        $null = Invoke-Step -Name "Disable autostart: $($entry.Name)" `
            -Test ({ Test-StartupDisabled -Entry $entry }.GetNewClosure()) `
            -Action ({ $null = Disable-StartupEntry -Entry $entry }.GetNewClosure()) `
            -UndoNote 'StartupApproved value restored from journal'
    }
}

#endregion

Export-ModuleMember -Function Initialize-Rig, Get-RigContext, Set-RigPhase, Stop-Rig, Get-RigOption,
    Write-Log, Add-RigResult, Invoke-Step, Get-RigResults, Write-RigSummary,
    Test-Admin, Test-RunningAsSystem, Test-Command, Update-SessionPath, Invoke-Native, Assert-Winget, Get-InteractiveUser, Invoke-AsUser,
    Add-Journal, Get-HiveRoots, Get-RegValueState, Test-RegistryValue, Set-RegistryValue, Test-TweakApplies, Invoke-TweakGroup, Get-TweakRegKeys,
    Set-ServiceManual, Test-ServiceNotAuto, Get-StartupEntries, Test-StartupDisabled, Disable-StartupEntry, Invoke-StartupDisable
