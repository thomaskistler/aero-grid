# Issues, changes, and releases

Start code work with [Check out and build](build.md).
A development environment is not required to file an issue.

## File an issue

Search [existing issues](https://github.com/thomaskistler/aero-grid/issues),
then [open an issue](https://github.com/thomaskistler/aero-grid/issues/new)
if needed.

For bugs, include:

| Detail | What to provide |
| --- | --- |
| Versions | AeroGrid version/commit, EdgeTX version, radio, and display size. |
| Environment | Hardware, Dev Kit/WASM, Companion, or mock tests; relevant tool version and OS. |
| Reproduction | Minimal steps, model/layout/theme, source setup, and switch/link state. |
| Expected / actual | Intended result, observed result, and exact error text. |
| Evidence | Logs, screenshots, failing output, or recording; duration and measurements for CPU/memory issues. |

Attach a minimal layout, not a personal SD card. Remove private model data and
GPS coordinates. State whether a fresh build/restart reproduces the failure.
For features, describe the problem, workflow, desired behavior, and relevant
radio/panel constraints. Discuss large behavioral changes before implementation.

## Prepare a focused change

Base your branch or fork on current `main`. Keep implementation, regression
tests, and directly related documentation together. Lua code and tests use
SPDX `GPL-2.0-only` headers.

| Element | Convention |
| --- | --- |
| Library modules and test filenames | snake_case; tests start with `test_`. |
| Panel filenames, IDs, and layout types | Matching kebab-case names. |
| Lua locals, functions, fields, settings | camelCase. |
| Constants | `UPPER_SNAKE_CASE`; keep internal constants local. |
| LuaDoc | Parameters in signature order, then returns. |

Comments and documentation describe current contracts and constraints, not
historical bug narratives or experiment results. Reuse shared service,
rendering, and settings conventions.

Cover absent data and boundaries. UI changes also need span/reflow coverage,
menu reservation, and editor behavior. See [Test and debug](testing.md) and
[Repository and architecture](architecture.md).

### Maintain simulator fixtures

`tests/fixtures/sdcard/` is deterministic input, not a running simulator's SD
card. Stop the simulator before deliberately updating tracked fixture files.

Shared sensors, mixes, timers, and model setup come from `MODELS/model1.yml`.
After changing them, regenerate the fixture models, labels, and flight
announcement tracks:

```sh
python3 tools/generate-simulator-models.py
python3 tools/generate-simulator-models.py --check
```

Category names/screens live in that generator. Keep registry order stable
because widget options store its indices.

When manually changing `RADIO/radio.yml` model selection, keep
`manuallyEdited: 1`. Companion also requires a valid checksum: run
`python3 -m unittest discover -s tools -p 'test_sdcard_checksum.py'` and, if
needed, set the first line to the reported checksum. It covers the exact bytes
after that line. Model generation does not update radio settings.

Check fixture changes with a fresh `make build`. Do not commit generated
bytecode, environments, simulator state, logs, or incidental captures.
Publish only reviewed documentation assets with matching provenance.

## Check and submit

For runtime Lua changes:

```sh
make format
make check
make lint
stylua --check src/WIDGETS tests
make build
```

Inspect formatting changes. Run the relevant
[tooling tests](testing.md#python-tooling-tests) for tool changes and `make docs`
for documentation. Exercise UI/behavior changes in a simulator.
Hardware-sensitive work needs radio evidence or an explicit unverified status.

Open a pull request against `main` explaining the problem, behavior change,
regression coverage, and remaining limitations. Link the issue; use
`Fixes #<number>` when appropriate. Distinguish mocks, synthetic simulator
inputs, and hardware observations.

**CI** checks Lua behavior/syntax, packaging, browser installer behavior, LuaLS,
pinned StyLua formatting, SD-image/source parity, and a clean generated tree.
**Documentation** strictly builds the site and tests publishing/browser layout.
Native captures run locally, not in CI.

## Publish a release

Maintainers:

1. Update `lib/package.lua` in a PR and merge to `main`. Use `X.Y.Z`,
   `X.Y.Z-beta.N`, or `X.Y.Z-rc.N`; beta/RC versions become prereleases.
   Change API versions only with their contracts.
2. Optionally inspect `make release-package` output before publication.
3. Run [Actions > Release](https://github.com/thomaskistler/aero-grid/actions/workflows/release.yml)
   on **main**. It validates the selected commit, creates `v<version>`, uploads
   the ZIP/checksum to a draft, and publishes it.

After a publication failure, rerun the same workflow run at the same commit
to resume a matching draft. Published versions and tags pointing elsewhere
are rejected. Never move a published version tag; use a new version.
Reusing an abandoned unpublished version requires deliberately removing its
draft and tag.

Successful push CI for the current `main` commit updates the rolling
[developer prerelease](https://github.com/thomaskistler/aero-grid/releases/tag/dev).
Its `dev` tag and assets are replaced; the USB installer exposes it only with
**Show developer releases** enabled.

### Publish documentation

The **Documentation** workflow maintains release-tag snapshots and updates
`main` separately, building missing snapshots and preserving existing ones.
It runs on relevant `main` changes and release publication; use
**Actions > Documentation > Run workflow** on **main** to redeploy.

The default is the latest stable release. **Documentation version** selects
released versions, prereleases, or `main`; installer release selection is
independent. Content/layouts are version-specific, while navigation, installer
UI, and analytics configuration use the current publishing implementation.

Snapshots are stored on `gh-pages`; do not edit it manually.
Repository **Settings > Pages > Source** must be **GitHub Actions**.
