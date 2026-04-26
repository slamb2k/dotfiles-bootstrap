<#
    install.ps1 - one-line launcher for a fresh Windows 11 machine.

    Invoke (paste in any pwsh / Windows PowerShell window):

        iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/install.ps1 | iex

    What it does:
      1. Verifies winget is present (ships with Windows 11; if missing, install
         "App Installer" from the Microsoft Store and re-run).
      2. winget install:  GitHub.cli, twpayne.chezmoi, Git.Git  (user scope).
      3. Refreshes PATH for the current shell.
      4. gh auth login --web   (opens a browser tab; copy the one-time code).
      5. gh repo clone slamb2k/dotfiles  ->  $env:USERPROFILE\.local\share\chezmoi
      6. Hands off to the private dotfiles repo's scripts\bootstrap.ps1
         which does the rest (chezmoi apply, optional toolchain, WSL bootstrap,
         ssh-agent, audit).

    Strictly read-only against system state until step 4. Steps 5/6 install
    software and write dotfiles -- only run if you trust this URL.
#>

param(
    [string] $RepoSlug = 'slamb2k/dotfiles',     # private dotfiles repo
    [switch] $Minimal,                           # passes through to bootstrap.ps1
    [switch] $SkipWsl                            # passes through to bootstrap.ps1
)

$ErrorActionPreference = 'Stop'

function Section { param($T) Write-Host ''; Write-Host "==> $T" -ForegroundColor Cyan }
function Ok      { param($T) Write-Host "    [OK]   $T" -ForegroundColor Green }
function Fail    { param($T) Write-Host "    [FAIL] $T" -ForegroundColor Red; throw $T }

Section 'install.ps1: fresh-Windows launcher for slamb2k/dotfiles'

# 1. winget present?
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fail 'winget not found. Install "App Installer" from Microsoft Store, then re-run.'
}
Ok "winget: $(winget --version)"

# 2. core deps
foreach ($id in 'GitHub.cli','twpayne.chezmoi','Git.Git') {
    Section "winget install $id"
    & winget install --id $id --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | Select-Object -Last 1
}

# 3. refresh PATH for this shell
$env:Path = [Environment]::GetEnvironmentVariable('Path','User') + ';' +
            [Environment]::GetEnvironmentVariable('Path','Machine')

foreach ($t in 'gh','chezmoi','git') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
        Fail "$t still not on PATH after install. Open a new PowerShell window and re-run."
    }
}
Ok 'PATH refreshed; gh, chezmoi, git all callable'

# 4. gh auth
$ghAuthed = $false
try { & gh auth status 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $ghAuthed = $true } } catch {}
if (-not $ghAuthed) {
    Section 'gh auth login --web'
    & gh auth login --web --hostname github.com --git-protocol https
    if ($LASTEXITCODE -ne 0) { Fail 'gh auth login failed' }
}
Ok 'gh authenticated'

# 5. clone private dotfiles
$srcDir = "$env:USERPROFILE\.local\share\chezmoi"
if (Test-Path "$srcDir\.git") {
    Section "Existing chezmoi source at $srcDir - pulling latest"
    Push-Location $srcDir
    & git pull --ff-only 2>&1 | Select-Object -Last 2
    Pop-Location
} else {
    Section "Cloning $RepoSlug -> $srcDir"
    New-Item -ItemType Directory -Path (Split-Path $srcDir -Parent) -Force | Out-Null
    & gh repo clone $RepoSlug $srcDir
    if ($LASTEXITCODE -ne 0) { Fail "gh repo clone failed (do you have access to $RepoSlug?)" }
}
Ok 'dotfiles repo present'

# 6. hand off to the private repo's full bootstrap
$bootstrap = Join-Path $srcDir 'scripts\bootstrap.ps1'
if (-not (Test-Path $bootstrap)) {
    Fail "$bootstrap missing - the private dotfiles repo doesn't include scripts/bootstrap.ps1"
}

Section 'launching scripts\bootstrap.ps1...'
$args = @{ RepoUrl = "https://github.com/$RepoSlug.git" }
if ($Minimal) { $args.Minimal = $true }
if ($SkipWsl) { $args.SkipWsl = $true }
& $bootstrap @args
