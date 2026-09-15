---
name: chicago-add-module
description: Add a module from its GitHub repository to the Chicago application (the ns.dependency entry in src/app/deps/_index.yaml naming the repository and a version range over its tags, with the parameters that bind the module's requirements, wippy update, restart), move a module to a newer tag, pin a branch or commit for development, or write a NEW module of the Chicago shell from chicago/module-template and release it by pushing a semver tag. Use when a program should appear in the Start menu that lives in a module, or when a module's version has to move.
---

# Adding a module to the application

The desktop's modules come from their GitHub repositories through the
runtime's git sources: a dependency names the repository, the versions are
the repository's semver tags, and the lock records the commit. The platform
modules (`kickside/*`) still come from the Hub. Nothing is replaced from
working copies. A module reaches the desktop in three steps, each necessary:
a dependency entry, a resolve into the lock, a restart.

## 1. The dependency entry

`src/app/deps/_index.yaml`, namespace `app.deps`, one `ns.dependency` per
module. Copy the shape of an existing entry:

```yaml
  # app.deps:weather
  - version: '>=0.2.0'
    name: weather
    kind: ns.dependency
    meta: {}
    component: github.com/chicago-desktop/weather
    parameters:
      - name: chicago.weather:target_db
        value: app:db
      - name: chicago.weather:process_host
        value: app:processes
```

- **`component` names the repository**, not a Hub module:
  `github.com/<org>/<repo>` (https assumed; a full `https://…` or `ssh://…`
  url and `git@host:org/repo.git` work too). The module's own name is what
  its `wippy.yaml` says (`chicago/weather`); the lock and the other modules
  refer to it by that name, and two dependencies resolving to the same module
  name from different sources are refused with both sources. A `component`
  of the form `org/module` (two segments, no dot) is a Hub module — that is
  how the `kickside/*` entries stay.
- **`version` is a range over the repository's semver tags** — `>=0.2.0`
  today (the modules' first tag is `v0.2.0`; `v0.2.1` and `0.2.1` count
  alike). The highest matching tag wins; a range no tag satisfies is refused
  naming the tags seen, and `'*'` against a repository with no tags is
  refused too: a branch is not a version (see the replacement below).
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
- **The entry `name` must be unique in `app.deps`.** A second entry with the
  same name does not warn for real: the runtime logs `duplicate entries
  detected (will use last definition)`, takes the last, and the first thing
  to break is the other module's `ns.requirement`s left without values; the
  boot then fails further on, on `duplicate entry id in baseline state`,
  pointing at the duplicate, not at the requirements.
- Keep the file's comments free of an unquoted `: ` — it breaks the parse of
  the whole index.
- The shell's **Add/Remove Programs** (Start → Settings) edits this same file
  through `app.desktop:deps_source` (`CHICAGO_DEPS_FS` in `.wippy.yaml`); it
  installs nothing into the running runtime either — the two steps below
  follow, and the window says so.

## 2. Resolve and restart

```bash
cp wippy.lock wippy.lock.bak     # wippy update rewrites the lock; a dropped dependency is a boot that fails
wippy update                      # lists each repository's tags (git ls-remote), picks the version, resolves it to a commit, writes the lock; kickside/* against the Hub
```

- The lock entry of a git module carries `source`, `commit` and
  `local_hash` (the tree hash of the checkout) instead of the Hub's `hash`:

  ```yaml
  - name: chicago/weather
    version: 0.2.0
    source: github.com/chicago-desktop/weather
    commit: 4fda75926ec141bbfd4a92cc9f96490feee1e969
    local_hash: sha256-tree-v1:…
  ```

  A declared dependency missing from `wippy.lock`, or an entry with `source`
  and no `commit`, stops the boot outright. Both ways to hit it — an entry
  added without a resolve, a range nothing satisfies — are fixed by
  correcting the entry and running `wippy update` again.
- **`wippy install` and the boot never look at the tags**: they take the
  commit from the lock. The cache is `~/.wippy/git/<host>/<path>/` — one bare
  clone per repository (`repo.git`) and one checkout per commit
  (`checkouts/<commit>/`), read-only for the runtime, `WIPPY_GIT_CACHE`
  overrides the location. A commit already checked out needs no network, so
  a fresh checkout of this repository needs `git` on PATH and the network
  once, for `wippy install`; every later boot works offline. A checkout
  whose tree hash differs from `local_hash` is refused.
- **`wippy update` is how a module is updated**, and the only thing that
  follows a tag: `>=0.2.0` re-resolves to the newest matching tag. A tag
  moved on GitHub changes nothing here until the next `update` — the lock
  holds the commit, not the tag. Authentication is git's own (credential
  helpers, the ssh agent, `GIT_*`); a private repository needs whatever
  `git clone` of it needs.
- **A new entry loads only at the next start.** Stop the running instance
  (it takes ~20 s; wait for `:8099` and `:2222` to be free), then `wippy run`.
  On the first boot after an update the modules are re-unpacked while the
  application starts and static assets answer 500 — restart once more.
- The module's windows appear in the Start menu under the folder the
  **module** declares (`meta.group`, e.g. `Programs/Weather`); without a
  group a window lands in `Programs`. The application does not keep a
  catalog of its own; `GET /api/v1/chicago/programs` shows what the registry
  found.
- A module's desktop widget or image pack is a registry entry the compositor
  reads at start — a restart, not a live update.

### Pinning a branch or a commit (development only)

A replacement in `.wippy.yaml` overrides the module's name with `url#ref`;
the ref (a branch or a commit) is resolved on `update` and recorded as a
commit — a branch is followed only by the next `update`, like a tag:

```yaml
workspace:
  replacements:
    chicago/weather: https://github.com/chicago-desktop/weather#main
    # or a commit: https://github.com/chicago-desktop/weather#4fda759…
    # or a working copy: ../weather
```

The dependency entry stays as it is (the range is not consulted while the
replacement is in place). Take the replacement out and run `wippy update`
before the lock is committed: `.wippy.yaml` is committed too, and a
replacement left there pins every checkout of this repository to that ref.

## 3. Writing a new module: the template

The template is `chicago/module-template`
([chicago-desktop/module-template](https://github.com/chicago-desktop/module-template)):
one sample window on the shell's SDK (`src/view.lua` — the window as data, a
pure library the tests exercise; `src/window.lua` — the process that runs
it), the module's image pack (`assets/images/{32,16}/hello.png`), the
harness in `test/`, the checks and the release targets in the Makefile.

```bash
gh repo create <owner>/<name> --template chicago-desktop/module-template --clone   # or "Use this template" on GitHub, or clone
cd <name>
make init ORG=chicago MODULE_NAME=<name> TITLE="<Title>"      # renames the template's identity; refuses to run twice with another identity
make setup WIPPY=~/src/runtime/dist/wippy-linux-amd64          # resolves the module's and the harness's locks (the shell and the base from GitHub by tag)
make check                                                     # identity, dependency ranges, embed list, no Cyrillic, no secrets
make lint                                                      # late locals, then wippy lint --ns <module ns> --ns app
make test                                                      # the harness boots the module with the shell; an empty discovery fails
```

`make init` also takes `NAMESPACE=`, `TAG=`, `GITHUB_OWNER=`
(`scripts/init-module.mjs --help`). Then rewrite the sample window: the
entry in `src/_index.yaml` (`meta.type: tui_desktop.window`, `title`,
`group: Programs/<Module>`, `image: <ns>:images/<file>`, `icon` for a
terminal without graphics, `width`/`height`, `pixel_render:
chicago.shell.sdk:render`, `pixel_state: <ns>:window`, `imports: {app:
chicago.shell.sdk:app}`, `security.policies: [chicago.shell.security:view_state]`)
and the code against the SDK — skill `wippy-window-app`, `docs/sdk.md`.

Rules the module has to keep:

- **It depends on `chicago/shell` and `chicago/tui-desktop`** — two
  `ns.dependency` entries in its `src/_index.yaml` naming the repositories
  (`component: github.com/chicago-desktop/shell`, `…/tui-desktop`) with a
  range (`>=0.2.0`), never an exact version. The shell lays out and draws
  the window, the base owns its frame and input. Git dependencies are
  transitive: the application resolves the module's own dependencies the
  same way.
- **Its own resources are `ns.requirement`s** (a database, a process host,
  a router, the user scope), not hard-coded `app:*` ids: the application
  binds them in step 1.
- **`make test` and `make lint` only with the runtime fork's build** (`WIPPY=`;
  the shell declares `gfx`, the release binary does not load it at all, and
  only the fork's build resolves modules from git).
- **Everything outside `src/` that the module declares lives in the
  repository** — image packs (`fs.directory`, `meta.type: chicago.images`,
  `base: module`), assets. A git checkout is loaded like a directory: the
  entries come from `src/` and `fs.directory` entries with `base: module`
  resolve against the checkout, so `embed:` in `wippy.yaml` is no longer
  needed for the pictures to arrive. It is harmless to keep — `wippy
  publish` (the Hub packaging) still reads it, and `scripts/check-module.mjs`
  still verifies every pack is listed.
- English only; no secrets in the tree (`make check`).

## 4. Releasing

A release is a semver tag on the module's repository — that is what
`wippy update` here lists and resolves:

```bash
make release-check                       # verify: setup, check, lint, test
git tag -a v0.2.1 -m "weather 0.2.1"     # the tag is the version; `v` optional
git push origin v0.2.1
```

- **A pushed tag is immutable in effect**: the lock records the commit it
  pointed to, and a moved tag is followed only by an explicit `wippy update`
  — nobody's boot changes underneath them. Bump the patch instead of moving
  a tag; a range that is already satisfied by the old tag only moves when
  `update` runs.
- The version the tag names should match the module's `wippy.yaml`; the
  lock's `version` comes from the tag.
- The template's `make publish` / `wippy publish --create …` is the Hub
  path; this application does not read the Hub for the desktop's modules,
  so a Hub publish alone changes nothing here.
- After the tag: the dependency entry here (step 1, or nothing for a module
  already declared), `wippy update` (step 2) with the lock backed up, a
  restart. `wippy.lock` is committed in this repository; `wippy install` on a
  fresh checkout takes the commits from it.
