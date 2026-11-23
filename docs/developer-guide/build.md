# Check out and build

AeroGrid is a Lua widget, not a firmware fork. Development builds assemble a
simulator SD card; release builds create the installable ZIP. Neither requires
building EdgeTX or connecting a radio.

## Get the code

```sh
git clone https://github.com/thomaskistler/aero-grid.git
cd aero-grid
git switch -c my-change
```

Fork and clone your fork if you do not have write access. Run guide commands
from the repository root.

## Prerequisites

Use macOS, Linux, or WSL with Git, Make, rsync, and Python 3 with
virtual-environment support. CI uses Python 3.11. The Makefile requires a Unix
shell and `bin/` environment paths. Native Windows Companion can use an SD
directory accessible from Windows.

```sh
make setup
make test
```

`make setup` installs pinned development dependencies into `build/venv/`.
Make invokes that environment directly; activation is unnecessary.
`make test` also creates it when needed.

### Install the validation tools

Runtime changes also need these executables on `PATH`:

| Tool | Purpose | Version |
| --- | --- | --- |
| `edgetx-luac` or Lua 5.3 `luac` | Source/test syntax checks in `make check`. | EdgeTX's compiler or Lua **5.3**. |
| `lua-language-server` | Static diagnostics in `make lint`. | CI uses 3.19.1. |
| `stylua` | Formatting and formatting checks. | CI pins 2.5.2. |

For Debian/Ubuntu:

```sh
sudo apt-get install git make rsync python3 python3-venv lua5.3
make check LUA_COMPILER=luac5.3
```

For macOS with Homebrew:

```sh
brew install python rsync lua@5.3
make check LUA_COMPILER="$(brew --prefix lua@5.3)/bin/luac"
```

Install [LuaLS](https://github.com/LuaLS/lua-language-server/releases) and
[StyLua](https://github.com/JohnnyMorganz/StyLua/releases) separately.
The VS Code Lua extension alone does not put LuaLS on Make's `PATH`.
`make check` searches for `edgetx-luac`, `luac5.3`, then `luac`; pass
`LUA_COMPILER` explicitly if discovery selects a different Lua version.

## Build

```sh
make build
```

This recreates `build/sdcard/` from `tests/fixtures/sdcard/`, overlays the widget
source and development layouts, and removes stale bytecode. There is no
transpilation or native compilation of AeroGrid.
See [Run and test in simulators](simulators.md) to use it.

**Stop the simulator before rebuilding.** A build deletes simulator-created
state in that image. Back up experiments elsewhere, and never build onto a
radio SD card or personal model backup.

For a separate image, use `make build BUILD_DIR=build/experiment` and point
the simulator at `build/experiment/sdcard/`. `BUILD_DIR` relocates Make-managed
environments and output, but not the [capture tools' output](tools.md).

## Build an installable package

```sh
make release-package
```

This writes `AeroGrid-<version>.zip` and `.zip.sha256` to `build/release/`,
using `lib/package.lua`. The deterministic source-only package includes runtime
code/assets, the license, and the `Default` and `Empty` layouts. Development
fixtures and bytecode are excluded.

Use the ZIP to check the actual
[installation and upgrade procedure](../user-guide/installation.md).
Packaging does not publish; see [Publish a release](contributing.md#publish-a-release).

## Build and preview the documentation

```sh
make docs
make docs-serve
```

These install pinned tools into `build/docs-venv/`, strictly build the site at
`build/docs/`, and serve a live preview at `http://127.0.0.1:8000`.
Stop the preview with Ctrl-C.

Markdown lives in `docs/`. Add or rename pages in both `mkdocs.yml` and
`docs/overrides/toc.html`. Site styles live in `docs/stylesheets/`; shared
Radio Console styles are in `console.css`. Builds use checked-in screenshots
without launching a simulator.

### Browser installer assets

The installer modules live in `docs/javascripts/`: `radio-storage.mjs` owns
connections, `radio-installer.mjs` handles verified widget replacement,
`radio-panel.mjs` drives the UI, and `radio-connection-help.mjs` provides help.

Automatic installation uses mirrored published stable releases and the rolling
`dev` release, not checkout sources. Dev is opt-in; beta/RC releases are
excluded. Only `WIDGETS/AeroGrid` is replaced. Downloads and installed content
are verified, but there is no backup or rollback.

To preview with mirrored assets:

```sh
make docs
python3 tools/installer_assets.py --output build/docs/installer
python3 -m http.server 8000 --directory build/docs
```

Mirroring requires GitHub access; optional `GH_TOKEN` stays server-side.
Use desktop Chrome or Edge over HTTPS or localhost. `make docs-serve` does not
mirror assets; unmirrored releases cannot be installed automatically.
Never direct generated output at a radio SD card.

## Command reference

| Command | Result |
| --- | --- |
| `make help` | List supported targets. |
| `make setup` | Install development Python dependencies. |
| `make test` | Run Python runner tests and Lua behavior suites. |
| `make test-installer` | Run Python/Node browser-installer tests. |
| `make check` | Run behavior tests and Lua syntax checks. |
| `make lint` | Run LuaLS diagnostics. |
| `make format` | Rewrite source/test Lua with StyLua. |
| `make build` | Recreate the simulator SD image. |
| `make capture-setup` / `make video-setup` | Install optional image/video dependencies. |
| `make release-package` | Create the installation ZIP and checksum. |
| `make docs` / `make docs-serve` | Build / preview the website. |
| `make clean` | Delete the configured build directory, including environments and simulator state. |
