<#
    dotfiles.ps1 - unified one-liner launcher for slamb2k/dotfiles.

    Invoke:
        iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/dotfiles.ps1 | iex

    Default behaviour: smart auto-detect based on machine state.
        - Fresh machine (no chezmoi source)   ->  mode = full
        - Existing machine with drift          ->  mode = audit
        - Existing machine fully aligned       ->  mode = audit (no-op)

    Override via $env:MODE / -Mode parameter / interactive arrow-key menu.

    Init phase (always): gh, chezmoi, bun, Claude Code CLI, gh auth, clone.
    User-scope only; never touches system state without confirmation.
#>

param(
    [string] $Mode      = $env:MODE,
    [string] $RepoSlug  = 'slamb2k/dotfiles',
    [switch] $Yes
)

$ErrorActionPreference = 'Stop'

# Force UTF-8 output so Unicode banner glyphs and OSC 8 hyperlinks render
# correctly in Windows Terminal / Warp / etc. Default codepage on Windows
# strips the multi-byte chars to '?' otherwise.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {}

# ----- ANSI helpers ---------------------------------------------------------

$E       = [char]27
$RST     = "$E[0m"
$BOLD    = "$E[1m"
$DIM     = "$E[2m"
$RED     = "$E[31m"
$GREEN   = "$E[32m"
$YELLOW  = "$E[33m"
$BLUE    = "$E[34m"
$MAGENTA = "$E[35m"
$CYAN    = "$E[36m"
$INVERT  = "$E[7m"

function HLink {
    param([string]$Path, [string]$Text)
    if (-not $Text) { $Text = $Path }
    try { $abs = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { $abs = $Path }
    $uri = if ($abs -match '^[A-Za-z]:[\\/]') { 'file:///' + ($abs -replace '\\','/') } else { 'file://' + ($abs -replace '\\','/') }
    return "${E}]8;;${uri}${E}\${Text}${E}]8;;${E}\"
}

function Section { param([string]$T) Write-Host "`n$BOLD$CYAN==>$RST $BOLD$T$RST" }
function Field   { param($K, $V) Write-Host ("  {0,-22} {1}" -f "$DIM$K$RST", $V) }
function Ok      { param($T) Write-Host "  $GREEN[OK]$RST  $T" }
function Warn    { param($T) Write-Host "  $YELLOW[!!]$RST  $T" }
function Fail    { param($T) Write-Host "  $RED[FAIL]$RST $T"; throw $T }
function Skip    { param($T) Write-Host "  $DIM[skip] $T$RST" }

function Cmd-Exists { param([string]$N) [bool] (Get-Command $N -ErrorAction SilentlyContinue) }

# ----- ASCII banner ---------------------------------------------------------

function Show-Banner {
    Write-Host ""
    $b = @(
        "${CYAN}██████╗  ██████╗ ████████╗███████╗██╗██╗     ███████╗███████╗${RST}",
        "${CYAN}██╔══██╗██╔═══██╗╚══██╔══╝██╔════╝██║██║     ██╔════╝██╔════╝${RST}",
        "${CYAN}██║  ██║██║   ██║   ██║   █████╗  ██║██║     █████╗  ███████╗${RST}",
        "${CYAN}██║  ██║██║   ██║   ██║   ██╔══╝  ██║██║     ██╔══╝  ╚════██║${RST}",
        "${CYAN}██████╔╝╚██████╔╝   ██║   ██║     ██║███████╗███████╗███████║${RST}",
        "${CYAN}╚═════╝  ╚═════╝    ╚═╝   ╚═╝     ╚═╝╚══════╝╚══════╝╚══════╝${RST}"
    )
    foreach ($l in $b) { Write-Host "  $l" }
    Write-Host "  ${DIM}slamb2k/dotfiles · unified launcher · audit · apply · full${RST}"
    Write-Host ""
}

# ----- Spinner --------------------------------------------------------------

function With-Spinner {
    param([string]$Message, [scriptblock]$Action)
    $frames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
    $job = Start-Job -ScriptBlock $Action
    $i = 0
    try { [Console]::CursorVisible = $false } catch {}
    try {
        while ($job.State -eq 'Running') {
            Write-Host -NoNewline "`r  $CYAN$($frames[$i % $frames.Count])$RST $Message  "
            Start-Sleep -Milliseconds 80
            $i++
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
    }
    $result = Receive-Job $job -Wait -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Write-Host -NoNewline "`r"
    $glyph = if ($job.State -eq 'Failed') { "$RED[fail]$RST" } else { "$GREEN[OK]$RST  " }
    Write-Host "  $glyph $Message$(' ' * 30)"
    return $result
}

# ----- Arrow-key menu (TTY) / numbered fallback -----------------------------

function Choose-Mode {
    param(
        [string[]]$Options,
        [string[]]$Descriptions,
        [string]$Default
    )

    $idx = [array]::IndexOf($Options, $Default)
    if ($idx -lt 0) { $idx = 0 }

    $interactive = $false
    try {
        $null = $Host.UI.RawUI.KeyAvailable
        if (-not [Console]::IsInputRedirected) { $interactive = $true }
    } catch {}

    if (-not $interactive) {
        # Non-TTY fallback: numbered menu via Read-Host
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $desc = if ($i -lt $Descriptions.Count) { " ${DIM}$($Descriptions[$i])${RST}" } else { '' }
            $marker = if ($Options[$i] -eq $Default) { "$GREEN>$RST" } else { ' ' }
            Write-Host "  $marker [$($i+1)] $BOLD$($Options[$i])$RST$desc"
        }
        Write-Host ""
        Write-Host -NoNewline "  Press [Enter] for $BOLD$Default$RST or pick 1-$($Options.Count): "
        $resp = Read-Host
        if (-not $resp) { return $Default }
        $n = 0
        if ([int]::TryParse($resp, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) {
            return $Options[$n - 1]
        }
        $resp = $resp.Trim().ToLower()
        foreach ($o in $Options) { if ($o.ToLower().StartsWith($resp)) { return $o } }
        return $Default
    }

    # Interactive arrow-key menu
    [Console]::CursorVisible = $false
    $top = [Console]::CursorTop
    try {
        while ($true) {
            [Console]::SetCursorPosition(0, $top)
            for ($i = 0; $i -lt $Options.Count; $i++) {
                $desc = if ($i -lt $Descriptions.Count) { "  $DIM$($Descriptions[$i])$RST" } else { '' }
                if ($i -eq $idx) {
                    $line = "  $GREEN▸$RST $BOLD$INVERT $($Options[$i]) $RST$desc"
                } else {
                    $line = "    $($Options[$i])$desc"
                }
                # strip ANSI for length calc
                $stripped = $line -replace "$E\[[\d;]*[a-zA-Z]", ''
                $stripped = $stripped -replace "$E\][^$E]*$E\\", ''
                $padding  = [Math]::Max(0, 90 - $stripped.Length)
                Write-Host ($line + (' ' * $padding))
            }
            Write-Host ""
            Write-Host -NoNewline "  $DIM(arrow keys, Enter to select, x/Esc to exit)$RST   "

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $idx = ($idx - 1 + $Options.Count) % $Options.Count }
                'DownArrow' { $idx = ($idx + 1) % $Options.Count }
                'Enter'     { Write-Host ''; return $Options[$idx] }
                'Escape'    { Write-Host ''; return 'exit' }
                default {
                    $c = $key.KeyChar.ToString().ToLower()
                    if ($c -eq 'x') { Write-Host ''; return 'exit' }
                    for ($i = 0; $i -lt $Options.Count; $i++) {
                        if ($Options[$i].ToLower().StartsWith($c)) { $idx = $i; break }
                    }
                }
            }
        }
    } finally {
        [Console]::CursorVisible = $true
    }
}

# ============================================================================
# Phase 0 - banner
# ============================================================================

Show-Banner

# ============================================================================
# Phase 1 - init / prereqs
# ============================================================================

Section 'Init phase'

if (-not (Cmd-Exists winget)) {
    Fail 'winget not found. Install "App Installer" from Microsoft Store and re-run.'
}

# winget user-scope: gh, chezmoi, git
foreach ($id in 'GitHub.cli','twpayne.chezmoi','Git.Git') {
    & winget list --id $id --disable-interactivity 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Skip "$id"
    } else {
        Write-Host "  $CYAN...$RST installing $id (winget user-scope)"
        & winget install --id $id --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | Out-Null
        Ok "installed $id"
    }
}

$env:Path = [Environment]::GetEnvironmentVariable('Path','User') + ';' +
            [Environment]::GetEnvironmentVariable('Path','Machine')

foreach ($t in 'gh','chezmoi','git') {
    if (-not (Cmd-Exists $t)) { Fail "$t not on PATH after install. Open a fresh PowerShell window and re-run." }
}

# bun
if (-not (Cmd-Exists bun)) {
    Write-Host "  $CYAN...$RST installing bun"
    & powershell -NoProfile -Command "iwr bun.sh/install.ps1 -useb | iex" 2>&1 | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable('Path','User') + ';' +
                [Environment]::GetEnvironmentVariable('Path','Machine')
    if (-not (Cmd-Exists bun)) { Fail 'bun install failed. Open a fresh shell and re-run.' }
    Ok "installed bun ($(& bun --version))"
} else {
    Skip "bun ($(& bun --version))"
}

# Claude Code CLI
if (-not (Cmd-Exists claude)) {
    Write-Host "  $CYAN...$RST installing Claude Code CLI via bun"
    & bun install -g '@anthropic-ai/claude-code' 2>&1 | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable('Path','User') + ';' +
                [Environment]::GetEnvironmentVariable('Path','Machine')
    Ok 'installed Claude Code CLI'
} else {
    Skip 'Claude Code CLI'
}

# gh auth
$ghAuthed = $false
try { & gh auth status 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $ghAuthed = $true } } catch {}
if (-not $ghAuthed) {
    Section 'gh auth login --web'
    & gh auth login --web --hostname github.com --git-protocol https
    if ($LASTEXITCODE -ne 0) { Fail 'gh auth login failed' }
    Ok 'gh authenticated'
} else {
    Skip 'gh authenticated'
}

# Clone or update private dotfiles repo
$srcDir = "$env:USERPROFILE\.local\share\chezmoi"
$wasFresh = -not (Test-Path "$srcDir\.git")
if ($wasFresh) {
    Write-Host "  $CYAN...$RST cloning $RepoSlug -> $srcDir"
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
# Phase 2 - inspect machine state
# ============================================================================

Section 'Machine state'

$statusOut  = & chezmoi --source $srcDir status 2>&1
$driftLines = @($statusOut | Where-Object { $_ -and $_.ToString().Trim() })
$driftCount = $driftLines.Count

$claudeAuthed = Test-Path "$env:USERPROFILE\.claude\.credentials.json"

$dsreg          = try { & dsregcmd /status 2>&1 } catch { @() }
$intuneEnrolled = [bool]($dsreg -match 'WorkplaceJoined\s*:\s*YES' -or $dsreg -match 'AzureAdJoined\s*:\s*YES')

$recommended = if ($wasFresh) { 'full' } elseif ($driftCount -gt 0) { 'audit' } else { 'audit' }

Field 'Host'         "$env:COMPUTERNAME ($([System.Environment]::OSVersion.VersionString))"
Field 'User'         $env:USERNAME
Field 'Chezmoi'      (& chezmoi --version)
Field 'Source dir'   (HLink $srcDir)
Field 'Repo state'   $(if ($wasFresh) { "$YELLOW(just cloned, never applied)$RST" } else { "$GREEN(present)$RST" })
Field 'Managed drift' $(if ($driftCount -eq 0) { "$GREEN" + "0 chezmoi-tracked files differ$RST" } else { "$YELLOW$driftCount chezmoi-tracked file(s) differ$RST  $DIM(audit will also report inventory drift + unmanaged dotfiles)$RST" })
Field 'gh auth'      "$GREEN(ready)$RST"
Field 'Claude Code'  $(if ($claudeAuthed) { "$GREEN(authed)$RST" } else { "$YELLOW(installed; run claude once for auth)$RST" })
Field 'Enterprise'   $(if ($intuneEnrolled) { "$YELLOW(workplace-joined / Azure AD)$RST" } else { "$GREEN(personal device)$RST" })

# ============================================================================
# Phase 3 - mode picker
# ============================================================================

Section 'Choose mode'

Write-Host ""
Write-Host "  $BOLD$GREEN▸ Recommended: $($recommended.ToUpper())$RST"
Write-Host ""

$opts  = @('audit','apply','full','exit')
$descs = @(
    'read-only; produces report.html and items.json',
    'audit + chezmoi apply (overwrites drifted managed files)',
    'apply + extended toolchain + ssh-agent + WSL bootstrap',
    'stop here'
)

if ($Mode) {
    Write-Host "  $DIM(MODE env var / -Mode parameter set: '$Mode')$RST"
} elseif ($Yes) {
    $Mode = $recommended
    Write-Host "  $DIM(-Yes given; defaulting to recommended)$RST"
} else {
    $Mode = Choose-Mode -Options $opts -Descriptions $descs -Default $recommended
}

if ($Mode -eq 'full' -and $intuneEnrolled -and -not $Yes) {
    Write-Host ""
    Write-Host "  $YELLOW[!!]$RST This machine looks enterprise-managed."
    Write-Host -NoNewline "       'full' may be blocked by Tamper Protection / Intune. Continue? [y/N] "
    $c = Read-Host
    if ($c -notmatch '^y') { Write-Host "  Aborting; pick 'audit' or 'apply' instead."; exit 0 }
}

if ($Mode -eq 'exit') { Write-Host "`n  Stopped on request."; exit 0 }

Write-Host ""
Write-Host "  $BOLD$MAGENTA▶ Running mode: $Mode$RST"

# ============================================================================
# Phase 4 - dispatch
# ============================================================================

$auditScript     = Join-Path $srcDir 'scripts\audit-and-diff.ps1'
$bootstrapScript = Join-Path $srcDir 'scripts\bootstrap.ps1'
$repoUrl         = "https://github.com/$RepoSlug.git"

switch ($Mode) {
    'audit' {
        Section 'Running audit'
        & $auditScript -RepoUrl $repoUrl
    }
    'apply' {
        Section 'Running audit'
        & $auditScript -RepoUrl $repoUrl
        if (-not $Yes) {
            Write-Host ""
            Write-Host -NoNewline "  About to run $YELLOW``chezmoi apply --force``$RST. Drifted managed files will be overwritten. Proceed? [y/N] "
            $c = Read-Host
            if ($c -notmatch '^y') { Warn 'Aborted; the audit report is in audit-output-*.'; exit 0 }
        }
        Section 'chezmoi apply'
        & chezmoi --source $srcDir apply --force
        Ok 'applied'
    }
    'full' {
        Section 'Running full bootstrap'
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
}
Write-Host ""
Write-Host "  Re-run any time:"
Write-Host ("  ${BOLD}iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/dotfiles.ps1 | iex${RST}")
Write-Host ""
