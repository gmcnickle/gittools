[CmdletBinding()]
param (
    [string]$RepoPath = (Get-Location).Path,
    [int]$Days,
    [string]$ReportPath,
    [switch]$UseCache
)

function Get-HashFilePath{
    param ( 
        [Parameter(Mandatory, ValueFromPipeline=$true)]
        [string]$Hash
    )

    $cacheFile =  [IO.Path]::Combine(([System.IO.Path]::GetDirectoryName($myInvocation.MyCommand.Definition)), "$($Hash).txt")

    return $cacheFile
}
function Update-Cache {
    param(
        [string]$Hash,
        $Data
    )

    if ($Data -and $Data.count -gt 0)
    {
        $cacheFile = $Hash | Get-HashFilePath

        Write-Debug "Caching github results to '$cacheFile' for future use..."
   
        $Data | Out-File -FilePath $cacheFile -Force
    }
}

function Get-DataFromCache {
    param (
        [string]$Hash,
        [switch]$UseCache
    )

    $cacheFile = $Hash | Get-HashFilePath

    if (Test-Path -Path $cacheFile)
    {
        $lastModified = (Get-ChildItem -Path $cacheFile | Select-Object -ExpandProperty LastWriteTime).Date
        $oldestAllowableDate = (Get-Date).AddDays(-1).Date

        if ($lastModified -lt $oldestAllowableDate)
        {
            $cacheFile | Remove-File
        }
        elseif ($UseCache)
        {
            $data = Get-Content -Path $cacheFile

            return $data
        }
    }
}

function Get-CachedQuery {
    param(
        [Parameter(Mandatory = $true)]
        [Alias("QueryScript", "Expression")]
        [object]$Query,
        [string]$Hash,
        [switch]$UseCache
    )

    if (-not $Hash) {
        $Hash = if ($Query -is [ScriptBlock]) {
            $Query.ToString() | Get-Hash
        }
        else {
            $Query | Get-Hash
        }
    }

    $normalizedQuery = ($Query.ToString() -split "`n" | ForEach-Object { $_.Trim() }) -join "`n"
    $response = Get-DataFromCache -hash $Hash -UseCache:$UseCache

    if ($null -eq $response) 
    {
        Write-Verbose "Executing Query: $normalizedQuery"

        $response = if ($Query -is [ScriptBlock]) {
            & $Query
        }
        else {
            Invoke-Expression $Query
        }

        Update-Cache -hash $Hash -data $response
    } else {
        Write-Host "Retrieved Query From Cache: $normalizedQuery"
    }

    # Check for 404-style error JSON
    if ($response -is [string] -and
        $response -match '"status"\s*:\s*"404"' -and
        $response -match '"message"\s*:\s*"Not Found"') 
    {
        Write-Warning "Query returned 404: ignoring this response for this query."
        return ""
    }

    return $response
}


function Get-GitUserCommitsLastXDays {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true)]
        [string]$RepoPath,

        [int]$Days,

        [string]$ReportPath,

        [switch]$UseCache
    )

    if (-not (Test-Path "$RepoPath/.git")) {
        throw "The specified path does not appear to be a Git repository."
    }

    $sinceClause = ""
    $sinceDate = ""

    if ($Days -gt 0) {
        $sinceDate = (Get-Date).AddDays(-$Days).ToString("yyyy-MM-dd")
        $sinceClause = "--since=`"$sinceDate`""
    }

    $repoName = (Get-Item -Path $RepoPath).Name
    $cacheKey = if ($sinceDate) { "cachedResults-$repoName-$sinceDate" } else { "cachedResults-$repoName-all" }

    $gitCommand = "git -C `"$RepoPath`" log $sinceClause --pretty=format:`"%H|%an|%ae|%ad|%s`" --date=iso 2>$null"

    $logOutput = Get-CachedQuery -UseCache:$UseCache -Hash $cacheKey {
        Invoke-Expression $gitCommand
    }

    if (-not $logOutput) {
        Write-Output "No commits found."
        return
    }

    $userCommits = @{}

    foreach ($line in ($logOutput -split "`r?\n")) {
        $parts = $line -split '\|', 5
        if ($parts.Count -eq 5) {
            $commit = [PSCustomObject]@{
                Hash    = $parts[0]
                Date    = $parts[3]
                Message = $parts[4]
            }

            $userKey = "$($parts[1]) <$($parts[2])>"

            if (-not $userCommits.ContainsKey($userKey)) {
                $userCommits[$userKey] = @()
            }

            $userCommits[$userKey] += $commit
        }
    }

    $result = [PSCustomObject]@{
        Repository     = $RepoPath
        SinceDate      = $sinceDate
        CommitsByUser  = $userCommits
    }

    if ($ReportPath) {
        try {
            $result | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportPath -Encoding UTF8
            Write-Host "Exported commit data to $ReportPath" -ForegroundColor Green
        } catch {
            Write-Warning "Failed to export to JSON: $_"
        }
    }

    return $result
}

function Set-Repository {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline=$true)]
        [string]$repositoryDirectory
    )

    if (-not $repositoryDirectory) {
        $repositoryDirectory = (Get-Location).Path
    }

    Set-Location -Path $repositoryDirectory
}

Push-Location

try {
    $RepoPath | Set-Repository
    Get-GitUserCommitsLastXDays -RepoPath $RepoPath -Days $Days -ReportPath $ReportPath -UseCache:$UseCache
}
finally {
    Pop-Location
}

