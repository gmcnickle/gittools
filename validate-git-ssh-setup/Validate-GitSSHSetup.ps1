<#
.SYNOPSIS
    Validates SSH identity setup for Git (e.g., GitHub or GitHub Enterprise) on Windows using PowerShell.
.DESCRIPTION
    Parses SSH config, verifies IdentityFile presence, tests SSH connectivity, checks Git identity, and
    optionally validates public keys via GitHub/GitHub Enterprise REST API. Can also test for SAML SSO restrictions.
.PARAMETER GitHubToken
    Personal Access Token for GitHub/GitHub Enterprise to verify registered SSH keys.
.PARAMETER GitHubApiBaseUrl
    Optional base API URL for GitHub Enterprise (default: https://api.github.com).
.PARAMETER SshConfigPath
    Optional path to the SSH config file. Defaults to ~/.ssh/config. Use this if your config file has a non-standard name or location.
.PARAMETER FixIdentityPaths
    Optional. Fixes backslashes in IdentityFile paths inside your SSH config file.
.PARAMETER LogFile
    Optional path to a log file where error details will be written.
.PARAMETER SamlTestRepo
    Optional. Remote repo path to test SAML SSO SSH access. If not provided, the script attempts to use the origin of the current directory if it is a Git repo.
.NOTES
Primary Author: Gary McNickle (gmcnickle@outlook.com)
Co-Author & Assistant: ChatGPT (OpenAI)

This script was collaboratively designed and developed through interactive sessions with ChatGPT, combining human experience and AI-driven support to solve real-world development challenges.
#>
param (
    [string]$GitHubToken,
    [string]$GitHubApiBaseUrl = "https://api.github.com",
    [string]$SshConfigPath = "$env:USERPROFILE\.ssh\config",
    [switch]$FixIdentityPaths,
    [string]$LogFile,
    [string]$SamlTestRepo
)

$defaultKey = "$env:USERPROFILE\.ssh\id_ed25519"

function Write-CheckResult {
    param (
        [Parameter(Mandatory)] [string]$Message,
        [Parameter(Mandatory)] [bool]$Success,
        [int]$Indent = 0,
        [string]$Detail = $null
    )

    $icon = if ($Success) { "✅" } else { "❌" }
    $paddedMessage = "{0,-78}" -f (" " * $Indent + $Message)
    Write-Host "$paddedMessage $icon"

    if (-not $Success -and $Detail) {
        $log = "❌ $Message`n    $Detail`n"
        if ($LogFile) {
            Add-Content -Path $LogFile -Value $log
        } else {
            Write-Host $log -ForegroundColor DarkGray
        }
    }
}

function Repair-IdentityPathsInConfig {
    if (!(Test-Path $sshConfigPath)) {
        Write-CheckResult -Message "SSH config file not found for path fix" -Success $false
        return
    }
    $configBackup = "$sshConfigPath.bak"
    Copy-Item $sshConfigPath $configBackup -Force
    (Get-Content $sshConfigPath) | ForEach-Object {
        if ($_ -match '^\s*IdentityFile\s+.*\\') {
            $_ -replace '\\', '/'
        } else {
            $_
        }
    } | Set-Content $sshConfigPath
    Write-CheckResult -Message "Repaired backslashes in IdentityFile paths" -Success $true
}

function Read-SshConfig {
    $configEntries = @{}
    if (!(Test-Path $sshConfigPath)) {
        Write-CheckResult -Message "SSH config file not found: $sshConfigPath" -Success $false
        return $configEntries
    }
    $lines = Get-Content $sshConfigPath
    $currentHost = $null
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -like "Host *") {
            $currentHost = $trimmed -replace "Host\s+", ""
            $configEntries[$currentHost] = @{ IdentityFile = $null }
            continue
        }
        if ($currentHost -and $trimmed -match "^IdentityFile\s+(.+)$") {
            $path = $matches[1].Trim().Replace('\\', '/')
            $configEntries[$currentHost]["IdentityFile"] = $path
        }
    }
    Write-CheckResult -Message "Parsed SSH config and extracted aliases" -Success ($configEntries.Count -gt 0)
    return $configEntries
}

function Get-GitHubSshKeys {
    param ([string]$Token, [string]$ApiBaseUrl)
    try {
        $headers = @{ Authorization = "token $Token" }
        $response = Invoke-RestMethod -Uri "$ApiBaseUrl/user/keys" -Headers $headers
        Write-CheckResult -Message "Fetched SSH keys from GitHub API" -Success $true
        return $response
    } catch {
        Write-CheckResult -Message "GitHub API request failed" -Success $false -Detail $_.Exception.Message
        return @()
    }
}

function Compare-PublicKey-ToGitHub {
    param ([string]$PublicKeyPath, [array]$GitHubKeys)
    if (!(Test-Path $PublicKeyPath)) {
        Write-CheckResult -Message "Public key not found: $PublicKeyPath" -Success $false
        return
    }
    $localKey = Get-Content $PublicKeyPath | Select-Object -First 1
    $localKeyClean = $localKey -replace '(\Assh-(rsa|ed25519) [A-Za-z0-9+/=]+).*', '$1'
    $found = $GitHubKeys | Where-Object { $_.key -eq $localKeyClean }
    Write-CheckResult -Message "Local public key match on GitHub" -Success ($null -ne $found) -Indent 4
}

function Test-SshAgentRunning {
    ssh-add -L | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Test-IdentityFileConfiguration {
    param (
        [string]$alias,
        [string]$identityFilePath,
        [array]$GitHubKeys
    )
    $identityExists = Test-Path $identityFilePath
    Write-CheckResult -Message "Validating IdentityFile for alias '$alias'" -Success $identityExists
    if (-not $identityExists) { return }
    $publicKey = "$identityFilePath.pub"
    if (!(Test-Path $publicKey)) {
        Write-CheckResult -Message "Public key not found for alias '$alias'" -Success $false -Indent 4
    }
    if (Test-SshAgentRunning) {
        try {
            ssh-add $identityFilePath | Out-Null
            Write-CheckResult -Message "Added key to ssh-agent for alias '$alias'" -Success $true -Indent 4
        } catch {
            Write-CheckResult -Message "Failed to add key to ssh-agent for alias '$alias'" -Success $false -Indent 4 -Detail $_.Exception.Message
        }
    } else {
        Write-CheckResult -Message "SSH agent not running for alias '$alias'" -Success $false -Indent 4
    }
    if ($GitHubKeys) {
        Compare-PublicKey-ToGitHub -PublicKeyPath $publicKey -GitHubKeys $GitHubKeys
    }
    $sshTest = ssh -T $alias 2>&1
    $success = ($sshTest -match "successfully authenticated")
    Write-CheckResult -Message "SSH test for alias '$alias'" -Success $success -Indent 4 -Detail $sshTest
}

function Test-GitSshSamlAccess {
    param ([string]$RepoPath)
    try {
        $result = git ls-remote $RepoPath 2>&1
        if ($result -match "SAML SSO") {
            Write-CheckResult -Message "SSH key is not SAML-authorized for this org" -Success $false -Detail $result
            Write-Host "ℹ️  To fix this, go to your GitHub account settings → 'SSH and GPG keys' and authorize the key for SSO access to the appropriate organization." -ForegroundColor Yellow
            return
        } elseif ($result -match "You must authenticate via a web browser") {
            Write-CheckResult -Message "SSH key requires SSO browser authorization" -Success $false -Detail $result
            Write-Host "ℹ️  To fix this, go to your GitHub account settings → 'SSH and GPG keys' and authorize the key for SSO access to the appropriate organization." -ForegroundColor Yellow
            return
        } elseif ($result -match "Permission denied" -or $result -match "Repository not found") {
            Write-CheckResult -Message "SSH connected, but repo is inaccessible (expected for dummy)" -Success $true
        } else {
            Write-CheckResult -Message "SSH check completed with unexpected result" -Success $true -Detail $result
        }
    } catch {
        Write-CheckResult -Message "Git command failed unexpectedly during SAML check" -Success $false -Detail $_.Exception.Message
    }
}

if ($FixIdentityPaths) {
    Repair-IdentityPathsInConfig
}

Write-CheckResult -Message "Reading and parsing SSH config" -Success (Test-Path $sshConfigPath)
$configMap = Read-SshConfig

$gitHubKeys = @()
if ($GitHubToken) {
    $gitHubKeys = Get-GitHubSshKeys -Token $GitHubToken -ApiBaseUrl $GitHubApiBaseUrl
}

if ($configMap.Count -eq 0) {
    Write-CheckResult -Message "No IdentityFile aliases found, defaulting to ~/.ssh/id_ed25519" -Success (Test-Path $defaultKey)
    Test-IdentityFileConfiguration -alias "git@github.com" -identityFilePath $defaultKey -GitHubKeys $gitHubKeys
} else {
    foreach ($entry in $configMap.GetEnumerator()) {
        $alias = $entry.Key
        $identityFilePath = $entry.Value.IdentityFile
        if ($identityFilePath) {
            Test-IdentityFileConfiguration -alias $alias -identityFilePath $identityFilePath -GitHubKeys $gitHubKeys
        } else {
            Write-CheckResult -Message "Skipped alias '$alias': No IdentityFile specified" -Success $false
        }
    }
}

# Determine repo for optional SAML check
if (-not $SamlTestRepo) {
    $insideRepo = (git rev-parse --is-inside-work-tree 2>$null) -eq "true"
    if ($insideRepo) {
        $remoteUrl = git remote get-url origin 2>$null
        if ($remoteUrl -match "[:/]([^/:]+)/([^/]+?)(\.git)?$") {
            $org = $matches[1]
            $repo = $matches[2]
            $SamlTestRepo = $remoteUrl
            Write-CheckResult -Message "Using current repo for SAML test: $org/$repo" -Success $true
        }
    }
}

if ($SamlTestRepo) {
    Test-GitSshSamlAccess -RepoPath $SamlTestRepo
} else {
    Write-CheckResult -Message "Skipping SAML SSO check: no test repo provided or detected" -Success $true
}

Write-CheckResult -Message "Verifying Git global user.name" -Success ($null -ne (git config --global user.name))
Write-CheckResult -Message "Verifying Git global user.email" -Success ($null -ne (git config --global user.email))

Write-Host "`nAll tests complete." -ForegroundColor Cyan
