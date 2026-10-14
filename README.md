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

1. **`claude` PATH shim** (`~/.herdr-shims/claude`)
   - exports `HERDR_AGENT=claude` so a ccs-wrapped pane uses Claude Code's screen manifest
     (Herdr's documented mechanism for wrapper-hidden agents), and
   - on `--resume <id>`, routes through `ccs <profile> [--browser] --resume` **iff** `<id>`
     was a ccs-started session; otherwise runs the real `claude`. Native sessions stay native.
2. **`ccs` PATH shim** (`~/.herdr-shims/ccs`) that starts the ccs-managed Chrome before a
   `--browser` launch. ccs only exposes its browser MCP tools (Claude Browser Attach) when
   Chrome already answers on the DevTools port at launch, and never starts Chrome itself —
   so without this, `ccs claude --browser` with Chrome closed silently comes up with no
   browser tools. When the last `--browser` session using that Chrome exits, the shim quits
   it again, so the DevTools port doesn't stay open. Every other invocation passes straight
   through to the real `ccs`.
3. **Claude Code `SessionStart` hook** that tags ccs-started sessions. ccs sets
   `ANTHROPIC_AUTH_TOKEN=ccs-internal-managed`; the hook writes a marker named after the
   session id, holding the ccs profile (`profile=claude`) and, when browser tools were live,
   `browser=1`. Bare `claude` never sets that token, so tagging is unambiguous.
4. **Shell-profile `PATH` line** so the shims resolve ahead of the real binaries.

The shims are transparent for non-ccs use: a fresh `claude`, a native `--resume`, and any
`ccs` call without `--browser` `exec` the real binary unchanged. A `ccs … --browser` call
stays alive as the parent of the real `ccs`, so it can close Chrome when that exits.

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
herdr-ccs status             # "tagged ccs sessions: 1 (with browser: 0)"
# a bare `claude` session is not tagged -> restores natively

# browser: with Chrome closed, this starts it first, then ccs exposes the browser tools
ccs claude --browser
ccs browser status           # "State: ready"
herdr-ccs status             # "(with browser: 1)"
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
and redirects only tagged sessions to `ccs <profile> --resume <id>`, adding `--browser` when
the marker says browser tools were live. It also fixes detection via `HERDR_AGENT=claude`.

Browser sessions come back with their tools on either path: a resume that reaches `ccs` with
`--browser` goes through the `ccs` shim, which starts Chrome if it isn't running. Markers
written before profile capture are empty and resume as `ccs claude`, exactly as before.

### Browser settings

The `ccs` shim reads the same settings ccs does, with the same precedence: the
`CCS_BROWSER_USER_DATA_DIR` / `CCS_BROWSER_DEVTOOLS_PORT` env overrides, then
`browser.claude` in `config.yaml` (under `CCS_DIR`, `CCS_HOME/.ccs`, or `~/.ccs`), then port
`9222`. It skips the launch when `browser.claude.enabled` is `false`, and refuses to start
Chrome when no `user_data_dir` is configured — ccs would then fall back to your everyday
Chrome profile, which should not be opened to DevTools unattended. Run `ccs browser setup`
once to create the managed profile.

The shim only closes a Chrome it started itself. If something already answers on the
DevTools port when a `--browser` session launches (a Chrome you opened by hand, say), it is
left running. State lives in `~/.herdr-shims/browser/<port>/`: one lease file per running
`--browser` session (named by the shim's PID) and an `owned` marker while the shim's own
Chrome runs. The last session to exit, or to hang up when its terminal closes, sends that
Chrome `SIGTERM`, which shuts it down cleanly. Leases of sessions that were killed outright
(`kill -9`) are cleared the next time a `--browser` session exits. `herdr-ccs status` shows
each port's owner and live session count.

## Caveats

- When `install` has to add its hook, it rewrites `settings.json` with 2-space indentation
  (a whitespace-only reformat) and writes a backup to `settings.json.herdr-ccs.bak`. When the
  hook is already there, `settings.json` is left untouched.
- Restore redirection assumes Herdr resolves `claude` via `PATH` (it sends the resume
  command to an interactive login pane shell, which sources your profile). If a future
  Herdr version pins an absolute path, the shim will not intercept restore.
- The ccs detection token (`ANTHROPIC_AUTH_TOKEN=ccs-internal-managed`) is a ccs
  implementation detail; if ccs changes it, update the marker hook. The same goes for
  `CCS_BROWSER_DEVTOOLS_HTTP_URL`, which the hook reads as "browser tools were live".
- ccs exports no profile name, so the hook reads it from the launching `ccs <profile> …`
  process (the first bare word after the ccs binary). If it can't, the marker has no
  profile and resume falls back to `ccs claude`.
- The marker reflects the latest launch of a session: resuming a browser session while
  Chrome can't start rewrites it without `browser=1`.
- Restoring a browser session starts Chrome with its DevTools port open on `127.0.0.1`,
  with no one at the keyboard. Any local process can drive that Chrome profile while it
  runs; keep sensitive logins out of it. The shim quits it when the restored session exits.

## License

MIT
