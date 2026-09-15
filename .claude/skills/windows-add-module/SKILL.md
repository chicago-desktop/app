---
name: windows-add-module
description: Add a Hub module to the Wippy Windows application (the ns.dependency entry in src/app/deps/_index.yaml with the parameters that bind the module's requirements, wippy update, restart), update a module to its newest version, or write a NEW module of the Windows 95 shell from the windows/module-template and publish it to the Hub. Use when a program should appear in the Start menu that lives in a module, or when a module's version has to move.
---

# Adding a module to the application

The application composes Hub modules; nothing is replaced from working copies.
A module reaches the desktop in three steps, each necessary: a dependency
entry, a resolve into the lock, a restart.

## 1. The dependency entry

`src/app/deps/_index.yaml`, namespace `app.deps`, one `ns.dependency` per
module. Copy the shape of an existing entry:

```yaml
  # app.deps:weather
  - version: '>=v0.0.0'
    name: weather
    kind: ns.dependency
    meta: {}
    component: windows/weather
    parameters:
      - name: windows.weather:target_db
        value: app:db
      - name: windows.weather:process_host
        value: app:processes
```

- **`parameters` bind the module's `ns.requirement`s** — the module declares
  what it needs, the application says which of its resources answers. The
  requirements seen so far and what answers them here:

  | requirement | value here | what it is |
  |---|---|---|
  | `<ns>:target_db` | `app:db` | the application's database (migrations, tables) |
  | `<ns>:process_host` | `app:processes` | the host for the module's services |
  | `<ns>:api_router` | `app:api` | the authenticated router, prefix `/api/v1` |
  | `<ns>.security:user_security_scope` | `app.security:user` | the scope a logged-on user's windows run under |

  Read the module's own `_index.yaml` (or its README) for the exact
  requirement ids: the name is `<module namespace>:<requirement>`, and a
  requirement left without a value fails the boot or leaves the module mute.
  A module with no requirements (Minesweeper) takes no `parameters`.
- **`version` is a range, `'>=v0.0.0'` here**: the lock holds the exact
  version. A range that no published version satisfies (`>=0.3.33` against
  a newest `0.3.32`) stops the boot as "unresolved".
- **The entry `name` must be unique in `app.deps`.** A second entry with the
  same name does not warn for real: the runtime logs `duplicate entries
  detected (will use last definition)`, takes the last, and the first thing
  to break is the other module's `ns.requirement`s left without values; the
  boot then fails further on, on `duplicate entry id in baseline state`,
  pointing at the duplicate, not at the requirements.
- Keep the file's comments free of an unquoted `: ` — it breaks the parse of
  the whole index.
- The shell's **Add/Remove Programs** (Start → Settings) edits this same file
  through `app.desktop:deps_source` (`WINDOWS_DEPS_FS` in `.wippy.yaml`); it
  installs nothing into the running runtime either — the two steps below
  follow, and the window says so.

## 2. Resolve and restart

```bash
cp wippy.lock wippy.lock.bak     # wippy update rewrites the lock; a dropped dependency is a boot that fails
wippy update                      # re-resolves src/app/deps against the Hub
```

- A declared dependency missing from `wippy.lock` stops the boot outright
  (the runtime verifies offline evidence and refuses). Both ways to hit it —
  an entry added without a resolve, a range nothing satisfies — are fixed by
  correcting the entry and running `wippy update` again.
- `wippy update` re-resolves `>=v0.0.0` to the **newest** published version:
  that is also how a module is updated. A published version is immutable, so
  a module's fix is always a new version; pull it with `wippy update`.
- **A new entry loads only at the next start.** Stop the running instance
  (it takes ~20 s; wait for `:8099` and `:2222` to be free), then `wippy run`.
  On the first boot after an update the modules are re-unpacked while the
  application starts and static assets answer 500 — restart once more.
- The module's windows appear in the Start menu under the folder the
  **module** declares (`meta.group`, e.g. `Programs/Weather`); without a
  group a window lands in `Programs`. The application does not keep a
  catalog of its own; `GET /api/v1/windows/programs` shows what the registry
  found.
- A module's desktop widget or image pack is a registry entry the compositor
  reads at start — a restart, not a live update.

## 3. Writing a new module: the template

The template is `windows/module-template`
([wippy-windows/module-template](https://github.com/wippy-windows/module-template)):
one sample window on the shell's SDK (`src/view.lua` — the window as data, a
pure library the tests exercise; `src/window.lua` — the process that runs
it), the module's image pack (`assets/images/{32,16}/hello.png`), the
harness in `test/`, the checks and the publish targets in the Makefile.

```bash
gh repo create <owner>/<name> --template wippy-windows/module-template --clone   # or "Use this template" on GitHub, or clone
cd <name>
make init ORG=windows MODULE_NAME=<name> TITLE="<Title>"      # renames the template's identity; refuses to run twice with another identity
make setup WIPPY=~/src/runtime/dist/wippy-linux-amd64          # resolves the module's and the harness's locks from the Hub
make check                                                     # identity, dependency ranges, embed list, no Cyrillic, no secrets
make lint                                                      # late locals, then wippy lint --ns <module ns> --ns app
make test                                                      # the harness boots the module with the shell; an empty discovery fails
```

`make init` also takes `NAMESPACE=`, `TAG=`, `GITHUB_OWNER=`
(`scripts/init-module.mjs --help`). Then rewrite the sample window: the
entry in `src/_index.yaml` (`meta.type: tui_desktop.window`, `title`,
`group: Programs/<Module>`, `image: <ns>:images/<file>`, `icon` for a
terminal without graphics, `width`/`height`, `pixel_render:
windows.shell.sdk:render`, `pixel_state: <ns>:window`, `imports: {app:
windows.shell.sdk:app}`, `security.policies: [windows.shell.security:view_state]`)
and the code against the SDK — skill `wippy-window-app`, `docs/sdk.md`.

Rules the module has to keep:

- **It depends on `windows/shell` and `windows/tui-desktop`** — two
  `ns.dependency` entries in its `src/_index.yaml` with a range (`"*"`),
  never an exact version. The shell lays out and draws the window, the base
  owns its frame and input.
- **Its own resources are `ns.requirement`s** (a database, a process host,
  a router, the user scope), not hard-coded `app:*` ids: the application
  binds them in step 1.
- **`make test` and `make lint` only with the runtime fork's build** (`WIPPY=`;
  the shell declares `gfx`, the release binary does not load it at all).
- **Everything outside `src/` that the module declares goes under `embed:` in
  `wippy.yaml`** — image packs (`fs.directory`, `meta.type: windows.images`),
  assets. `wippy publish` packs the entries of `src/` and embeds only what is
  listed; without the line the published module has no pictures.
  `scripts/check-module.mjs` verifies every pack is there.
- English only; no secrets in the tree (`make check`).

## 4. Publishing

```bash
make release-check     # verify + wippy auth status + a publish dry run
make publish           # node scripts/check-module.mjs && wippy publish --create --module-visibility public --module-type plugin
```

By hand, the same call:

```bash
wippy publish --version X.Y.Z --create --module-visibility public --module-type plugin
```

- `--create` registers the module in the Hub on its first publish;
  `--module-visibility public` is the `windows` organization's rule (set
  `VIS=private` in the Makefile for a module that must not be), the type is
  `plugin`.
- **A published version is immutable**: publishing over one answers
  `version_exists`. Bump the patch instead of correcting a version in place.
  Without `--version` the publisher bumps the latest published one.
- After publishing: the dependency entry here (step 1), `wippy update`
  (step 2) with the lock backed up, a restart. `wippy.lock` is committed in
  this repository; `wippy install` on a fresh checkout takes the modules
  from it.
