# Validate-GitSSHSetup.ps1

📌 **Validate-GitSSHSetup.ps1** is a PowerShell utility for verifying and troubleshooting SSH-based Git access on Windows systems, with optional GitHub key validation.


## 🚀 Features

- ✅ Parses your `~/.ssh/config` file to identify all SSH aliases with `IdentityFile` entries
- 🔐 Checks for key file existence and permissions
- 🔁 Automatically adds keys to `ssh-agent`
- 🔗 Tests connectivity using `ssh -T` for each alias
- 🧠 Verifies global Git identity settings
- 🛠️ Optional: Validates your local public keys against those registered with GitHub via the GitHub API
- 🧼 Optional: Repairs `IdentityFile` path format issues in the SSH config (e.g., `\` ➜ `/`)

## 🧰 Requirements

- PowerShell 5.1+ (Windows PowerShell) or PowerShell Core (7.x)
- OpenSSH installed and available on your system
- Git for Windows installed
- (Optional) GitHub Personal Access Token with `read:user` or `read:public_key` scope


## 📦 Usage

### 🔍 Basic Usage
```powershell
.\Validate-GitSSHSetup.ps1
```

### 🔐 Include GitHub Key Validation
```powershell
.\Validate-GitSSHSetup.ps1 -GitHubToken 'ghp_yourGitHubToken'
```

### 🛠️ Fix Backslashes in IdentityFile Paths
```powershell
.\Validate-GitSSHSetup.ps1 -FixIdentityPaths
```

### 🧪 Full Diagnostic Mode
```powershell
.\Validate-GitSSHSetup.ps1 -GitHubToken 'ghp_...' -FixIdentityPaths -Debug
```


## 🔄 Output

- Prints readable results to the console
- Uses `Write-Debug` for traceable logging (viewable with `-Debug` flag)
- Makes a backup of your SSH config if `-FixIdentityPaths` is used


## 🛡️ Safety Notes

- The script never modifies your config unless `-FixIdentityPaths` is explicitly passed.
- If path-fixing is enabled, your original `~/.ssh/config` is backed up as `config.bak`.


## 📄 License

MIT License


## 🤝 Contributions

Feel free to open a PR or submit an issue for enhancements or bug reports. This tool was created to streamline multi-device Git SSH setup validation, especially in environments with multiple aliases and keys.

## Attribution

**Primary Author:** Gary McNickle (gmcnickle@outlook.com)<br>
**Co-Author & Assistant:** ChatGPT (OpenAI)

This script was collaboratively designed and developed through interactive sessions with ChatGPT, combining human experience and AI-driven support to solve real-world development challenges.
