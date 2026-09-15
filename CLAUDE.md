# app — the Chicago desktop application

A wippy *application*, not a module: it composes Hub modules (the kickside
platform, `chicago/tui-desktop`, `chicago/shell`, the games and apps) and adds
what only an application declares — the logon, the SSH host, the system
windows. Its own namespace is `app` / `app.*`; the dependencies are in
`src/app/deps/_index.yaml`; the overrides in `.wippy.yaml`.

## Rules

- **English only.** Code, comments, `meta.comment`, YAML comments, docs,
  commit messages. No Russian anywhere (owner's rule).
- **It runs only on a build of the runtime fork** — chicago-desktop/runtime,
  branch `wippy-projects`. The shell declares the `gfx` module and the
  application declares a `terminal.ssh` host; a release `wippy` has neither,
  and one unknown module fails the whole boot. Set `WIPPY` for `make`.
- **Ports:** the gateway on `127.0.0.1:8099` (loopback on purpose, set in
  `.wippy.yaml`), the SSH desktop on `0.0.0.0:2222`. One instance at a time —
  a second one dies quietly on the port; stopping takes ~20 s.
- **`--host` on every command:** `wippy run --host chicago.shell:terminal chicago`
  for the local desktop, `wippy test --host wippy.terminal:host` for the tests
  (which boot the whole application).
- **`wippy update` rewrites `wippy.lock`.** Back it up first; a dependency
  missing from the lock stops the boot.
- **Entry ids named by environment variables stay put:** `app.desktop:logon`,
  `app.desktop:user_name`, `app.desktop:deps_source`, `app.profile:window`
  (see the `CHICAGO_*` overrides in `.wippy.yaml`).
- An unquoted `: ` inside a YAML comment or `meta.comment` breaks the whole
  index file; quote `meta.comment` values that contain a colon.
- `tools/late-locals.py src` finds file-level locals used above their
  declaration (a nil in Lua, silently); `wippy lint` does not.
- Skills for the work here are in `.claude/skills/` — `windows-debug` (what
  the desktop is doing, the probe, live update, the silent traps),
  `windows-add-module`, `tui-desktop`, `wippy-window-app`,
  `wippy-window-workshop`; the README's "For agents" lists them.
- The icon set (an interim one, being replaced with original pixel art —
  chicago-desktop/shell#1) ships with the shell module; the application
  carries no icon files of its own.
