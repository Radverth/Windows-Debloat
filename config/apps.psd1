# Install matrix. winget IDs were checked against the plan on 2026-10-19; re-verify with `winget show --id <id> -e` on a live machine
# and update Checked. Preflight/Install log WARN if an ID no longer resolves.
@{
    Apps = @(
        @{ Key = 'pwsh';    Name = 'PowerShell 7';      Group = 'Dev';    WingetId = 'Microsoft.PowerShell';           Scope = 'machine'; Verify = 'pwsh -v';           Command = 'pwsh';   Checked = '2026-10-19'
           Fallback = @{ Type = 'GitHubMsi'; Repo = 'PowerShell/PowerShell'; AssetPattern = 'PowerShell-*-win-x64.msi' } }
        @{ Key = 'git';     Name = 'Git for Windows';   Group = 'Dev';    WingetId = 'Git.Git';                        Scope = 'machine'; Verify = 'git --version';     Command = 'git';    Checked = '2026-10-19' }
        @{ Key = 'gh';      Name = 'GitHub CLI';        Group = 'Dev';    WingetId = 'GitHub.cli';                     Scope = 'machine'; Verify = 'gh --version';      Command = 'gh';     Checked = '2026-10-19'
           Fallback = @{ Type = 'GitHubMsi'; Repo = 'cli/cli'; AssetPattern = 'gh_*_windows_amd64.msi' } }
        @{ Key = 'chrome';  Name = 'Google Chrome';     Group = 'Dev';    WingetId = 'Google.Chrome';                  Scope = 'machine'; Checked = '2026-10-19'
           VerifyPaths = @('%ProgramFiles%\Google\Chrome\Application\chrome.exe', '%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe')
           Fallback = @{ Type = 'Winget'; WingetId = 'Google.Chrome.EXE' } }
        @{ Key = 'vscode';  Name = 'VS Code';           Group = 'Dev';    WingetId = 'Microsoft.VisualStudioCode';     Scope = 'machine'; Verify = 'code --version'; Command = 'code'; Checked = '2026-10-19'
           Fallback = @{ Type = 'Winget'; WingetId = 'Microsoft.VisualStudioCode'; Scope = 'user' } }
        # Native installer, per-user, run non-elevated. Do NOT also install the winget package (PATH conflict, claude-code issue #31980).
        @{ Key = 'claude';  Name = 'Claude Code';       Group = 'Dev';    Installer = 'ClaudeNative'; Command = 'claude'; Verify = 'claude --version'; Checked = '2026-10-19'
           NativeUrl = 'https://claude.ai/install.ps1'
           Fallback = @{ Type = 'Winget'; WingetId = 'Anthropic.ClaudeCode' } }
        # Grok Bot: no confirmed winget package. The installer step searches winget first, then uses DownloadUrl if set.
        # DownloadUrl must be filled in from the "More downloads" link on https://x.ai/bot#download (not exposed for Windows at plan time).
        @{ Key = 'grokbot'; Name = 'Grok Bot';          Group = 'Dev';    Installer = 'GrokBot'; WingetSearch = 'Grok Bot'; Checked = '2026-10-19'
           DownloadUrl = ''; DownloadUrlChecked = ''
           AllowedSigners = @('xAI', 'SpaceXAI', 'Anysphere', 'Cursor')
           SilentArgs = ''   # discover on the VM (try /S, /silent, --silent); empty = run interactively
           ManualUrl = 'https://x.ai/bot#download'
           VerifyShortcut = 'Grok*' }
        @{ Key = 'steam';   Name = 'Steam';             Group = 'Gaming'; WingetId = 'Valve.Steam';                    Scope = 'machine'; Checked = '2026-10-19'
           VerifyPaths = @('%ProgramFiles(x86)%\Steam\steam.exe', '%ProgramFiles%\Steam\steam.exe') }
        @{ Key = 'epic';    Name = 'Epic Games Launcher'; Group = 'Gaming'; WingetId = 'EpicGames.EpicGamesLauncher';  Scope = 'machine'; Checked = '2026-10-19'
           VerifyPaths = @('%ProgramFiles(x86)%\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe', '%ProgramFiles(x86)%\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe') }
        @{ Key = 'amazon';  Name = 'Amazon Games (Prime Gaming)'; Group = 'Gaming'; WingetId = 'Amazon.Games';         Scope = 'user'; AsUser = $true; Checked = '2026-10-19'
           VerifyPaths = @('%LOCALAPPDATA%\Amazon Games\App\Amazon Games.exe') }
        @{ Key = 'node';    Name = 'Node.js LTS';       Group = 'Optional'; Switch = 'WithNode';   WingetId = 'OpenJS.NodeJS.LTS';     Scope = 'machine'; Verify = 'node -v';   Command = 'node';   Checked = '2026-10-19' }
        @{ Key = 'python';  Name = 'Python 3';          Group = 'Optional'; Switch = 'WithPython'; WingetId = 'Python.Python.3.13';    Scope = 'machine'; Verify = 'py -V';     Command = 'py';     Checked = '2026-10-19' }
        @{ Key = 'docker';  Name = 'Docker Desktop';    Group = 'Optional'; Switch = 'WithDocker'; WingetId = 'Docker.DockerDesktop';  Scope = 'machine'; Verify = 'docker -v'; Command = 'docker'; Checked = '2026-10-19' }
    )

    VSCodeExtensions = @(
        'anthropic.claude-code', 'ms-vscode.powershell', 'eamodio.gitlens', 'github.vscode-pull-request-github'
    )
}
