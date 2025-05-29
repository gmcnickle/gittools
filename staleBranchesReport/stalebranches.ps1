<#
.SYNOPSIS
Generates an HTML report of stale Git branches that have not been merged to master.

.DESCRIPTION
This script scans the specified Git repository (or the current directory if none is provided),
identifies branches not fully merged to master, and produces a styled HTML report of those
branches along with commit stats, authorship, and PR status. It supports caching for performance
and includes options for filtering and limiting results.

.PARAMETER OlderThanDays
Filters out branches whose latest commit is more recent than the specified number of days ago.
Set to 0 to disable this filter (default).

.PARAMETER IncludeRemote
If specified, includes remote branches in the analysis (e.g., origin/*). Otherwise, only local branches are included.

.PARAMETER CleanCache
If specified, deletes the cached Git command results before execution. Useful when testing or if repo contents have changed.

.PARAMETER OutputPath
The full path and filename for the generated HTML report. If not specified, defaults to "stale-branches.html" in the user's Documents folder.

.PARAMETER Location
Optional. The path to the Git repository to analyze. If not provided, the current directory is used.

.PARAMETER Limit
Optional. Limits the number of branches analyzed, which can be useful during testing or debugging. A value of 0 means no limit (default).

.EXAMPLE
.\Get-StaleGitBranches.ps1 -OlderThanDays 30 -IncludeRemote -CleanCache -Limit 50

Generates a report of up to 50 branches (including remote) that haven’t been updated in the last 30 days,
after clearing any cached Git output.

#>

param (
    [Parameter()]
    [int]$OlderThanDays = 0,

    [Parameter()]
    [switch]$IncludeRemote = $false,

    [Parameter()]
    [switch]$CleanCache = $false,

    [Parameter()]
    [string]$OutputPath = "",

    [Parameter()]
    [string]$Location = "",

    [Parameter()]
    [int]$Limit = 0
)

function Remove-CacheFolder {
    $cacheDir = Join-Path ([System.IO.Path]::GetTempPath()) 'git-cache'

    if (Test-Path $cacheDir) {
        Remove-Item -Path $cacheDir -Recurse
    }
}

function Get-GitHubRepoInfo {
    $url = git remote get-url origin 2>$null
    if (-not $url) { return $null }

    # HTTPS format: https://host/owner/repo.git
    if ($url -match 'https?://[^/]+/([^/]+)/([^/]+?)(\.git)?$') {
        return $matches[1], $matches[2]
    }

    # SSH format: git@host:owner/repo.git (host can be anything)
    if ($url -match 'git@[^:]+:([^/]+)/([^/]+?)(\.git)?$') {
        return $matches[1], $matches[2]
    }

    Write-Warning "Unable to parse GitHub remote URL: $url"
    return "Unknown", "Unknown"
}


function Get-CachedGitOutput {
    param (
        [string]$GitCommand,
        [int]$MaxAgeMinutes = 60
    )

    $hash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($GitCommand)
        )
    ) -replace '-', ''

    $cacheDir = Join-Path ([System.IO.Path]::GetTempPath()) 'git-cache'

    if (-not (Test-Path $cacheDir)) {
        New-Item -Path $cacheDir -ItemType Directory | Out-Null
    }

    $cachePath = Join-Path $cacheDir "$hash.txt"

    if (Test-Path $cachePath) {
        $age = (Get-Date) - (Get-Item $cachePath).LastWriteTime
        if ($age.TotalMinutes -lt $MaxAgeMinutes) {
            return Get-Content $cachePath
        }
    }

    $output = Invoke-Expression $GitCommand
    Set-Content -Path $cachePath -Value $output
    return $output
}

function Write-StaleBranchHtmlReport {
    param (
        [Parameter(Mandatory)]
        [array]$Results,

        [Parameter(Mandatory)]
        [array]$AuthorSummary,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    $HtmlTemplate = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Stale Git Branch Report</title>
<style>
    body {
        font-family: "Segoe UI", Tahoma, sans-serif;
        background-color: #1e1e2f;
        color: #f0f0f0;
        padding: 20px;
    }
    h1, h2 {
        color: #ffffff;
        border-bottom: 1px solid #444;
        padding-bottom: 4px;
        margin-top: 1.5em;
    }
    table {
        width: 100%;
        border-collapse: collapse;
        margin-bottom: 1em;
    }
    th, td {
        padding: 10px;
        text-align: left;
        font-size: 14px;
    }
    th {
        background-color: #2e3d55;
        color: #c0e0ff;
        border-bottom: 2px solid #406080;
        font-weight: bold;
        position: sticky;
        top: 0;
        z-index: 10;
    }
    td {
        background-color: #2a2a3a;
        border-bottom: 1px solid #333;
    }
    .summary-container, .details-container {
        max-height: 400px;
        overflow-y: auto;
        border: 1px solid #444;
        padding: 10px;
        background-color: #262636;
        position: relative;
    }
    input[type="text"] {
        background-color: #2e2e3e;
        color: #f0f0f0;
        border: 1px solid #555;
        padding: 6px 10px;
        width: 100%;
        margin-bottom: 10px;
        box-sizing: border-box;
    }
    a.branch-link {
        color: #66ccff;
        text-decoration: none;
    }
    a.branch-link:hover {
        text-decoration: underline;
    }
    .stale-high {
        background-color: #662222 !important;
    }
    .stale-mid {
        background-color: #665522 !important;
    }
    .stale-low {
        background-color: #224422 !important;
    }
    ::-webkit-scrollbar {
        width: 10px;
    }
    ::-webkit-scrollbar-thumb {
        background-color: #555;
        border-radius: 6px;
    }
    ::-webkit-scrollbar-track {
        background-color: #2a2a3a;
    }
    .split-logo {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 20px;
    }
    .split-logo h1 {
        margin: 0;
        font-size: 1.8em;
    }
    .split-logo img {
        height: 100px;
    }
</style>
</head>
<script>
function applyFilters() {
    var authorInput = document.getElementById("authorFilter").value.toLowerCase();
    var branchInput = document.getElementById("branchFilter").value.toLowerCase();

    var authorTable = document.getElementById("authorTable");
    var branchTable = document.getElementById("branchTable");

    var matchingAuthors = new Set();
    var matchingBranches = [];

    var branchRows = branchTable.getElementsByTagName("tr");
    for (var i = 1; i < branchRows.length; i++) {
        var row = branchRows[i];
        var branchCell = row.getElementsByTagName("td")[0];
        var authorAttr = row.getAttribute("data-author") || "";

        var branchText = branchCell.textContent || branchCell.innerText;

        var branchMatch = branchText.toLowerCase().includes(branchInput);
        var authorMatch = authorAttr.includes(authorInput);

        var showRow = (!branchInput || branchMatch) && (!authorInput || authorMatch);
        row.style.display = showRow ? "" : "none";

        if (showRow) {
            matchingAuthors.add(authorAttr);
            matchingBranches.push(branchText.toLowerCase());
        }
    }

    var authorRows = authorTable.getElementsByTagName("tr");
    for (var i = 1; i < authorRows.length; i++) {
        var row = authorRows[i];
        var authorCell = row.getElementsByTagName("td")[0];
        var authorText = authorCell.textContent || authorCell.innerText;

        row.style.display = matchingAuthors.has(authorText.toLowerCase()) ? "" : "none";
    }
}

function clearFilters() {
    document.getElementById("authorFilter").value = "";
    document.getElementById("branchFilter").value = "";
    applyFilters();
}
</script>

<body>
    <div class="report-header split-logo">
        <div>
            <h1>Stale Git Branch Report</h1>
            <h3 style="color:#ccc; margin-top: -0.15em;">Generated for: {REPO}</h3>
        </div>
        <img src="https://raw.githubusercontent.com/gmcnickle/gittools/main/assets/gitTools-dk.png" alt="Logo">
    </div>

    <h2>Summary</h2>
    <table class="summary-table">
        <tr><th>Total Stale Branches</th><td>{TOTAL}</td></tr>
        <tr><th>Generated On</th><td>{DATE}</td></tr>
    </table>

    <h2>By Author</h2>
    <input type="text" id="authorFilter" placeholder="Filter by author" oninput="applyFilters()" style="margin-bottom:10px; padding:4px; width: 20%; box-sizing: border-box;">

    <div class="summary-container">
        <table class="summary-table" id="authorTable">
            <tr><th>Author</th><th>Branch Count</th></tr>
            {AUTHOR_ROWS}
        </table>
    </div>

    <h2>By Branch</h2>
    <input type="text" id="branchFilter" placeholder="Filter by branch" oninput="applyFilters()" style="margin-bottom:10px; padding:4px; width: 20%; box-sizing: border-box;">
    <br>
    <button onclick="clearFilters()">🔄 Clear Filters</button>

    <h2>Detailed Branch List</h2>
    <div class="details-container" id="branchTable">
        <table class="details-table" >
            <tr>
                <th>Branch</th>
                <th>Last Commit</th>
                <th>Age (Days)</th>
                <th>Author</th>
                <th>Commits</th>
                <th>Files</th>
                <th>Lines Added</th>
                <th>Lines Deleted</th>
                <th>Net &#916;</th>
                <th>Merge Status</th>
                <th>Open PR</th>
                <th>Message</th>
            </tr>
            {BRANCH_ROWS}
        </table>
    </div>

    <footer style="margin-top: 40px; padding-top: 10px; border-top: 1px solid #444; text-align: center; font-size: 0.9em; color: #888;">
        <p>&copy; $(Get-Date -Format 'yyyy') <a href="https://github.com/gmcnickle" target="_blank" style="color: #66ccff; text-decoration: none;">Gary McNickle</a>. All rights reserved.  🍂</p>
    </footer>

    </body>
</html>
"@

    $GitHubOwner, $GitHubRepo = Get-GitHubRepoInfo

    $authorRows = ($AuthorSummary | ForEach-Object {
        "<tr><td>$($_.Name)</td><td>$($_.Count)</td></tr>"
    }) -join "`n"

    $branchRows = ($Results | ForEach-Object {
        $branch     = $_.Branch
        $commitDate = $_.LastCommit.ToString("yyyy-MM-dd")
        $age        = $_.AgeDays
        $author     = $_.Author
        $message    = ($_.Message -replace '\|', '-') -replace '\s+', ' '
        if ($message.Length -gt 80) {
            $message = $message.Substring(0,77) + "..."
        }
        $commitCount = $_.CommitCount
        $filesChanged = $_.FilesChanged
        $netChange = $_.NetChange
        $linesAdded = $_.LinesAdded
        $linesDeleted = $_.LinesDeleted
        $mergeStatus = $_.MergeStatus
        $openPR = $_.HasOpenPR

        $class = if ($age -ge 90) {
            "stale-high"
        } elseif ($age -ge 30) {
            "stale-mid"
        } else {
            "stale-low"
        }

        $cleanBranch = $branch -replace '^origin/', ''
        $branchUrl = "https://github.com/$GitHubOwner/$GitHubRepo/tree/$cleanBranch"

        @(
            "<tr class='$class' data-author='$($author.ToLower())'>",
            "<td><a href='$branchUrl' target='_blank' class='branch-link'>$branch</a></td>",
            "<td>$commitDate</td>",
            "<td>$age</td>",
            "<td>$author</td>",
            "<td>$commitCount</td>",
            "<td>$filesChanged</td>",
            "<td>$linesAdded</td>",
            "<td>$linesDeleted</td>",
            "<td>$netChange</td>",
            "<td>$mergeStatus</td>",
            "<td>$openPR</td>",
            "<td>$message</td>",
            "</tr>"
        ) -join ''
    }) -join "`n"

    $htmlContent = $HtmlTemplate -replace '{TOTAL}', $Results.Count
    $htmlContent = $htmlContent -replace '{DATE}', (Get-Date).ToString("yyyy-MM-dd HH:mm")
    $htmlContent = $htmlContent -replace '{AUTHOR_ROWS}', $authorRows.Trim()
    $htmlContent = $htmlContent -replace '{BRANCH_ROWS}', $branchRows.Trim()
    $htmlContent = $htmlContent -replace '{REPO}', "$GitHubOwner/$GitHubRepo"

    Set-Content -Path $OutputPath -Value $htmlContent -Encoding UTF8
    Write-Host "HTML report saved to $OutputPath"
}

function Get-CommitInfo($branch) {
    $cmd = "git log -1 --pretty=format:`"%ci|%an|%s`" $branch"
    $logOutput = Get-CachedGitOutput $cmd

    if (-not $logOutput -or $logOutput.Count -eq 0) {
        Write-Warning "No commits found for $branch"
        return $null
    }

    $commitInfo = $logOutput | Select-Object -First 1
    $parts = $commitInfo -split '\|', 3

    if ($parts.Count -lt 3) {
        Write-Warning "Invalid commit format for $($branch): $($commitInfo)"
        return $null
    }

    return @{
        Date    = [datetimeoffset]::Parse($parts[0])
        Author  = $parts[1]
        Message = $parts[2]
    }
}

function Test-IsBranchMerged($branch) {
    # 1. Does the branch tip exist in master?
    Get-CachedGitOutput "git merge-base --is-ancestor $branch master"
    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    # 2. Does the branch have *any* commits not in master?
    $commitCount = Get-CachedGitOutput "git rev-list --count $branch --not master"
    if ([int]$commitCount -gt 0) {
        return $false
    }

    # 3. Fallback: look for merged PR
    $prCheck = Test-BranchWasMergedViaPR $branch
    if ($prCheck) {
        return $true
    }    

    # Fallthrough (e.g., squash merge or moved pointer): flag as suspicious
    return $null
}

function Test-BranchWasMergedViaPR($branch) {
    try {
        $result = Get-CachedGitOutput "gh pr list --base master --head $branch --state merged"
        return -not [string]::IsNullOrWhiteSpace($result)
    } catch {
        Write-Warning "Unable to check merged PR for $($branch): $_"
        return $false
    }
}

function Test-BranchHasOpenPR($branch) {
    try {
        $output = Get-CachedGitOutput "gh pr list --base master --head $branch --state open"
        return -not [string]::IsNullOrWhiteSpace($output)
    } catch {
        Write-Warning "Failed to check PR for $($branch): $_"
        return $false
    }
}

function Get-BranchStats($branch, $base) {
    $commitCount = Get-CachedGitOutput "git rev-list --count $base..$branch"

    $diffStatsRaw = Get-CachedGitOutput "git -c diff.renameLimit=0 diff --shortstat $base $branch"
    $diffStats = ($diffStatsRaw -join "`n")  

    $filesChanged = 0
    $linesAdded   = 0
    $linesDeleted = 0

    if ($diffStats -match '(\d+) files? changed') {
        $filesChanged = [int]$matches[1]
    }
    if ($diffStats -match '(\d+) insertions?') {
        $linesAdded = [int]$matches[1]
    }
    if ($diffStats -match '(\d+) deletions?') {
        $linesDeleted = [int]$matches[1]
    }

    return @{
        CommitCount  = [int]$commitCount
        FilesChanged = $filesChanged
        NetChange    = $linesAdded - $linesDeleted
        LinesAdded   = $linesAdded
        LinesDeleted = $linesDeleted
    }
}

function Get-FilteredBoundParams {
    param (
        [hashtable]$AllParams,
        [string[]]$AllowList
    )

    $result = @{}
    foreach ($key in $AllowList) {
        if ($AllParams.ContainsKey($key)) {
            $result[$key] = $AllParams[$key]
        }
    }
    return $result
}


function Get-StaleGitBranches {
    [CmdletBinding()]
    param (
        [int]$OlderThanDays = 0,
        [switch]$IncludeRemote = $false,
        [string]$OutputPath = "",
        [int]$Limit = 0
    )

    $branchCmd = if ($IncludeRemote) {
        'git branch -r --no-merged origin/master --format="%(refname:short)"'
    } else {
        'git branch --no-merged master --format="%(refname:short)"'
    }

    $branches = Get-CachedGitOutput -GitCommand $branchCmd |
        Where-Object { $_ -and ($_ -notmatch "origin/HEAD") } |
        ForEach-Object { $_.Trim() }

    if ($Limit -gt 0) {
        $branches = $branches | Select-Object -First $Limit
    }

    $results = @()

    for ($i = 0; $i -lt $branches.Count; $i++) {
        $branch = $branches[$i]
        Write-Progress -Activity "Inspecting branches..." -Status "$branch ($($i+1)/$($branches.Count))" -PercentComplete (($i+1)/$branches.Count*100)

        $info = Get-CommitInfo $branch
        if (-not $info) { continue }

        $commitDate = $info.Date
        $author     = $info.Author
        $message    = $info.Message
        $ageDays    = (New-TimeSpan -Start $commitDate.UtcDateTime -End (Get-Date).ToUniversalTime()).Days

        if ($OlderThanDays -gt 0 -and $ageDays -lt $OlderThanDays) {
            continue
        }

        $mergeStatus = Test-IsBranchMerged $branch

        if ($mergeStatus -eq $true) {
            continue
        }

        $hasPR = Test-BranchHasOpenPR $branch

        $staleIndicator, $mergeFlag = switch ($mergeStatus) {
            $false {
                if ($hasPR) {
                    '⏳', "⏳ PR Open"
                } else {
                    '❌', "❌ Unmerged"
                }
            }
            $null {
                if ($hasPR) {
                    '⚠️⏳', "⚠️ Pointer Merged + PR Open"
                } else {
                    '⚠️', "⚠️ Pointer Merged"
                }
            }
            default { '❓', "❓ Unknown" }
        }

        $base = Get-CachedGitOutput "git merge-base $branch master"
        $stats = Get-BranchStats $branch $base

        $results += [PSCustomObject]@{
            Branch        = $branch
            LastCommit    = $commitDate
            AgeDays       = $ageDays
            Author        = $author
            Message       = $message
            CommitCount   = $stats.CommitCount
            FilesChanged  = $stats.FilesChanged
            NetChange     = $stats.NetChange
            LinesAdded    = $stats.LinesAdded
            LinesDeleted  = $stats.LinesDeleted
            Stale         = $staleIndicator
            HasOpenPR     = if ($hasPR) { "✅" } else { "❌" }
            MergeStatus   = $mergeFlag
        }
    }

    Write-Progress -Activity "Inspecting branches..." -Completed

    $results = $results | Sort-Object LastCommit -Descending

    if (-not $OutputPath) {
        $OutputPath = Join-Path -Path ([Environment]::GetFolderPath("MyDocuments")) -ChildPath "stale-branches.html"
    }

    $authorSummary = $results | Group-Object Author | Sort-Object Count -Descending

    Write-StaleBranchHtmlReport -Results $results -AuthorSummary $authorSummary -OutputPath $OutputPath

    return $results
}

if ($CleanCache) {
    Remove-CacheFolder
}

if ($Location) {
    Set-Location $Location
}

$filteredParams = Get-FilteredBoundParams -AllParams $PSBoundParameters -AllowList @('OlderThanDays', 'IncludeRemote', 'OutputPath', 'Limit')
Get-StaleGitBranches  @filteredParams
