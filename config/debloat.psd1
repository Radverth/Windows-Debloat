# Debloat lists. Every entry has a Reason. Patterns are -like wildcards against Appx package Name.
@{
    # HARD keep-list. Remove-RigAppx refuses these at every level, even if a removal entry or the Lean sweep matches.
    Protected = @(
        @{ Pattern = 'Microsoft.WindowsStore';          Reason = 'Store; needed for updates and Game Pass' }
        @{ Pattern = 'Microsoft.StorePurchaseApp';      Reason = 'Store purchase flow' }
        @{ Pattern = 'Microsoft.DesktopAppInstaller';   Reason = 'App Installer (winget)' }
        @{ Pattern = 'Microsoft.SecHealthUI';           Reason = 'Windows Security app' }
        @{ Pattern = 'Microsoft.GamingApp';             Reason = 'Xbox app' }
        @{ Pattern = 'Microsoft.GamingServices';        Reason = 'Gaming Services; Game Pass and many PC titles' }
        @{ Pattern = 'Microsoft.Xbox*';                 Reason = 'Xbox Identity Provider, TCUI, Game Bar overlay and friends' }
        @{ Pattern = 'Microsoft.WindowsTerminal*';      Reason = 'Default terminal' }
        @{ Pattern = 'Microsoft.VCLibs*';               Reason = 'VC++ runtime' }
        @{ Pattern = 'Microsoft.UI.Xaml*';              Reason = 'XAML runtime' }
        @{ Pattern = 'Microsoft.NET*';                  Reason = '.NET runtime' }
        @{ Pattern = 'Microsoft.WindowsAppRuntime*';    Reason = 'Windows App SDK runtime' }
        @{ Pattern = 'Microsoft.WebView2*';             Reason = 'Edge WebView2 runtime' }
        @{ Pattern = 'Microsoft.WindowsCalculator';     Reason = 'Calculator' }
        @{ Pattern = 'Microsoft.Windows.Photos';        Reason = 'Photos' }
        @{ Pattern = 'Microsoft.ScreenSketch';          Reason = 'Snipping Tool' }
        @{ Pattern = 'Microsoft.WindowsNotepad';        Reason = 'Notepad' }
        @{ Pattern = 'Microsoft.Paint';                 Reason = 'Paint' }
    )

    # Extra keeps used ONLY by the Lean allow-list sweep (drivers, codecs, shell glue). Add your own here.
    LeanSafetyKeep = @(
        'Microsoft.MicrosoftEdge*', 'Microsoft.Edge*', 'Microsoft.Services.Store.Engagement',
        'Microsoft.*ImageExtension', 'Microsoft.*VideoExtension', 'Microsoft.*Extensions', 'Microsoft.RawImageExtension',
        'Microsoft.Winget.*', 'Microsoft.PowerShell*', 'Microsoft.ApplicationCompatibilityEnhancements',
        'MicrosoftWindows.Client.*', 'MicrosoftWindows.*', 'Windows.*', 'windows.*',
        'NVIDIACorp.*', 'AdvancedMicroDevicesInc*', 'AppUp.Intel*', 'RealtekSemiconductorCorp.*', 'DolbyLaboratories.*',
        'Microsoft.HEVCVideoExtension*', 'Microsoft.OneDriveSync'
    )

    # Named removals (Standard level, and also run at Lean). Flag: skipped when that switch is passed to the entry script.
    Remove = @(
        @{ Pattern = 'Clipchamp.Clipchamp';                     Reason = 'Consumer video editor' }
        @{ Pattern = 'Microsoft.BingNews';                      Reason = 'News feed' }
        @{ Pattern = 'Microsoft.BingWeather';                   Reason = 'Weather' }
        @{ Pattern = 'Microsoft.BingSearch';                    Reason = 'Bing search app' }
        @{ Pattern = 'Microsoft.GetHelp';                       Reason = 'Get Help' }
        @{ Pattern = 'Microsoft.Getstarted';                    Reason = 'Tips' }
        @{ Pattern = 'Microsoft.WindowsFeedbackHub';            Reason = 'Feedback Hub' }
        @{ Pattern = 'Microsoft.MicrosoftSolitaireCollection';  Reason = 'Ad-supported games' }
        @{ Pattern = 'Microsoft.Todos';                         Reason = 'To Do' }
        @{ Pattern = 'Microsoft.People';                        Reason = 'People' }
        @{ Pattern = 'Microsoft.WindowsMaps';                   Reason = 'Maps' }
        @{ Pattern = 'Microsoft.PowerAutomateDesktop';          Reason = 'Power Automate' }
        @{ Pattern = 'MicrosoftCorporationII.MicrosoftFamily';  Reason = 'Family' }
        @{ Pattern = 'MicrosoftCorporationII.QuickAssist';      Reason = 'Quick Assist' }
        @{ Pattern = 'Microsoft.MicrosoftStickyNotes';          Reason = 'Sticky Notes'; Flag = 'KeepStickyNotes' }
        @{ Pattern = 'Microsoft.MixedReality.Portal';           Reason = 'Mixed Reality Portal' }
        @{ Pattern = 'MicrosoftTeams';                          Reason = 'Teams (personal, old)' }
        @{ Pattern = 'MSTeams';                                 Reason = 'Teams (personal)' }
        @{ Pattern = 'Microsoft.OutlookForWindows';             Reason = 'New Outlook' }
        @{ Pattern = 'Microsoft.Copilot';                       Reason = 'Copilot app'; Flag = 'KeepCopilot' }
        @{ Pattern = 'Microsoft.Windows.Ai.Copilot.Provider';   Reason = 'Copilot provider'; Flag = 'KeepCopilot' }
        @{ Pattern = 'Microsoft.MicrosoftOfficeHub';            Reason = 'Office upsell hub' }
        @{ Pattern = 'Microsoft.Windows.DevHome';               Reason = 'Dev Home (retired)' }
        @{ Pattern = 'SpotifyAB.SpotifyMusic';                  Reason = 'OEM/promoted install' }
        @{ Pattern = 'Disney.*';                                Reason = 'Promoted install (Disney+)' }
        @{ Pattern = '*TikTok*';                                Reason = 'Promoted install' }
        @{ Pattern = '*Instagram*';                             Reason = 'Promoted install' }
        @{ Pattern = '*LinkedIn*';                              Reason = 'Promoted install' }
        @{ Pattern = '*king.com*';                              Reason = 'Candy Crush and other King games' }
        @{ Pattern = '*CandyCrush*';                            Reason = 'Candy Crush' }
        @{ Pattern = '*Facebook*';                              Reason = 'Facebook stubs' }
    )

    # Lean level only: extra removals beyond the named list.
    LeanRemove = @(
        @{ Pattern = 'Microsoft.YourPhone';                     Reason = 'Phone Link' }
        @{ Pattern = 'Microsoft.549981C3F5F10';                 Reason = 'Cortana remnant' }
        @{ Pattern = 'MicrosoftWindows.Client.WebExperience';   Reason = 'Widgets platform' }
    )

    # Optional Windows capabilities removed at Lean level (not core components).
    Capabilities = @(
        @{ Name = 'Media.WindowsMediaPlayer~~~~*';   Reason = 'Legacy Windows Media Player' }
        @{ Name = 'Microsoft.Windows.WordPad~~~~*';  Reason = 'WordPad' }
        @{ Name = 'App.StepsRecorder~~~~*';          Reason = 'Steps Recorder' }
        @{ Name = 'Browser.InternetExplorer~~~~*';   Reason = 'Internet Explorer mode' }
    )
    # Optional features (Disable-WindowsOptionalFeature) removed at Lean level.
    OptionalFeatures = @(
        @{ Name = 'WorkFolders-Client';              Reason = 'Work Folders' }
    )

    # Services set to Manual (never Disabled, never deleted).
    ServicesManual = @(
        @{ Name = 'DiagTrack';  Reason = 'Telemetry (Connected User Experiences)'; Level = 'Standard' }
        @{ Name = 'Fax';        Reason = 'Fax';                                    Level = 'Lean' }
        @{ Name = 'RetailDemo'; Reason = 'Retail demo';                            Level = 'Lean' }
        @{ Name = 'MapsBroker'; Reason = 'Downloaded maps manager';                Level = 'Lean' }
        @{ Name = 'lfsvc';      Reason = 'Geolocation';                            Level = 'Lean'; Flag = 'NoLocation' }
    )

    # Run-key values hidden from startup via StartupApproved (reversible). Wildcards ok.
    StartupDisable = @(
        'MicrosoftEdgeAutoLaunch*', 'com.squirrel.Teams.Teams', 'Teams*', 'Skype*', 'Spotify', 'Cortana*'
    )

    # Never touched at any level, reported by Verify (read-only).
    SecurityServices = @('WinDefend', 'wscsvc', 'mpssvc', 'wuauserv', 'SecurityHealthService')

    # Unattended (scheduled) runs skip while any of these process names run, or any process lives under a game library path.
    MaintenanceSkipProcesses = @('TiWorker', 'TrustedInstaller')
    MaintenanceGamePaths     = @('*\steamapps\common\*', '*\Epic Games\*\Binaries\*', '*\Amazon Games\Library\*', '*\XboxGames\*')
}
