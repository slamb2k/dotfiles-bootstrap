#!/usr/bin/env bash
#
# audit.sh - one-line read-only audit launcher.
#
# Invoke:
#   curl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/audit.sh | bash
#
# Strictly read-only against system state. Init phase ensures the
# prerequisites (gh, chezmoi, pwsh, bun, Claude Code CLI - all user-scope)
# are in place and gh is authenticated. Then runs scripts/audit-and-diff.ps1
# to produce the same rich markdown + HTML + items.json artefacts as the
# Windows path. Never applies chezmoi changes.
#
# Why install Claude Code in the audit launcher? Because the natural
# follow-up to the audit is the dotfiles-incorporate skill executing the
# user's decisions. Having Claude Code present and authed by the time
# audit finishes means no second prereq round-trip.

set -euo pipefail

REPO_SLUG="${RepoSlug:-slamb2k/dotfiles}"

section() { printf '\n==> %s\n' "$*"; }
ok()      { printf '    [OK]   %s\n' "$*"; }
skip()    { printf '    [skip] %s\n' "$*"; }
fail()    { printf '    [FAIL] %s\n' "$*"; exit 1; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }
if [ -t 0 ] || [ ! -e /dev/tty ]; then : ; else exec </dev/tty; fi

section 'audit.sh: read-only audit launcher'

# 1. apt deps (idempotent)
need=()
for p in git curl ca-certificates wget; do
    dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
done
if [ ${#need[@]} -gt 0 ]; then
    section "apt install ${need[*]}"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
else
    skip 'apt deps already present'
fi

# 2. gh CLI (install if missing)
if ! cmd_exists gh; then
    section 'install gh CLI'
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
fi

# 3. chezmoi (user-scope, no sudo)
mkdir -p "$HOME/.local/bin"
if [ ! -x "$HOME/.local/bin/chezmoi" ] && ! cmd_exists chezmoi; then
    section 'install chezmoi -> ~/.local/bin'
    curl -fsLS https://get.chezmoi.io | bash -s -- -b "$HOME/.local/bin"
fi
export PATH="$HOME/.local/bin:$PATH"

# 4. clone if needed
SRC="$HOME/.local/share/chezmoi"
if [ ! -d "$SRC/.git" ]; then
    if ! gh auth status >/dev/null 2>&1; then
        section 'gh auth login --web (needed to clone private dotfiles)'
        gh auth login --web --hostname github.com --git-protocol https
    fi
    section "Cloning $REPO_SLUG -> $SRC (read-only fetch; no chezmoi apply)"
    mkdir -p "$(dirname "$SRC")"
    gh repo clone "$REPO_SLUG" "$SRC"
else
    section "Updating $SRC (no apply)"
    git -C "$SRC" fetch --quiet
    git -C "$SRC" pull --ff-only
fi
ok 'dotfiles source available'

# 5. install pwsh user-scope if missing (needed for the rich audit)
if ! cmd_exists pwsh && [ ! -x "$HOME/.local/share/powershell/pwsh" ]; then
    section 'install pwsh (user-scope tarball, no sudo)'
    PWSH_VER="${PWSH_VER:-7.4.6}"
    mkdir -p "$HOME/.local/share/powershell"
    curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VER}/powershell-${PWSH_VER}-linux-x64.tar.gz" \
        | tar -xzf - -C "$HOME/.local/share/powershell"
    chmod +x "$HOME/.local/share/powershell/pwsh"
    ln -sf "$HOME/.local/share/powershell/pwsh" "$HOME/.local/bin/pwsh"
    ok "pwsh installed at ~/.local/share/powershell/pwsh"
fi
PWSH="$(command -v pwsh || echo "$HOME/.local/bin/pwsh")"

# 6. install bun (gateway for Claude Code CLI)
if ! cmd_exists bun && [ ! -x "$HOME/.bun/bin/bun" ]; then
    section 'install bun'
    curl -fsSL https://bun.sh/install | bash
fi
export PATH="$HOME/.bun/bin:$PATH"
BUN="${BUN:-$HOME/.bun/bin/bun}"

# 7. install Claude Code CLI (required for the dotfiles-incorporate skill)
section 'install Claude Code CLI via bun'
"$BUN" install -g @anthropic-ai/claude-code 2>&1 | tail -2 || warn 'claude-code install failed'

# 8. check Claude Code auth (interactive; user does this once)
if [ ! -f "$HOME/.claude/.credentials.json" ]; then
    printf '\n'
    printf '    *** Claude Code is INSTALLED but NOT AUTHENTICATED ***\n'
    printf '    After this audit finishes, run `claude` once in any terminal\n'
    printf '    to do the browser auth flow. Then the audit -> incorporate skill works.\n'
    printf '\n'
else
    ok 'Claude Code authenticated'
fi

# 9. run the rich audit (cross-platform PowerShell script)
section "running scripts/audit-and-diff.ps1 via pwsh"
"$PWSH" -NoProfile -File "$SRC/scripts/audit-and-diff.ps1" || true

ok 'audit complete; no system state modified beyond user-scope tool installs'
echo
echo "Open the HTML report in your browser:"
echo "  xdg-open ./audit-output-*/report.html   # or just navigate to the file"
echo
echo "Then in Claude Code:  \"execute decisions.json from <path>\""
