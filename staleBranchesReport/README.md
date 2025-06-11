
# 🍂 Stale Git Branch Report

A PowerShell script that scans your Git repository and generates a styled **HTML report** showing stale branches, their metadata, and merge status — helping you keep your Git history clean and healthy.

![Report Screenshot](https://raw.githubusercontent.com/gmcnickle/gittools/main/assets/gitTools-dk.png)

## 📋 Features

- Detects **stale branches** (not merged to `master`)
- Includes **author, age, commit stats, last message**
- Detects **open pull requests**
- Flags **fully merged** vs. **pointer merged** branches
- Filter by **author** or **branch name**
- Generates a **responsive HTML report** with dark theme
- Supports local and remote branches
- Optional **caching** for fast repeated runs

## 🚀 Usage

### 🔧 Parameters

```
Get-StaleGitBranches.ps1 [-OlderThanDays <int>] [-IncludeRemote] [-CleanCache]
                         [-Limit <int>] [-OutputPath <string>] [-Location <string>]
```

| Parameter        | Description                                                                 |
|------------------|-----------------------------------------------------------------------------|
| `-OlderThanDays` | Only include branches whose latest commit is older than this many days.    |
| `-IncludeRemote` | Include remote branches (default: false).                                  |
| `-CleanCache`    | Clears the local cache before running.                                     |
| `-Limit`         | Only process up to this many branches (for faster testing).                |
| `-OutputPath`    | Path to save the HTML report. If not specified, saves to Documents folder. |
| `-Location`      | Path to the Git repo. Optional if script is run from within the repo.      |

### 📄 Example

```powershell
.\Get-StaleGitBranches.ps1 -IncludeRemote -OlderThanDays 30 -CleanCache
```

## 📁 Output

The report is saved as an HTML file (e.g. `stale-branches.html`) and includes:

- Scrollable, filterable table of stale branches
- Author summary with counts
- GitHub links to each branch
- Merge status and open PR indicators

## 🔍 Requirements

- PowerShell 5.1+ or PowerShell Core
- Git CLI installed and available in PATH

## 🧹 Why?

Over time, Git branches accumulate — many of them forgotten after being merged or abandoned. This tool helps you **audit**, **track**, and **clean** them up safely.

## 📷 Screenshots

![Report Screenshot](https://raw.githubusercontent.com/gmcnickle/gittools/main/assets/stalebranches-screenshot.png)

## 🤝 Contributions

Feel free to fork, submit PRs, or suggest improvements via GitHub Issues.

## 📜 License

MIT License — use freely, modify proudly.

## Attribution

**Primary Author:** Gary McNickle (gmcnickle@outlook.com)<br>
**Co-Author & Assistant:** ChatGPT (OpenAI)

This script was collaboratively designed and developed through interactive sessions with ChatGPT, combining human experience and AI-driven support to solve real-world development challenges.
