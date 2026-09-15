---
name: tui-desktop
description: Drive the windows of a live desktop (chicago/tui-desktop, the Chicago shell over it) through its command channel — open a window with a program, type into it, read its screen, move or close a window, bring the desktop up. Use when an agent must act on a running desktop without touching the person's keyboard.
---

# Driving the desktop

The desktop holds windows with real programs. Through the command channel an
agent drives them while a person works at the same screen: there is one
compositor, and it serializes the keyboard with the commands itself.

Work through the channel, not through the person's keyboard: their terminal
does not belong to you.

## Address and access

The endpoints live behind the application's authenticated router, and **the
prefix is set by the application, not by the module**: in this application
the router is `app:api`, so the channel is `/api/v1/tui-desktop` on
`127.0.0.1:8099` (in the module's own harness it is `/api`). A miss does not
look like a miss: an unknown path answers the facade page with code 200, so
"no such endpoint" is indistinguishable from "the endpoint answered" by the
code alone. The sign of a hit is `application/json` in the answer.

The token is an account's session token: mint one with the account's e-mail
and password, it lives 24 hours. `{"error":"Authentication required"}` means
an expired token, not a broken application.

```bash
curl -s -H 'Content-Type: application/json' -X POST \
  -d '{"email":"admin@example.com","password":"…"}' \
  http://127.0.0.1:8099/api/public/user/token | jq -r .token   # → KICKSIDE_API_TOKEN

set -a; . ./.env.local; set +a                       # or export KICKSIDE_API_TOKEN
API="http://127.0.0.1:8099/api/v1/tui-desktop"       # the prefix comes from the application
AUTH="Authorization: Bearer $KICKSIDE_API_TOKEN"
```

The shell has an API of its own next to the channel, under
`/api/v1/windows/...`: `GET /api/v1/chicago/status` (is the shell alive, its
windows, the workshop `restore` report, the frame instruments),
`GET /api/v1/chicago/programs` (the Start menu catalog from the registry),
`GET|POST /api/v1/chicago/desktop` and `PATCH|DELETE /api/v1/chicago/desktop/{id}`
(the desktop shortcuts).

## What can be done

Every command answers `{"success":true,...}` or the reason of a refusal. There
is no silence: a desktop that is not running, a desktop that does not answer
and a window that does not exist are three different answers.

```bash
curl -s -H "$AUTH" $API/windows                       # what is open, the focus, the screen size

curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST \
  -d '{"title":"build","command":"/bin/bash --noprofile --norc","x":4,"y":3,"w":80,"h":20}' \
  $API/windows                                        # → {"window":{"id":"w1",...}}

curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST \
  -d '{"entry":"app.desktop:ssh_keys_window"}' $API/windows   # an application window

curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST \
  -d '{"text":"make test","enter":true}' $API/windows/w1/type

curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST \
  -d '{}' $API/windows/w1/screen                      # → {"rows":[...]} — the window's screen
```

A window with a program is opened by `command`, an application window by
`entry` (a process entry declared by the application or a module). What is
declared is visible in the Start menu; the same mark,
`meta.type: tui_desktop.window`, can be searched in the registry
(`GET /api/v1/chicago/programs` lists it).

The other actions of the same shape: `key` (`key`, `ctrl`, `alt`, `shift`),
`move` (`x`, `y`), `resize` (`w`, `h`), `focus`, `minimize` (`value`), `close`.

With the SSH host there can be several desktops in one runtime, one per
connection (the name family `chicago.shell.desktop`, `chicago.shell.desktop.2`, …). The
channel addresses the first one; a command meant for every desktop (a tray
item, a refresh) is sent by code that iterates the family.

## How to read the result

**The screen is the only evidence.** The return code of `type` says only that
the keys reached the window; what the program did with them is visible only
in `screen`. So after every meaningful input read the screen and judge by it.

**A window does not answer at once.** A fresh window reports `"ready": false`
until the program has drawn its first frame; input in that gap is refused
with a reason. Read `screen` again until the expected text appears, not right
after `type`.

**The screen is a snapshot, not a log.** `rows` hold what is visible now: a
long output scrolls away for good. Give a command whose whole output is
needed a file (`make test > /tmp/out.log 2>&1`) and read the file separately.

**A pixel window has no text screen.** A window drawn through the shell's
pixel renderer (`pixel_render`) answers an empty `screen`; its evidence is a
PNG rendered offline by the same code (skill `wippy-window-workshop`,
"Verification").

## Building a new window

A window need not be a file: its code travels in the request body, is applied
to the registry and shows up in the menu at once.

```bash
curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST \
  -d '{"name":"clock","title":"Clock","width":30,"height":6,
       "modules":["time"],"source":"local tty = require(\"tty\") … return {main = main}"}' \
  ${API%/tui-desktop}/tui-desktop/apps
```

The code must return a table with `main`, and the modules come from a
whitelist (`json`, `sql`, `time` on top of the always present `tty`,
`channel`, `process`; no `fs`, `env`, `exec`, `http`). A stored window
survives a restart: `GET /tui-desktop/apps` shows the list with the `live`
flag (stored but not registered now is not the same as gone),
`DELETE /tui-desktop/apps/{name}` removes it. The same fields as an entry from
a file are accepted (`imports`, `pixel_render`, `group`, `image`, `icon`,
`window_type`, `resizable`, `in_menu`) — that is how a window on the shell's
SDK is built here; the details are in the skill `wippy-window-workshop`.

Such a window opens like any other — by the `entry` from the answer.

## Bringing the desktop up

```bash
wippy run                                           # the web platform on :8099 and the SSH desktop on :2222
wippy run --host chicago.shell:terminal chicago     # the Chicago shell in this terminal
wippy run --host chicago.tui_desktop:terminal desktop   # the bare desktop base, no shell
```

`--host` is required: the CLI's terminal-host autodetection counts
`terminal.host` entries, and the desktop modules bring more than one. The
local-terminal commands take the terminal whole and bring up the full runtime
with the gateway, so a person runs them — an agent has no terminal, and
without one `screen_size()` answers zeros. The SSH desktop needs no terminal
on the server side: `ssh -t -p 2222 localhost` from any client (skill
`chicago-debug`).

Whether a desktop is up is one `GET /windows` on the channel: it answers a
list, not "not running". `GET /api/v1/chicago/status` answers
`running: false` for a shell that is shut down — with code 200, because a
shut-down shell is not a broken application.
