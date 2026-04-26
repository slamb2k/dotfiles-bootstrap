#!/usr/bin/env bash
#
# audit.sh - one-line read-only audit launcher.
#
# Invoke:
#   curl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/audit.sh | bash
#
# Strictly read-only against system state. Will install gh + chezmoi if
# missing, authenticate with GitHub if necessary, and ensure the private
# dotfiles repo is cloned at ~/.local/share/chezmoi. Then runs
# scripts/audit-and-diff.ps1 (via pwsh if available) OR prints WSL diff
# directly. Never applies chezmoi changes.

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

# 5. run the audit
section 'running chezmoi diff'
chezmoi diff --no-tty 2>/dev/null || chezmoi diff || true

# Bonus: if pwsh is around, run the full PS audit script too
if cmd_exists pwsh; then
    section 'running scripts/audit-and-diff.ps1 via pwsh'
    pwsh -File "$SRC/scripts/audit-and-diff.ps1" -SkipWsl || true
else
    cat <<EOF

The full markdown audit (audit-and-diff.ps1) is PowerShell-only. To run it
from Linux, install pwsh:

    sudo apt install -y wget apt-transport-https software-properties-common
    wget -q https://packages.microsoft.com/config/ubuntu/\$(lsb_release -rs)/packages-microsoft-prod.deb
    sudo dpkg -i packages-microsoft-prod.deb
    sudo apt update && sudo apt install -y powershell

Or just run it from a Windows shell - it covers WSL too.

EOF
fi

ok 'audit complete; no system state modified beyond gh+chezmoi installs'
