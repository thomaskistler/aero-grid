# Check out and build

AeroGrid is a Lua widget, not a firmware fork. You do not need to build EdgeTX
or connect a radio to get started. The development build assembles an SD-card
directory that either simulator can boot; the release build creates the ZIP
that users install.

## Get the code

With Git installed, clone the repository and create a branch for your change:

```sh
git clone https://github.com/thomaskistler/aero-grid.git
cd aero-grid
git switch -c my-change
```

If you do not have repository write access, fork it on GitHub and clone your
fork instead. Run all commands in this guide from the repository root.

## Prerequisites

Install Python 3 with virtual-environment support, Make, and rsync.
Python 3.11 is the version used in CI. The Makefile uses a Unix shell and
`bin/` virtual-environment paths: use macOS, Linux, or WSL for these commands.
On Windows, Companion can run natively, but must be pointed at a directory
accessible from Windows.

### Set up the development environment

```sh
make setup
make test
```

`make setup` creates `build/venv/` and installs the pinned `lupa` dependency.
There is no need to activate the environment: Make invokes its Python directly.
`make test` also sets up this environment automatically when needed.

### Install the validation tools

Behavior tests need only the Python environment, but runtime changes also need
these tools on `PATH`:

| Tool | Used for | Version guidance |
| --- | --- | --- |
| `edgetx-luac` or Lua 5.3 `luac` | Parse source and test Lua in `make check`. | Prefer EdgeTX's compiler when available; otherwise use Lua **5.3**, not a different Lua version. |
| `lua-language-server` | Static diagnostics in `make lint`. | CI uses 3.19.1; install the appropriate binary from [LuaLS releases](https://github.com/LuaLS/lua-language-server/releases). |
| `stylua` | Format Lua and check formatting. | CI pins 2.5.2; use [StyLua releases](https://github.com/JohnnyMorganz/StyLua/releases). |

For example, on Debian/Ubuntu:

```sh
sudo apt-get install git make rsync python3 python3-venv lua5.3
make check LUA_COMPILER=luac5.3
```

On macOS with Homebrew, the basic dependencies and Lua compiler can be installed
with:

```sh
brew install python rsync lua@5.3
make check LUA_COMPILER="$(brew --prefix lua@5.3)/bin/luac"
```

Install LuaLS and StyLua separately and ensure their executables are on `PATH`.
The VS Code Lua extension is useful in the editor, but does not by itself make
the LuaLS command-line binary available to Make.

`make check` searches for `edgetx-luac`, `luac5.3`, then `luac`.
If the last one is a different version, pass `LUA_COMPILER` explicitly.
See [Test and debug](testing.md) for the complete validation workflow.

## Build

```sh
make build
```

This creates the SD image at `build/sdcard/`. To see the dashboard, follow
[Run and test in simulators](simulators.md).

### What the build does

```text
tests/fixtures/sdcard/        radio, models, registry, and model image
            +
src/WIDGETS/AeroGrid/         current widget, panels, libraries, and layouts
            |
            v
build/sdcard/                disposable simulator SD-card root
```

`make build` copies the fixture first, then overlays the whole widget package.
It removes compiled `.luac` files and updates Lua source timestamps so EdgeTX
recompiles the current sources. There is no transpilation or native compilation
of AeroGrid itself.

**Stop the simulator before rebuilding.** The build recreates the image from
the baseline, deleting simulator-created models, saved layouts, registry changes,
and other files not present in the fixture. Back up experiments outside that
directory first. Never point a build at a real SD card or personal model backup.

Use a separate image when you want an independent experiment:

```sh
make build BUILD_DIR=build/experiment
```

Its SD-card root is `build/experiment/sdcard/`; change the simulator path to match.
Changing `BUILD_DIR` also relocates Make-managed environments and output.
The screenshot tools have their own fixed output paths, described in
[Project tools](tools.md).

## Build an installable package

```sh
make release-package
```

This writes `AeroGrid-<version>.zip` and its `.sha256` file to `build/release/`,
using the version in `src/WIDGETS/AeroGrid/lib/package.lua`. The archive contains
runtime Lua, the editor assets, the `Default`, `Empty`, `Host`, and `Theme` layouts, and
the license. Review layouts, fixture models, simulator state, and bytecode are
not included.

Use this ZIP, rather than the development SD image, to check the actual
[installation and upgrade procedure](../user-guide/installation.md).
Publishing a release is a separate [maintainer workflow](contributing.md#publish-a-release).

## Build and preview the documentation

```sh
make docs
make docs-serve
```

The first command installs the pinned MkDocs dependency into
`build/docs-venv/` and strictly builds the site at `build/docs/`.
The second serves a live-reloading preview at `http://127.0.0.1:8000`;
stop it with Ctrl-C.

Markdown lives in `docs/`. When adding or renaming a page, update **both**
`mkdocs.yml` and the explicit sidebar in `docs/overrides/toc.html`.
Site styling is in `docs/stylesheets/aerogrid.css`. Checked-in screenshots are
used as-is; building the site never launches a simulator.

## Command reference

| Command | Result |
| --- | --- |
| `make help` | List supported targets. |
| `make setup` | Install development Python dependencies. |
| `make test` | Run every Lua behavior suite once with firmware-like string behavior. |
| `make check` | Run behavior tests, then parse source/test Lua. |
| `make lint` | Run LuaLS diagnostics. |
| `make format` | Rewrite source/test Lua using StyLua. |
| `make build` | Reset and assemble the development SD image. |
| `make capture-setup` | Install optional panel screenshot dependencies. |
| `make release-package` | Generate the installation ZIP and checksum. |
| `make docs` / `make docs-serve` | Build / preview the website. |
| `make clean` | Delete the configured build directory, including environments and simulator state. |
