#!/usr/bin/env bash
#
# dotfiles.sh - unified one-liner launcher for slamb2k/dotfiles.
#
# Invoke:
#   curl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/dotfiles.sh | bash
#
# Default behaviour: smart auto-detect based on machine state.
#   - Fresh machine          -> mode = full
#   - Existing with drift    -> mode = audit
#   - Existing fully aligned -> mode = audit (no-op)
#
# Override with the MODE env var, or pick interactively from the menu.

set -euo pipefail

REPO_SLUG="${RepoSlug:-slamb2k/dotfiles}"
MODE="${MODE:-}"
YES="${YES:-0}"

# ----- ANSI helpers ---------------------------------------------------------

esc() { printf '\033[%sm' "$1"; }
RST=$(esc 0); BOLD=$(esc 1); DIM=$(esc 2); INVERT=$(esc 7)
RED=$(esc 31); GRN=$(esc 32); YEL=$(esc 33); CYN=$(esc 36); MAG=$(esc 35)

hlink() {
    local path="$1" text="${2:-$1}" abs uri
    abs="$(readlink -f -- "$path" 2>/dev/null || echo "$path")"
    uri="file://$abs"
    printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$uri" "$text"
}

section() { printf '\n%s%s==>%s %s%s%s\n' "$BOLD" "$CYN" "$RST" "$BOLD" "$1" "$RST"; }
field()   { printf '  %s%-22s%s %s\n' "$DIM" "$1" "$RST" "$2"; }
ok()      { printf '  %s[OK]%s   %s\n'   "$GRN" "$RST" "$1"; }
warn()    { printf '  %s[!!]%s   %s\n'   "$YEL" "$RST" "$1"; }
fail()    { printf '  %s[FAIL]%s %s\n'   "$RED" "$RST" "$1"; exit 1; }
skip()    { printf '  %s[skip] %s%s\n'   "$DIM" "$1"   "$RST"; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

TTY=0
if [ -t 0 ] || [ ! -e /dev/tty ]; then : ; else exec </dev/tty; fi
if [ -t 0 ] || [ -t 1 ]; then TTY=1; fi

# ----- ASCII banner ---------------------------------------------------------

show_banner() {
    printf '\n'
    printf '  %s██████╗  ██████╗ ████████╗███████╗██╗██╗     ███████╗███████╗%s\n' "$CYN" "$RST"
    printf '  %s██╔══██╗██╔═══██╗╚══██╔══╝██╔════╝██║██║     ██╔════╝██╔════╝%s\n' "$CYN" "$RST"
    printf '  %s██║  ██║██║   ██║   ██║   █████╗  ██║██║     █████╗  ███████╗%s\n' "$CYN" "$RST"
    printf '  %s██║  ██║██║   ██║   ██║   ██╔══╝  ██║██║     ██╔══╝  ╚════██║%s\n' "$CYN" "$RST"
    printf '  %s██████╔╝╚██████╔╝   ██║   ██║     ██║███████╗███████╗███████║%s\n' "$CYN" "$RST"
    printf '  %s╚═════╝  ╚═════╝    ╚═╝   ╚═╝     ╚═╝╚══════╝╚══════╝╚══════╝%s\n' "$CYN" "$RST"
    printf '  %sslamb2k/dotfiles · unified launcher · audit · apply · full%s\n\n' "$DIM" "$RST"
}

# ----- Spinner --------------------------------------------------------------

with_spinner() {
    local msg="$1"; shift
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local n=${#frames}
    "$@" >/dev/null 2>&1 &
    local pid=$!
    local i=0
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        local f="${frames:$((i % n)):1}"
        printf '\r  %s%s%s %s  ' "$CYN" "$f" "$RST" "$msg"
        sleep 0.08
        i=$((i + 1))
    done
    wait "$pid"
    local rc=$?
    tput cnorm 2>/dev/null || true
    printf '\r'
    if [ "$rc" = "0" ]; then
        printf '  %s[OK]%s   %s%s\n' "$GRN" "$RST" "$msg" "$(printf ' %.0s' {1..40})"
    else
        printf '  %s[fail]%s %s\n' "$RED" "$RST" "$msg"
    fi
    return $rc
}

# ----- Menu (arrow keys via tty + ANSI cursor; numbered fallback) -----------

choose_mode() {
    local default="$1"; shift
    local opts=("$@")
    local i=0 idx=0
    local labels=() summaries=()
    for entry in "${opts[@]}"; do
        local name="${entry%%|*}"
        local desc="${entry#*|}"
        labels+=("$name")
        summaries+=("$desc")
        if [ "$name" = "$default" ]; then idx=$i; fi
        i=$((i + 1))
    done

    if [ "$TTY" != "1" ]; then
        # Numbered fallback (curl|bash without TTY)
        for j in "${!labels[@]}"; do
            local marker='  '
            if [ "${labels[$j]}" = "$default" ]; then marker="$GRN>$RST "; fi
            printf '  %s[%d] %s%s%s %s%s%s\n' "$marker" "$((j + 1))" "$BOLD" "${labels[$j]}" "$RST" "$DIM" "${summaries[$j]}" "$RST"
        done
        printf '\n  Press [Enter] for %s%s%s or pick 1-%d: ' "$BOLD" "$default" "$RST" "${#labels[@]}"
        read -r resp
        if [ -z "$resp" ]; then printf '%s\n' "$default"; return 0; fi
        if [[ "$resp" =~ ^[0-9]+$ ]] && [ "$resp" -ge 1 ] && [ "$resp" -le "${#labels[@]}" ]; then
            printf '%s\n' "${labels[$((resp - 1))]}"; return 0
        fi
        for l in "${labels[@]}"; do
            case "$l" in "$resp"*|"${resp,,}"*) printf '%s\n' "$l"; return 0 ;; esac
        done
        printf '%s\n' "$default"
        return 0
    fi

    # Arrow-key menu
    tput civis 2>/dev/null || true
    local nlines=$(( ${#labels[@]} + 2 ))
    for _ in $(seq 1 $nlines); do printf '\n'; done
    printf '\033[%dA' $nlines

    local key
    while true; do
        printf '\033[s'
        for j in "${!labels[@]}"; do
            local marker='   '
            local prefix=""
            local suffix="$RST"
            if [ "$j" = "$idx" ]; then
                marker="$GRN▸$RST "
                prefix="$BOLD$INVERT "
                suffix=" $RST"
            fi
            printf '  %s %s%s%s  %s%s%s\033[K\n' "$marker" "$prefix" "${labels[$j]}" "$suffix" "$DIM" "${summaries[$j]}" "$RST"
        done
        printf '\n  %s(arrow keys, Enter to select, x/Esc to exit)%s\033[K' "$DIM" "$RST"
        printf '\033[u'

        IFS= read -rsn1 key
        if [ "$key" = $'\033' ]; then
            IFS= read -rsn1 -t 0.05 key2 || key2=''
            if [ "$key2" = "[" ]; then
                IFS= read -rsn1 key3
                case "$key3" in
                    A) idx=$(( (idx - 1 + ${#labels[@]}) % ${#labels[@]} )) ;;
                    B) idx=$(( (idx + 1) % ${#labels[@]} )) ;;
                esac
            else
                tput cnorm 2>/dev/null || true
                printf '\033[%dB\n' $nlines
                printf '%s\n' 'exit'
                return 0
            fi
        elif [ -z "$key" ] || [ "$key" = $'\n' ] || [ "$key" = $'\r' ]; then
            tput cnorm 2>/dev/null || true
            printf '\033[%dB\n' $nlines
            printf '%s\n' "${labels[$idx]}"
            return 0
        elif [ "$key" = "x" ] || [ "$key" = "q" ]; then
            tput cnorm 2>/dev/null || true
            printf '\033[%dB\n' $nlines
            printf '%s\n' 'exit'
            return 0
        else
            for j in "${!labels[@]}"; do
                if [[ "${labels[$j]}" == "$key"* ]]; then idx=$j; break; fi
            done
        fi
    done
}

# ============================================================================
# Phase 0 - banner
# ============================================================================

show_banner

# ============================================================================
# Phase 1 - init / prereqs
# ============================================================================

section 'Init phase'

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
    ok 'installed gh'
else
    skip 'gh'
fi

# 3. chezmoi (user-scope)
mkdir -p "$HOME/.local/bin"
if [ ! -x "$HOME/.local/bin/chezmoi" ] && ! cmd_exists chezmoi; then
    curl -fsLS https://get.chezmoi.io | bash -s -- -b "$HOME/.local/bin" >/dev/null
    ok 'installed chezmoi'
else
    skip 'chezmoi'
fi
export PATH="$HOME/.local/bin:$PATH"
CHEZMOI="$(command -v chezmoi || echo "$HOME/.local/bin/chezmoi")"

# 4. pwsh user-scope (for the rich audit-and-diff.ps1)
if ! cmd_exists pwsh && [ ! -x "$HOME/.local/share/powershell/pwsh" ]; then
    PWSH_VER="${PWSH_VER:-7.4.6}"
    mkdir -p "$HOME/.local/share/powershell"
    curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VER}/powershell-${PWSH_VER}-linux-x64.tar.gz" \
        | tar -xzf - -C "$HOME/.local/share/powershell"
    chmod +x "$HOME/.local/share/powershell/pwsh"
    ln -sf "$HOME/.local/share/powershell/pwsh" "$HOME/.local/bin/pwsh"
    ok 'installed pwsh'
else
    skip 'pwsh'
fi
PWSH="$(command -v pwsh || echo "$HOME/.local/bin/pwsh")"

# 5. bun
if ! cmd_exists bun && [ ! -x "$HOME/.bun/bin/bun" ]; then
    curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1
    ok 'installed bun'
else
    skip 'bun'
fi
export PATH="$HOME/.bun/bin:$PATH"
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"

# 6. Claude Code CLI
if ! cmd_exists claude; then
    "$BUN" install -g @anthropic-ai/claude-code >/dev/null 2>&1 || warn 'claude-code install non-zero'
    export PATH="$HOME/.bun/bin:$PATH"
    ok 'installed Claude Code CLI'
else
    skip 'Claude Code CLI'
fi

# 7. gh auth
if ! gh auth status >/dev/null 2>&1; then
    section 'gh auth login --web'
    gh auth login --web --hostname github.com --git-protocol https
    ok 'gh authenticated'
else
    skip 'gh authenticated'
fi

# 8. Clone or update private dotfiles repo
SRC="$HOME/.local/share/chezmoi"
WAS_FRESH=0
if [ ! -d "$SRC/.git" ]; then
    WAS_FRESH=1
    section "Cloning $REPO_SLUG -> $SRC"
    mkdir -p "$(dirname "$SRC")"
    gh repo clone "$REPO_SLUG" "$SRC" >/dev/null 2>&1 || fail "gh repo clone failed"
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

section 'Machine state'

DRIFT_LINES=$("$CHEZMOI" --source "$SRC" status 2>/dev/null | grep -c . || true)
[ -z "$DRIFT_LINES" ] && DRIFT_LINES=0
[ -f "$HOME/.claude/.credentials.json" ] && CLAUDE_AUTHED=1 || CLAUDE_AUTHED=0

if [ "$WAS_FRESH" = "1" ]; then RECOMMENDED='full'; else RECOMMENDED='audit'; fi

field 'Host'         "$(hostname) ($(uname -srm))"
field 'User'         "$USER"
field 'Chezmoi'      "$("$CHEZMOI" --version)"
field 'Source dir'   "$(hlink "$SRC")"
field 'Repo state'   "$([ "$WAS_FRESH" = "1" ] && printf '%s(just cloned, never applied)%s' "$YEL" "$RST" || printf '%s(present)%s' "$GRN" "$RST")"
field 'Drift'        "$([ "$DRIFT_LINES" = "0" ] && printf '%s0 changes - in sync%s' "$GRN" "$RST" || printf '%s%s file(s) differ%s' "$YEL" "$DRIFT_LINES" "$RST")"
field 'gh auth'      "$(printf '%s(ready)%s' "$GRN" "$RST")"
field 'Claude Code'  "$([ "$CLAUDE_AUTHED" = "1" ] && printf '%s(authed)%s' "$GRN" "$RST" || printf '%s(installed; run claude once for auth)%s' "$YEL" "$RST")"

# ============================================================================
# Phase 3 - mode picker
# ============================================================================

section 'Choose mode'

printf '\n  %s%s▸ Recommended: %s%s\n\n' "$BOLD" "$GRN" "$(printf '%s' "$RECOMMENDED" | tr a-z A-Z)" "$RST"

if [ -n "$MODE" ]; then
    printf '  %s(MODE env var set: %s)%s\n' "$DIM" "$MODE" "$RST"
elif [ "$YES" = "1" ]; then
    MODE="$RECOMMENDED"
    printf '  %s(YES=1; defaulting to recommended)%s\n' "$DIM" "$RST"
else
    MODE=$(choose_mode "$RECOMMENDED" \
        "audit|read-only; produces report.html and items.json" \
        "apply|audit + chezmoi apply (overwrites drifted managed files)" \
        "full|apply + extended toolchain + ssh-agent + WSL bootstrap" \
        "exit|stop here")
fi

if [ "$MODE" = 'exit' ]; then printf '\n  Stopped on request.\n'; exit 0; fi

printf '\n  %s%s▶ Running mode: %s%s\n\n' "$BOLD" "$MAG" "$MODE" "$RST"

# ============================================================================
# Phase 4 - dispatch
# ============================================================================

REPO_URL="https://github.com/${REPO_SLUG}.git"
AUDIT_PS1="$SRC/scripts/audit-and-diff.ps1"
BOOTSTRAP_SH="$SRC/scripts/bootstrap.sh"

case "$MODE" in
    audit)
        section 'Running audit (via pwsh)'
        "$PWSH" -NoProfile -File "$AUDIT_PS1" || true
        ;;
    apply)
        section 'Running audit (via pwsh)'
        "$PWSH" -NoProfile -File "$AUDIT_PS1" || true
        if [ "$YES" != "1" ]; then
            printf '\n  About to run %s`chezmoi apply --force`%s. Drifted managed files will be overwritten. Proceed? [y/N] ' "$YEL" "$RST"
            read -r c
            case "$c" in y|Y|yes) : ;; *) warn 'Aborted; the audit report remains.'; exit 0 ;; esac
        fi
        section 'chezmoi apply --force'
        "$CHEZMOI" --source "$SRC" apply --force
        ok 'applied'
        ;;
    full)
        section 'Running scripts/bootstrap.sh'
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
fi
printf '\n  Re-run any time:\n'
printf '    %scurl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/dotfiles.sh | bash%s\n\n' "$BOLD" "$RST"
