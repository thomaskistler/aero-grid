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
runtime Lua, the editor assets, the `Default`, `Empty`, `Diagnostics`, and `Palette` layouts, and
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

### Browser installer assets

The USB installer is composed of ES modules under `docs/javascripts/`.
`radio-storage.mjs` exports the page-session `radioStorage` connection and
UI-independent storage/metadata helpers for future map workflows. The installer
only replaces the AeroGrid widget; no map writer or firmware flasher is included.
`radioHardware()` maps saved board identifiers to radio names and color/monochrome
logical display dimensions. The lookup is based on EdgeTX
[v2.12.0 target definitions](https://github.com/EdgeTX/edgetx/tree/v2.12.0/radio/src/targets):
color dimensions come from each target's `hal.h`, and monochrome sizes from
`taranis/CMakeLists.txt`. Unknown boards keep their identifier with an Unknown
screen; do not infer dimensions from SD bitmap-pack sizes or the browser screen.
The compatibility check follows the UI policy of recognized color-screen hardware
and stable EdgeTX 2.11.0 or later. The
[EdgeTX 2.11.0 release](https://github.com/EdgeTX/edgetx/releases/tag/v2.11.0)
introduced Lua LVGL controls. This check is not selected-release hardware
certification; unknown or unsupported configurations show an install-at-your-own-risk
warning in the page and confirmation, but remain installable.

Pages builds mirror **published stable releases**, not the current source tree,
into same-origin versioned files, individual `releases/<version>/manifest.json`
manifests, `installer/latest.json`, and an `installer/releases.json` catalog.
The latest release is selected by default. Historical releases without a compatible
ZIP/checksum pair are listed as unavailable, not silently substituted.
The build validates the release ZIP's SHA-256, archive paths, size limits, and
package version before emitting the payload. The browser checks the latest
GitHub release against its manifest and verifies every downloaded and written
file. These are content integrity checks, not signed publisher authentication.
Verification tolerates macOS AppleDouble (`._`) sidecars only when they have an
AppleDouble v2 header and a complete descriptor table, and correspond to a
release file or existing directory. Sidecars are not deleted by verification;
all release files still receive full size/hash checks. Other unexpected files
remain errors. Verification errors include missing/unexpected paths on-page
(up to 20 per category) and full structured differences in the JavaScript console.
Payload downloads run in batches of up to four, all verified before any radio
mutation. Radio writes remain sequential and reuse directory handles within the
replacement operation. Read-back verification enumerates each widget directory
once and reuses the discovered file handles, while still checking every release
file's size and SHA-256. These handles are not cached across installations.
The JavaScript console logs deletion failures with their target, exact path and
original browser error. Routine operations do not log directory listings or
perform extra diagnostic scans.
Deletion errors still stop installation without retrying or falling back.
Widget removal enumerates each directory and deletes `._` entries before other
entries. macOS automatically removes associated AppleDouble files on filesystems
without native extended attributes; sidecar-first ordering avoids Chromium
attempting to remove those already-deleted entries during bulk recursive removal.
Directories are removed only after their children. Traversal is limited to
10,000 entries and 64 levels inside the resolved widget directory; errors include
the exact path and still stop installation.
An explicitly selected downgrade requires a downgrade-specific confirmation.
The storage writer still refuses downgrades unless that confirmation authorizes
one; it does not convert user data to older layout or settings formats.

To include those assets in a disposable built-site preview:

```sh
make docs
python3 tools/installer_assets.py --output build/docs/installer
python3 -m http.server 8000 --directory build/docs
```

The mirroring command needs network access to GitHub; an optional `GH_TOKEN`
is used only for the server-side GitHub API request. No token is sent to the
browser. Stop the preview with Ctrl-C. Ordinary `make docs-serve` does not mirror
assets, so its installer reports release assets unavailable while the manual
instructions remain usable. Do not point the asset output or any development
build at a radio's SD card.

Documentation deployment runs after successful Release workflow completion
(GitHub-token-created release events do not start another workflow), on published
release events, and on documentation changes. Missing newest-release assets fail
the build rather than quietly mirroring an older release. Between publication
and deployment, the browser disables automatic installation if the site payload
is behind the latest stable release.

## Command reference

| Command | Result |
| --- | --- |
| `make help` | List supported targets. |
| `make setup` | Install development Python dependencies. |
| `make test` | Run every Lua behavior suite once with firmware-like string behavior. |
| `make test-installer` | Test the browser installer with Node.js 22 and Python. |
| `make check` | Run behavior tests, then parse source/test Lua. |
| `make lint` | Run LuaLS diagnostics. |
| `make format` | Rewrite source/test Lua using StyLua. |
| `make build` | Reset and assemble the development SD image. |
| `make capture-setup` | Install optional panel screenshot dependencies. |
| `make release-package` | Generate the installation ZIP and checksum. |
| `make docs` / `make docs-serve` | Build / preview the website. |
| `make clean` | Delete the configured build directory, including environments and simulator state. |
