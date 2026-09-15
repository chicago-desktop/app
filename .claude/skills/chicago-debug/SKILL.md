---
name: chicago-debug
description: Debug the Chicago application — see what a running desktop is doing through the command channel and the shell's status endpoint, drive the SSH desktop with the terminal probe, read the log, restart without ending up with two instances, update app.* code live through keeper, run lint and tests with the right build, and recognize the traps that fail silently (late locals, YAML colons, the test form, env.get permission silence, go-lua). Use when a window does not open, a desktop looks dead, a change "did not land", or a test is green for no reason.
---

# Debugging the Chicago application

Most of what breaks here breaks silently: a window that dies on its first
frame just is not there, a permission denial reads as "not set", a test that
never ran prints green. The order of work is therefore: **look at the
evidence first** (the screen, the channel, the status endpoint, the log), and
only then read code.

## 1. What is the desktop doing

Everything is behind the application's router `app:api`, prefix `/api/v1`
on `127.0.0.1:8099`, with a bearer token (`.env.example` says how to mint
one; it lives 24 hours, and `{"error":"Authentication required"}` means it
expired, not that the application broke). A miss on a path answers the
facade page with **200** — check `content-type: application/json`, not the
code.

```bash
set -a; . ./.env.local; set +a          # or export KICKSIDE_API_TOKEN=…
API=http://127.0.0.1:8099/api/v1; AUTH="Authorization: Bearer $KICKSIDE_API_TOKEN"

curl -s -H "$AUTH" $API/tui-desktop/windows      # the base's dashboard: windows, focus, screen, restore, frame
curl -s -H "$AUTH" $API/chicago/status           # the shell: running, windows, restore, frame instruments
curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST -d '{}' \
  $API/tui-desktop/windows/w1/screen             # a window's screen, rows of text
```

- `GET /tui-desktop/windows` is a dashboard on purpose: `notice` (the status
  line the person sees — a refusal nobody awaited shows only there),
  `menu_open` / `menu_path` / `menu_cursor` (did the click reach the menu, or
  did it reach and the theme did not draw), `selected`, `pixels` (which mode
  the compositor draws in), `frame` (`changed_rows`, `bytes_written`,
  `placements_sent` — chrome cut wrong draws the RIGHT screen, just slowly),
  and **`restore`** (`restored`, `failed`, `names`, `error`): what became of
  the workshop windows at start. Silence there would read as "there were no
  windows".
- `GET /chicago/status` answers `running: false` **with 200** for a shell
  that is shut down: a shut-down shell is not a broken application. It is
  the only place a person can see the restore report — the terminal host's
  log is muted.
- With the SSH host there is one desktop per connection (the name family
  `chicago.shell`, `chicago.shell.2` … `.16`); the channel and the status
  endpoint address the first one. `user = {id, name}` in `desktop.list` is
  the only way to tell windows under a person from windows under the
  service actor.
- **The screen is the only evidence.** A `type` that succeeded says the keys
  reached the window; what the program did with them is in `screen`. A
  fresh window is `"ready": false` until its first frame, and a pixel window
  (`pixel_render`) has an empty text screen — its evidence is a rendered PNG
  (skill `wippy-window-workshop`, "Verification"). Skill `tui-desktop` has
  the whole channel.
- A window that dies on its first frame disappears silently and `windows`
  does not list it. Usual causes: a `nil` module, a control without `id`, a
  duplicate `id`, a call outside the window's module whitelist, a late
  `local` (below).
- **A compositor crash looks like a delivery problem from outside**: the
  name stays in the registry, the screen holds the last frame, commands get
  no answer. Before hunting a race, look at the compositor's SCREEN.

## 2. The SSH desktop

`app.desktop:ssh` (`src/app/desktop/_index.yaml`): `terminal.ssh` on
`0.0.0.0:2222`, `auth: logon`, `entry: chicago.shell:shell` (the entry ID,
not the CLI command name `windows`), `close_grace: 10s`, `max_sessions: 16`,
host key `.wippy/ssh_host_ed25519_key` (generated once). The kind exists only
in the runtime fork's build.

```bash
ssh -t -p 2222 localhost                  # on the machine
ssh -t -J <machine> -p 2222 localhost     # from outside
```

- The door asks nothing (`auth: logon`): "Welcome to Chicago" checks the
  account's name and password, the same as the web logon; a key pasted in
  Start → Settings → SSH Keys (`app.desktop:ssh_keys_window`, table
  `app_ssh_keys`, `key_owner: app.desktop:ssh_key_owner`) logs its owner on
  without the password screen; an unknown key is refused so the client tries
  its next, and a keyboard-interactive round that asks nothing lets everyone
  else through to the logon.
- **At most 10 failed logons per user name**, counted across connections in
  the memory store `app.desktop:logon_attempts` (`app.desktop:logon_limit`),
  name in lower case, unknown names count too; the tenth answers "Too many
  failed logons" and the name is not checked for 15 minutes; a success
  clears it; a restart forgets the counts. The web logon has no such limit.
- **Every connection is a desktop of its own**: size and resizes from
  `pty-req`/`window-change`, graphics and cell size probed on that very
  terminal, environment from what the client sent — not the server's.
- **A disconnect is a CANCEL, not a crash**: the host asks the desktop to
  finish, the compositor closes its windows as "Shut Down" does, and after
  `close_grace` it is terminated. A frame that cannot be written (the
  terminal is gone) ends the desktop the same way. Nothing is written to a
  terminal that is gone, so the desktop ends with success.
- Bash windows (`window_pty`, `meta.requires: tui_desktop.pty`) are for
  scopes with the action: `app.security:admin` has `*`, an ordinary user is
  refused with the reason on the desktop. Task Manager, AntiBug, Add/Remove
  Programs, Registry Editor require `chicago.admin`.
- Port forwarding and exec are refused; a key with options in
  `authorized_keys` is skipped whole.

## 3. The terminal probe

A full-screen program cannot be judged by its exit code, and an agent has no
terminal. `tools/tui-probe.py` gives a command a PTY of a chosen size, types
by a script (keys, clicks, double-clicks, moves, wheel, drags, resizes — in
command-line order) and prints the screen as a text grid; `--expect` turns
it into a check. Over SSH this logs on and shows the desktop:

```bash
python3 tools/tui-probe.py --cols 100 --rows 30 --boot 15 --settle 3 --tail 6 \
  --send '<email>' --send-key tab --send '<password>' --send-key enter \
  -- ssh -tt -o StrictHostKeyChecking=no -p 2222 localhost
```

- `--boot` is how long to wait before the first step: 15 s is enough for an
  SSH connection to a running application; a cold `wippy run … windows` in
  the probe's own PTY needs `--boot 75` (the first frame comes after the
  ~40 s start).
- `--tail` is separate from `--settle`: the exit of the whole runtime takes
  longer than any pause of the script.
- Mouse steps send real SGR 1006 events with one-based coordinates; a
  double-click goes as one chunk (a pause between the clicks would break
  the timing). Do not add keyboard paths to the interface for the sake of
  the probe.
- **A reproducible result is not proof you measured what you think.** Three
  times "right arrow does not open the submenu" measured a solid zero — the
  script pressed `↓` first "to seat the cursor", which moved it from the
  folder to a program, where right is silent by design. Read the screen
  after every step, not only at the end. And where both sides of a contract
  are in front of you, ten minutes of reading find what three probe runs do
  not; the probe is for the boundary with foreign code.

## 4. The log, the instance, the terminal

- **The log is the stdout of `wippy run`.** The terminal hosts
  (`chicago.shell:terminal`, `chicago.tui_desktop:terminal`) hide their own
  log — a runtime log line would scramble the frame for good — so **a
  failure told only to the log is told to no one**. Run the platform with
  plain `wippy run` (the SSH desktops come with it) when you need the log,
  and read `restore` in the status endpoints for what the compositor could
  not say.
- **One instance.** A second `wippy run` cannot bind `:8099` (and `:2222`)
  and dies quietly while the first keeps serving stale code. If a change
  seems not to have landed, count the processes first. `pgrep -f 'wippy run'`
  also matches the shell you typed it in — take the pid from the port:
  `ss -ltnp | grep -E ':8099|:2222'`.
- **It does not stop quickly.** After `pkill` the process keeps running ~20 s
  (the shell asks its windows to close, waits, then the application stops).
  Wait for the ports to be free (`ss -ltn | grep -E ':8099|:2222'` empty)
  before starting the next one; a fixed sleep is how you end up with two. A
  cold start then takes ~40 s. On the first boot after an install or update
  the modules are re-unpacked while the application starts and every static
  asset answers 500 — restart once more.
- **The terminal is left with mouse modes on** when a desktop ends badly
  (every mouse move types `[<35;…M` into the shell):
  `printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1015l'` or `reset`.
- `--host` is required on every command: the desktop modules bring their own
  `terminal.host` entries and the CLI refuses to pick.

## 5. Updating code without a restart

`tools/live-update.sh <namespace> [migration-id …]` pushes `src/` for one
`app.*` namespace into the running registry through keeper's sync (widens
keeper's managed namespaces from `app.deps` for the run and puts them back),
then runs the named migrations with a dry run first:

```bash
tools/live-update.sh app.desktop                       # entries of src/app/desktop
tools/live-update.sh app.desktop app.desktop:01_ssh_keys
```

- **UPLOAD only.** `POST /keeper/sync/download` writes the registry over the
  source files; never call it. `GET /keeper/sync/state` shows `has_changes`.
- A changed `process.service` **keeps running its old code** (the supervisor
  swaps only the lifecycle config); new services start. Windows and
  libraries take the new code when a process is spawned — close and reopen
  the window. A NEW widget or image-pack entry the running compositor needs
  still wants a restart (the compositor spawns widgets at start and on
  `desktop.refresh`).
- Migrations: `POST /keeper/hub/migrations/run {"entry_ids": [...],
  "operation": "up", "dry_run": true}`; without `dry_run` it applies.

## 6. Tests and lint

```bash
WIPPY=~/src/runtime/dist/wippy-linux-amd64      # the runtime fork's build, always
$WIPPY test --host wippy.terminal:host           # boots the WHOLE application, migrations included
$WIPPY lint --ns app --ns app.desktop --ns app.workshop   # one --ns per namespace you touched
python3 tools/late-locals.py src                 # before lint; wippy lint does not see late locals
```

- `wippy test` here brings the whole application up: run it only when the
  application may come up (ports free, nothing running). New entries load
  only at the next start of whatever is running.
- **Lint only with the fork's build.** A release `wippy` has no `gfx` types,
  so `raster:text`, `gfx.font`, `raster:blit` are nameless to it and it
  answers "clean" on code it could not look at (569 vs 629 findings on one
  stand). The opposite failure exists too: a type declaration stricter than
  the implementation reports 98 "errors" in correct code — the fix goes into
  the declaration, not into 98 `math.tointeger` wrappers. Name a raster's
  font type (`value :: gfx.Font`) rather than `any`, which switches off the
  coordinate checks with it. A typechecker panic (`E9999`) makes a module
  `any` for its neighbours; one clean run proves little — run lint three
  times.
- **A test in the form `return {run = run}` is green because it does not
  run**: `test.describe(...)` inside `local function run()` counts in the
  total, prints `<1ms`, and executes nothing. The form that runs:

  ```lua
  local function define_tests() test.describe(...) end
  local run_cases = test.run_cases(define_tests)
  return {run = function(options) return run_cases(options) end}
  ```

  Break a new test with a mutation first; if it did not go red it is not a
  test. `<1ms` beside a file with ten cases is the tell. The harness has no
  `test.expect`, only `test.eq / is_nil / not_nil / is_true / …`. A case is
  cut off at 30 s.
- A function nobody calls is green in any suite; check the list of
  functions against the list of calls in the tests.

## 7. Traps that fail silently

- **A `local` declared below the function that reads it is a global there,
  that is `nil`**, with no error: "attempt to call a non-function object", an
  empty label, a compositor that "stopped answering" on a rare path. Rule:
  everything a function calls is declared above it. `tools/late-locals.py`
  finds file-level ones; `wippy lint` does not.
- **An unquoted `: ` in a YAML comment or `meta.comment`** breaks the parse
  of the whole `_index.yaml` — lint without JSON, the boot of the whole
  application. Quote such comments.
- **A declared module without the permission answers emptiness, not a
  refusal.** `env.get` returns `nil` plus an error with `kind =
  PermissionDenied`; code that drops the second value turns "may not read"
  into "not set", and a default beside it (`env.get("X") or "app:db"`)
  finishes the disguise. `env.get_all` does not error at all — it just omits
  the forbidden keys. Grant environment rights by name, never `*`; check the
  rule "every declared module has its permission" (`env`→`env.get`,
  `fs`→`fs.get`, `sql`→`db.get`), not a list.
- **A name collision in `ns.dependency` replaces silently**: the runtime logs
  `duplicate entries detected (will use last definition)`, takes the last,
  and the first thing to break is someone else's `ns.requirement` left
  without values; the boot then fails further on, on `duplicate entry id in
  baseline state`.
- **`${env:…}` inside a module entry** resolves against the registry's
  environment, not the OS, and can fail the boot; `exec` does not inherit
  the OS environment — pass `env` explicitly (the PTY window gets `HOME` and
  `PATH` through overrides in `.wippy.yaml`).
- **Two representations of one value diverge silently**: a parsed path vs a
  string, `id` vs `action` in a hit, one rule in two constants, two style
  tables. Each half is right on its own and both look tested; compare the
  SET of fields with the reference consumer, not the presence of a hit.
- **SQLite binds `$N` by order of first appearance**, not by number:
  `SET x=$3 WHERE a=$1` updates 0 rows silently. Write placeholders
  ascending. `as` is a reserved word in this Lua: `local function as()`
  fails the whole boot with a syntax error.
- **Inherited actor counted as substituted** (runtime, fixed in the fork):
  `process.with_options(...):with_context(...)` demanded `process.security`
  even when it substituted nothing — "not allowed to spawn processes with
  custom security context" on a click, the window never opens. Each call
  works alone, so tests pass; only the fork's build has the fix.
- **`funcs` honours the callee's declared actor** (measured): a window with
  a narrow scope calls a `function.lua` with its own actor and wide policy —
  that is the trust anchor, the window gets only `funcs.call` on it.
- **go-lua**, one line each: a tail call `return <yield-call>(...)` from a
  coroutine's base frame never runs (0 ms, empty result, no error — bind the
  result first, then return it; every Go yield: `call_tool`, websocket,
  `ch:receive()`); an error caught by `pcall` splits an upvalue between a
  closure and its owner, frames below the pcall included (keep shared
  mutable state in a table, no `pcall` around the theme in the compositor's
  frame); `string.format("%02x", 255)` prints `"323535"` and `%.1f` with an
  integer prints `%!f(lua.LInteger=3)` (build hex by hand, `x + 0.0` before
  float verbs); `table.concat(t, sep, j+1, j)` returns `t[j]`, not `""`;
  `x and x.f or nil` inside a generic `for` crashed before v1.5.18.
