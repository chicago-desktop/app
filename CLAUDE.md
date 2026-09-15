# app — the Chicago desktop application

A wippy *application*, not a module: it composes modules — the kickside
platform from the Hub; `chicago/tui-desktop`, `chicago/shell`, the games and
apps from their GitHub repositories by tag — and adds what only an
application declares — the logon, the SSH host, the system windows. Its own
namespace is `app` / `app.*`; the dependencies are in
`src/app/deps/_index.yaml`; the overrides in `.wippy.yaml`.

## Rules

- **English only.** Code, comments, `meta.comment`, YAML comments, docs,
  commit messages. No Russian anywhere (owner's rule).
- **It runs only on a build of the runtime fork** — chicago-desktop/runtime,
  branch `wippy-projects`. The shell declares the `gfx` module and the
  application declares a `terminal.ssh` host; a release `wippy` has neither,
  and one unknown module fails the whole boot. Set `WIPPY` for `make`.
- **Installation and operation on a server: `INSTALLATION.md`** — keep it in
  step with the `Makefile` and `.wippy.yaml` (the runtime target, the
  addresses, the overrides) and with `src/app/desktop/_index.yaml` (the SSH
  host).
- **Ports:** the gateway on `127.0.0.1:8099` (loopback on purpose, set in
  `.wippy.yaml`), the SSH desktop on `0.0.0.0:2222`. One instance at a time —
  a second one dies quietly on the port; stopping takes ~20 s.
- **`--host` on every command:** `wippy run --host chicago.shell:terminal chicago`
  for the local desktop, `wippy test --host wippy.terminal:host` for the tests
  (which boot the whole application).
- **The desktop's modules come from GitHub tags through the runtime's git
  sources** (`component: github.com/chicago-desktop/<name>`, a range over the
  repository's semver tags, `>=0.2.0`); only the `kickside/*` platform
  modules come from the Hub. The lock records the commit (`source`,
  `commit`, `local_hash`) and is committed; `wippy install` on a fresh
  checkout needs `git` on PATH and the network the first time only (the
  cache is `~/.wippy/git`, `WIPPY_GIT_CACHE`), later boots work offline. A
  moved tag is followed only by `wippy update`. Skill `chicago-add-module`
  has the whole procedure, the `url#ref` replacement for a branch included.
- **`wippy update` rewrites `wippy.lock`.** Back it up first; a dependency
  missing from the lock stops the boot.
- **Entry ids named by environment variables stay put:** `app.desktop:logon`,
  `app.desktop:user_name`, `app.desktop:deps_source`, and the Users module's
  `chicago.users:profile` (see the `CHICAGO_*` overrides in `.wippy.yaml`).
- An unquoted `: ` inside a YAML comment or `meta.comment` breaks the whole
  index file; quote `meta.comment` values that contain a colon.
- `tools/late-locals.py src` finds file-level locals used above their
  declaration (a nil in Lua, silently); `wippy lint` does not.
- Skills for the work here are in `.claude/skills/` — `chicago-debug` (what
  the desktop is doing, the probe, live update, the silent traps),
  `chicago-add-module`, `tui-desktop`, `wippy-window-app`,
  `wippy-window-workshop`; the README's "For agents" lists them.
- The icon set (an interim one, being replaced with original pixel art —
  chicago-desktop/shell#1) ships with the shell module; the application
  carries no icon files of its own.
