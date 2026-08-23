# Copy to deploy.local.ps1 (gitignored). Fill in the values for THIS site.
# Anything left blank falls back to the InMotion defaults inside deploy.ps1.

# ---- Required ----
$DeploySiteName   = "Top-Notch Detailing"
$DeploySiteUrl    = "https://topnotchdetailingllc.com"
$DeployRemotePath = "/home/b93e335/topnotchdetailingllc.com"

# ---- Local source ----
# What to upload. For a plain static site leave as $PSScriptRoot.
# For a Vite/Next/Astro build use "$PSScriptRoot\dist" (or out/, build/).
$DeployLocalPath    = $PSScriptRoot
$DeployBuildCommand = ""            # e.g. "npm run build" - leave empty for no-build sites.

# Optional: extra files copied from repo root into the upload stage (alongside $DeployLocalPath contents).
# Useful when the site has loose files that live outside the build output.
$DeployExtraFiles = @()             # e.g. @("resume-gate.css","resume-gate.js")

# Optional: extra exclude patterns layered on top of the defaults (.git, node_modules, deploy.*, etc.).
# Folder names (no wildcards) and file globs both work.
$DeployExtraExcludeDirs  = @()      # e.g. @("V2","V3","scripts","supabase")
$DeployExtraExcludeFiles = @()      # e.g. @("*.zip","TESTING.md","SOURCING-GUIDE.md")

# Optional: a script to run AFTER successful upload (path relative to repo root).
# Used by 55solutionsinc for scripts/bump-site-version.mjs. Leave empty to skip.
$DeployPostScript = ""

# ---- Remote / SFTP ----
# Leave any blank to use the InMotion default in deploy.ps1.
$DeploySftpHost       = ""          # default: b93e33f8565513087.temporary.link
$DeploySftpPort       = 0           # 0 = use default 2222
$DeploySftpUser       = ""          # default: b93e335
$DeployPrivateKeyPath = ""          # default: C:\Temp\vibin\domainbuilds\deploy.ppk

# SSH host key pin lives in C:\Temp\vibin\domainbuilds\deploy.defaults.ps1 (shared).
# Override here only for a different host. Emergency first connect only:
# $DeployAllowInsecureHostKey = $true

# ---- Secrets ----
# Shared neutral secrets file (holds $DeployPpkPassphrase).
$DeploySharedSecretsPath = "C:\Temp\vibin\domainbuilds\deploy.secrets.ps1"

# Optional fallback if you don't want the shared file.
$DeployPpkPassphrase = ""
$DeploySftpPassword  = ""

# ---- Git + GitHub auto-release (optional) ----
$DeployGitTagOnSuccess  = $false    # commit + tag + push after upload
$DeployGitHubAutoCreate = $false    # create private GitHub repo if origin missing (requires gh auth login)
$DeployGitHubRepoSlug   = ""        # e.g. "djwilson/top-notch" - defaults to "<gh-user>/<folder-name>"

# ---- WinSCP location override (optional) ----
# $DeployWinScpPath    = "$env:LOCALAPPDATA\Programs\WinSCP\WinSCP.com"
# $DeployWinScpLogPath = "$env:TEMP\winscp-deploy-last.log"
