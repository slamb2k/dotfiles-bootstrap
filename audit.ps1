<#
    audit.ps1 - one-line read-only audit launcher.

    Invoke:
        iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/audit.ps1 | iex

    Strictly read-only against system state. Init phase ensures the
    prerequisites are in place (gh, chezmoi, bun, Claude Code CLI - all
    user-scope) and gh + Claude Code are authenticated. Then runs
    scripts/audit-and-diff.ps1 from the cloned dotfiles source. Never
    applies chezmoi changes; never modifies dotfiles, registry, services,
    or PATH beyond what the package managers themselves do.

    Why install Claude Code in the audit launcher? Because the natural
    follow-up to "audit -> review HTML -> generate decisions.json" is the
    dotfiles-incorporate skill executing those decisions. Having Claude
    Code installed and authenticated by the time the audit finishes means
    no second prereq round-trip when you want to act on the report.

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

# 4. install bun (gateway dependency for Claude Code CLI)
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    Section 'install bun'
    & powershell -NoProfile -Command "iwr bun.sh/install.ps1 -useb | iex"
    $env:Path = [Environment]::GetEnvironmentVariable('Path','User') + ';' +
                [Environment]::GetEnvironmentVariable('Path','Machine')
}
$bunExe = (Get-Command bun -ErrorAction SilentlyContinue).Source
if (-not $bunExe) { Fail 'bun not on PATH after install. Open a new shell and re-run.' }
Skip "bun: $(& $bunExe --version)"

# 5. install Claude Code CLI (required for the dotfiles-incorporate skill)
Section 'install Claude Code CLI via bun'
& $bunExe install -g '@anthropic-ai/claude-code' 2>&1 | Select-Object -Last 1

# 6. check Claude Code auth (interactive; the user does this once)
$claudeCreds = Test-Path "$env:USERPROFILE\.claude\.credentials.json"
if (-not $claudeCreds) {
    Write-Host ''
    Write-Host '    *** Claude Code is INSTALLED but NOT AUTHENTICATED ***'                  -ForegroundColor Yellow
    Write-Host '    After this audit finishes, run `claude` once in any terminal'             -ForegroundColor Yellow
    Write-Host '    to do the browser auth flow. Then the audit -> incorporate skill works.'  -ForegroundColor Yellow
    Write-Host ''
} else {
    Ok 'Claude Code authenticated'
}

# 7. Run the audit
$audit = Join-Path $srcDir 'scripts\audit-and-diff.ps1'
if (-not (Test-Path $audit)) { Fail "$audit missing in $RepoSlug" }

Section 'running scripts\audit-and-diff.ps1...'
$argList = @{ RepoUrl = "https://github.com/$RepoSlug.git" }
if ($SkipWsl) { $argList.SkipWsl = $true }
& $audit @argList

Write-Host ''
Write-Host 'Audit complete. No system state was modified beyond installing gh, chezmoi, bun, and Claude Code CLI (all user-scope).' -ForegroundColor Green
Write-Host 'Read the HTML report, pick actions, download decisions.json, then in Claude Code: "execute decisions.json from <path>".' -ForegroundColor DarkGray
