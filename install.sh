#!/usr/bin/env bash
#
# install.sh - one-line launcher for a fresh Linux / WSL2 Ubuntu machine.
#
# Invoke (paste in any bash/zsh shell):
#
#     curl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/install.sh | bash
#
# What it does:
#   1. apt install: git, curl, ca-certificates, wget.
#   2. Adds the GitHub CLI apt source (if not present) and installs `gh`.
#   3. gh auth login --web   (interactive; reads from /dev/tty).
#   4. Installs chezmoi to ~/.local/bin (no sudo).
#   5. gh repo clone slamb2k/dotfiles -> ~/.local/share/chezmoi
#   6. Hands off to the private dotfiles repo's scripts/bootstrap.sh
#      which does the rest (chezmoi apply, optional toolchain, /etc/wsl.conf hint).
#
# Read-only against system state until step 1. Steps 1/2/4/5/6 install software
# and modify ~ -- only run if you trust this URL.

set -euo pipefail

REPO_SLUG="${RepoSlug:-slamb2k/dotfiles}"
MINIMAL="${MINIMAL:-0}"

section() { printf '\n==> %s\n' "$*"; }
ok()      { printf '    [OK]   %s\n' "$*"; }
fail()    { printf '    [FAIL] %s\n' "$*"; exit 1; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# When invoked via curl|bash, stdin is the script - bind tty for interactive prompts.
if [ -t 0 ] || [ ! -e /dev/tty ]; then : ; else exec </dev/tty; fi

section 'install.sh: fresh-Linux launcher for slamb2k/dotfiles'

# 1. apt deps
section 'apt install git curl ca-certificates wget'
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates wget

# 2. gh CLI (use official apt source for latest; fall back to universe if blocked)
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
ok "gh: $(gh --version | head -1)"

# 3. gh auth
if gh auth status >/dev/null 2>&1; then
    ok 'gh already authenticated'
else
    section 'gh auth login --web'
    gh auth login --web --hostname github.com --git-protocol https
fi

# 4. chezmoi (user-scope, no sudo)
mkdir -p "$HOME/.local/bin"
if [ ! -x "$HOME/.local/bin/chezmoi" ]; then
    section 'install chezmoi -> ~/.local/bin'
    curl -fsLS https://get.chezmoi.io | bash -s -- -b "$HOME/.local/bin"
fi
export PATH="$HOME/.local/bin:$PATH"
ok "chezmoi: $("$HOME/.local/bin/chezmoi" --version)"

# 5. clone private dotfiles
SRC="$HOME/.local/share/chezmoi"
if [ -d "$SRC/.git" ]; then
    section "Existing chezmoi source at $SRC - pulling latest"
    git -C "$SRC" pull --ff-only
else
    section "Cloning $REPO_SLUG -> $SRC"
    mkdir -p "$(dirname "$SRC")"
    gh repo clone "$REPO_SLUG" "$SRC"
fi
ok 'dotfiles repo present'

# 6. hand off to the private repo's full bootstrap
BOOTSTRAP="$SRC/scripts/bootstrap.sh"
[ -f "$BOOTSTRAP" ] || fail "$BOOTSTRAP missing - the private dotfiles repo doesn't include scripts/bootstrap.sh"

section 'launching scripts/bootstrap.sh...'
RepoUrl="https://github.com/$REPO_SLUG.git" MINIMAL="$MINIMAL" bash "$BOOTSTRAP"
