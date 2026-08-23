#!/usr/bin/env pwsh
<#
  Generic site deploy - WinSCP + .ppk to InMotion (or any SFTP target).
  Source of truth: ~/.cursor/skills/deploy/deploy.template.ps1
  Per-project copy is identical; only deploy.local.ps1 differs.

  Usage:  .\deploy.ps1 [[-Action] full|update] [-DryRun]
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("full", "update")]
    [string]$Action = "full",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$mode = $Action
$LocalPath = $PSScriptRoot

# ----------------------------------------------------------------------------
# Load shared defaults, then deploy.local.ps1, then secrets
# ----------------------------------------------------------------------------
if (-not $DeploySharedDefaultsPath) {
    $DeploySharedDefaultsPath = "C:\Temp\vibin\domainbuilds\deploy.defaults.ps1"
}
if (Test-Path -LiteralPath $DeploySharedDefaultsPath) {
    . $DeploySharedDefaultsPath
}

$LocalConfig = Join-Path $LocalPath "deploy.local.ps1"
if (-not (Test-Path -LiteralPath $LocalConfig)) {
    Write-Error "Missing deploy.local.ps1. Copy deploy.config.example.ps1 to deploy.local.ps1 and fill it in."
}
. $LocalConfig

$LocalSecrets = Join-Path $LocalPath "deploy.secrets.ps1"
if ($DeploySharedSecretsPath -and (Test-Path -LiteralPath $DeploySharedSecretsPath)) {
    . $DeploySharedSecretsPath
}
elseif (Test-Path -LiteralPath $LocalSecrets) {
    . $LocalSecrets
}

# ----------------------------------------------------------------------------
# Defaults - InMotion shared account. Override in deploy.local.ps1 if needed.
# ----------------------------------------------------------------------------
if (-not $DeploySftpHost)         { $DeploySftpHost = "b93e33f8565513087.temporary.link" }
if (-not $DeploySftpPort -or $DeploySftpPort -eq 0) { $DeploySftpPort = 2222 }
if (-not $DeploySftpUser)         { $DeploySftpUser = "b93e335" }
if (-not $DeployPrivateKeyPath)   { $DeployPrivateKeyPath = "C:\Temp\vibin\domainbuilds\deploy.ppk" }
if (-not $DeploySharedSecretsPath){ $DeploySharedSecretsPath = "C:\Temp\vibin\domainbuilds\deploy.secrets.ps1" }
if (-not $DeploySharedDefaultsPath){ $DeploySharedDefaultsPath = "C:\Temp\vibin\domainbuilds\deploy.defaults.ps1" }
if (-not $DeployTransport)            { $DeployTransport = "sftp" }
if (-not $DeployLocalPath)        { $DeployLocalPath = $LocalPath }
if ($null -eq $DeployExtraFiles)         { $DeployExtraFiles = @() }
if ($null -eq $DeployExtraExcludeDirs)   { $DeployExtraExcludeDirs = @() }
if ($null -eq $DeployExtraExcludeFiles)  { $DeployExtraExcludeFiles = @() }
if (-not $DeployPpkPassphrase -and $env:DEPLOY_PPK_PASSPHRASE) { $DeployPpkPassphrase = $env:DEPLOY_PPK_PASSPHRASE }
if (-not $DeploySftpPassword -and $env:DEPLOY_SFTP_PASSWORD)   { $DeploySftpPassword = $env:DEPLOY_SFTP_PASSWORD }

if (-not $DeploySiteName)   { $DeploySiteName = Split-Path -Leaf $LocalPath }
if (-not $DeployRemotePath) { Write-Error "deploy.local.ps1 must set `$DeployRemotePath." }

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function ConvertFrom-SecureStringToPlain {
    param([System.Security.SecureString]$SecureString)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { if ($bstr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) } }
}

function Test-NativeCmd {
    param([scriptblock]$Cmd)
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & $Cmd *>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prev
        $global:LASTEXITCODE = 0
    }
}

function Resolve-WinScpCom {
    if ($DeployWinScpPath -and (Test-Path -LiteralPath $DeployWinScpPath)) { return $DeployWinScpPath }
    foreach ($wp in @(
            "${env:ProgramFiles(x86)}\WinSCP\WinSCP.com",
            "$env:ProgramFiles\WinSCP\WinSCP.com",
            "$env:LOCALAPPDATA\Programs\WinSCP\WinSCP.com"
        )) {
        if (Test-Path -LiteralPath $wp) { return $wp }
    }
    return $null
}

# ----------------------------------------------------------------------------
# Auth resolution
# ----------------------------------------------------------------------------
$keyMode = $false
if ($DeployPrivateKeyPath -and (Test-Path -LiteralPath $DeployPrivateKeyPath)) { $keyMode = $true }

if (-not $DryRun) {
    if ($keyMode) {
        if (-not $DeployPpkPassphrase) {
            if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
                Write-Host "PPK passphrase required (input hidden):"
                $sec = Read-Host -AsSecureString "Passphrase"
                if (-not $sec -or $sec.Length -eq 0) {
                    Write-Error "No passphrase entered. Set it in $DeploySharedSecretsPath or `$env:DEPLOY_PPK_PASSPHRASE."
                }
                $DeployPpkPassphrase = ConvertFrom-SecureStringToPlain -SecureString $sec
            }
            else {
                Write-Error "Non-interactive deploy needs a PPK passphrase. Populate $DeploySharedSecretsPath or set `$env:DEPLOY_PPK_PASSPHRASE."
            }
        }
    }
    else {
        if (-not $DeploySftpPassword) {
            Write-Error "No private key found at '$DeployPrivateKeyPath' and `$DeploySftpPassword is empty. Provide one or the other."
        }
    }
}

# ----------------------------------------------------------------------------
# Build the deploy version stamp (used by token-replace + git tag)
# ----------------------------------------------------------------------------
$deployStamp = Get-Date -Format "yyyyMMdd-HHmm"
$deployIso   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$gitSha      = ""
if (Get-Command git -ErrorAction SilentlyContinue) {
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $shaRaw = & git -C $LocalPath rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $shaRaw) { $gitSha = $shaRaw.Trim() }
    } catch { $gitSha = "" }
    finally { $ErrorActionPreference = $prev; $global:LASTEXITCODE = 0 }
}
$siteVersion = if ($gitSha) { "$deployStamp.$gitSha" } else { $deployStamp }

Write-Host ""
Write-Host "=== Deploying $DeploySiteName ($mode) -> ${DeploySftpHost}:${DeploySftpPort}$DeployRemotePath ===" -ForegroundColor Cyan
Write-Host "  Transport: $DeployTransport via WinSCP (SSH)" -ForegroundColor Gray
Write-Host "  Version: $siteVersion" -ForegroundColor Gray
Write-Host ""

# ----------------------------------------------------------------------------
# Build (optional)
# ----------------------------------------------------------------------------
if ($mode -eq "full" -and $DeployBuildCommand) {
    Write-Host "Running build: $DeployBuildCommand" -ForegroundColor Yellow
    Push-Location $LocalPath
    try {
        Invoke-Expression $DeployBuildCommand
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Build failed (exit $LASTEXITCODE). Aborting deploy." -ForegroundColor Red
            exit 1
        }
        Write-Host "  Build OK`n" -ForegroundColor Green
    }
    finally { Pop-Location }
}

# ----------------------------------------------------------------------------
# Resolve source path
# ----------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $DeployLocalPath)) {
    Write-Error "Source path not found: $DeployLocalPath"
}
$srcInfo = Get-Item -LiteralPath $DeployLocalPath
if (-not $srcInfo.PSIsContainer) {
    Write-Error "`$DeployLocalPath must be a folder, got: $DeployLocalPath"
}

# ----------------------------------------------------------------------------
# Stage upload set with excludes via Robocopy
# ----------------------------------------------------------------------------
$defaultExcludeDirs = @(
    ".git", ".github", ".vscode", ".idea", ".cursor", ".claude",
    "node_modules", "dist-ssr", ".cache", ".next", ".parcel-cache",
    "deploy", "docs"
)
$defaultExcludeFiles = @(
    "deploy.ps1", "deploy.template.ps1",
    "deploy.local.ps1", "deploy.secrets.ps1", "deploy.config.example.ps1",
    "deploy.secrets.example.ps1",
    ".env", ".env.*", ".gitignore",
    "*.zip", "*.7z", "*.tar", "*.tar.gz", "*.log",
    "DEPLOY-*.md", "DEPLOYMENT.md", "MOTION_HOSTING.md",
    "TESTING.md", "TEST_*.md", "TEST_*.txt", "OUTREACH-*.md",
    "PAYMENT-*.md", "SETUP-*.md", "SOURCING-*.md"
)
$allExcludeDirs  = ($defaultExcludeDirs + $DeployExtraExcludeDirs) | Select-Object -Unique
$allExcludeFiles = ($defaultExcludeFiles + $DeployExtraExcludeFiles) | Select-Object -Unique

$StageName = "deploy-stage-" + [Guid]::NewGuid().ToString("n")
$Stage = Join-Path $env:TEMP $StageName
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

try {
    $rcArgs = @(
        "`"$DeployLocalPath`"", "`"$Stage`"",
        "/E", "/NFL", "/NDL", "/NP", "/NJH", "/NJS", "/R:1", "/W:1"
    )
    if ($allExcludeDirs.Count -gt 0)  { $rcArgs += "/XD"; $rcArgs += $allExcludeDirs }
    if ($allExcludeFiles.Count -gt 0) { $rcArgs += "/XF"; $rcArgs += $allExcludeFiles }

    Write-Host "Staging files (excluding $($allExcludeDirs.Count) dirs, $($allExcludeFiles.Count) file patterns)..." -ForegroundColor Yellow
    $null = & robocopy.exe @rcArgs
    # Robocopy exit codes 0-7 are success-ish; >=8 indicates failure
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code $LASTEXITCODE"
    }
    $global:LASTEXITCODE = 0

    foreach ($f in $DeployExtraFiles) {
        $src = Join-Path $LocalPath $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $Stage $f) -Force
        }
    }

    # ------------------------------------------------------------------------
    # Site version: replace __SITE_VERSION__ tokens in staged text files and
    # drop a version.json at the stage root.
    # ------------------------------------------------------------------------
    $versionJson = @{
        version    = $siteVersion
        deployedAt = $deployIso
        site       = $DeploySiteName
        url        = $DeploySiteUrl
        git        = $gitSha
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText((Join-Path $Stage "version.json"), $versionJson, [System.Text.UTF8Encoding]::new($false))

    $textPatterns = @("*.html", "*.js", "*.css", "*.txt", "*.xml", "*.json")
    $replacedCount = 0
    $tokenFiles   = Get-ChildItem -Path $Stage -Recurse -File -Include $textPatterns
    foreach ($tf in $tokenFiles) {
        $content = [System.IO.File]::ReadAllText($tf.FullName)
        if ($content.Contains("__SITE_VERSION__")) {
            $newContent = $content.Replace("__SITE_VERSION__", $siteVersion)
            [System.IO.File]::WriteAllText($tf.FullName, $newContent, [System.Text.UTF8Encoding]::new($false))
            $replacedCount++
        }
    }
    Write-Host "  Wrote version.json + replaced __SITE_VERSION__ in $replacedCount file(s)." -ForegroundColor Gray

    if ($DryRun) {
        Write-Host ""
        Write-Host "DRY RUN - would mirror to $DeployRemotePath`n" -ForegroundColor Cyan
        Get-ChildItem -Path $Stage -Recurse -File | ForEach-Object {
            $_.FullName.Substring($Stage.Length).TrimStart("\")
        } | Sort-Object
        Write-Host ""
        return
    }

    # ------------------------------------------------------------------------
    # Build WinSCP script
    # ------------------------------------------------------------------------
    $userUrl = [Uri]::EscapeDataString($DeploySftpUser)
    $openHost = if ($DeploySftpPort -eq 22) {
        "sftp://${userUrl}@$DeploySftpHost/"
    } else {
        "sftp://${userUrl}@${DeploySftpHost}:$DeploySftpPort/"
    }

    $hostKeyPart = $null
    if ($DeployWinScpHostKey -and $DeployWinScpHostKey.Trim().Length -gt 0) {
        $hke = $DeployWinScpHostKey.Trim().Replace('"', '""')
        $hostKeyPart = "-hostkey=""$hke"""
        Write-Host "  Host key: pinned (SSH MITM protection)" -ForegroundColor Gray
    }
    elseif ($DeployAllowInsecureHostKey -eq $true) {
        $hostKeyPart = "-hostkey=*"
        Write-Host "  Host key: accept-any (insecure - fix deploy.defaults.ps1)" -ForegroundColor Yellow
    }
    else {
        Write-Error @"
No pinned SSH host key. WinSCP SFTP is only as secure as SSH when you verify the server.
Copy deploy.defaults.example.ps1 to C:\Temp\vibin\domainbuilds\deploy.defaults.ps1 and set `$DeployWinScpHostKey,
or set `$DeployWinScpHostKey in deploy.local.ps1.
One-time only: `$DeployAllowInsecureHostKey = `$true to connect and read the fingerprint from WinSCP.
"@
    }
    if ($keyMode) {
        $pkEsc = $DeployPrivateKeyPath.Replace('"', '""')
        $openLine = "open $openHost -privatekey=""$pkEsc"" -passphrase=%DEPLOY_WINSCP_PASS% $hostKeyPart"
    } else {
        $openLine = "open $openHost -password=%DEPLOY_WINSCP_PASS% $hostKeyPart"
    }

    $remotePath = $DeployRemotePath.TrimEnd("/")
    $stageWin = (Resolve-Path -LiteralPath $Stage).Path

    $scriptLines = @(
        "option batch on",
        "option confirm off",
        $openLine,
        "cd $remotePath",
        "synchronize remote -mirror -transfer=binary -preservetime=on `"$stageWin`" .",
        "exit"
    )
    $scriptBody = $scriptLines -join "`r`n"

    $WinScpCom = Resolve-WinScpCom
    if (-not $WinScpCom) {
        Write-Error "WinSCP.com not found. Install WinSCP or set `$DeployWinScpPath in deploy.local.ps1."
    }

    $tempScript = [System.IO.Path]::GetTempFileName()
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tempScript, $scriptBody, $utf8NoBom)

        if ($keyMode) {
            Set-Item -Path "Env:DEPLOY_WINSCP_PASS" -Value $DeployPpkPassphrase
        } else {
            Set-Item -Path "Env:DEPLOY_WINSCP_PASS" -Value $DeploySftpPassword
        }

        $winscpArgs = @("/ini=nul", "/script=$tempScript")
        if ($DeployWinScpLogPath) {
            $winscpArgs += "/log=$DeployWinScpLogPath"
            $winscpArgs += "/loglevel=-1"
        }

        Write-Host "Uploading via WinSCP (mirror)..." -ForegroundColor Yellow
        & $WinScpCom @winscpArgs | Out-Host
        if ($LASTEXITCODE -ne 0) {
            $hint = if ($DeployWinScpLogPath) { " See $DeployWinScpLogPath" } else { "" }
            throw "WinSCP exited with code $LASTEXITCODE$hint"
        }
        if ($DeployWinScpLogPath) {
            Write-Host "WinSCP log: $DeployWinScpLogPath" -ForegroundColor Gray
        }
        Write-Host "  Upload OK" -ForegroundColor Green
    }
    finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "Env:DEPLOY_WINSCP_PASS" -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# Post-script (e.g. version bumper)
# ----------------------------------------------------------------------------
if ($mode -eq "full" -and $DeployPostScript) {
    $postPath = if ([System.IO.Path]::IsPathRooted($DeployPostScript)) {
        $DeployPostScript
    } else {
        Join-Path $LocalPath $DeployPostScript
    }
    if (Test-Path -LiteralPath $postPath) {
        Write-Host "Running post-deploy script: $DeployPostScript" -ForegroundColor Yellow
        Push-Location $LocalPath
        try {
            if ($postPath -match '\.mjs$|\.js$') { node $postPath }
            elseif ($postPath -match '\.ps1$')  { & $postPath }
            else { & $postPath }
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  Post-script exited $LASTEXITCODE (continuing)." -ForegroundColor Yellow
            }
        }
        finally { Pop-Location }
    }
}

# ----------------------------------------------------------------------------
# Git + GitHub auto-release (optional)
# ----------------------------------------------------------------------------
if ($DeployGitTagOnSuccess -or $DeployGitHubAutoCreate) {
    Push-Location $LocalPath
    try {
        $hasGit = (Get-Command git -ErrorAction SilentlyContinue) -ne $null
        if (-not $hasGit) {
            Write-Host "git not installed; skipping git/GitHub steps." -ForegroundColor Yellow
        } else {
            $insideRepo = Test-NativeCmd { git rev-parse --is-inside-work-tree }

            if (-not $insideRepo) {
                Write-Host "Initializing git repo..." -ForegroundColor Yellow
                git init | Out-Host
                git add -A | Out-Host
                git commit -m "chore: initial import" | Out-Host
            }

            if ($DeployGitHubAutoCreate) {
                $hasGh = (Get-Command gh -ErrorAction SilentlyContinue) -ne $null
                if (-not $hasGh) {
                    Write-Host "gh CLI not installed; skipping GitHub create." -ForegroundColor Yellow
                } else {
                    $authOk = Test-NativeCmd { gh auth status }
                    if (-not $authOk) {
                        Write-Host "gh not logged in. Run 'gh auth login' once, then re-run deploy." -ForegroundColor Yellow
                    } else {
                        $hasOrigin = Test-NativeCmd { git remote get-url origin }
                        if (-not $hasOrigin) {
                            $slug = if ($DeployGitHubRepoSlug) { $DeployGitHubRepoSlug } else { Split-Path -Leaf $LocalPath }
                            Write-Host "Creating private GitHub repo: $slug" -ForegroundColor Yellow
                            gh repo create $slug --private --source=. --remote=origin --push | Out-Host
                        }
                    }
                }
            }

            if ($DeployGitTagOnSuccess) {
                $stamp = $deployStamp
                $msg = "deploy: $DeploySiteName @ $stamp"
                $tag = "deploy-$stamp"

                git add -A | Out-Null
                $status = git status --porcelain
                if ($status) {
                    Write-Host "Committing deploy snapshot..." -ForegroundColor Yellow
                    git commit -m $msg | Out-Host
                } else {
                    Write-Host "Working tree clean - skipping commit." -ForegroundColor Gray
                }

                $tagOk = Test-NativeCmd { git tag -a $tag -m "Deployed $DeploySiteUrl" }
                if (-not $tagOk) {
                    Write-Host "Tag $tag already exists - skipping." -ForegroundColor Gray
                }

                $hasOrigin2 = Test-NativeCmd { git remote get-url origin }
                if ($hasOrigin2) {
                    Write-Host "Pushing to origin (with tags)..." -ForegroundColor Yellow
                    git push origin HEAD --tags | Out-Host
                } else {
                    Write-Host "No 'origin' remote - skipping push. (Set `$DeployGitHubAutoCreate to create one.)" -ForegroundColor Gray
                }
                $global:LASTEXITCODE = 0
            }
        }
    }
    finally { Pop-Location }
}

Write-Host ""
Write-Host "=== Deployment Complete ===" -ForegroundColor Green
if ($DeploySiteUrl) { Write-Host "Site: $DeploySiteUrl" }
Write-Host ""
