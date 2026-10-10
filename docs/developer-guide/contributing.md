# Issues, changes, and releases

You can contribute a reproducible bug report, a focused fix, a panel, or clearer
documentation. Start with the [checkout instructions](build.md) for code work;
you do not need a working development environment to file an issue.

## File an issue

Search [existing issues](https://github.com/thomaskistler/aero-grid/issues)
first. If none describes the problem, choose
[New issue](https://github.com/thomaskistler/aero-grid/issues/new).
There are currently no repository-specific issue templates.

For a bug report, include:

| Detail | What to provide |
| --- | --- |
| Summary | A specific title and what failed. |
| Version | AeroGrid package version or Git commit; EdgeTX version; radio type and display size. |
| Environment | Physical radio, VS Code Dev Kit/WASM, Companion native simulator, or mock test; extension/Companion version and desktop OS when relevant. |
| Reproduction | Steps from a clean baseline, selected model/layout/theme, and the smallest layout or settings that reproduce it. |
| Expected / actual | What should happen and what actually happens, including exact error text. |
| Evidence | Relevant logs, screenshots, failing test output, or a recording. For growth/CPU problems, include duration and observed measurements. |
| Data setup | Source names/types/units, link state, switches, timers, and any synthetic inputs needed to reproduce it. |

Attach a minimal YAML layout rather than an entire personal SD card. Remove
unrelated model information, GPS coordinates, and other private data before
posting. State whether the issue survives a fresh build/restart; that helps
separate a code defect from stale bytecode or saved-layout overrides.

For a feature request, describe the developer or pilot problem, an example
workflow, and the desired behavior. Mention relevant panel sizes and radio
constraints. Discuss large behavioral changes before implementing them.

The optional GitHub CLI provides the same workflow:

```sh
gh issue list --repo thomaskistler/aero-grid
gh issue create --repo thomaskistler/aero-grid
```

## Prepare a focused change

Work on a branch or fork based on current `main`. Keep implementation, tests,
and directly related documentation together. Runtime code and tests use SPDX
`GPL-2.0-only` headers.

Lua naming follows these conventions:

| Element | Convention |
| --- | --- |
| Module and test filenames | kebab-case |
| Panel IDs and layout types | kebab-case; match the panel filename |
| Lua locals, functions, fields, and settings keys | camelCase |
| Constants | `UPPER_SNAKE_CASE`; keep implementation details local and expose a module field only when callers or tests use it |
| LuaDoc | Annotate parameters in signature order, followed by return values |

Comments should explain current contracts, non-obvious decisions, or firmware
constraints. Keep historical bug narratives and experiment results in tests,
commit history, or developer documentation rather than beside the implementation.
Use the established settings vocabulary and shared rendering/service helpers.

For a fix, add a regression test that fails before the change. Exercise absent
data and boundary values, not only the happy path. For UI changes, cover
declared spans, resizing, content shedding/restoration, App mode's menu
reservation, and editor behavior. See [Test and debug](testing.md) and
[Repository and architecture](architecture.md).

`tests/fixtures/sdcard/` is deterministic input, not a place to save a running
simulator. If a radio/model change intentionally becomes the baseline, stop the
simulator and update only the relevant tracked fixture files. Keep
`manuallyEdited: 1` in `RADIO/radio.yml` when manually changing its model
selection; EdgeTX can then accept the edit and regenerate the checksum.
Companion's SD import still checks the checksum even with that flag. After
editing, run `python3 -m unittest discover -s tools -p 'test_sdcard_checksum.py'`
and update the first line to the calculated value reported by a failing check.
The checksum includes the exact bytes after the first line, including line
endings. Check a fresh `make build` afterwards.

Do not commit `.luac`, virtual environments, logs, framebuffer dumps,
`build/sdcard/`, or incidental captures. Reviewed website screenshots belong
in `docs/assets/` with the relevant provenance and disclosure.

## Check and submit

For runtime Lua changes, use:

```sh
make format
make check
make lint
stylua --check src/WIDGETS tests
make build BUILD_DIR=build/package-check
diff -r src/WIDGETS/AeroGrid build/package-check/sdcard/WIDGETS/AeroGrid
```

Inspect formatting changes before committing. Run the
[tooling tests](testing.md#python-tooling-tests) if changing Python tools,
and `make docs` if changing documentation. Exercise behavior/UI changes in
a simulator; hardware-sensitive changes need radio evidence or an explicit
statement that hardware remains unverified.

Push your branch and open a pull request against `main`. Explain the problem,
the behavior change, reproduction/regression coverage, and any remaining
limitations. Reference the associated issue, using `Fixes #<number>` when the
PR resolves it. Distinguish mocked, synthetic simulator, and real hardware
observations rather than calling all three "tested."

GitHub's **CI** workflow runs Lua behavior/syntax checks, release-package tests,
LuaLS, pinned StyLua formatting, SD-image/source parity, and clean-tree checks.
The separate **Documentation** workflow strictly builds website changes.
The native screenshot tools are local macOS tools, not CI jobs.

## Publish a release

This is a maintainer operation, not a required step for a normal contribution.

1. Update `src/WIDGETS/AeroGrid/lib/package.lua` in a PR and merge to `main`.
   Use `X.Y.Z`, `X.Y.Z-beta.N`, or `X.Y.Z-rc.N`; beta/RC releases become
   prereleases. Change API versions only when the corresponding contract
   changes.
2. Build locally with `make release-package` when checking archive contents.
   The allowlists in `tools/package-release.py` separate installation content
   from development fixtures.
3. In [Actions > Release](https://github.com/thomaskistler/aero-grid/actions/workflows/release.yml),
   choose **Run workflow** on **main**. The workflow runs CI, documentation,
   and package validation against the exact selected commit, creates
   `v<version>`, uploads the ZIP and checksum to a draft, then publishes.

There is no automatic release on every merge, and no need to create a release
manually in the Releases UI. Release notes include installation links and
hardware coverage.

If validation fails, fix it in a PR, merge, and run again. If publication fails
after creating a tag/draft, rerun the **same workflow run** at the same commit:
it can resume a matching draft and replace incomplete assets. A tag pointing
to another commit or an already-public release is rejected. Never move a
published tag; use a new version for fixes. Abandoning an unpublished attempt
requires deliberately removing its draft and tag before reusing that version.

Documentation publication is independent: the Documentation workflow deploys
changes on `main` to GitHub Pages. Repository **Settings > Pages > Source**
must be **GitHub Actions**.
