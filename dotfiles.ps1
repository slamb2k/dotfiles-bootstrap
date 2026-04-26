<#
    dotfiles.ps1 - unified one-liner launcher for slamb2k/dotfiles.

    Invoke:
        iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/dotfiles.ps1 | iex

    Default behaviour: smart auto-detect based on machine state.
        - Fresh machine (no chezmoi source)   ->  mode = full
        - Existing machine with drift          ->  mode = audit
        - Existing machine fully aligned       ->  mode = audit (will be a no-op)

    Override with the MODE env var:
        $env:MODE = 'audit'  ->  read-only; produces report.html only
        $env:MODE = 'apply'  ->  audit + chezmoi apply (overwrites drifted managed files)
        $env:MODE = 'full'   ->  apply + extended toolchain + ssh-agent + WSL bootstrap

    Init phase (always runs first): gh, chezmoi, bun, Claude Code CLI, gh auth.
    User-scope only; never touches system state without confirmation.
#>

param(
    [string] $Mode      = $env:MODE,
    [string] $RepoSlug  = 'slamb2k/dotfiles',
    [switch] $Yes       # skip confirmations (for scripted use)
)

$ErrorActionPreference = 'Stop'

# ----- ANSI colour helpers (work in pwsh 7+ and Win Terminal) ----------------

$ESC    = [char]27
$RST    = "$ESC[0m"
$BOLD   = "$ESC[1m"
$DIM    = "$ESC[2m"
$RED    = "$ESC[31m"
$GREEN  = "$ESC[32m"
$YELLOW = "$ESC[33m"
$BLUE   = "$ESC[34m"
$CYAN   = "$ESC[36m"
$MAGENT = "$ESC[35m"

function Box {
    param([string]$Title)
    $w = 76
    $pad = $w - $Title.Length - 2
    Write-Host ""
    Write-Host "$CYAN+$('-'*$w)+$RST"
    Write-Host "$CYAN|$RST $BOLD$Title$RST$(' '*($pad-1)) $CYAN|$RST"
    Write-Host "$CYAN+$('-'*$w)+$RST"
}

function Section { param([string]$T) Write-Host "`n$BOLD$CYAN==>$RST $BOLD$T$RST" }
function Field   { param($K, $V) Write-Host ("  {0,-22} $RST {1}" -f "$DIM$K$RST", $V) }
function Ok      { param($T) Write-Host "  $GREEN[OK]$RST  $T" }
function Warn    { param($T) Write-Host "  $YELLOW[!!]$RST  $T" }
function Fail    { param($T) Write-Host "  $RED[FAIL]$RST $T" -ForegroundColor Red; throw $T }
function Skip    { param($T) Write-Host "  $DIM[skip] $T$RST" }

function Cmd-Exists { param([string]$N) [bool] (Get-Command $N -ErrorAction SilentlyContinue) }

# ============================================================================
# Phase 0 - banner
# ============================================================================

Box "dotfiles . slamb2k/dotfiles . unified launcher"
Write-Host "  $DIM" + "Single entry point. Detects machine state. Runs the right path." + "$RST"

# ============================================================================
# Phase 1 - init / prereqs
# ============================================================================

Section 'Init phase: prereqs'

if (-not (Cmd-Exists winget)) {
    Fail 'winget not found. Install "App Installer" from Microsoft Store and re-run.'
}

# 1. winget user-scope: gh, chezmoi, git
foreach ($id in 'GitHub.cli','twpayne.chezmoi','Git.Git') {
    & winget list --id $id --disable-interactivity 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Skip "$id"
    } else {
        & winget install --id $id --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 |
            Select-Object -Last 1 | Out-Null
        Ok "installed $id"
    }
}

# Refresh PATH for this session so the just-installed binaries are callable
$env:Path = [Environment]::GetEnvironmentVariable('Path','User') + ';' +
            [Environment]::GetEnvironmentVariable('Path','Machine')

foreach ($t in 'gh','chezmoi','git') {
    if (-not (Cmd-Exists $t)) {
        Fail "$t still not on PATH after install. Open a new PowerShell window and re-run."
    }
}

# 2. bun (gateway for Claude Code CLI)
if (-not (Cmd-Exists bun)) {
    & powershell -NoProfile -Command "iwr bun.sh/install.ps1 -useb | iex" 2>&1 | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable('Path','User') + ';' +
                [Environment]::GetEnvironmentVariable('Path','Machine')
    if (-not (Cmd-Exists bun)) { Fail 'bun install failed. Open a fresh shell and re-run.' }
    Ok "installed bun ($(& bun --version))"
} else {
    Skip "bun ($(& bun --version))"
}

# 3. Claude Code CLI
$claudeCli = (Get-Command claude -ErrorAction SilentlyContinue)
if (-not $claudeCli) {
    & bun install -g '@anthropic-ai/claude-code' 2>&1 | Select-Object -Last 1 | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable('Path','User') + ';' +
                [Environment]::GetEnvironmentVariable('Path','Machine')
    Ok "installed Claude Code CLI"
} else {
    Skip "Claude Code CLI"
}

# 4. gh auth
$ghAuthed = $false
try { & gh auth status 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $ghAuthed = $true } } catch {}
if (-not $ghAuthed) {
    Section 'gh auth login --web (browser flow)'
    & gh auth login --web --hostname github.com --git-protocol https
    if ($LASTEXITCODE -ne 0) { Fail 'gh auth login failed' }
    Ok 'gh authenticated'
} else {
    Skip 'gh authenticated'
}

# 5. clone or update private dotfiles repo
$srcDir = "$env:USERPROFILE\.local\share\chezmoi"
$wasFresh = -not (Test-Path "$srcDir\.git")
if ($wasFresh) {
    Section "Cloning $RepoSlug -> $srcDir"
    New-Item -ItemType Directory -Path (Split-Path $srcDir -Parent) -Force | Out-Null
    & gh repo clone $RepoSlug $srcDir 2>&1 | Out-Null
    if (-not (Test-Path "$srcDir\.git")) { Fail "gh repo clone failed (verify access to $RepoSlug)" }
    Ok 'cloned'
} else {
    Skip "dotfiles already at $srcDir"
    Push-Location $srcDir
    & git fetch --quiet 2>&1 | Out-Null
    & git pull --ff-only --quiet 2>&1 | Out-Null
    Pop-Location
    Ok 'pulled latest'
}

# ============================================================================
# Phase 2 - inspect machine state, decide recommended mode
# ============================================================================

Section 'Machine state inspection'

# Drift size via chezmoi status (one-shot, fast)
$statusOut  = & chezmoi --source $srcDir status 2>&1
$driftLines = @($statusOut | Where-Object { $_ -and $_.ToString().Trim() })
$driftCount = $driftLines.Count

# Auth state for Claude Code
$claudeAuthed = Test-Path "$env:USERPROFILE\.claude\.credentials.json"

# Enterprise-managed sniff (cheap heuristic; full version is in audit-and-diff.ps1)
$dsreg          = Try { & dsregcmd /status 2>&1 } catch { @() }
$intuneEnrolled = [bool]($dsreg -match 'WorkplaceJoined\s*:\s*YES' -or
                         $dsreg -match 'AzureAdJoined\s*:\s*YES')

# Recommended mode
$recommended = if ($wasFresh) { 'full' }
              elseif ($driftCount -gt 0) { 'audit' }
              else { 'audit' }

# Render the inspection panel
Field 'Host'           "$env:COMPUTERNAME ($([System.Environment]::OSVersion.VersionString))"
Field 'User'           $env:USERNAME
Field 'Chezmoi'        (& chezmoi --version)
Field 'Source dir'     $srcDir
Field 'Repo state'     $(if ($wasFresh) { "$YELLOW(just cloned, never applied)$RST" } else { "$GREEN(present)$RST" })
Field 'Drift'          $(if ($driftCount -eq 0) { "$GREEN0 changes - in sync$RST" } else { "$YELLOW$driftCount file(s) differ$RST" })
Field 'gh auth'        "$GREEN(ready)$RST"
Field 'Claude Code'    $(if ($claudeAuthed) { "$GREEN(authed)$RST" } else { "$YELLOW(installed; run claude once for auth)$RST" })
Field 'Enterprise'    $(if ($intuneEnrolled) { "$YELLOW(workplace-joined / Azure AD signal)$RST" } else { "$GREEN(personal device)$RST" })

# ============================================================================
# Phase 3 - rich path picker
# ============================================================================

Section 'Decision'

Write-Host ""
Write-Host "  $BOLD$GREEN  Recommended mode: $($recommended.ToUpper())$RST"
Write-Host ""
Write-Host "  $DIM    a$RST | $BOLD" + "audit" + "$RST  - read-only; produces report.html and items.json"
Write-Host "  $DIM    p$RST | $BOLD" + "apply" + "$RST  - audit + ``chezmoi apply`` (overwrites any drift in managed files)"
Write-Host "  $DIM    f$RST | $BOLD" + "full" + "$RST   - apply + toolchain + ssh-agent + WSL bootstrap"
Write-Host "  $DIM    x$RST | $BOLD" + "exit" + "$RST   - stop here"
Write-Host ""

# Resolve user choice
if ($Mode) {
    Write-Host "  $DIM(MODE env var / -Mode parameter set: '$Mode')$RST"
} elseif ($Yes) {
    $Mode = $recommended
    Write-Host "  $DIM(-Yes given; defaulting to recommended)$RST"
} else {
    Write-Host -NoNewline "  Press [Enter] for $BOLD$recommended$RST, or type a/p/f/x to override -> "
    $resp = Read-Host
    $resp = ($resp -as [string]).Trim().ToLower()
    $Mode = switch ($resp) {
        ''        { $recommended }
        'a'       { 'audit' }
        'audit'   { 'audit' }
        'p'       { 'apply' }
        'apply'   { 'apply' }
        'f'       { 'full' }
        'full'    { 'full' }
        'x'       { 'exit' }
        'exit'    { 'exit' }
        default   { Warn "Unrecognised '$resp'; defaulting to $recommended"; $recommended }
    }
}

# Block destructive on enterprise-managed unless user is very explicit
if ($Mode -eq 'full' -and $intuneEnrolled -and -not $Yes) {
    Write-Host ""
    Write-Host "  $YELLOW[!!]$RST  This machine looks enterprise-managed (workplace-joined / Azure AD)."
    Write-Host "       'full' mode adds ssh-agent service changes + Defender exclusions, which"
    Write-Host "       Tamper Protection / Intune may block. Continue anyway? [y/N] " -NoNewline
    $c = Read-Host
    if ($c -notmatch '^y') { Write-Host "  Aborting; pick 'audit' or 'apply' instead."; exit 0 }
}

if ($Mode -eq 'exit') { Write-Host "  Stopped on request."; exit 0 }

Write-Host ""
Write-Host "  $BOLD$MAGENT> Running mode: $Mode$RST"
Write-Host ""

# ============================================================================
# Phase 4 - dispatch
# ============================================================================

$auditScript     = Join-Path $srcDir 'scripts\audit-and-diff.ps1'
$bootstrapScript = Join-Path $srcDir 'scripts\bootstrap.ps1'
$repoUrl         = "https://github.com/$RepoSlug.git"

switch ($Mode) {
    'audit' {
        Section 'Running audit-and-diff.ps1'
        & $auditScript -RepoUrl $repoUrl
    }
    'apply' {
        Section 'Running audit-and-diff.ps1'
        & $auditScript -RepoUrl $repoUrl
        if (-not $Yes) {
            Write-Host ""
            Write-Host -NoNewline "  About to run $YELLOW``chezmoi apply --force``$RST. Any drifted managed file will be overwritten with repo state. Proceed? [y/N] "
            $c = Read-Host
            if ($c -notmatch '^y') { Warn 'Aborted; the audit report is still in audit-output-*.'; exit 0 }
        }
        Section 'chezmoi apply --force'
        & chezmoi --source $srcDir apply --force
        Ok 'applied'
    }
    'full' {
        Section 'Running scripts/bootstrap.ps1 (full toolchain + apply + ssh-agent + WSL)'
        & $bootstrapScript -RepoUrl $repoUrl
    }
}

# ============================================================================
# Phase 5 - close-out
# ============================================================================

Section 'Done'
if (-not $claudeAuthed) {
    Write-Host ""
    Write-Host "  $YELLOW[!!]  Claude Code is installed but NOT authenticated.$RST"
    Write-Host "       Run ``claude`` once in any terminal for the browser auth flow."
    Write-Host "       After that, the dotfiles-incorporate skill works end-to-end."
    Write-Host ""
}

Write-Host "  Re-run any time: " -NoNewline
Write-Host "$BOLD" + "iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/dotfiles.ps1 | iex" + "$RST"
Write-Host ""
