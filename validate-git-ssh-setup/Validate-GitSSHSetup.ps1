<#
.SYNOPSIS
Validates SSH configuration, keys, and GitHub access for one or more identities.

.DESCRIPTION
This script performs a comprehensive validation of your SSH and GitHub access setup by:
- Parsing your SSH config file to extract aliases (defined via `Host`) and associated `IdentityFile` paths
- Optionally fixing backslashes in IdentityFile paths
- Verifying SSH keys exist and are loaded into the SSH agent
- Matching local SSH public keys against the keys stored in GitHub (for one or more tokens)
- Testing SSH connectivity using aliases (`ssh -T <alias>`)
- Validating GitHub SAML access for a repository (auto-detected or specified)
- Checking Git global configuration for user.name and user.email

.PARAMETER GitHubTokens
One or more GitHub personal access tokens, provided as a comma- or semicolon-delimited string.
Used to fetch SSH keys for verification and determine token ownership.
Each token should have at least the `read:public_key` scope.

.PARAMETER GitHubApiBaseUrl
Optional. Base URL for GitHub API (defaults to `https://api.github.com`). 
Override if using GitHub Enterprise.

.PARAMETER SshConfigPath
Optional. Path to the SSH config file (defaults to `$HOME\.ssh\config`).

.PARAMETER FixIdentityPaths
Optional switch. If set, the script will replace backslashes (`\`) with forward slashes (`/`) in all IdentityFile paths in the SSH config file.

.PARAMETER LogFile
Optional. If specified, logs detailed output of failed checks and other messages to the given file.

.PARAMETER SamlTestRepo
Optional. A GitHub repository URL to test SAML/SSO authorization via SSH.
If not provided, the script will attempt to use the current Git repo.

.EXAMPLE
.\Validate-GitSSHSetup.ps1 -GitHubTokens "ghp_ABC123,ghp_DEF456" -FixIdentityPaths

Validates SSH setup using the two tokens provided and repairs slashes in IdentityFile paths.

.EXAMPLE
.\Validate-GitSSHSetup.ps1 -GitHubTokens "ghp_ABC123" -SamlTestRepo "git@github.com:my-org/my-repo.git"

Tests that the SSH key is authorized for GitHub SSO access to the specified repository.

.NOTES
- SSH aliases must be defined in your SSH config using the `Host` and `IdentityFile` directives.
- The script tests each alias independently and validates SSH connectivity per alias.
- It attempts to match public key comments with GitHub usernames or email addresses to determine the correct token for each key.
- SSH agent will be started if not already running.

Primary Author: Gary McNickle (gmcnickle@outlook.com)
Co-Author: ChatGPT (OpenAI)
GitHub: https://github.com/gmcnickle
License: MIT License

This script was collaboratively designed and developed through interactive sessions with ChatGPT, combining human experience and AI-driven support to solve real-world development challenges.
#>
param (
    [string]$GitHubTokens,  # comma- or semicolon-delimited list
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

    if (-not $Success -and $Detail) 
    {
        $log = "❌ $Message`n    $Detail`n"

        if ($LogFile) 
        {
            Add-Content -Path $LogFile -Value $log
        } 
        else 
        {
            Write-Host $log -ForegroundColor DarkGray
        }
    }
}

function Test-SshConfigExists 
{ 
    if (-not (Test-Path $sshConfigPath)) 
    {
        Write-CheckResult -Message "SSH config file not found: $sshConfigPath" -Success $false

        return $false
    }

    return $true
}

function Repair-IdentityPathsInConfig {

    if (-not (Test-SshConfigExists)) 
    { 
        return 
    }

    $configBackup = "$sshConfigPath.bak"
    Copy-Item $sshConfigPath $configBackup -Force

    (Get-Content $sshConfigPath) | ForEach-Object {
        if ($_ -match '^\s*IdentityFile\s+.*\\') {
            $_ -replace '\\', '/'
        } 
        else {
            $_
        }
    } | Set-Content $sshConfigPath

    Write-CheckResult -Message "Repaired backslashes in IdentityFile paths" -Success $true
}

function Read-SshConfig {
    $configEntries = @{}

    if (-not (Test-SshConfigExists)) 
    { 
        return $configEntries 
    }

    $lines = Get-Content $sshConfigPath
    $currentHost = $null

    foreach ($line in $lines) 
    {
        $trimmed = $line.Trim()

        if ($trimmed -like "Host *") 
        {
            $currentHost = $trimmed -replace "Host\s+", ""
            $configEntries[$currentHost] = @{ IdentityFile = $null }
            continue
        }
        if ($currentHost -and $trimmed -match "^IdentityFile\s+(.+)$") 
        {
            $path = $matches[1].Trim().Replace('\\', '/')
            $configEntries[$currentHost]["IdentityFile"] = $path
        }
    }

    Write-CheckResult -Message "Parsed SSH config and extracted aliases" -Success ($configEntries.Count -gt 0)
    return $configEntries
}

function Get-GitHubSshKeys 
{
    param (
        [string]$Token, 
        [string]$ApiBaseUrl
    )

    try 
    {
        $headers = @{ Authorization = "token $Token" }
        $response = Invoke-RestMethod -Uri "$ApiBaseUrl/user/keys" -Headers $headers
        Write-CheckResult -Message "Fetched SSH keys from GitHub API" -Success $true

        return $response
    } 
    catch 
    {
        Write-CheckResult -Message "GitHub API request failed" -Success $false -Detail $_.Exception.Message
        return @()
    }
}

function Compare-PublicKey-ToGitHub 
{
    param (
        [string]$PublicKeyPath,
        [array]$GitHubKeys
    )

    if (!(Test-Path $PublicKeyPath)) 
    {
        Write-CheckResult -Message "Public key not found: $PublicKeyPath" -Success $false

        return
    }

    if (-not $GitHubKeys -or $GitHubKeys.Count -eq 0) 
    {
        Write-CheckResult -Message "No SSH keys returned by GitHub API" -Success $false -Indent 4
        Write-Host "ℹ️  Ensure your PAT has the 'read:public_key' or 'read:org' scope." -ForegroundColor Yellow

        return
    }

    $localKeyLine = (Get-Content $PublicKeyPath | Select-Object -First 1).Trim()
    $localKeyParts = $localKeyLine -split "\s+"

    if ($localKeyParts.Count -lt 2) 
    {
        Write-CheckResult -Message "Local public key format invalid" -Success $false -Indent 4

        return
    }

    $localKeyBase64 = $localKeyParts[1]
    $found = $GitHubKeys | Where-Object {
        ($_keyParts = $_.key -split "\s+") -and
        ($_keyParts.Count -ge 2) -and
        ($_keyParts[1] -eq $localKeyBase64)
    }

    if ($found) 
    {
        Write-CheckResult -Message "Key is registered with GitHub" -Success $true -Indent 4
    } 
    else 
    {
        Write-CheckResult -Message "Key is not registered with GitHub" -Success $false -Indent 4
        Write-Host "ℹ️  Local key (last 10 chars): ...$($localKeyBase64[-10..-1] -join '')" -ForegroundColor DarkGray
        Write-Host "🔍 GitHub keys (last 10 chars):" -ForegroundColor DarkGray

        foreach ($key in $GitHubKeys) 
        {
            $remoteKeyParts = $key.key -split "\s+"

            if ($remoteKeyParts.Count -ge 2) 
            {
                $suffix = $remoteKeyParts[1][-10..-1] -join ''
                Write-Host "    ...$suffix" -ForegroundColor DarkGray
            }
        }
    }
}


function Start-SshAgentIfNeeded 
{
    function Test-SshAgentRunning {
        ssh-add -L | Out-Null

        return ($LASTEXITCODE -eq 0)
    }

    if (Test-SshAgentRunning) 
    {
        return $true
    }

    try 
    {
        $agentOutput = & ssh-agent

        if ($agentOutput -match "SSH_AUTH_SOCK=(.+?);") 
        {
            $env:SSH_AUTH_SOCK = $matches[1]
        }

        if ($agentOutput -match "SSH_AGENT_PID=(\d+);") 
        {
            $env:SSH_AGENT_PID = $matches[1]
        }

        Start-Sleep -Milliseconds 500
        Write-CheckResult -Message "Started SSH agent" -Success $true -Indent 4

        return (Test-SshAgentRunning)
    } 
    catch 
    {
        return $false
    }
}


function Test-IdentityFileConfiguration 
{
    param (
        [string]$alias,
        [string]$identityFilePath,
        [array]$GitHubKeys
    )

    $identityExists = Test-Path $identityFilePath
    Write-CheckResult -Message "Validating public key for alias '$alias'" -Success $identityExists

    if (-not $identityExists) 
    { 
        return 
    }

    $publicKey = "$identityFilePath.pub"

    if (!(Test-Path $publicKey)) 
    {
        Write-CheckResult -Message "key not found for alias '$alias'" -Success $false -Indent 4
    }

    if (-not (Start-SshAgentIfNeeded)) 
    {
        Write-CheckResult -Message "SSH agent not running and could not be started" -Success $false -Indent 4
    }

    try 
    {
        ssh-add $identityFilePath *>$null
        Write-CheckResult -Message "Added key to ssh-agent for alias '$alias'" -Success $true -Indent 4
    } 
    catch 
    {
        Write-CheckResult -Message "Failed to add key to ssh-agent for alias '$alias'" -Success $false -Indent 4 -Detail $_.Exception.Message
    }

    $pubLine = Get-Content $publicKey | Select-Object -First 1
    $pubParts = $pubLine -split '\s+'
    $matchingToken = $null

    if ($pubParts.Count -ge 2) 
    {
        $pubBase64 = $pubParts[1]

        if ($keyTokenMap.ContainsKey($pubBase64)) 
        {
            $matchingToken = $keyTokenMap[$pubBase64]
        }
    }

    if ($matchingToken -and $tokenKeyMap.ContainsKey($matchingToken)) 
    {
        $matchingKeys = $tokenKeyMap[$matchingToken]
        Compare-PublicKey-ToGitHub -PublicKeyPath $publicKey -GitHubKeys $matchingKeys
    } 
    elseif ($tokenKeyMap.Count -gt 0) 
    {
        Write-CheckResult -Message "No matching GitHub token for public key comment '$comment'. Comparing to all tokens." -Success $false -Indent 4

        $allKeys = @()

        foreach ($k in $tokenKeyMap.Keys) 
        {
            $allKeys += $tokenKeyMap[$k]
        }

        Compare-PublicKey-ToGitHub -PublicKeyPath $publicKey -GitHubKeys $allKeys
    } 
    else 
    {
        Write-CheckResult -Message "No valid GitHub keys available for comparison" -Success $false -Indent 4
        Write-Host "ℹ️  Check whether the provided token(s) are expired, incorrect, or lack 'read:public_key'" -ForegroundColor Yellow
    }

    $sshTest = ssh -T $alias 2>&1
    $success = ($sshTest -match "successfully authenticated")

    Write-CheckResult -Message "SSH test for alias '$alias'" -Success $success -Indent 4 -Detail $sshTest
}

function Test-GitSshSamlAccess 
{
    param ([string]$RepoPath)

    try 
    {
        # Join all lines into a single string for reliable -match usage
        $result = (git ls-remote $RepoPath 2>&1) -join "`n"

        if ($result -match "SAML SSO") 
        {
            Write-CheckResult -Message "SSH key is not SAML-authorized for this org" -Success $false -Detail $result
            Write-Host "ℹ️  To fix this, go to your GitHub account settings → 'SSH and GPG keys' and authorize the key for SSO access to the appropriate organization." -ForegroundColor Yellow

            return
        }

        if ($result -match "You must authenticate via a web browser") 
        {
            Write-CheckResult -Message "SSH key requires browser-based SSO authorization" -Success $false -Detail $result
            Write-Host "ℹ️  To fix this, go to your GitHub account settings → 'SSH and GPG keys' and authorize the key for SSO access to the appropriate organization." -ForegroundColor Yellow

            return
        }

        if ($result -match "Permission denied") 
        {
            Write-CheckResult -Message "SSH connection succeeded, but access to the repo was denied" -Success $true -Detail $result

            return
        }

        if ($result -match "Repository not found") 
        {
            Write-CheckResult -Message "SSH connection succeeded, but the repo does not exist (or you lack access)" -Success $true -Detail $result

            return
        }

        if ($result -match "^[0-9a-f]{40}\s+\S+" -or $result -match "^ref:") 
        {
            Write-CheckResult -Message "SSH and repository access verified" -Success $true -Detail $result

            return
        }

        # Fallback for unexpected but non-error output
        Write-CheckResult -Message "SSH completed with unrecognized output" -Success $true -Detail $result
    } 
    catch 
    {
        Write-CheckResult -Message "Git command failed unexpectedly during SAML check" -Success $false -Detail $_.Exception.Message
    }
}

function Get-GitHubUsernameFromToken {
    param (
        [string]$Token, 
        [string]$ApiBaseUrl = "https://api.github.com"
    )

    try 
    {
        $headers = @{ Authorization = "token $Token" }
        $response = Invoke-RestMethod -Uri "$ApiBaseUrl/user" -Headers $headers

        return $response.login
    } 
    catch 
    {
        return $null
    }
}

function Invoke-Main 
{
    if ($FixIdentityPaths) 
    {
        Repair-IdentityPathsInConfig
    }

    Write-CheckResult -Message "Reading and parsing SSH config" -Success (Test-Path $sshConfigPath)
    $configMap = Read-SshConfig

    # Split and validate GitHub tokens
    $tokenList = ($GitHubTokens -split '[,;]' | Where-Object { $_ -and ($_ -notmatch '^\s*$') }) | ForEach-Object { $_.Trim() }

    $tokenUserMap = @{}
    $tokenKeyMap  = @{}
    $keyTokenMap  = @{}

    foreach ($token in $tokenList) 
    {
        $user = Get-GitHubUsernameFromToken -Token $token

        if ($user) 
        {
            $tokenUserMap[$token] = $user
            $keys = Get-GitHubSshKeys -Token $token -ApiBaseUrl $GitHubApiBaseUrl
            $tokenKeyMap[$token] = $keys

            foreach ($key in $keys) 
            {
                $parts = $key.key -split "\s+"

                if ($parts.Count -ge 2) 
                {
                    $base64 = $parts[1]
                    $keyTokenMap[$base64] = $token
                }
            }
        } 
        else 
        {
            Write-Warning "⚠️  Could not validate GitHub token (possibly expired or invalid)"
        }
    }

    if ($configMap.Count -eq 0) 
    {
        Write-CheckResult -Message "No IdentityFile aliases found, defaulting to ~/.ssh/id_ed25519" -Success (Test-Path $defaultKey)
        Test-IdentityFileConfiguration -alias "git@github.com" -identityFilePath $defaultKey -GitHubKeys $gitHubKeys
    } 
    else 
    {
        foreach ($entry in $configMap.GetEnumerator()) 
        {
            $alias = $entry.Key
            $identityFilePath = $entry.Value.IdentityFile

            if ($identityFilePath) 
            {
                Test-IdentityFileConfiguration -alias $alias -identityFilePath $identityFilePath -GitHubKeys $gitHubKeys
            } 
            else 
            {
                Write-CheckResult -Message "Skipped alias '$alias': No IdentityFile specified" -Success $false
            }
        }
    }

    if (-not $SamlTestRepo) 
    {
        $insideRepo = (git rev-parse --is-inside-work-tree 2>$null) -eq "true"

        if ($insideRepo) 
        {
            $remoteUrl = git remote get-url origin 2>$null

            if ($remoteUrl -match "[:/]([^/:]+)/([^/]+?)(\.git)?$") 
            {
                $org = $matches[1]
                $repo = $matches[2]
                $SamlTestRepo = $remoteUrl
                Write-CheckResult -Message "Using current repo for SAML test: $org/$repo" -Success $true
            }
        }
    }

    if ($SamlTestRepo) 
    {
        Test-GitSshSamlAccess -RepoPath $SamlTestRepo
    } 
    else 
    {
        Write-CheckResult -Message "Skipping SAML SSO check: no test repo provided or detected" -Success $true
    }

    Write-CheckResult -Message "Verifying Git global user.name" -Success ($null -ne (git config --global user.name))
    Write-CheckResult -Message "Verifying Git global user.email" -Success ($null -ne (git config --global user.email))

    Write-Host "`nAll tests complete." -ForegroundColor Cyan
}

Invoke-Main
