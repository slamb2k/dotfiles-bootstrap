# dotfiles-bootstrap

Public launchers for [slamb2k/dotfiles](https://github.com/slamb2k/dotfiles)
(the actual dotfiles repo is private).

The chicken-and-egg problem: you can't `gh repo clone` a private repo on a
fresh machine because `gh` isn't installed and you're not authenticated yet.
Hosting the small bootstrap launcher on a public repo — separate from the
secrets-bearing dotfiles content — solves that without exposing the rest.

## The init / prereq phase

Every entry point below begins with the same minimal init phase:

| Prereq | Why | Install path |
|---|---|---|
| `gh` | Auth + clone the private dotfiles repo | winget / apt |
| `chezmoi` | Apply / diff dotfiles | winget / curl `get.chezmoi.io` |
| `bun` | Install Claude Code CLI (no Node required) | `bun.sh/install.ps1` / `bun.sh/install` |
| **Claude Code CLI** | Run the `dotfiles-incorporate` skill that executes `decisions.json` | `bun install -g @anthropic-ai/claude-code` |
| `pwsh` (Linux only) | Run the cross-platform `audit-and-diff.ps1` | user-scope tarball |

After install, two things require **interactive auth** (one-time, browser flow):

1. **`gh auth login --web`** — prompted automatically by the launcher when needed.
2. **`claude` (run once)** — Claude Code CLI's first-run prompts for Claude.ai login.
   The launchers print a yellow warning if `~/.claude/.credentials.json` is absent.

Once both are authed, every workflow below works end-to-end with no further prompts.

## One-line entry points

### Full bootstrap — install + apply

Fresh Windows 11:

```powershell
iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/install.ps1 | iex
```

Fresh Linux / WSL2 Ubuntu:

```bash
curl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/install.sh | bash
```

### Audit-only — read-only, never modifies dotfiles

Run this on a work laptop *before* a full bootstrap, or on any machine where
you want a drift report without applying anything.

Windows:

```powershell
iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/audit.ps1 | iex
```

Linux / WSL:

```bash
curl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/audit.sh | bash
```

The audit-only launcher installs `gh` + `chezmoi` (idempotent), clones the
dotfiles, and runs `chezmoi diff` (Linux) or `scripts/audit-and-diff.ps1`
(Windows; the rich version with enterprise-detection + classification table).
**Never** runs `chezmoi apply`. Output: `audit-output-<date>/report.md` plus
raw dumps you can inspect.

## What `install.{ps1,sh}` does

1. **Verify prerequisites** (winget on Windows, apt on Linux).
2. **Install** the absolute minimum:  `gh`, `chezmoi`, `git`.
3. **Authenticate** to GitHub via `gh auth login --web` (interactive).
4. **Clone** [slamb2k/dotfiles](https://github.com/slamb2k/dotfiles) into
   chezmoi's source dir.
5. **Hand off** to the dotfiles repo's own `scripts/bootstrap.{ps1,sh}` which
   does the substantive work:
   - `chezmoi init --apply` (or `chezmoi update --apply` on re-run)
   - Optional toolchain (Claude desktop, bun, starship, fzf, ripgrep, fd, bat,
     zoxide, gsudo, pwsh 7, Windows Terminal, VS Code, Bitwarden — Linux gets
     apt-installable equivalents)
   - WSL bootstrap (Windows side): installs Ubuntu, runs `bootstrap.sh` inside
   - Configures `ssh-agent` (Windows side, via gsudo)
   - Runs the in-repo `audit-and-diff.ps1` so you see the resulting state

## Pass-through arguments

```bash
# Linux: skip the optional toolchain
curl -fsSL https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/install.sh | MINIMAL=1 bash
```

```powershell
# Windows: download first, then invoke with flags
$tmp = "$env:TEMP\install.ps1"
iwr -useb https://raw.githubusercontent.com/slamb2k/dotfiles-bootstrap/main/install.ps1 -OutFile $tmp
& $tmp -Minimal -SkipWsl
Remove-Item $tmp
```

## Idempotency — re-running on an existing machine

The full bootstrap is **mostly** idempotent, but with one important caveat.
Read this before re-running on a working machine.

| Step | Behaviour on re-run |
|---|---|
| `winget install <id>` (Windows) | Each id is checked first via `winget list`; if installed, **skipped** entirely. No reinstall, no version downgrade. |
| `apt install <pkg>` (Linux) | Each package checked via `dpkg -s`; installed packages **skipped**. |
| `gh auth login` | `gh auth status` checked first; if already authed, **skipped**. No browser tab. |
| `gh repo clone` | If `~/.local/share/chezmoi/.git` exists, `git pull --ff-only` instead of clone. **Won't lose local commits**, but will fail if there are uncommitted changes in the source dir. |
| `chezmoi update --apply` | **Pulls latest from origin and overwrites any chezmoi-managed file with the source version.** This is the one to be careful about — see below. |
| Optional CLI installs (starship/fzf/etc.) | All idempotent via the same package-manager checks. |
| `wsl --install Ubuntu-24.04` | Skipped if Ubuntu already registered. |
| `ssh-agent` enable | Only acts if currently `Disabled`. |
| Audit at end | Always runs and writes a fresh timestamped output dir. |

### The one risky step: `chezmoi update --apply`

If you've **hand-edited a chezmoi-managed file directly in `$HOME`** since
the last apply (e.g. tweaked your `.zshrc` without going through `chezmoi
re-add`), running the bootstrap again will **silently overwrite that local
edit** with the source version from git.

**To avoid surprises, before re-running on a working machine:**

```bash
# See what would change, on each side:
chezmoi diff          # any output here = local edits will be lost
```

If `chezmoi diff` is empty, the re-run is fully safe (a no-op for managed
files). If not, either:

- Capture local edits first: `chezmoi re-add` then `chezmoi cd; git commit; git push`.
- Or use the **audit-only** one-liner above, which never applies, to inspect
  before deciding.

### What re-running does NOT do

- Does **not** re-run `gh auth login` if already authed.
- Does **not** reinstall already-current packages.
- Does **not** modify Defender exclusions, services, or registry beyond what
  `winget install` itself does.
- Does **not** delete files that have been removed from the dotfiles repo
  since last apply (chezmoi tracks state in `~/.config/chezmoi/chezmoistate.boltdb`;
  removing a managed file from source and re-applying *will* delete it from
  `$HOME`, but only those files chezmoi already manages).
- Does **not** push anything to GitHub. All write ops are local.

### TL;DR for re-running

| Scenario | Safe to one-liner? |
|---|---|
| Fresh machine, never bootstrapped | Yes — that's the design |
| Already bootstrapped, no local edits to managed files | Yes — fully idempotent |
| Already bootstrapped, you have local edits to managed files | **No** — run `chezmoi diff` first or use the audit-only one-liner |
| Already bootstrapped, dotfiles have moved forward upstream | Yes — pulls + applies the new state (assuming no local edits) |
| Corporate machine with Tamper Protection / locked policies | Use the **audit-only** one-liner first; the full bootstrap will silently fail on policy-restricted operations (ssh-agent, Defender exclusions) but otherwise complete |

## Safety

- **You're trusting these URLs** to install software and write dotfiles. Read
  [`install.ps1`](install.ps1), [`install.sh`](install.sh), [`audit.ps1`](audit.ps1),
  and [`audit.sh`](audit.sh) before running. They're each ~100 lines.
- The launchers themselves contain no secrets. They fetch only from official
  sources: winget, apt, `get.chezmoi.io`, and your private repo via `gh`.
- The private dotfiles repo can't be cloned without your GitHub credentials —
  this repo just bootstraps the *path* to that clone.

## Layout

```
.
├── install.ps1     # Windows full-bootstrap launcher
├── install.sh      # Linux/WSL full-bootstrap launcher
├── audit.ps1       # Windows read-only audit launcher
├── audit.sh        # Linux/WSL read-only audit launcher
└── README.md       # this file
```

## License

MIT.
