# dotfiles-bootstrap

Public launchers for [slamb2k/dotfiles](https://github.com/slamb2k/dotfiles)
(the actual dotfiles repo is private).

The chicken-and-egg problem: you can't `gh repo clone` a private repo on a
fresh machine because `gh` isn't installed and you're not authenticated yet.
Hosting the small bootstrap launcher on a public repo — separate from the
secrets-bearing dotfiles content — solves that without exposing the rest.

## One-line install

### Windows 11 (PowerShell or pwsh)

```powershell
iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/install.ps1 | iex
```

### Linux / WSL2 Ubuntu

```bash
curl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/install.sh | bash
```

That's it. Each launcher is ~80 lines, fetches its single counterpart, and
walks you through the install. You'll see a browser tab for `gh auth login`
midway — copy the one-time code from the terminal into the browser.

## What it actually does

1. **Verify prerequisites** (winget on Windows, apt on Linux).
2. **Install** the absolute minimum:  `gh`, `chezmoi`, `git` (Windows) /
   `gh`, `git`, `curl`, `chezmoi` (Linux).
3. **Authenticate** to GitHub via `gh auth login --web` (interactive).
4. **Clone** [slamb2k/dotfiles](https://github.com/slamb2k/dotfiles) into
   chezmoi's source dir.
5. **Hand off** to the dotfiles repo's own `scripts/bootstrap.{ps1,sh}` which
   does the substantive work:
   - `chezmoi init --apply`
   - Optional toolchain (Claude desktop, bun, starship, fzf, ripgrep, fd, bat,
     zoxide, gsudo, pwsh 7, Windows Terminal, VS Code, Bitwarden — Linux side
     gets the apt-installable equivalents)
   - WSL bootstrap (Windows side): installs Ubuntu, runs `bootstrap.sh` inside
   - Configures `ssh-agent` (Windows side, via gsudo)
   - Runs the in-repo `audit-and-diff.ps1` so you see the resulting state

## Pass-through arguments

Both launchers accept the same flags as the private repo's bootstrap:

```powershell
# Windows: skip the optional toolchain (faster; chezmoi-only)
iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/install.ps1 | iex
# (then re-run with -Minimal flag if needed; or use option 2 below)

# Linux: skip the optional toolchain
curl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/install.sh | MINIMAL=1 bash
```

To pass flags to the Windows launcher when invoked via `iwr | iex`, download
first then invoke:

```powershell
$tmp = "$env:TEMP\install.ps1"
iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/install.ps1 -OutFile $tmp
& $tmp -Minimal -SkipWsl
Remove-Item $tmp
```

## Safety

- **You're trusting this URL** to install software and write dotfiles. Read
  [`install.ps1`](install.ps1) and [`install.sh`](install.sh) before running.
  They're short.
- The launchers themselves don't contain secrets and never download anything
  outside official sources (winget, apt, get.chezmoi.io, your private repo
  clone via gh).
- The private dotfiles repo can't be cloned without your GitHub credentials —
  this repo just bootstraps the *path* to that clone.
- All `chezmoi` operations are idempotent. Re-running the one-liner on an
  already-configured machine pulls the latest dotfiles and re-applies; it
  doesn't reinstall packages that are already current.

## Layout

```
.
├── install.ps1     # Windows launcher (PowerShell)
├── install.sh      # Linux/WSL launcher (bash)
└── README.md       # this file
```

## License

MIT.
