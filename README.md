# dotfiles-bootstrap

Public launcher for [slamb2k/dotfiles](https://github.com/slamb2k/dotfiles)
(the actual dotfiles repo is private).

The chicken-and-egg problem: you can't `gh repo clone` a private repo on a
fresh machine because `gh` isn't installed and you're not authenticated yet.
Hosting a small launcher on a public repo — separate from the secrets-bearing
dotfiles — solves that without exposing the rest.

## One-line install

### Windows 11 (PowerShell or pwsh)

```powershell
iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/dotfiles.ps1 | iex
```

### Linux / WSL2 Ubuntu

```bash
curl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/dotfiles.sh | bash
```

That's it. One URL per platform. The launcher inspects the machine, picks the
right path automatically, and asks before doing anything destructive.

## What the launcher does

```
+-----------------------------------------------------------------------------+
|  Phase 1 - init / prereqs (always)                                          |
|    - winget/apt: gh, chezmoi, git                                           |
|    - bun.sh: bun                                                            |
|    - bun install -g @anthropic-ai/claude-code                               |
|    - pwsh user-scope tarball (Linux only)                                   |
|    - gh auth login --web (browser flow if not cached)                       |
|    - gh repo clone slamb2k/dotfiles  ->  ~/.local/share/chezmoi             |
+-----------------------------------------------------------------------------+
|  Phase 2 - inspect machine state                                            |
|    - chezmoi status (drift count)                                           |
|    - Claude Code auth presence                                              |
|    - Enterprise sniff (Azure AD / Workplace join)                           |
+-----------------------------------------------------------------------------+
|  Phase 3 - rich TUI: shows recommended mode + override options              |
|    Recommended is auto-derived from machine state:                          |
|      fresh machine          -> full                                         |
|      existing with drift    -> audit                                        |
|      existing fully aligned -> audit (will be a no-op)                      |
|    Press [Enter] to accept, or type a/p/f/x to override.                    |
+-----------------------------------------------------------------------------+
|  Phase 4 - dispatch into chosen mode                                        |
|    audit  -> scripts/audit-and-diff.ps1   (read-only; report.html + JSON)   |
|    apply  -> audit + chezmoi apply --force (with confirm)                   |
|    full   -> scripts/bootstrap.{ps1,sh} (apply + toolchain + ssh + WSL)     |
|    exit   -> stop here                                                      |
+-----------------------------------------------------------------------------+
|  Phase 5 - close-out                                                        |
|    Yellow warning if `claude` hasn't been auth'd yet (interactive,          |
|    user does it once).                                                      |
+-----------------------------------------------------------------------------+
```

## Modes

| Mode | What it does | Safe on a corp laptop? |
|---|---|---|
| **audit** | Init phase, then runs the cross-platform `audit-and-diff.ps1`. Produces `report.html`, `report.md`, `items.json` + raw dumps. **Never modifies dotfiles.** | Yes |
| **apply** | Audit, then `chezmoi apply --force`. **Overwrites any drifted managed file** in `$HOME` with the repo version. Confirm prompt before applying. | Caution — review the audit first |
| **full** | Apply, plus extended toolchain (Claude Desktop, Cursor, jq/yq/delta/mise, fzf/rg/fd/bat/zoxide, gsudo, PowerToys, Bitwarden), ssh-agent enable (Windows), Defender exclusions (Windows), WSL bootstrap (Windows). Auto-blocked on detected enterprise machines unless you confirm. | No — refused on enterprise-managed devices unless overridden |

## Override

Skip the smart-default detection by setting `MODE` before invocation:

```powershell
# Windows
$env:MODE = 'audit'   # or 'apply' or 'full'
iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/dotfiles.ps1 | iex

# Or download + invoke with parameters:
$tmp = "$env:TEMP\dotfiles.ps1"
iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/dotfiles.ps1 -OutFile $tmp
& $tmp -Mode apply -Yes   # -Yes skips confirmation prompts
```

```bash
# Linux / WSL
MODE=audit  curl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/dotfiles.sh | bash
MODE=apply  curl -fsSL ... | bash
MODE=full   curl -fsSL ... | bash
YES=1 MODE=apply curl -fsSL ... | bash   # skip confirms
```

## Authentication — two interactive flows, one-time each

Both happen on first run; subsequent runs are unattended.

1. **`gh auth login --web`** — auto-prompted by the launcher when needed.
   Opens your browser, you paste a one-time code.
2. **`claude` (run once)** — Claude Code CLI's first-run flow. Opens
   `claude.ai` for browser auth. After that, `~/.claude/.credentials.json`
   exists and the launcher's auth check stops warning.

The launcher prints a yellow `[!!]` line if Claude Code isn't authed; you
won't miss it.

## Safety

- **Read-only by default** on existing machines. The smart-default picks
  `audit`, never `apply`, when there's existing chezmoi state.
- **Enterprise sniff** detects Azure AD / Workplace-joined machines and
  refuses `full` mode without explicit override.
- **No system writes** without confirmation. `chezmoi apply --force` and the
  full bootstrap always pause for a `[y/N]` prompt unless you set `YES=1` /
  `-Yes`.
- **No secrets in this repo.** The launcher contains nothing except the
  install + dispatch logic.

## Layout

```
.
├── dotfiles.ps1     # Windows launcher (single entry point)
├── dotfiles.sh      # Linux / WSL launcher (single entry point)
└── README.md        # this file
```

## License

MIT.
