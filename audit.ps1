<#
    audit.ps1 - one-line read-only audit launcher.

    Invoke:
        iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/audit.ps1 | iex

    Strictly read-only against system state. Will install gh + chezmoi if
    missing (winget user-scope), authenticate with GitHub if necessary, and
    ensure the private dotfiles repo is cloned at ~/.local/share/chezmoi.
    Then runs scripts/audit-and-diff.ps1 from that source. Never applies
    chezmoi changes; never modifies dotfiles, registry, services, or PATH
    beyond what 'winget install' itself does.

    Output: a markdown report at .\audit-output-<date>\report.md plus
    raw\*.json|.txt dumps. You read the report and decide what to do.
#>

param(
    [string] $RepoSlug = 'slamb2k/dotfiles',
    [switch] $SkipWsl
)

$ErrorActionPreference = 'Stop'

function Section { param($T) Write-Host ''; Write-Host "==> $T" -ForegroundColor Cyan }
function Ok      { param($T) Write-Host "    [OK]   $T" -ForegroundColor Green }
function Skip    { param($T) Write-Host "    [skip] $T" -ForegroundColor DarkGray }
function Fail    { param($T) Write-Host "    [FAIL] $T" -ForegroundColor Red; throw $T }

Section 'audit.ps1: read-only audit launcher'

# 1. Need winget for the install path. If it's not there we can't proceed.
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fail 'winget not found. Install "App Installer" from Microsoft Store.'
}

# 2. gh + chezmoi (skip if present)
foreach ($id in 'GitHub.cli','twpayne.chezmoi') {
    & winget list --id $id --disable-interactivity 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Skip "$id already installed"
    } else {
        Section "winget install $id"
        & winget install --id $id --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | Select-Object -Last 1
    }
}

# Refresh PATH for this shell
$env:Path = [Environment]::GetEnvironmentVariable('Path','User') + ';' +
            [Environment]::GetEnvironmentVariable('Path','Machine')

if (-not (Get-Command gh       -ErrorAction SilentlyContinue)) { Fail 'gh not on PATH after install' }
if (-not (Get-Command chezmoi  -ErrorAction SilentlyContinue)) { Fail 'chezmoi not on PATH after install' }

# 3. gh auth (only if cloning is needed)
$srcDir = "$env:USERPROFILE\.local\share\chezmoi"
if (-not (Test-Path "$srcDir\.git")) {
    $ghAuthed = $false
    try { & gh auth status 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $ghAuthed = $true } } catch {}
    if (-not $ghAuthed) {
        Section 'gh auth login --web (needed to clone private dotfiles)'
        & gh auth login --web --hostname github.com --git-protocol https
    }
    Section "Cloning $RepoSlug -> $srcDir (read-only fetch; no chezmoi apply)"
    New-Item -ItemType Directory -Path (Split-Path $srcDir -Parent) -Force | Out-Null
    & gh repo clone $RepoSlug $srcDir
} else {
    Section "Updating $srcDir (no apply)"
    Push-Location $srcDir
    & git fetch --quiet 2>&1 | Select-Object -Last 1
    & git pull --ff-only 2>&1 | Select-Object -Last 1
    Pop-Location
}
Ok 'dotfiles source available'

# 4. Run the audit
$audit = Join-Path $srcDir 'scripts\audit-and-diff.ps1'
if (-not (Test-Path $audit)) { Fail "$audit missing in $RepoSlug" }

Section 'running scripts\audit-and-diff.ps1...'
$argList = @{ RepoUrl = "https://github.com/$RepoSlug.git" }
if ($SkipWsl) { $argList.SkipWsl = $true }
& $audit @argList

Write-Host ''
Write-Host 'Audit complete. No system state was modified beyond installing gh + chezmoi.' -ForegroundColor Green
Write-Host 'Read the report, then decide whether to run install.ps1 (full bootstrap) or apply specific files manually.' -ForegroundColor DarkGray
