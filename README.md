# herdr-ccs

Integrate [`ccs claude`](https://www.npmjs.com/package/@kaitranntt/ccs) with
[Herdr](https://herdr.dev), on top of Herdr's built-in Claude Code integration.

## Why

`ccs claude` runs Claude Code inside the **ccs** launcher (a proxy/router). Because the
foreground process in the pane is `node`/`ccs` rather than `claude`, Herdr may not detect
the pane as Claude Code (no live `working`/`idle`/`blocked` state).

Restore is more nuanced. Herdr's **restart-restore** (server restart / after reboot) replays
each pane's original foreground command, so ccs panes already come back as
`ccs claude --resume <id>` — through ccs — on their own. But Herdr's **canonical resume**
path (an agent-level resume / `agent start --kind claude`) relaunches the bare `claude`
binary, which would bypass ccs.

`herdr-ccs` closes the detection gap and makes the canonical-resume path launcher-aware,
while leaving native `claude` untouched.

## What it does

1. **PATH shim** (`~/.herdr-shims/claude`)
   - exports `HERDR_AGENT=claude` so a ccs-wrapped pane uses Claude Code's screen manifest
     (Herdr's documented mechanism for wrapper-hidden agents), and
   - on `--resume <id>`, routes through `ccs claude --resume` **iff** `<id>` was a
     ccs-started session; otherwise runs the real `claude`. Native sessions stay native.
2. **Claude Code `SessionStart` hook** that tags ccs-started sessions. ccs sets
   `ANTHROPIC_AUTH_TOKEN=ccs-internal-managed`; the hook records the session id under the
   shim's markers dir. Bare `claude` never sets that token, so tagging is unambiguous.
3. **Shell-profile `PATH` line** so the shim resolves ahead of the real binary.

The shim is transparent for non-ccs use: a fresh `claude`, and a native `--resume`, `exec`
the real binary unchanged.

## Requirements

- [Herdr](https://herdr.dev) installed, with the Claude integration:
  `herdr integration install claude`
- `ccs` (`@kaitranntt/ccs`) on `PATH`
- `python3` (marker hook + `settings.json` editing)
- zsh or bash (fish/others: set `HERDR_CCS_PROFILE` or add the shim dir to `PATH` manually)

## Install

### As a Herdr plugin

```sh
herdr plugin install kennethwkz/herdr-ccs
herdr plugin action invoke kennethwkz.herdr-ccs.install
herdr plugin action invoke kennethwkz.herdr-ccs.status
```

Local development against a checkout:

```sh
herdr plugin link /path/to/herdr-ccs
herdr plugin action invoke kennethwkz.herdr-ccs.install
```

### As a plain CLI

```sh
git clone https://github.com/kennethwkz/herdr-ccs
cd herdr-ccs
./install.sh                 # copies bin/herdr-ccs -> ~/.local/bin
herdr-ccs install            # writes shim + hook, patches settings.json + shell profile
source ~/.zshrc              # or open a new shell
which claude                 # expect: ~/.herdr-shims/claude
```

## Verify

```sh
herdr-ccs status
# start a ccs session, then check it was tagged:
ccs claude
herdr-ccs status             # "tagged ccs sessions: 1"
# a bare `claude` session is not tagged -> restores natively
```

After a Herdr restart, confirm a restored ccs pane runs through ccs — its process tree
shows `ccs claude --resume <id>` → `claude --settings …/ccs-launch-settings-… --resume <id>`.

## Uninstall

```sh
herdr-ccs uninstall          # revert; keeps session markers
herdr-ccs uninstall --purge  # revert + delete shim dir and markers
```

`uninstall` strips only this tool's `SessionStart` entry (co-located hooks are preserved),
removes the `PATH` block, and deletes the shim and marker hook.

## Configuration

Environment overrides (all optional):

| Variable | Default | Purpose |
| --- | --- | --- |
| `HERDR_CCS_SHIM_DIR` | `~/.herdr-shims` | Where the shim + session markers live |
| `HERDR_CCS_PROFILE` | shell-derived | Shell profile to receive the `PATH` line |
| `HERDR_CCS_REAL_CLAUDE` | auto-detected | Path to the real `claude` binary |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code config dir to patch |

## How restore works

Herdr has two resume paths:

- **Restart-restore** (server restart / reboot): Herdr replays each pane's original
  foreground command. ccs panes were launched as `ccs claude`, so they are restored as
  `ccs claude --resume <id>` — already through ccs, with no help from this tool.
  (Verified: after a reboot, restored panes run `ccs claude --resume` → real `claude`
  with ccs's `--settings`, even with an empty marker set.)
- **Canonical resume** (agent-level resume / `agent start --kind claude`): Herdr launches
  the bare `claude` binary, which has no memory of the launcher and would bypass ccs.

`herdr-ccs` is the safety net for the second path. The `SessionStart` marker records which
sessions were ccs-started; the shim consults it when something runs `claude --resume <id>`
and redirects only tagged sessions to `ccs claude --resume <id>`. It also fixes detection
via `HERDR_AGENT=claude`.

## Caveats

- `install` rewrites `settings.json` with 2-space indentation (a whitespace-only reformat).
  A backup is written to `settings.json.herdr-ccs.bak`.
- Restore redirection assumes Herdr resolves `claude` via `PATH` (it sends the resume
  command to an interactive login pane shell, which sources your profile). If a future
  Herdr version pins an absolute path, the shim will not intercept restore.
- The ccs detection token (`ANTHROPIC_AUTH_TOKEN=ccs-internal-managed`) is a ccs
  implementation detail; if ccs changes it, update the marker hook.

## License

MIT
