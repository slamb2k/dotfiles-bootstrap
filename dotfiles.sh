#!/usr/bin/env bash
#
# dotfiles.sh - unified one-liner launcher for slamb2k/dotfiles.
#
# Invoke:
#   curl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/dotfiles.sh | bash
#
# Default behaviour: smart auto-detect based on machine state.
#   - Fresh machine (no chezmoi source)     -> mode = full
#   - Existing machine with drift            -> mode = audit
#   - Existing machine fully aligned         -> mode = audit (no-op)
#
# Override with the MODE env var:
#   MODE=audit  curl ... | bash    # read-only; produces report.html only
#   MODE=apply  curl ... | bash    # audit + chezmoi apply
#   MODE=full   curl ... | bash    # apply + extended toolchain
#
# Init phase (always): apt deps, gh, chezmoi, pwsh, bun, Claude Code CLI, gh auth.
# User-scope only; never touches system state without confirmation.

set -euo pipefail

REPO_SLUG="${RepoSlug:-slamb2k/dotfiles}"
MODE="${MODE:-}"
YES="${YES:-0}"

# ----- ANSI helpers ---------------------------------------------------------

esc() { printf '\033[%sm' "$1"; }
RST=$(esc 0); BOLD=$(esc 1); DIM=$(esc 2)
RED=$(esc 31); GRN=$(esc 32); YEL=$(esc 33); CYN=$(esc 36); MAG=$(esc 35)

box() {
    local title="$1" w=76 pad
    pad=$(( w - ${#title} - 2 ))
    printf '\n%s+%s+%s\n' "$CYN" "$(printf '%.0s-' $(seq 1 $w))" "$RST"
    printf '%s|%s %s%s%s%*s %s|%s\n' "$CYN" "$RST" "$BOLD" "$title" "$RST" "$pad" '' "$CYN" "$RST"
    printf '%s+%s+%s\n' "$CYN" "$(printf '%.0s-' $(seq 1 $w))" "$RST"
}
section() { printf '\n%s%s==>%s %s%s%s\n' "$BOLD" "$CYN" "$RST" "$BOLD" "$1" "$RST"; }
field()   { printf '  %s%-22s%s %s\n' "$DIM" "$1" "$RST" "$2"; }
ok()      { printf '  %s[OK]%s   %s\n'   "$GRN" "$RST" "$1"; }
warn()    { printf '  %s[!!]%s   %s\n'   "$YEL" "$RST" "$1"; }
fail()    { printf '  %s[FAIL]%s %s\n'   "$RED" "$RST" "$1"; exit 1; }
skip()    { printf '  %s[skip] %s%s\n'   "$DIM" "$1"   "$RST"; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# When invoked via curl|bash, stdin is the script - bind to tty for prompts.
if [ -t 0 ] || [ ! -e /dev/tty ]; then : ; else exec </dev/tty; fi

# ============================================================================
# Phase 0 - banner
# ============================================================================

box "dotfiles . slamb2k/dotfiles . unified launcher"
printf '  %sSingle entry point. Detects machine state. Runs the right path.%s\n' "$DIM" "$RST"

# ============================================================================
# Phase 1 - init / prereqs
# ============================================================================

section 'Init phase: prereqs'

# 1. apt deps
need=()
for p in git curl ca-certificates wget; do
    dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
done
if [ ${#need[@]} -gt 0 ]; then
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
    ok "apt: ${need[*]}"
else
    skip 'apt deps'
fi

# 2. gh
if ! cmd_exists gh; then
    if [ ! -f /etc/apt/sources.list.d/github-cli.list ]; then
        sudo install -dm 0755 /etc/apt/keyrings
        wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        sudo apt-get update -qq
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh
    ok "installed gh"
else
    skip 'gh'
fi

# 3. chezmoi (user-scope)
mkdir -p "$HOME/.local/bin"
if [ ! -x "$HOME/.local/bin/chezmoi" ] && ! cmd_exists chezmoi; then
    curl -fsLS https://get.chezmoi.io | bash -s -- -b "$HOME/.local/bin" >/dev/null
    ok "installed chezmoi"
else
    skip 'chezmoi'
fi
export PATH="$HOME/.local/bin:$PATH"
CHEZMOI="$(command -v chezmoi || echo "$HOME/.local/bin/chezmoi")"

# 4. pwsh (user-scope tarball; needed for the rich audit-and-diff.ps1)
if ! cmd_exists pwsh && [ ! -x "$HOME/.local/share/powershell/pwsh" ]; then
    PWSH_VER="${PWSH_VER:-7.4.6}"
    mkdir -p "$HOME/.local/share/powershell"
    curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VER}/powershell-${PWSH_VER}-linux-x64.tar.gz" \
        | tar -xzf - -C "$HOME/.local/share/powershell"
    chmod +x "$HOME/.local/share/powershell/pwsh"
    ln -sf "$HOME/.local/share/powershell/pwsh" "$HOME/.local/bin/pwsh"
    ok "installed pwsh"
else
    skip 'pwsh'
fi
PWSH="$(command -v pwsh || echo "$HOME/.local/bin/pwsh")"

# 5. bun
if ! cmd_exists bun && [ ! -x "$HOME/.bun/bin/bun" ]; then
    curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1
    ok "installed bun"
else
    skip 'bun'
fi
export PATH="$HOME/.bun/bin:$PATH"
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"

# 6. Claude Code CLI
if ! cmd_exists claude; then
    "$BUN" install -g @anthropic-ai/claude-code >/dev/null 2>&1 || warn 'claude-code install non-zero'
    export PATH="$HOME/.bun/bin:$PATH"
    ok "installed Claude Code CLI"
else
    skip 'Claude Code CLI'
fi

# 7. gh auth
if ! gh auth status >/dev/null 2>&1; then
    section 'gh auth login --web (browser flow)'
    gh auth login --web --hostname github.com --git-protocol https
    ok 'gh authenticated'
else
    skip 'gh authenticated'
fi

# 8. clone or update private dotfiles repo
SRC="$HOME/.local/share/chezmoi"
WAS_FRESH=0
if [ ! -d "$SRC/.git" ]; then
    WAS_FRESH=1
    section "Cloning $REPO_SLUG -> $SRC"
    mkdir -p "$(dirname "$SRC")"
    gh repo clone "$REPO_SLUG" "$SRC" >/dev/null 2>&1 || fail "gh repo clone failed (check access)"
    ok 'cloned'
else
    skip "dotfiles already at $SRC"
    git -C "$SRC" fetch --quiet
    git -C "$SRC" pull --ff-only --quiet
    ok 'pulled latest'
fi

# ============================================================================
# Phase 2 - inspect machine state
# ============================================================================

section 'Machine state inspection'

# Drift size via chezmoi status
DRIFT_LINES=$("$CHEZMOI" --source "$SRC" status 2>/dev/null | grep -c . || true)
[ -z "$DRIFT_LINES" ] && DRIFT_LINES=0

# Claude Code auth state
if [ -f "$HOME/.claude/.credentials.json" ]; then CLAUDE_AUTHED=1; else CLAUDE_AUTHED=0; fi

# Recommended mode
if [ "$WAS_FRESH" = "1" ]; then
    RECOMMENDED='full'
else
    RECOMMENDED='audit'
fi

# Render inspection panel
field 'Host'         "$(hostname) ($(uname -srm))"
field 'User'         "$USER"
field 'Chezmoi'      "$("$CHEZMOI" --version)"
field 'Source dir'   "$SRC"
field 'Repo state'   "$([ "$WAS_FRESH" = "1" ] && printf '%s(just cloned, never applied)%s' "$YEL" "$RST" || printf '%s(present)%s' "$GRN" "$RST")"
field 'Drift'        "$([ "$DRIFT_LINES" = "0" ] && printf '%s0 changes - in sync%s' "$GRN" "$RST" || printf '%s%s file(s) differ%s' "$YEL" "$DRIFT_LINES" "$RST")"
field 'gh auth'      "$(printf '%s(ready)%s' "$GRN" "$RST")"
field 'Claude Code'  "$([ "$CLAUDE_AUTHED" = "1" ] && printf '%s(authed)%s' "$GRN" "$RST" || printf '%s(installed; run claude once for auth)%s' "$YEL" "$RST")"

# ============================================================================
# Phase 3 - rich path picker
# ============================================================================

section 'Decision'

printf '\n  %s%s  Recommended mode: %s%s\n' "$BOLD" "$GRN" "$(printf '%s' "$RECOMMENDED" | tr a-z A-Z)" "$RST"
printf '\n'
printf '  %s    a%s | %saudit%s  - read-only; produces report.html and items.json\n' "$DIM" "$RST" "$BOLD" "$RST"
printf '  %s    p%s | %sapply%s  - audit + `chezmoi apply` (overwrites any drift in managed files)\n' "$DIM" "$RST" "$BOLD" "$RST"
printf '  %s    f%s | %sfull%s   - apply + toolchain + ssh-agent + WSL bootstrap\n' "$DIM" "$RST" "$BOLD" "$RST"
printf '  %s    x%s | %sexit%s   - stop here\n' "$DIM" "$RST" "$BOLD" "$RST"
printf '\n'

# Resolve mode
if [ -n "$MODE" ]; then
    printf '  %s(MODE env var set: %s)%s\n' "$DIM" "$MODE" "$RST"
elif [ "$YES" = "1" ]; then
    MODE="$RECOMMENDED"
    printf '  %s(YES=1; defaulting to recommended)%s\n' "$DIM" "$RST"
else
    printf '  Press [Enter] for %s%s%s, or type a/p/f/x to override -> ' "$BOLD" "$RECOMMENDED" "$RST"
    read -r resp
    resp=$(echo "$resp" | tr A-Z a-z | xargs)
    case "$resp" in
        '')                MODE="$RECOMMENDED" ;;
        a|audit)           MODE='audit' ;;
        p|apply)           MODE='apply' ;;
        f|full)            MODE='full'  ;;
        x|exit|q|quit)     MODE='exit'  ;;
        *)                 warn "Unrecognised '$resp'; defaulting to $RECOMMENDED"; MODE="$RECOMMENDED" ;;
    esac
fi

if [ "$MODE" = 'exit' ]; then printf '  Stopped on request.\n'; exit 0; fi

printf '\n  %s%s> Running mode: %s%s\n\n' "$BOLD" "$MAG" "$MODE" "$RST"

# ============================================================================
# Phase 4 - dispatch
# ============================================================================

REPO_URL="https://github.com/${REPO_SLUG}.git"
AUDIT_PS1="$SRC/scripts/audit-and-diff.ps1"
BOOTSTRAP_SH="$SRC/scripts/bootstrap.sh"

case "$MODE" in
    audit)
        section 'Running audit-and-diff.ps1 (via pwsh)'
        "$PWSH" -NoProfile -File "$AUDIT_PS1" || true
        ;;
    apply)
        section 'Running audit-and-diff.ps1 (via pwsh)'
        "$PWSH" -NoProfile -File "$AUDIT_PS1" || true
        if [ "$YES" != "1" ]; then
            printf '\n  About to run %s`chezmoi apply --force`%s. Any drifted managed file will be overwritten. Proceed? [y/N] ' "$YEL" "$RST"
            read -r c
            case "$c" in y|Y|yes) : ;; *) warn 'Aborted; the audit report remains in audit-output-*.'; exit 0 ;; esac
        fi
        section 'chezmoi apply --force'
        "$CHEZMOI" --source "$SRC" apply --force
        ok 'applied'
        ;;
    full)
        section 'Running scripts/bootstrap.sh (full toolchain + apply)'
        RepoUrl="$REPO_URL" bash "$BOOTSTRAP_SH"
        ;;
esac

# ============================================================================
# Phase 5 - close-out
# ============================================================================

section 'Done'
if [ "$CLAUDE_AUTHED" != "1" ]; then
    printf '\n'
    printf '  %s[!!]  Claude Code is installed but NOT authenticated.%s\n' "$YEL" "$RST"
    printf '       Run `claude` once in any terminal for the browser auth flow.\n'
    printf '       After that, the dotfiles-incorporate skill works end-to-end.\n'
    printf '\n'
fi

printf '  Re-run any time:\n'
printf '    %scurl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/dotfiles.sh | bash%s\n' "$BOLD" "$RST"
printf '\n'
