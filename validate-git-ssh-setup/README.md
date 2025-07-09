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


## 💡 Usage

Run the script from PowerShell to validate your SSH configuration for GitHub:

```powershell
.\Validate-GitSshSetup.ps1
```

Optional parameters:

| Parameter           | Description |
|---------------------|-------------|
| `-GitHubToken`      | Your GitHub (or GitHub Enterprise) personal access token. Used to verify that your public SSH keys are properly registered. |
| `-GitHubApiBaseUrl` | Optional. Defaults to `https://api.github.com`. Override this for GitHub Enterprise environments. |
| `-SshConfigPath`    | Optional. Path to your SSH config file (default: `~/.ssh/config`). |
| `-FixIdentityPaths` | Optional switch. Automatically replaces backslashes with forward slashes in `IdentityFile` paths in your SSH config. |
| `-LogFile`          | Optional. Path to a log file for recording error details. |
| `-SamlTestRepo`     | Optional. A Git remote path (e.g. `git@github.com:my-org/private-repo.git`) to test for SAML SSO restrictions. If omitted, the script will attempt to detect and use the current Git repo if you're inside one. |

---

### 🔒 SAML SSO Testing

If you are working with an organization that enforces SAML Single Sign-On:

- Provide `-SamlTestRepo` to test whether your SSH key has been authorized for use with that organization.
- If omitted, the script tries to detect the current Git remote and use it automatically.
- If SAML authorization is required but missing, you’ll be prompted with guidance on how to authorize your SSH key via GitHub settings.

### 🧪 Full Diagnostic Mode
```powershell
.\Validate-GitSSHSetup.ps1 -GitHubToken 'ghp_...' -FixIdentityPaths -SamlTestRepo 'https://...' -Debug 
```


## 🔄 Output

- Prints readable results to the console
- Uses `Write-Debug` for traceable logging (viewable with `-Debug` flag)
- Makes a backup of your SSH config if `-FixIdentityPaths` is used


## 🛡️ Safety Notes

- The script never modifies your config unless `-FixIdentityPaths` is explicitly passed.
- If path-fixing is enabled, your original `~/.ssh/config` is backed up as `config.bak`.


## 🛠️ Common Issues and Solutions

### ❌ GitHub API returns "401 Unauthorized"
**Symptoms**:
- GitHub key verification fails with a 401 error.
- You see a message like:
  ```
  GitHub API request failed
      Response status code does not indicate success: 401 (Unauthorized).
  ```

**Possible Causes**:
- The Personal Access Token (PAT) is missing required scopes.
- The token is expired or has been revoked.
- The token is not authorized for the organization.

**Solutions**:
- Ensure the PAT includes at least the `read:public_key` and `user` scopes.
- Re-authorize the token for all organizations under your GitHub account.
- If using GitHub Enterprise, check the correct API URL is specified via `-GitHubApiBaseUrl`.

---

### ❌ "SSH agent not running" or "Error connecting to agent"
**Symptoms**:
- You see a warning like:
  ```
  SSH agent not running for alias 'JCI'
  ```

**Possible Causes**:
- The OpenSSH Authentication Agent service is not running.
- `ssh-agent` is not started in your current terminal session.

**Solutions**:
- Start the SSH agent service in an ***elevated shell*** using:
  ```powershell
  Start-Service ssh-agent
  ```
- Or start it manually in your terminal:
  ```bash
  eval "$(ssh-agent -s)"
  ```

---

### ❌ Public key is not registered with GitHub
**Symptoms**:
- You see:
  ```
  ❌ This public key is NOT registered with GitHub.
  ```

**Possible Causes**:
- Your local `.pub` key file does not match any keys registered on GitHub.
- Wrong key used in your SSH config file.

**Solutions**:
- Add the correct public key to your GitHub account under Settings → SSH and GPG keys.
- Double-check that `IdentityFile` in your SSH config points to the expected key.

---

### ⚠️ IdentityFile uses backslashes (`\`) instead of forward slashes (`/`)
**Symptoms**:
- SSH connections fail unexpectedly.
- The script cannot find or read your key files.

**Possible Causes**:
- `IdentityFile` paths in your `~/.ssh/config` use `\` (Windows-style), which can break parsing.

**Solutions**:
- Run the script with the `-FixIdentityPaths` flag to automatically fix slashes:
  ```powershell
  .\Validate-GitSSHSetup.ps1 -FixIdentityPaths
  ```


## 📄 License

MIT License


## 🤝 Contributions

Feel free to open a PR or submit an issue for enhancements or bug reports. This tool was created to streamline multi-device Git SSH setup validation, especially in environments with multiple aliases and keys.

## Attribution

**Primary Author:** Gary McNickle (gmcnickle@outlook.com)<br>
**Co-Author & Assistant:** ChatGPT (OpenAI)

This script was collaboratively designed and developed through interactive sessions with ChatGPT, combining human experience and AI-driven support to solve real-world development challenges.
