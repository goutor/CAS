#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$CodexHome = if ($env:CODEX_HOME -and $env:CODEX_HOME.Trim()) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$AuthFile = Join-Path $CodexHome "auth.json"
$SwitcherDir = Join-Path $HOME ".codex-account-switcher"
$ProfilesDir = Join-Path $SwitcherDir "profiles"
$BackupsDir = Join-Path $SwitcherDir "backups"
$CurrentFile = Join-Path $SwitcherDir "current_profile"
$PendingProfileFile = Join-Path $SwitcherDir "pending_profile"
$PendingPrevProfileFile = Join-Path $SwitcherDir "pending_previous_profile"
$PendingPrevFingerprintFile = Join-Path $SwitcherDir "pending_previous_fingerprint"
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

function Read-TextFileTrimmed {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $value = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }
    return $value
}

function Read-CurrentProfile {
    Read-TextFileTrimmed -Path $CurrentFile
}

function Write-CurrentProfile {
    param([string]$Name)
    Set-Content -LiteralPath $CurrentFile -Value "$Name`n" -Encoding UTF8
}

function Read-PendingProfile {
    Read-TextFileTrimmed -Path $PendingProfileFile
}

function Read-PendingPreviousProfile {
    Read-TextFileTrimmed -Path $PendingPrevProfileFile
}

function Read-PendingPreviousFingerprint {
    Read-TextFileTrimmed -Path $PendingPrevFingerprintFile
}

function Write-PendingProfile {
    param([string]$Name)
    Set-Content -LiteralPath $PendingProfileFile -Value "$Name`n" -Encoding UTF8
}

function Write-PendingPreviousProfile {
    param([string]$Name)
    if ($Name -and $Name.Trim()) {
        Set-Content -LiteralPath $PendingPrevProfileFile -Value "$Name`n" -Encoding UTF8
    } elseif (Test-Path -LiteralPath $PendingPrevProfileFile) {
        Remove-Item -LiteralPath $PendingPrevProfileFile -Force
    }
}

function Write-PendingPreviousFingerprint {
    param([string]$Fingerprint)
    if ($Fingerprint -and $Fingerprint.Trim()) {
        Set-Content -LiteralPath $PendingPrevFingerprintFile -Value "$Fingerprint`n" -Encoding UTF8
    } elseif (Test-Path -LiteralPath $PendingPrevFingerprintFile) {
        Remove-Item -LiteralPath $PendingPrevFingerprintFile -Force
    }
}

function Clear-PendingState {
    foreach ($path in @($PendingProfileFile, $PendingPrevProfileFile, $PendingPrevFingerprintFile)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
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

function Get-FileDigest {
    param([string]$Path)
    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    } catch {
        return $null
    }
}

function Get-ItemDigestEntries {
    param(
        [string]$Path,
        [string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $item = Get-Item -LiteralPath $Path
    if (-not $item.PSIsContainer) {
        $hash = Get-FileDigest -Path $Path
        if (-not $hash) { return @() }
        return @("file:${Label}:$hash")
    }

    $entries = @("dir:$Label")
    $children = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Sort-Object FullName
    foreach ($child in $children) {
        $relative = $child.FullName.Substring($Path.Length).TrimStart("\")
        $hash = Get-FileDigest -Path $child.FullName
        if ($hash) {
            $entries += "file:${Label}/${relative}:$hash"
        }
    }
    return $entries
}

function Compute-Sha256FromText {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-SessionFingerprint {
    param(
        [string]$AuthPath,
        [string]$SessionRoot
    )
    $entries = @()
    if ($AuthPath -and (Test-Path -LiteralPath $AuthPath)) {
        $hash = Get-FileDigest -Path $AuthPath
        if ($hash) {
            $entries += "file:auth.json:$hash"
        }
    }
    if ($SessionRoot -and (Test-Path -LiteralPath $SessionRoot)) {
        foreach ($item in $ManagedBrowserSessionItems) {
            $entries += Get-ItemDigestEntries -Path (Join-Path $SessionRoot $item) -Label "browser/$item"
        }
    }
    if ($entries.Count -eq 0) {
        return $null
    }
    $joined = ($entries | Sort-Object) -join "`n"
    return Compute-Sha256FromText -Text $joined
}

function Get-CurrentSessionFingerprint {
    $sessionRoot = Get-CodexSessionPath
    Get-SessionFingerprint -AuthPath $AuthFile -SessionRoot $sessionRoot
}

function Convert-FromBase64Url {
    param([string]$Value)
    $padded = $Value.Replace("-", "+").Replace("_", "/")
    switch ($padded.Length % 4) {
        2 { $padded += "==" }
        3 { $padded += "=" }
    }
    try {
        $bytes = [System.Convert]::FromBase64String($padded)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        return $null
    }
}

function Get-ProfileEmailFromAuth {
    param([string]$AuthPath)
    if (-not (Test-Path -LiteralPath $AuthPath)) {
        return $null
    }
    try {
        $json = Get-Content -LiteralPath $AuthPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }

    if ($json.PSObject.Properties.Name -contains "email") {
        $value = [string]$json.email
        if ($value) { return $value }
    }

    if (($json.PSObject.Properties.Name -contains "tokens") -and $json.tokens) {
        $tokenProps = $json.tokens.PSObject.Properties.Name
        if ($tokenProps -contains "id_token") {
            $idToken = [string]$json.tokens.id_token
            if ($idToken) {
                $parts = $idToken.Split(".")
                if ($parts.Length -ge 2) {
                    $payloadText = Convert-FromBase64Url -Value $parts[1]
                    if ($payloadText) {
                        try {
                            $payload = $payloadText | ConvertFrom-Json -ErrorAction Stop
                            if ($payload.PSObject.Properties.Name -contains "email") {
                                $value = [string]$payload.email
                                if ($value) { return $value }
                            }
                        } catch {
                        }
                    }
                }
            }
        }
    }
    return $null
}

function Has-UsableAuthFile {
    if (-not (Test-Path -LiteralPath $AuthFile)) {
        return $false
    }
    try {
        $json = Get-Content -LiteralPath $AuthFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $false
    }
    if (($json.PSObject.Properties.Name -contains "OPENAI_API_KEY") -and $json.OPENAI_API_KEY) {
        return $true
    }
    if (($json.PSObject.Properties.Name -contains "tokens") -and $json.tokens) {
        $props = $json.tokens.PSObject.Properties.Name
        foreach ($tokenName in @("access_token", "refresh_token", "id_token")) {
            if ($props -contains $tokenName) {
                $value = [string]$json.tokens.$tokenName
                if ($value) { return $true }
            }
        }
    }
    return $false
}

function Is-CodexRunning {
    @(Get-Process -Name "Codex" -ErrorAction SilentlyContinue).Count -gt 0
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

    [System.Windows.Forms.MessageBox]::Show(
        "Could not launch Codex automatically. Open it manually.",
        "Codex Account Switcher",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
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

function Save-SessionSnapshotToProfile {
    param([string]$ProfileName)
    Ensure-Directories
    $profileDir = Get-ProfileDir $ProfileName
    if (-not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }

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

function Switch-ToProfile {
    param([string]$ProfileName)
    $name = Validate-ProfileName $ProfileName
    $profileDir = Get-ProfileDir $name
    if (-not (Test-Path -LiteralPath $profileDir)) {
        Fail "Profile '$name' was not found."
    }

    $profileAuth = Get-ProfileAuthPath $name
    $profileSessionRoot = Get-ProfileSessionPath $name
    $hasAuth = Test-Path -LiteralPath $profileAuth
    $hasSession = Test-SessionSnapshotHasData -SessionRoot $profileSessionRoot
    if (-not $hasAuth -and -not $hasSession) {
        Fail "Profile '$name' has no saved session."
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

    Write-CurrentProfile $name
    Start-Codex
    Write-Log "Switched to profile '$name'"
}

function Save-CurrentSessionToProfile {
    param([string]$ProfileName)
    $name = Validate-ProfileName $ProfileName
    Stop-Codex
    Save-SessionSnapshotToProfile -ProfileName $name
    Write-CurrentProfile $name
    Start-Codex
    Write-Log "Saved current session as '$name'"
}

function Rename-Profile {
    param(
        [string]$OldName,
        [string]$NewName
    )
    $oldValid = Validate-ProfileName $OldName
    $newValid = Validate-ProfileName $NewName
    if ($oldValid -eq $newValid) {
        return
    }
    $source = Get-ProfileDir $oldValid
    $target = Get-ProfileDir $newValid
    if (-not (Test-Path -LiteralPath $source)) {
        Fail "Profile '$oldValid' was not found."
    }
    if (Test-Path -LiteralPath $target) {
        Fail "Profile '$newValid' already exists."
    }
    Move-Item -LiteralPath $source -Destination $target

    if ((Read-CurrentProfile) -eq $oldValid) {
        Write-CurrentProfile $newValid
    }
    if ((Read-PendingProfile) -eq $oldValid) {
        Write-PendingProfile $newValid
    }
    Write-Log "Renamed profile '$oldValid' to '$newValid'"
}

function Delete-Profile {
    param([string]$ProfileName)
    $name = Validate-ProfileName $ProfileName
    $target = Get-ProfileDir $name
    if (-not (Test-Path -LiteralPath $target)) {
        return
    }
    Remove-Item -LiteralPath $target -Recurse -Force
    if ((Read-CurrentProfile) -eq $name -and (Test-Path -LiteralPath $CurrentFile)) {
        Remove-Item -LiteralPath $CurrentFile -Force
    }
    if ((Read-PendingProfile) -eq $name) {
        Clear-PendingState
    }
    Write-Log "Deleted profile '$name'"
}

function Test-ProfileExists {
    param([string]$Name)
    $profileDir = Get-ProfileDir $Name
    Test-Path -LiteralPath $profileDir
}

function Get-SuggestedProfileName {
    $existing = @(Get-ChildItem -LiteralPath $ProfilesDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $index = 1
    while ($true) {
        $candidate = "Account $index"
        if (-not ($existing | Where-Object { $_.ToLowerInvariant() -eq $candidate.ToLowerInvariant() })) {
            return $candidate
        }
        $index++
    }
}

function Get-ProfileObjects {
    Ensure-Directories
    $active = Read-CurrentProfile
    $dirs = Get-ChildItem -LiteralPath $ProfilesDir -Directory -ErrorAction SilentlyContinue
    $profiles = @()
    foreach ($dir in $dirs) {
        $name = $dir.Name
        $auth = Join-Path $dir.FullName "auth.json"
        $session = Join-Path $dir.FullName "CodexSession"
        $hasAuth = Test-Path -LiteralPath $auth
        $hasSession = Test-SessionSnapshotHasData -SessionRoot $session
        if (-not $hasAuth -and -not $hasSession) {
            continue
        }
        $modified = $null
        if ($hasAuth) {
            $modified = (Get-Item -LiteralPath $auth).LastWriteTime
        }
        if ($hasSession) {
            $sessionWrite = (Get-Item -LiteralPath $session).LastWriteTime
            if (-not $modified -or $sessionWrite -gt $modified) {
                $modified = $sessionWrite
            }
        }
        $email = if ($hasAuth) { Get-ProfileEmailFromAuth -AuthPath $auth } else { $null }
        $profiles += [pscustomobject]@{
            Name       = $name
            Path       = $dir.FullName
            AuthPath   = $auth
            SessionDir = $session
            HasAuth    = $hasAuth
            HasSession = $hasSession
            ModifiedAt = $modified
            IsActive   = ($active -and ($active.ToLowerInvariant() -eq $name.ToLowerInvariant()))
            Email      = $email
        }
    }
    return $profiles | Sort-Object Name
}

function Start-PendingLoginFlow {
    param([string]$ProfileName)
    $name = Validate-ProfileName $ProfileName
    if (Test-ProfileExists $name) {
        Fail "Profile '$name' already exists."
    }

    Stop-Codex
    Refresh-ActiveProfileSessionIfPossible
    Backup-CurrentAuthIfPresent
    $previous = Read-CurrentProfile
    $fingerprint = Get-CurrentSessionFingerprint
    Clear-CurrentSession

    Write-PendingProfile $name
    Write-PendingPreviousProfile $previous
    Write-PendingPreviousFingerprint $fingerprint
    if (Test-Path -LiteralPath $CurrentFile) {
        Remove-Item -LiteralPath $CurrentFile -Force
    }

    Start-Codex
    Write-Log "Started login flow for '$name'"
}

function Complete-PendingLoginFlow {
    $pending = Read-PendingProfile
    if (-not $pending) {
        return $false
    }
    Save-SessionSnapshotToProfile -ProfileName $pending
    Write-CurrentProfile $pending
    Clear-PendingState
    Write-Log "Completed login flow for '$pending'"
    return $true
}

function Cancel-PendingLoginFlow {
    $pending = Read-PendingProfile
    if (-not $pending) {
        return
    }
    $previous = Read-PendingPreviousProfile
    Clear-PendingState
    if ($previous -and (Test-ProfileExists $previous)) {
        Switch-ToProfile -ProfileName $previous
    }
    Write-Log "Cancelled login flow for '$pending'"
}

function Get-PendingLoginAgeSeconds {
    if (-not (Test-Path -LiteralPath $PendingProfileFile)) {
        return [double]::PositiveInfinity
    }
    $startedAt = (Get-Item -LiteralPath $PendingProfileFile).LastWriteTime
    return [int]((Get-Date) - $startedAt).TotalSeconds
}

function Poll-PendingLoginFlow {
    $pending = Read-PendingProfile
    if (-not $pending) {
        return "none"
    }

    if (-not (Has-UsableAuthFile)) {
        if ((-not (Is-CodexRunning)) -and ((Get-PendingLoginAgeSeconds) -gt 8)) {
            Cancel-PendingLoginFlow
            return "cancelled"
        }
        return "waiting"
    }

    $currentFingerprint = Get-CurrentSessionFingerprint
    $previousFingerprint = Read-PendingPreviousFingerprint
    if ($currentFingerprint -and (($currentFingerprint -ne $previousFingerprint) -or -not $previousFingerprint)) {
        if (Complete-PendingLoginFlow) {
            return "completed"
        }
    }
    return "waiting"
}

if ($SelfTest) {
    Ensure-Directories
    $profiles = @(Get-ProfileObjects)
    Write-Output "SelfTest: OK"
    Write-Output "Profiles: $($profiles.Count)"
    Write-Output "SessionRoot: $(Get-CodexSessionPath)"
    exit 0
}

Ensure-Directories

$script:statusLabel = $null
$script:pendingLabel = $null
$script:listView = $null
$script:detailsName = $null
$script:detailsPath = $null
$script:detailsState = $null
$script:detailsSaved = $null
$script:detailsContent = $null
$script:detailsEmail = $null
$script:newProfileBox = $null
$script:cachedProfiles = @()

function Set-StatusText {
    param([string]$Text)
    if ($script:statusLabel) {
        $script:statusLabel.Text = $Text
    }
    Write-Log $Text
}

function Show-ErrorDialog {
    param([System.Exception]$ErrorObject)
    [System.Windows.Forms.MessageBox]::Show(
        $ErrorObject.Message,
        "Codex Account Switcher",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Get-SelectedProfile {
    if (-not $script:listView.SelectedItems -or $script:listView.SelectedItems.Count -eq 0) {
        return $null
    }
    $name = $script:listView.SelectedItems[0].Tag
    return $script:cachedProfiles | Where-Object { $_.Name -eq $name } | Select-Object -First 1
}

function Update-DetailsPanel {
    $profile = Get-SelectedProfile
    if (-not $profile) {
        $script:detailsName.Text = "No profile selected"
        $script:detailsPath.Text = "-"
        $script:detailsState.Text = "-"
        $script:detailsSaved.Text = "-"
        $script:detailsContent.Text = "-"
        $script:detailsEmail.Text = "-"
        return
    }
    $script:detailsName.Text = $profile.Name
    $script:detailsPath.Text = $profile.Path
    $script:detailsState.Text = if ($profile.IsActive) { "Active" } else { "Saved" }
    $script:detailsSaved.Text = if ($profile.ModifiedAt) { $profile.ModifiedAt.ToString("yyyy-MM-dd HH:mm:ss") } else { "Unknown" }
    $parts = @()
    if ($profile.HasSession) { $parts += "Browser session" }
    if ($profile.HasAuth) { $parts += "CLI auth.json" }
    $script:detailsContent.Text = if ($parts.Count -gt 0) { $parts -join " + " } else { "Empty" }
    $script:detailsEmail.Text = if ($profile.Email) { $profile.Email } else { "-" }
}

function Select-ProfileByName {
    param([string]$Name)
    if (-not $Name) {
        return
    }
    foreach ($item in $script:listView.Items) {
        if ($item.Tag -eq $Name) {
            $item.Selected = $true
            $item.Focused = $true
            $item.EnsureVisible()
            return
        }
    }
}

function Refresh-ProfileList {
    param([string]$PreferredSelection)
    $script:cachedProfiles = @(Get-ProfileObjects)
    $script:listView.BeginUpdate()
    try {
        $script:listView.Items.Clear()
        foreach ($profile in $script:cachedProfiles) {
            $state = if ($profile.IsActive) { "Active" } else { "Saved" }
            $saved = if ($profile.ModifiedAt) { $profile.ModifiedAt.ToString("yyyy-MM-dd HH:mm:ss") } else { "Unknown" }
            $content = if ($profile.HasSession -and $profile.HasAuth) { "Session + auth" } elseif ($profile.HasSession) { "Session only" } else { "Auth only" }
            $email = if ($profile.Email) { $profile.Email } else { "" }
            $item = New-Object System.Windows.Forms.ListViewItem($profile.Name)
            [void]$item.SubItems.Add($state)
            [void]$item.SubItems.Add($saved)
            [void]$item.SubItems.Add($content)
            [void]$item.SubItems.Add($email)
            $item.Tag = $profile.Name
            if ($profile.IsActive) {
                $item.BackColor = [System.Drawing.Color]::FromArgb(230, 245, 230)
            }
            [void]$script:listView.Items.Add($item)
        }
    } finally {
        $script:listView.EndUpdate()
    }

    $pending = Read-PendingProfile
    if ($pending) {
        $script:pendingLabel.Text = "Pending login: $pending"
    } else {
        $script:pendingLabel.Text = "Pending login: none"
    }

    if ($PreferredSelection) {
        Select-ProfileByName -Name $PreferredSelection
    } elseif ($script:listView.Items.Count -gt 0) {
        $active = Read-CurrentProfile
        if ($active) {
            Select-ProfileByName -Name $active
        } else {
            $script:listView.Items[0].Selected = $true
            $script:listView.Items[0].Focused = $true
        }
    }

    Update-DetailsPanel
}

function Show-TextPrompt {
    param(
        [string]$Title,
        [string]$LabelText,
        [string]$DefaultValue
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.Width = 430
    $dialog.Height = 170
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Left = 12
    $label.Top = 15
    $label.Width = 390
    $label.Text = $LabelText

    $textbox = New-Object System.Windows.Forms.TextBox
    $textbox.Left = 12
    $textbox.Top = 42
    $textbox.Width = 390
    $textbox.Text = $DefaultValue

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.Left = 246
    $okButton.Top = 78
    $okButton.Width = 75
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Left = 327
    $cancelButton.Top = 78
    $cancelButton.Width = 75
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dialog.Controls.AddRange(@($label, $textbox, $okButton, $cancelButton))
    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton

    $result = $dialog.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $textbox.Text
    }
    return $null
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Codex Account Switcher (Windows)"
$form.Width = 1120
$form.Height = 720
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(980, 640)

$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = "Fill"
$mainLayout.ColumnCount = 2
$mainLayout.RowCount = 2
$mainLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 56)))
$mainLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 44)))
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 58)))

$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Dock = "Fill"
$leftPanel.Padding = New-Object System.Windows.Forms.Padding(10)

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = "Top"
$headerPanel.Height = 100

$nameLabel = New-Object System.Windows.Forms.Label
$nameLabel.Text = "Profile Name"
$nameLabel.Left = 4
$nameLabel.Top = 10
$nameLabel.AutoSize = $true

$script:newProfileBox = New-Object System.Windows.Forms.TextBox
$script:newProfileBox.Left = 4
$script:newProfileBox.Top = 32
$script:newProfileBox.Width = 320

$loginButton = New-Object System.Windows.Forms.Button
$loginButton.Text = "Login (New Profile)"
$loginButton.Left = 335
$loginButton.Top = 30
$loginButton.Width = 150

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "Save Current"
$saveButton.Left = 492
$saveButton.Top = 30
$saveButton.Width = 118

$script:pendingLabel = New-Object System.Windows.Forms.Label
$script:pendingLabel.Left = 4
$script:pendingLabel.Top = 69
$script:pendingLabel.AutoSize = $true
$script:pendingLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 72, 0)

$headerPanel.Controls.AddRange(@($nameLabel, $script:newProfileBox, $loginButton, $saveButton, $script:pendingLabel))

$script:listView = New-Object System.Windows.Forms.ListView
$script:listView.Dock = "Fill"
$script:listView.View = [System.Windows.Forms.View]::Details
$script:listView.FullRowSelect = $true
$script:listView.MultiSelect = $false
$script:listView.HideSelection = $false
$script:listView.Columns.Add("Profile", 160) | Out-Null
$script:listView.Columns.Add("State", 80) | Out-Null
$script:listView.Columns.Add("Saved", 160) | Out-Null
$script:listView.Columns.Add("Contents", 130) | Out-Null
$script:listView.Columns.Add("Email", 210) | Out-Null

$leftPanel.Controls.Add($script:listView)
$leftPanel.Controls.Add($headerPanel)

$rightPanel = New-Object System.Windows.Forms.Panel
$rightPanel.Dock = "Fill"
$rightPanel.Padding = New-Object System.Windows.Forms.Padding(10)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Profile Details"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$title.Dock = "Top"
$title.Height = 28

$detailsTable = New-Object System.Windows.Forms.TableLayoutPanel
$detailsTable.Dock = "Top"
$detailsTable.Height = 220
$detailsTable.ColumnCount = 2
$detailsTable.RowCount = 5
$detailsTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 95)))
$detailsTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

function New-DetailValueLabel {
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $true
    $label.MaximumSize = New-Object System.Drawing.Size(410, 0)
    return $label
}

$script:detailsName = New-DetailValueLabel
$script:detailsPath = New-DetailValueLabel
$script:detailsState = New-DetailValueLabel
$script:detailsSaved = New-DetailValueLabel
$script:detailsContent = New-DetailValueLabel
$script:detailsEmail = New-DetailValueLabel

$leftTexts = @("Name:", "State:", "Saved:", "Contents:", "Path:", "Email:")
$rightLabels = @($script:detailsName, $script:detailsState, $script:detailsSaved, $script:detailsContent, $script:detailsPath, $script:detailsEmail)
$detailsTable.RowCount = $leftTexts.Count
for ($i = 0; $i -lt $leftTexts.Count; $i++) {
    $detailsTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $leftTexts[$i]
    $l.AutoSize = $true
    $l.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $detailsTable.Controls.Add($l, 0, $i)
    $detailsTable.Controls.Add($rightLabels[$i], 1, $i)
}

$buttonsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonsPanel.Dock = "Top"
$buttonsPanel.Height = 126
$buttonsPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$buttonsPanel.WrapContents = $true

$switchButton = New-Object System.Windows.Forms.Button
$switchButton.Text = "Switch"
$switchButton.Width = 120
$switchButton.Height = 34

$renameButton = New-Object System.Windows.Forms.Button
$renameButton.Text = "Rename"
$renameButton.Width = 120
$renameButton.Height = 34

$deleteButton = New-Object System.Windows.Forms.Button
$deleteButton.Text = "Delete"
$deleteButton.Width = 120
$deleteButton.Height = 34

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "Refresh"
$refreshButton.Width = 120
$refreshButton.Height = 34

$openFolderButton = New-Object System.Windows.Forms.Button
$openFolderButton.Text = "Open Profiles Folder"
$openFolderButton.Width = 170
$openFolderButton.Height = 34

$cancelPendingButton = New-Object System.Windows.Forms.Button
$cancelPendingButton.Text = "Cancel Pending Login"
$cancelPendingButton.Width = 170
$cancelPendingButton.Height = 34

$buttonsPanel.Controls.AddRange(@($switchButton, $renameButton, $deleteButton, $refreshButton, $openFolderButton, $cancelPendingButton))

$rightPanel.Controls.Add($buttonsPanel)
$rightPanel.Controls.Add($detailsTable)
$rightPanel.Controls.Add($title)

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Dock = "Fill"
$statusPanel.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 8)
$script:statusLabel = New-Object System.Windows.Forms.Label
$script:statusLabel.Dock = "Fill"
$script:statusLabel.Text = "Ready."
$statusPanel.Controls.Add($script:statusLabel)

$mainLayout.Controls.Add($leftPanel, 0, 0)
$mainLayout.Controls.Add($rightPanel, 1, 0)
$mainLayout.SetColumnSpan($statusPanel, 2)
$mainLayout.Controls.Add($statusPanel, 0, 1)
$form.Controls.Add($mainLayout)

$script:listView.add_SelectedIndexChanged({
    Update-DetailsPanel
})

$script:listView.add_DoubleClick({
    $profile = Get-SelectedProfile
    if ($profile) {
        try {
            Switch-ToProfile -ProfileName $profile.Name
            Refresh-ProfileList -PreferredSelection $profile.Name
            Set-StatusText "Switched to '$($profile.Name)'."
        } catch {
            Show-ErrorDialog -ErrorObject $_.Exception
            Set-StatusText "Error: $($_.Exception.Message)"
        }
    }
})

$loginButton.add_Click({
    try {
        $name = $script:newProfileBox.Text
        Start-PendingLoginFlow -ProfileName $name
        Set-StatusText "Waiting for Codex login for '$name'."
        Refresh-ProfileList
    } catch {
        Show-ErrorDialog -ErrorObject $_.Exception
        Set-StatusText "Error: $($_.Exception.Message)"
    }
})

$saveButton.add_Click({
    try {
        $name = $script:newProfileBox.Text
        if (-not $name -or -not $name.Trim()) {
            $selected = Get-SelectedProfile
            if ($selected) {
                $name = $selected.Name
            }
        }
        Save-CurrentSessionToProfile -ProfileName $name
        $script:newProfileBox.Text = ""
        Refresh-ProfileList -PreferredSelection $name
        Set-StatusText "Saved current session as '$name'."
    } catch {
        Show-ErrorDialog -ErrorObject $_.Exception
        Set-StatusText "Error: $($_.Exception.Message)"
    }
})

$switchButton.add_Click({
    $profile = Get-SelectedProfile
    if (-not $profile) {
        return
    }
    try {
        Switch-ToProfile -ProfileName $profile.Name
        Refresh-ProfileList -PreferredSelection $profile.Name
        Set-StatusText "Switched to '$($profile.Name)'."
    } catch {
        Show-ErrorDialog -ErrorObject $_.Exception
        Set-StatusText "Error: $($_.Exception.Message)"
    }
})

$renameButton.add_Click({
    $profile = Get-SelectedProfile
    if (-not $profile) {
        return
    }
    $newName = Show-TextPrompt -Title "Rename Profile" -LabelText "New name for '$($profile.Name)':" -DefaultValue $profile.Name
    if ($null -eq $newName) {
        return
    }
    try {
        Rename-Profile -OldName $profile.Name -NewName $newName
        Refresh-ProfileList -PreferredSelection $newName
        Set-StatusText "Renamed profile to '$newName'."
    } catch {
        Show-ErrorDialog -ErrorObject $_.Exception
        Set-StatusText "Error: $($_.Exception.Message)"
    }
})

$deleteButton.add_Click({
    $profile = Get-SelectedProfile
    if (-not $profile) {
        return
    }
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Delete profile '$($profile.Name)'?",
        "Confirm Delete",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }
    try {
        Delete-Profile -ProfileName $profile.Name
        Refresh-ProfileList
        Set-StatusText "Deleted profile '$($profile.Name)'."
    } catch {
        Show-ErrorDialog -ErrorObject $_.Exception
        Set-StatusText "Error: $($_.Exception.Message)"
    }
})

$refreshButton.add_Click({
    try {
        Refresh-ProfileList
        Set-StatusText "Refreshed."
    } catch {
        Show-ErrorDialog -ErrorObject $_.Exception
        Set-StatusText "Error: $($_.Exception.Message)"
    }
})

$openFolderButton.add_Click({
    try {
        Ensure-Directories
        Start-Process -FilePath "explorer.exe" -ArgumentList $ProfilesDir | Out-Null
        Set-StatusText "Opened profiles folder."
    } catch {
        Show-ErrorDialog -ErrorObject $_.Exception
        Set-StatusText "Error: $($_.Exception.Message)"
    }
})

$cancelPendingButton.add_Click({
    try {
        Cancel-PendingLoginFlow
        Refresh-ProfileList
        Set-StatusText "Pending login cancelled."
    } catch {
        Show-ErrorDialog -ErrorObject $_.Exception
        Set-StatusText "Error: $($_.Exception.Message)"
    }
})

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 2000
$pollTimer.add_Tick({
    try {
        $state = Poll-PendingLoginFlow
        switch ($state) {
            "completed" {
                $saved = Read-CurrentProfile
                Refresh-ProfileList -PreferredSelection $saved
                Set-StatusText "New profile '$saved' saved after login."
            }
            "cancelled" {
                Refresh-ProfileList
                Set-StatusText "Pending login cancelled."
            }
            "waiting" {
                $pending = Read-PendingProfile
                if ($pending) {
                    $script:pendingLabel.Text = "Pending login: $pending"
                }
            }
            default {
                $script:pendingLabel.Text = "Pending login: none"
            }
        }
    } catch {
        Write-Log "Polling error: $($_.Exception.Message)"
    }
})

$form.add_Shown({
    try {
        if (-not $script:newProfileBox.Text) {
            $script:newProfileBox.Text = Get-SuggestedProfileName
        }
        Refresh-ProfileList
        Set-StatusText "Ready."
        $pollTimer.Start()
    } catch {
        Show-ErrorDialog -ErrorObject $_.Exception
        Set-StatusText "Error: $($_.Exception.Message)"
    }
})

$form.add_FormClosing({
    $pollTimer.Stop()
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
