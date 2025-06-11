<#
.SYNOPSIS
    Validates SSH identity setup for Git (e.g., GitHub or GitHub Enterprise) on Windows using PowerShell.
.DESCRIPTION
    Parses SSH config, verifies IdentityFile presence, tests SSH connectivity, checks Git identity, and
    optionally validates public keys via GitHub/GitHub Enterprise REST API.
.PARAMETER GitHubToken
    Personal Access Token for GitHub/GitHub Enterprise to verify registered SSH keys.
.PARAMETER GitHubApiBaseUrl
    Optional base API URL for GitHub Enterprise (default: https://api.github.com).
.PARAMETER FixIdentityPaths
    Optional. Fixes backslashes in IdentityFile paths inside your SSH config file.
.NOTES
    Author: ChatGPT
#>

param (
    [string]$GitHubToken,
    [string]$GitHubApiBaseUrl = "https://api.github.com",
    [switch]$FixIdentityPaths
)

$sshConfigPath = "$env:USERPROFILE\.ssh\config"
$defaultKey = "$env:USERPROFILE\.ssh\id_ed25519"

function Repair-IdentityPathsInConfig {
    if (!(Test-Path $sshConfigPath)) {
        Write-Warning "SSH config file not found, cannot fix paths: $sshConfigPath"
        return
    }

    Write-Host "Fixing backslashes in IdentityFile paths..." -ForegroundColor Cyan
    $configBackup = "$sshConfigPath.bak"
    Copy-Item $sshConfigPath $configBackup -Force
    Write-Debug "Backup created at $configBackup"

    (Get-Content $sshConfigPath) |
        ForEach-Object {
            if ($_ -match '^\s*IdentityFile\s+.*\\') {
                $_ -replace '\\', '/'
            } else {
                $_
            }
        } | Set-Content $sshConfigPath

    Write-Host "SSH config updated. Backup saved as: $configBackup" -ForegroundColor Yellow
}

function Read-SshConfig {
    Write-Debug "Parsing SSH config: $sshConfigPath"
    $configEntries = @{}
    if (!(Test-Path $sshConfigPath)) {
        Write-Error "SSH config file not found: $sshConfigPath"
        return $configEntries
    }

    $lines = Get-Content $sshConfigPath
    $currentHost = $null
    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed -like "Host *") {
            $currentHost = $trimmed -replace "Host\s+", ""
            Write-Debug "Found host: $($currentHost)"
            $configEntries[$currentHost] = @{ IdentityFile = $null }
            continue
        }

        if ($currentHost -and $trimmed -match "^IdentityFile\s+(.+)$") {
            $path = $matches[1].Trim().Replace('\', '/')
            Write-Debug "Found IdentityFile for $($currentHost): $path"
            $configEntries[$currentHost]["IdentityFile"] = $path
        }
    }

    return $configEntries
}

function Get-GitHubSshKeys {
    param (
        [string]$Token,
        [string]$ApiBaseUrl
    )

    Write-Debug "Fetching SSH keys from GitHub API at $ApiBaseUrl"
    try {
        $headers = @{ Authorization = "token $Token" }
        $response = Invoke-RestMethod -Uri "$ApiBaseUrl/user/keys" -Headers $headers
        return $response
    } catch {
        Write-Warning "GitHub API request failed: $($_.Exception.Message)"
        return @()
    }
}

function Compare-PublicKey-ToGitHub {
    param (
        [string]$PublicKeyPath,
        [array]$GitHubKeys
    )

    if (!(Test-Path $PublicKeyPath)) {
        Write-Warning "Public key not found: $PublicKeyPath"
        return
    }

    $localKey = Get-Content $PublicKeyPath | Select-Object -First 1
    $localKeyClean = $localKey -replace '(\Assh-(rsa|ed25519) [A-Za-z0-9+/=]+).*', '$1'

    $found = $GitHubKeys | Where-Object { $_.key -eq $localKeyClean }
    if ($found) {
        Write-Host "✅ Local public key matches a registered GitHub SSH key titled: '$($found.title)'" -ForegroundColor Green
    } else {
        Write-Warning "❌ This public key is NOT registered with GitHub."
    }
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

    Write-Host "`n== [$alias] Validating IdentityFile: $identityFilePath ==" -ForegroundColor Cyan
    Write-Debug "Checking identity file: $identityFilePath"

    if (!(Test-Path $identityFilePath)) {
        Write-Warning "Private key not found: $identityFilePath"
        return
    }

    $publicKey = "$identityFilePath.pub"
    if (!(Test-Path $publicKey)) {
        Write-Warning "Public key not found: $publicKey"
    }

    $privateAcl = Get-Acl $identityFilePath
    Write-Host "Private key permissions:" -ForegroundColor Green
    $privateAcl.Access | Format-Table

    if (Test-SshAgentRunning) {
        Write-Debug "Adding key to ssh-agent: $identityFilePath"
        ssh-add $identityFilePath | Out-Null
    } else {
        Write-Warning "SSH agent not running. Skipping ssh-add for '$identityFilePath'"
    }

    if ($GitHubKeys) {
        Compare-PublicKey-ToGitHub -PublicKeyPath $publicKey -GitHubKeys $GitHubKeys
    }

    Write-Host "Testing SSH connection for alias '$alias'..." -ForegroundColor Yellow
    ssh -T $alias
}

if ($FixIdentityPaths) {
    Repair-IdentityPathsInConfig
}

Write-Host "== Parsing SSH Config File ==" -ForegroundColor Cyan
$configMap = Read-SshConfig

$gitHubKeys = @()
if ($GitHubToken) {
    Write-Host "`n== Fetching SSH keys from GitHub ==" -ForegroundColor Cyan
    $gitHubKeys = Get-GitHubSshKeys -Token $GitHubToken -ApiBaseUrl $GitHubApiBaseUrl
}

if ($configMap.Count -eq 0) {
    Write-Warning "No Host entries with IdentityFile found in SSH config. Defaulting to: $defaultKey"
    Test-IdentityFileConfiguration -alias "git@github.com" -identityFilePath $defaultKey -GitHubKeys $gitHubKeys
} else {
    foreach ($entry in $configMap.GetEnumerator()) {
        $alias = $entry.Key
        $identityFilePath = $entry.Value.IdentityFile
        if ($identityFilePath) {
            Test-IdentityFileConfiguration -alias $alias -identityFilePath $identityFilePath -GitHubKeys $gitHubKeys
        } else {
            Write-Host "`n== [$alias] Skipped: No IdentityFile specified ==" -ForegroundColor DarkGray
        }
    }
}

Write-Host "`n== Verifying Git Identity ==" -ForegroundColor Cyan
git config --global user.name
git config --global user.email

Write-Host "`nAll tests complete." -ForegroundColor Cyan
