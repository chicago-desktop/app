# Installing Chicago on a server

The step-by-step guide to install and run the desktop on a fresh Linux
server: from an empty account to a desktop you reach with `ssh -p 2222`.
Every step names the command and what success looks like; the output
excerpts are from a real install on 2026-09-15 (a fresh clone into an empty
directory, an empty git cache, the runtime release `v0.3.40a-chicago.2`).

1. [What you get and what you need](#1-what-you-get-and-what-you-need)
2. [Get the code](#2-get-the-code)
3. [The runtime](#3-the-runtime)
4. [The modules](#4-the-modules)
5. [The first administrator](#5-the-first-administrator)
6. [Ports and addresses](#6-ports-and-addresses)
7. [Start](#7-start)
8. [Connect](#8-connect)
9. [Updating and backups](#9-updating-and-backups)
10. [Troubleshooting](#10-troubleshooting)

## 1. What you get and what you need

One process, `wippy run`, serves two doors:

- **the desktop over SSH** on port 2222 — every connection gets a terminal
  desktop of its own, in the look of the mid-nineties desktops, under the
  account that logs on: a taskbar, a Start menu, overlapping windows, real
  programs under a PTY (a bash, htop, an editor), the games and the apps;
- **the web platform** on `127.0.0.1:8099` — users, agents, models,
  sessions, MCP; the same accounts.

You need:

- **A Linux server**, x86_64 or arm64 (the runtime is released for both;
  macOS builds exist too, for a workstation). Debian/Ubuntu commands below;
  any distribution works.
- **`git`, `curl`, `make`** — `git` is what fetches the desktop's modules
  from GitHub, `curl` downloads the runtime, `make` runs the two-line
  targets in the `Makefile`.
- **No font package.** The shell ships the fonts its pixel theme draws
  with (Liberation Sans and Liberation Mono under the SIL Open Font
  License, `assets/fonts` of `chicago/shell` with the licence next to
  them); nothing on the server has to be installed for text in pixels.
- **A terminal on the client side** with Kitty graphics or Sixel for the
  pixel theme (kitty, WezTerm, foot, and the terminals that speak Sixel).
  Any terminal gets the cell rendering of the same desktop; the runtime
  probes each connecting terminal and picks.
- **An account to run it as, not root.** A logged-on administrator can open
  a bash window, and that bash runs on the server under the OS account the
  runtime runs as. Run it as `root` and every administrator of the desktop
  has a root shell on your server.

```bash
sudo apt-get install -y git curl make
sudo adduser --disabled-password --gecos "" chicago
sudo -iu chicago
```

Everything below runs as that account, in its home directory.

## 2. Get the code

```bash
git clone https://github.com/chicago-desktop/app.git chicago && cd chicago
```

The repository is small (the modules are not in it): 1.3 s on the test
machine. It contains the application's own sources (`src/`), the committed
`wippy.lock` that pins every module, `.wippy.yaml` with the overrides, and
the `Makefile`.

## 3. The runtime

The desktop runs only on the **runtime fork**
[chicago-desktop/runtime](https://github.com/chicago-desktop/runtime)
(branch `wippy-projects`), not on a release `wippy`: the fork has the `gfx`
module (pixels in the terminal), the `terminal.ssh` host (the desktop over
SSH) and the git sources (modules resolved from GitHub by tag). A release
`wippy` has none of the three, and an entry that declares a module the
runtime does not know fails the whole boot (see [10](#10-troubleshooting)).

```bash
make runtime            # downloads the fork's latest release for this OS and CPU into bin/wippy
```

`make runtime` fetches
`https://github.com/chicago-desktop/runtime/releases/latest/download/wippy-<os>-<arch>`
(the [releases page](https://github.com/chicago-desktop/runtime/releases)
lists the builds and a `SHA256SUMS`), marks it executable and prints its
version. `RUNTIME_TAG=v0.3.40a-chicago.2 make runtime` pins a release
instead of taking the latest. 44 s on the test machine, most of it the
download. Success ends with the version banner:

```
chmod +x bin/wippy
./bin/wippy version

  ╦ ╦╦╔═╗╔═╗╦ ╦  Adaptive Application Runtime https://wippy.ai
  ║║║║╠═╝╠═╝╚╦╝  v0.3.40a-chicago.2 2026-09-15
  ╚╩╝╩╩  ╩   ╩   by Spiral Scout
```

`bin/` is ignored by git. Every command from here on is `./bin/wippy …`;
a `wippy` on your PATH is most likely a release build and must not be used
for this application.

## 4. The modules

```bash
./bin/wippy install     # every module the committed wippy.lock names
```

Two kinds of modules arrive:

- **the desktop's modules** (`chicago/shell`, `chicago/tui-desktop`, the
  games and apps — 13 in the lock today) come **from GitHub by tag**: the
  lock records the repository, the commit and the tree hash of each, and
  `install` clones the repository with the system `git` into the cache
  `~/.wippy/git/<host>/<path>/` (one bare clone per repository, one
  checkout per commit; `WIPPY_GIT_CACHE` moves the cache) and verifies the
  checkout against the hash. This needs `git` on PATH and the network once;
  the boot then loads the checkouts from the cache and never looks at the
  tags again;
- **the platform's modules** (`kickside/*`, `wippy/*`, `keeper/keeper` —
  48) come from the Hub into `.wippy/vendor/`.

Measured cold, with an empty cache: **1 min 21 s** in all — 18 s for the 13
git modules, 63 s for the 48 Hub downloads. The output starts with the git
modules, one `checking out` line each, then the Hub:

```
2026-09-15 19:08:01	INFO	install	installing dependencies	{"lock_file": "wippy.lock"}
2026-09-15 19:08:01	INFO	install	module comes from a git repository; taken from the cache	{"module": "chicago/aicq", "source": "github.com/chicago-desktop/aicq", "commit": "24daf913c658925a3955a3e923c7c7e20bccbdc5"}
…
2026-09-15 19:08:01	INFO	install	checking out git module	{"module": "chicago/aicq", "source": "github.com/chicago-desktop/aicq", "commit": "24daf913c658925a3955a3e923c7c7e20bccbdc5"}
…
2026-09-15 19:08:18	INFO	install	checking out git module	{"module": "chicago/weather", "source": "github.com/chicago-desktop/weather", "commit": "4fda75926ec141bbfd4a92cc9f96490feee1e969"}
2026-09-15 19:08:19	INFO	install	git modules verified from cache	{"count": 13}
2026-09-15 19:08:19	INFO	install	remote modules to install	{"count": 48, "skipped_replaced": 0}
2026-09-15 19:08:19	INFO	install	downloading module	{"module": "keeper/keeper", "version": "0.5.83"}
…
2026-09-15 19:09:22	INFO	install	installed module	{"module": "wippy/views", "version": "0.5.10"}
2026-09-15 19:09:22	INFO	install	installation complete	{"installed": 48, "cached": 0, "skipped_replaced": 0, "total": 48}
```

Success is the two lines `git modules verified from cache {"count": 13}`
and `installation complete {"installed": 48, …}`; on a second run the Hub
modules are `cached` instead of `installed`. Afterwards `.wippy/vendor/` is
about 29 MB and the git cache 14 MB, and `git status` is clean — `install`
does not rewrite the lock. Later boots work offline from the cache.

A failure names its cause: a missing `git` is one clear error naming the
source; a checkout whose tree differs from the lock is refused; a
dependency missing from the lock stops the boot outright (fix the entry in
`src/app/deps/_index.yaml` and re-resolve — [9](#9-updating-and-backups)).

**Install as the account that will run the service.** The git cache lives
under that account's `$HOME`, and the boot reads it from there.

## 5. The first administrator

On the first start the platform runs a migration that creates the first
administrator account. It reads two variables **from the OS environment of
the `wippy run` process** — the users module binds them to an
`env.storage.os` storage, so a `.env` file in the checkout is not read by
anything: export them in the shell (or source the file into it), or set them
in the service unit. `.env.example` lists them:

```bash
export KICKSIDE_USERS_DEFAULT_ADMIN_EMAIL=admin@example.com
export KICKSIDE_USERS_DEFAULT_ADMIN_PASSWORD='choose one'
# or: cp .env.example .env; edit it; then  set -a; . ./.env; set +a
```

What happens with and without them:

- **Set:** the account is created with that e-mail (it is the user name
  too) and that password, in the administrators' group. The log says
  `Using provided default admin credentials` and prints a block
  `DEFAULT ADMIN USER CREATED - SAVE THESE CREDENTIALS!` with the e-mail.
- **Not set:** an administrator `admin-<8 random characters>@localhost`
  with a random 16-character password is created instead, printed **once**,
  to the log, as `GENERATED ADMIN USER CREATED - SAVE THESE CREDENTIALS!`.
  If you started without the variables, copy them from the first boot's
  output; they are not shown again.
- The migration runs once. After the account exists the variables are
  ignored, so they are needed for the first start only; take them out of
  the environment afterwards.

Two more things the first start creates, both kept and both outside git:

- **the encryption key** — `ENCRYPTION_KEY` generated into `.wippy/.env`
  (the platform's own env file, `app.env:file`; not the `.env` above). The
  log: `ENCRYPTION_KEY not found, generating new key` … `Successfully
  generated and persisted ENCRYPTION_KEY`; on every later start
  `ENCRYPTION_KEY already exists, skipping generation`. Lose the file and
  everything encrypted with it (connection secrets, tokens) is unreadable;
- **the SSH host key** — `.wippy/ssh_host_ed25519_key`, ed25519, mode 0600,
  generated by the SSH host on its first start and reused from then on
  (`host_key:` in `app.desktop:ssh`). Its fingerprint is in the
  `ssh terminal host listening` log line; clients pin it on their first
  connection, so keep the file across reinstalls or every client sees a
  changed host key.

## 6. Ports and addresses

| What | Address | Where it is set |
|---|---|---|
| the web platform (gateway) | `127.0.0.1:8099` | `.wippy.yaml`, override `"app:gateway:data.addr"` |
| the address the web UI calls the API at | `http://localhost:8099` | `.wippy.yaml`, override `"app.env:defaults:data.values.PUBLIC_API_URL"` |
| the desktop over SSH | `0.0.0.0:2222` | `src/app/desktop/_index.yaml`, entry `app.desktop:ssh`, field `address:` |

**The gateway is on loopback on purpose**: a server may publish ports it
did not mean to. Reach the web UI through an SSH tunnel and open
`http://localhost:8099` in the browser:

```bash
ssh -L 8099:127.0.0.1:8099 chicago@server        # then http://localhost:8099
```

Keep the local end of the tunnel on 8099: the web UI calls the API at
`PUBLIC_API_URL`, and a tunnel on another local port leaves the browser
calling a port nothing answers on.

To move the gateway, change **both** overrides in `.wippy.yaml` (the
address and `PUBLIC_API_URL`; one without the other is a UI that calls the
old port). To move or bind the SSH desktop, change `address:` in
`src/app/desktop/_index.yaml` (`127.0.0.1:2222` keeps it local, behind a
jump host: `ssh -t -J server -p 2222 localhost`). Either change takes a
restart. For a change you do not want to commit, put the override in a
second config file — the pattern in [10](#10-troubleshooting).

**Firewall:** open 2222/tcp, keep 8099 closed (it is not reachable from
outside anyway while it listens on loopback):

```bash
sudo ufw allow 2222/tcp
```

The SSH door on 2222 asks nothing itself (`auth: logon`); the desktop's
logon dialog checks the account, and at most 10 failed logons per user
name are accepted before that name is refused for 15 minutes
([8](#8-connect)). It refuses port forwarding and exec, so it is not a
second OpenSSH.

## 7. Start

### In a terminal first

```bash
./bin/wippy run
```

The log is the process's stdout. The first ~20–40 s are the boot (~40 s
cold, when the modules are unpacked and the migrations run); success is
the gateway and the SSH host reporting themselves:

```
  ╦ ╦╦╔═╗╔═╗╦ ╦  Adaptive Application Runtime https://wippy.ai
  ║║║║╠═╝╠═╝╚╦╝  v0.3.40a-chicago.2 2026-09-15
  ╚╩╝╩╩  ╩   ╩   by Spiral Scout

2026-09-15 19:00:26	INFO	initializing runtime	{"memory_limit": "1.0GB"}
2026-09-15 19:00:26	INFO	run	loading entries from lock file	{"path": "…/chicago/wippy.lock"}
2026-09-15 19:00:26	INFO	run	loaded entries	{"count": 3381}
…
2026-09-15 19:00:45	INFO	terminal	terminal host started	{"id": "wippy.terminal:host"}
2026-09-15 19:00:45	INFO	terminal	terminal host started	{"id": "chicago.tui_desktop:terminal"}
2026-09-15 19:00:45	INFO	terminal	terminal host started	{"id": "chicago.shell:terminal"}
2026-09-15 19:00:45	INFO	terminal.ssh	ssh terminal host listening	{"id": "app.desktop:ssh", "address": "0.0.0.0:2222", "entry": "chicago.shell:shell", "auth": "logon", "host_key": "SHA256:…"}
2026-09-15 19:00:45	INFO	boot.encryption	ENCRYPTION_KEY already exists, skipping generation	{…}
2026-09-15 19:00:45	INFO	core	service app:gateway is running	{"serviceID": "app:gateway", "status": "running", "details": "service listening on 127.0.0.1:8099"}
```

(`WARN unresolved requirement` lines during the boot are the platform's
optional requirements this application does not bind; they are not
failures.) From another shell:

```bash
ss -ltn | grep -E ':8099|:2222'                    # both listening
curl -s -H 'Content-Type: application/json' -X POST \
  -d '{"email":"admin@example.com","password":"choose one"}' \
  http://127.0.0.1:8099/api/public/user/token      # → {"token":"…"} — the administrator exists
```

**The first boot after an install (or an update) may answer 500 on static
files** in the web UI: the modules are re-unpacked while the application is
starting, and a filesystem opened over a directory that is then replaced
serves nothing. The process is healthy; stop it and start it once more.

**Stopping takes about twenty seconds.** Ctrl+C (SIGTERM does the same)
starts a graceful stop: the shell asks every desktop's windows to close,
waits, then the application stops. A second Ctrl+C forces the exit.
Before starting again, wait until both ports are free
(`ss -ltn | grep -E ':8099|:2222'` prints nothing): a second instance
started early cannot bind the ports and dies quietly.

### As a service

`/etc/systemd/system/chicago.service`:

```ini
[Unit]
Description=Chicago desktop
After=network-online.target
Wants=network-online.target

[Service]
User=chicago
Group=chicago
WorkingDirectory=/home/chicago/chicago
ExecStart=/home/chicago/chicago/bin/wippy run
# The PTY windows get HOME and PATH from the process environment (.wippy.yaml);
# the git cache is read from $HOME/.wippy/git.
Environment=HOME=/home/chicago
Environment=PATH=/usr/local/bin:/usr/bin:/bin
# Only for the very first start: the first administrator. Remove after it,
# or keep an EnvironmentFile that you empty afterwards.
#Environment=KICKSIDE_USERS_DEFAULT_ADMIN_EMAIL=admin@example.com
#Environment=KICKSIDE_USERS_DEFAULT_ADMIN_PASSWORD=change-me
#EnvironmentFile=-/home/chicago/chicago/.env
# Stopping takes ~20 s (the desktops close their windows first); give it 45.
KillSignal=SIGTERM
TimeoutStopSec=45
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now chicago
systemctl status chicago                # active (running); the ports after ~30 s
journalctl -u chicago -f               # the same log as the terminal's stdout
journalctl -u chicago | grep -E 'ADMIN USER CREATED|ssh terminal host listening|app:gateway is running'
```

`Restart=on-failure` restarts a crash but not a clean stop. The first-boot
500 above applies here too: after the first `enable --now` (and after
every `wippy install`/`update`), `systemctl restart chicago` once.

## 8. Connect

```bash
ssh -t -p 2222 chicago@server           # any user name after the @ — the desktop asks for the account itself
```

`-t` asks for a terminal, which the desktop needs. The client's OpenSSH
accepts the server's host key on the first connection (compare the
fingerprint with the `ssh terminal host listening` log line); the door then
lets you through without a password prompt of its own, and the shell opens
its **logon dialog**: a user name field, a password field, OK and Cancel.
Type the administrator's e-mail and password from
[5](#5-the-first-administrator). The web logon and this one check the same
account.

What you see after the logon, on the first start: the teal desktop with a
column of icons on the left, the widgets on the right (the weather, the
runtime's memory and goroutines), a taskbar along the bottom with **Start**
on the left and the clock on the right. Start → Programs has the apps and
the games; Start → Settings the system windows (Users, Services, Scheduled
Tasks, Event Viewer, Connections, SSH Keys, Add/Remove Programs, Task
Manager…); Start → Shut Down ends the session. Every connection is a
desktop of its own — size, graphics and cell size are probed on the
connecting terminal, and a terminal without Kitty or Sixel graphics gets
the same desktop in cells. Closing the ssh client ends the desktop as Shut
Down does.

- **Logon without the password:** paste your public key's `.pub` line in
  Start → Settings → **SSH Keys**. From then on a client that offers that
  key opens your desktop straight away; an unknown key is refused so the
  client tries its next, and then the logon dialog. A key names who is
  coming; the account, not `authorized_keys`, decides.
- **At most 10 failed logons per user name**, counted across connections;
  the tenth answers "Too many failed logons", and for 15 minutes the
  password of that name is not checked at all. A success clears the count;
  a restart forgets it. Unknown names count too.
- **Ordinary users get no bash window**: a bash runs on the server under
  the runtime's OS account, so it is for administrators only; the desktop
  refuses it with the reason. Task Manager, AntiBug, Add/Remove Programs
  and the Registry Editor are administrators' too. Create the other
  accounts in the web UI (Users) or Start → Settings → Users.

The same desktop can be opened in the server's own terminal, the whole
runtime coming up with it — `./bin/wippy run --host chicago.shell:terminal chicago`
(`make windows`) — but not next to a running service: it is a second
instance on the same ports.

## 9. Updating and backups

```bash
systemctl stop chicago                  # nothing running: a boot with a half-written lock is a boot that fails
make runtime                            # a newer release of the runtime, if there is one (RUNTIME_TAG= pins)
cp wippy.lock wippy.lock.bak            # wippy update REWRITES the lock
./bin/wippy update                      # re-resolves src/app/deps: the desktop's modules against their GitHub tags, the platform's against the Hub
./bin/wippy install                     # fetches what the new lock names
systemctl start chicago                 # then once more: the first boot after an update re-unpacks the modules
```

`wippy update` lists each repository's tags (`git ls-remote --tags`), picks
the highest one in the entry's range (`>=0.2.0`) and records the commit;
`install` and the boot never look at the tags — a module's fix reaches you
only through an `update`. Pulling this repository (`git pull`) brings a
lock that was resolved elsewhere; then `./bin/wippy install` is enough. A
dependency the resolve drops is a boot that fails — compare the new lock
with the backup before starting.

**What to back up** (all under the checkout, none of it in git):

| File | What it is | Lost without it |
|---|---|---|
| `.wippy/app.db` | the application's SQLite database: accounts, SSH keys, desktops' layouts, everything the apps store | everything |
| `.wippy/.env` | the `ENCRYPTION_KEY` | every secret encrypted with it |
| `.wippy/ssh_host_ed25519_key` | the SSH host key | clients see a changed host key |
| `.wippy/uploads/` | uploaded files, if any | the files |

Stop the service before copying `app.db`, or use `sqlite3 .wippy/app.db
".backup app.db.bak"`. `.wippy/vendor/` and `~/.wippy/git/` are caches:
`./bin/wippy install` rebuilds both.

## 10. Troubleshooting

- **Port already in use — a second instance dies quietly.** A second
  `wippy run` cannot bind `:8099` or `:2222`, logs it and exits while the
  first keeps serving the old code. Count the processes from the ports, not
  from `pgrep` (which also matches the shell you typed it in):
  `ss -ltnp | grep -E ':8099|:2222'`.
- **It does not stop quickly.** ~20 s after Ctrl+C or `systemctl stop`;
  wait for the ports to be free before starting again. A fixed sleep of a
  few seconds is how you end up with two.
- **`failed to load state: unresolved dependencies after retry: … node
  with ID {gfx :gfx} not found`** — a release `wippy` was used instead of
  the fork's build: the shell declares the `gfx` module, the release
  runtime has no such module, and one unknown module fails the whole boot.
  Run `./bin/wippy` (step [3](#3-the-runtime)); `./bin/wippy version` must
  say `-chicago`. A release build refuses `kind: terminal.ssh` the same way.
- **The SSH host refuses `auth: logon` or `key_owner:`** — an older fork
  build (before the 2026-09-15 releases); `make runtime` again. And
  `entry not found` there means `entry:` names the CLI command instead of
  the entry ID `chicago.shell:shell`.
- **The terminal is left with mouse modes on** after a desktop ended badly
  (every mouse move types `[<35;…M` into the shell):
  `printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1015l'` or `reset`.
- **Where the log is.** The stdout of `wippy run` — `journalctl -u chicago`
  under systemd. The desktops' own terminal hosts hide their log (a log
  line would scramble the frame), so what a running desktop is doing is
  read from the API instead: `GET /api/v1/tui-desktop/windows` and
  `GET /api/v1/chicago/status` with a bearer token (`.env.example` says how
  to mint one; it lives 24 hours, and `{"error":"Authentication required"}`
  means it expired). The agent skill `.claude/skills/chicago-debug/SKILL.md`
  has the whole procedure.
- **`{"error":"Authentication required"}` on every request** — the token
  expired (24 h), not a broken server. Mint a new one with the account's
  e-mail and password.
- **The web UI answers 500 on static files** — the first boot after an
  install or update; restart once ([7](#7-start)).
- **`Too many failed logons`** — ten failures on that user name; wait 15
  minutes or restart the service (the count is in memory).
- **A bash window is refused** — the account is not an administrator
  ([8](#8-connect)).
- **Two instances side by side, for testing.** The second one needs other
  ports and its own state; run it from a second checkout with a second
  config file that overrides the three addresses. `--config` is repeatable
  and later files override earlier ones, but passing it **replaces** the
  default list, so name `.wippy.yaml` too:

  ```yaml
  # local.yaml — a test instance next to the service
  version: "1.0"
  override:
    "app:gateway:data.addr": "127.0.0.1:8199"
    "app.env:defaults:data.values.PUBLIC_API_URL": "http://localhost:8199"
    "app.desktop:ssh:address": "127.0.0.1:2223"
  ```

  ```bash
  ./bin/wippy run --config .wippy.yaml --config local.yaml
  ssh -t -p 2223 localhost
  ```

  The same pattern moves the service's own addresses without editing the
  committed files — put the `--config` pair in `ExecStart`.
