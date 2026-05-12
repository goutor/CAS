#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "run",
    [Parameter(Position = 1)]
    [string]$Profile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AppName = "Codex"
$CodexHome = if ($env:CODEX_HOME -and $env:CODEX_HOME.Trim()) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$AuthFile = Join-Path $CodexHome "auth.json"
$SwitcherDir = Join-Path $HOME ".codex-account-switcher"
$ProfilesDir = Join-Path $SwitcherDir "profiles"
$CurrentFile = Join-Path $SwitcherDir "current_profile"
$BackupsDir = Join-Path $SwitcherDir "backups"
$LogFile = Join-Path $SwitcherDir "switcher.log"
$ManagedBrowserSessionItems = @(
    "Cookies",
    "Cookies-journal",
    "Local Storage",
    "Session Storage",
    "Partitions",
    "Network Persistent State",
    "Preferences",
    "SharedStorage",
    "SharedStorage-wal",
    "Trust Tokens",
    "Trust Tokens-journal",
    "TransportSecurity",
    "DIPS",
    "DIPS-wal",
    "blob_storage"
)

function Ensure-Directories {
    foreach ($dir in @($SwitcherDir, $ProfilesDir, $BackupsDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Write-Log {
    param([string]$Message)
    Ensure-Directories
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $LogFile -Value "[$stamp] $Message" -Encoding UTF8
}

function Fail {
    param([string]$Message)
    Write-Log "ERROR: $Message"
    throw $Message
}

function Validate-ProfileName {
    param([string]$Name)
    $trimmed = if ($Name) { $Name.Trim() } else { "" }
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        Fail "Profile name is required."
    }
    if ($trimmed -eq "." -or $trimmed -eq "..") {
        Fail "Profile name '$trimmed' is not allowed."
    }
    if ($trimmed -notmatch "^[A-Za-z0-9 ._-]+$") {
        Fail "Profile name can contain only Latin letters, numbers, space, dot, dash, and underscore."
    }
    return $trimmed
}

function Get-ProfileDir {
    param([string]$Name)
    Join-Path $ProfilesDir $Name
}

function Get-ProfileAuthPath {
    param([string]$Name)
    Join-Path (Get-ProfileDir $Name) "auth.json"
}

function Get-ProfileSessionPath {
    param([string]$Name)
    Join-Path (Get-ProfileDir $Name) "CodexSession"
}

function Read-CurrentProfile {
    if (-not (Test-Path -LiteralPath $CurrentFile)) {
        return $null
    }
    $value = (Get-Content -LiteralPath $CurrentFile -Raw -Encoding UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }
    return $value
}

function Write-CurrentProfile {
    param([string]$Name)
    Ensure-Directories
    Set-Content -LiteralPath $CurrentFile -Value "$Name`n" -Encoding UTF8
}

function Copy-ItemReplacing {
    param(
        [string]$Source,
        [string]$Destination
    )
    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}

function Get-CodexSessionCandidates {
    @(
        if ($env:APPDATA) { Join-Path $env:APPDATA "Codex" } else { $null }
        if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Roaming\Codex" } else { $null }
        if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Codex" } else { $null }
    ) | Where-Object { $_ } | Select-Object -Unique
}

function Get-CodexSessionPath {
    $candidates = Get-CodexSessionCandidates
    $scored = @()
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }
        $score = 0
        foreach ($item in $ManagedBrowserSessionItems) {
            if (Test-Path -LiteralPath (Join-Path $candidate $item)) {
                $score++
            }
        }
        $scored += [pscustomobject]@{
            Path  = $candidate
            Score = $score
        }
    }

    if ($scored.Count -gt 0) {
        return ($scored | Sort-Object Score -Descending | Select-Object -First 1).Path
    }
    return (Get-CodexSessionCandidates | Select-Object -First 1)
}

function Test-SessionSnapshotHasData {
    param([string]$SessionRoot)
    if (-not $SessionRoot -or -not (Test-Path -LiteralPath $SessionRoot)) {
        return $false
    }
    foreach ($item in $ManagedBrowserSessionItems) {
        if (Test-Path -LiteralPath (Join-Path $SessionRoot $item)) {
            return $true
        }
    }
    return $false
}

function Save-SessionSnapshotToProfile {
    param([string]$ProfileName)
    $profileDir = Get-ProfileDir $ProfileName
    $profileAuth = Get-ProfileAuthPath $ProfileName
    $profileSessionRoot = Get-ProfileSessionPath $ProfileName
    $sessionRoot = Get-CodexSessionPath

    if (Test-Path -LiteralPath $AuthFile) {
        Copy-ItemReplacing -Source $AuthFile -Destination $profileAuth
    } elseif (Test-Path -LiteralPath $profileAuth) {
        Remove-Item -LiteralPath $profileAuth -Force
    }

    if (Test-Path -LiteralPath $profileSessionRoot) {
        Remove-Item -LiteralPath $profileSessionRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $profileSessionRoot -Force | Out-Null
    if ($sessionRoot -and (Test-Path -LiteralPath $sessionRoot)) {
        foreach ($item in $ManagedBrowserSessionItems) {
            $source = Join-Path $sessionRoot $item
            if (-not (Test-Path -LiteralPath $source)) {
                continue
            }
            $target = Join-Path $profileSessionRoot $item
            Copy-ItemReplacing -Source $source -Destination $target
        }
    }

    $hasAuth = Test-Path -LiteralPath $profileAuth
    $hasSessionData = Test-SessionSnapshotHasData -SessionRoot $profileSessionRoot
    if (-not $hasAuth -and -not $hasSessionData) {
        Fail "Codex login data not found. Sign in to Codex first."
    }
}

function Refresh-ActiveProfileSessionIfPossible {
    $current = Read-CurrentProfile
    if (-not $current) {
        return
    }
    $profileDir = Get-ProfileDir $current
    if (-not (Test-Path -LiteralPath $profileDir)) {
        return
    }
    try {
        Save-SessionSnapshotToProfile -ProfileName $current
        Write-Log "Refreshed active profile '$current'"
    } catch {
        Write-Log "Skipped refresh for active profile '$current': $($_.Exception.Message)"
    }
}

function Backup-CurrentAuthIfPresent {
    if (-not (Test-Path -LiteralPath $AuthFile)) {
        return
    }
    Ensure-Directories
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $target = Join-Path $BackupsDir "auth.$stamp.json"
    Copy-Item -LiteralPath $AuthFile -Destination $target -Force
}

function List-Profiles {
    Ensure-Directories
    $dirs = Get-ChildItem -LiteralPath $ProfilesDir -Directory -ErrorAction SilentlyContinue
    $names = foreach ($dir in $dirs) {
        $auth = Join-Path $dir.FullName "auth.json"
        $session = Join-Path $dir.FullName "CodexSession"
        $hasAuth = Test-Path -LiteralPath $auth
        $hasSession = Test-SessionSnapshotHasData -SessionRoot $session
        if ($hasAuth -or $hasSession) {
            $dir.Name
        }
    }
    $names | Sort-Object -Unique
}

function Stop-Codex {
    $running = @(Get-Process -Name "Codex" -ErrorAction SilentlyContinue)
    foreach ($process in $running) {
        try {
            $null = $process.CloseMainWindow()
        } catch {
        }
    }
    Start-Sleep -Milliseconds 900
    $running = @(Get-Process -Name "Codex" -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
    }
}

function Start-Codex {
    $candidateExe = @(
        if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Programs\Codex\Codex.exe" } else { $null }
        if ($env:ProgramFiles) { Join-Path $env:ProgramFiles "Codex\Codex.exe" } else { $null }
        if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "Codex\Codex.exe" } else { $null }
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

    if ($candidateExe) {
        Start-Process -FilePath $candidateExe | Out-Null
        return
    }

    try {
        Start-Process -FilePath "explorer.exe" -ArgumentList "shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App" | Out-Null
        return
    } catch {
    }

    Write-Warning "Could not launch Codex automatically. Open it manually."
}

function Clear-CurrentSession {
    $sessionRoot = Get-CodexSessionPath
    if ($sessionRoot -and (Test-Path -LiteralPath $sessionRoot)) {
        foreach ($item in $ManagedBrowserSessionItems) {
            $target = Join-Path $sessionRoot $item
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force
            }
        }
    }
    if (Test-Path -LiteralPath $AuthFile) {
        Remove-Item -LiteralPath $AuthFile -Force
    }
}

function Save-CurrentSessionToNamedProfile {
    param([string]$RequestedProfile)
    $profileName = Validate-ProfileName $RequestedProfile
    Ensure-Directories
    Stop-Codex
    $profileDir = Get-ProfileDir $profileName
    if (-not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    Save-SessionSnapshotToProfile -ProfileName $profileName
    Write-CurrentProfile -Name $profileName
    Write-Log "Saved current session as profile '$profileName'"
    Write-Output "Saved profile '$profileName'."
    Start-Codex
}

function Switch-Profile {
    param([string]$RequestedProfile)
    $profileName = Validate-ProfileName $RequestedProfile
    Ensure-Directories
    $profileDir = Get-ProfileDir $profileName
    if (-not (Test-Path -LiteralPath $profileDir)) {
        Fail "Profile '$profileName' was not found."
    }

    $profileAuth = Join-Path $profileDir "auth.json"
    $profileSessionRoot = Join-Path $profileDir "CodexSession"
    $hasAuth = Test-Path -LiteralPath $profileAuth
    $hasSession = Test-SessionSnapshotHasData -SessionRoot $profileSessionRoot
    if (-not $hasAuth -and -not $hasSession) {
        Fail "Profile '$profileName' has no saved session."
    }

    Stop-Codex
    Refresh-ActiveProfileSessionIfPossible
    Backup-CurrentAuthIfPresent

    $sessionRoot = Get-CodexSessionPath
    if ($sessionRoot -and -not (Test-Path -LiteralPath $sessionRoot)) {
        New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
    }
    Clear-CurrentSession

    if ($hasAuth) {
        $authDir = Split-Path -Parent $AuthFile
        if (-not (Test-Path -LiteralPath $authDir)) {
            New-Item -ItemType Directory -Path $authDir -Force | Out-Null
        }
        Copy-ItemReplacing -Source $profileAuth -Destination $AuthFile
    } elseif (Test-Path -LiteralPath $AuthFile) {
        Remove-Item -LiteralPath $AuthFile -Force
    }

    if ($hasSession -and $sessionRoot) {
        foreach ($item in $ManagedBrowserSessionItems) {
            $source = Join-Path $profileSessionRoot $item
            if (-not (Test-Path -LiteralPath $source)) {
                continue
            }
            $target = Join-Path $sessionRoot $item
            Copy-ItemReplacing -Source $source -Destination $target
        }
    }

    Write-CurrentProfile -Name $profileName
    Write-Log "Switched to profile '$profileName'"
    Write-Output "Switched to profile '$profileName'."
    Start-Codex
}

function Show-Status {
    $current = Read-CurrentProfile
    if (-not $current) {
        $current = "none selected"
    }
    $profiles = @(List-Profiles)
    Write-Output "Active profile: $current"
    if ($profiles.Count -eq 0) {
        Write-Output "Profiles: none"
        return
    }
    Write-Output "Profiles:"
    foreach ($profile in $profiles) {
        if ($profile -eq $current) {
            Write-Output " * $profile (active)"
        } else {
            Write-Output " - $profile"
        }
    }
}

function Choose-Profile {
    $profiles = @(List-Profiles)
    if ($profiles.Count -eq 0) {
        Fail "No profiles found. Save one first: .\scripts\codex-account-switcher.ps1 save my"
    }

    Write-Output "Choose profile:"
    for ($index = 0; $index -lt $profiles.Count; $index++) {
        Write-Output "[$($index + 1)] $($profiles[$index])"
    }

    $choice = Read-Host "Enter number (empty to cancel)"
    if ([string]::IsNullOrWhiteSpace($choice)) {
        return
    }
    if ($choice -notmatch "^\d+$") {
        Fail "Invalid selection."
    }
    $number = [int]$choice
    if ($number -lt 1 -or $number -gt $profiles.Count) {
        Fail "Invalid selection."
    }
    Switch-Profile -RequestedProfile $profiles[$number - 1]
}

function Toggle-Or-Setup {
    $profiles = @(List-Profiles)
    $count = $profiles.Count
    if ($count -eq 0) {
        Fail "No profiles yet. Save current account first: .\scripts\codex-account-switcher.ps1 save my"
    }
    if ($count -eq 2) {
        $current = Read-CurrentProfile
        if ($current) {
            $other = $profiles | Where-Object { $_ -ne $current } | Select-Object -First 1
            if ($other) {
                Switch-Profile -RequestedProfile $other
                return
            }
        }
    }
    Choose-Profile
}

function Show-Usage {
@"
Usage:
  .\scripts\codex-account-switcher.ps1 run
  .\scripts\codex-account-switcher.ps1 choose
  .\scripts\codex-account-switcher.ps1 switch <profile>
  .\scripts\codex-account-switcher.ps1 save <profile>
  .\scripts\codex-account-switcher.ps1 list
  .\scripts\codex-account-switcher.ps1 status

First-time flow:
  1. Sign in to Codex manually with account #1.
  2. .\scripts\codex-account-switcher.ps1 save my
  3. Sign in to Codex manually with account #2.
  4. .\scripts\codex-account-switcher.ps1 save brother
  5. Use run/choose/switch to swap quickly.
"@
}

try {
    Ensure-Directories
    switch ($Command.ToLowerInvariant()) {
        "run" { Toggle-Or-Setup }
        "choose" { Choose-Profile }
        "switch" {
            if (-not $Profile) { Fail "Profile name is required: switch <profile>" }
            Switch-Profile -RequestedProfile $Profile
        }
        "save" {
            if (-not $Profile) { Fail "Profile name is required: save <profile>" }
            Save-CurrentSessionToNamedProfile -RequestedProfile $Profile
        }
        "list" { List-Profiles }
        "status" { Show-Status }
        "help" { Show-Usage }
        "-h" { Show-Usage }
        "--help" { Show-Usage }
        default {
            Show-Usage
            exit 2
        }
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
