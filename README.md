# Chicago

A desktop in the terminal, in the look of the mid-nineties desktops, served from a server over SSH.

`ssh -t -p 2222 <server>` gets you "Log On to Windows", then a teal desktop
with a taskbar, a Start menu, overlapping windows, real programs under a PTY
(a bash, htop, an editor), the games and the apps — and the same platform's
agents, models and MCP behind them. Every connection is a desktop of its own,
under the account that logged on. The same application serves the web
platform (users, agents, models, sessions, MCP) on `127.0.0.1:8099`.

This repository is the *application*: it composes modules (the platform's from the Hub, the desktop's resolved from their GitHub repositories by tag — v0.2.0 is the first) and adds what
only an application can declare — the logon, the SSH host, the users'
SSH keys, the runtime monitor widgets, the MCP window workshop, and the
platform's system windows (Users, Services, Scheduled Tasks, Event Viewer,
Connections, User Profile).

## What it composes

| Module | Repository | What it is |
|---|---|---|
| `kickside/kickside`, `kickside/mcp` | Hub | the platform: users, agents, models, sessions, MCP |
| `windows/tui-desktop` | [wippy-windows/tui-desktop](https://github.com/wippy-windows/tui-desktop) | the terminal window manager: compositor, PTY windows, the command channel |
| `windows/shell` | [wippy-windows/windows](https://github.com/wippy-windows/windows) | the Chicago shell: theme, Start menu, the SDK windows are written against |
| `windows/minesweeper` | [wippy-windows/minesweeper](https://github.com/wippy-windows/minesweeper) | Minesweeper |
| `windows/weather` | [wippy-windows/weather](https://github.com/wippy-windows/weather) | Weather: window, tray, desktop widget |
| `windows/aicq` | [wippy-windows/aicq](https://github.com/wippy-windows/aicq) | aICQ: people and agents in one contact list |
| the runtime | [wippy-windows/runtime](https://github.com/wippy-windows/runtime) | the fork of wippyai/runtime the shell needs (see below) |

The declarations live in `src/app/deps/_index.yaml`; the shell's
"Add/Remove Programs" edits that file.

## Requirements

- **The runtime fork** — [wippy-windows/runtime](https://github.com/wippy-windows/runtime),
  branch `wippy-projects`. The shell needs its `gfx` module (pixels in the
  terminal) and its `terminal.ssh` host; a release `wippy` does not have
  either, and an entry that declares a module the runtime does not know fails
  the whole boot, not just that entry. `make runtime` downloads the fork's
  latest [release](https://github.com/wippy-windows/runtime/releases) binary
  for this machine into `bin/wippy` (Linux and macOS, amd64 and arm64;
  `RUNTIME_TAG=v0.3.40a-windows.1` pins a version); or build it there with
  `make build-wippy-local` and point `WIPPY` at the binary.
- **fonts-liberation** (`/usr/share/fonts/truetype/liberation/`) — the pixel
  theme renders text from these files; `app:system_fonts` in
  `src/app/storage/_index.yaml` names the directory.
- A terminal with kitty or sixel graphics for the pixel theme (Windows
  Terminal, kitty, WezTerm, foot …). Any terminal works in cell mode.

## First boot

```bash
make runtime                                    # the runtime fork's release binary into bin/wippy
wippy install                                   # modules from the committed wippy.lock
export KICKSIDE_USERS_DEFAULT_ADMIN_EMAIL=admin@example.com
export KICKSIDE_USERS_DEFAULT_ADMIN_PASSWORD='choose one'
wippy run
```

The two variables (see `.env.example`) create the first administrator on the
first start; the encryption key is generated into `.wippy/.env` and the SSH
host key into `.wippy/ssh_host_ed25519_key` — both are kept, neither is in
git. On the very first start after an install the modules are still being
unpacked while the application starts; if the web UI answers 500 on static
files, restart once.

## Running

```bash
wippy run                                       # the web platform on 127.0.0.1:8099 and the SSH desktop on :2222
ssh -t -p 2222 <server>                         # from anywhere: "Log On to Windows", then the desktop
wippy run --host windows.shell:terminal windows # the desktop in this terminal (the whole runtime comes up with it)
```

The SSH door asks nothing itself (`auth: logon`): "Log On to Windows" checks
the account's name and password, the same as the web logon. A public key
pasted in Start → Settings → SSH Keys logs its owner on without the password
screen. At most 10 failed logons per user name, then 15 minutes of refusal.

`--host` is required for every command: the desktop modules bring terminal
hosts of their own, and the CLI refuses to pick one when it sees several.

Only one instance can run: a second one cannot bind :8099 and dies quietly
while the first keeps serving. Stopping takes about twenty seconds.

## Tests

```bash
wippy test --host wippy.terminal:host
```

This boots the whole application (the modules' migrations included), so run
it only when the application may come up. The tests are the `*_test.lua`
files next to the code, each with a `meta.type: test` entry.

## Updating

```bash
wippy update            # re-resolves src/app/deps against the Hub and rewrites wippy.lock
```

Back up `wippy.lock` before running it against a working system: a
dependency the resolve drops is a boot that fails. A published module version
is immutable, so a fix is always a new version.

## For agents

Skills in `.claude/skills/` (one `SKILL.md` each):

- `wippy-window-app` — write or repair a window on the shell's SDK (registry entry, component tree, resize, scrolling, input, lifecycle); `docs/sdk.md` is the application's copy of the shell's SDK guide.
- `wippy-window-workshop` — build a window in the running runtime through the WindowsWorkshop MCP tool (`app.workshop:windows_workshop`) or `POST /api/v1/tui-desktop/apps`, no files, no restart.
- `tui-desktop` — drive a live desktop through its command channel: open a window, type into it, read its screen, move or close it.
- `windows-debug` — see what the desktop is doing, the SSH desktop, the terminal probe, the log, restarts, live update, tests and lint, and the traps that fail silently.
- `windows-add-module` — add a Hub module to the application, update one, or write and publish a new one from `windows/module-template`.

Tools in `tools/`:

- `tui-probe.py` — a PTY probe: runs a command (the shell, or `ssh -tt -p 2222 localhost`), types by a script, prints the screen as text.
- `live-update.sh <namespace> [migration …]` — pushes `src/` of one `app.*` namespace into the running registry through keeper's sync (upload only) and runs migrations.
- `late-locals.py` — finds file-level locals read above their declaration.

## The icons

The icon set ships with the shell module (`windows/shell`,
`assets/icons`, see its `SOURCE.md`); the application carries none of its
own. The icon set is an interim one and is being replaced with original pixel art
([chicago-desktop/shell#1](https://github.com/chicago-desktop/shell/issues/1));
the code is MIT (`LICENSE`).
