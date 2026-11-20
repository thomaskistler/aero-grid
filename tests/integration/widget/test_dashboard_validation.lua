-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local hostIo = fixture.hostIo
local radio = fixture.radio
local resetRadio = fixture.reset
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local writeFile = fixture.writeFile
local makeWidget = fixture.makeWidget
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local entryById = fixture.entryById
local pump = fixture.pump
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    return fixture.createLoaded(zone, options, path, definition)
end

local hostTurn = fixture.hostTurn

local function testTimerIndexIsRefusedAtLoad()
    resetRadio()

    local function load(value)
        local widget = makeWidget(
            "timer-index-" .. string.gsub(tostring(value), "[^%w]", ""),
            table.concat({
                "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n",
                "  - id: clock\n    type: flight-timer\n",
                "    col: 0\n    row: 0\n    colSpan: 2\n    rowSpan: 2\n",
                "    config:\n      timer: ",
                tostring(value),
                "\n",
            })
        )
        return createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widget)
    end

    -- Refused, and the message names the panel the way every other refusal
    -- does, so an author can find it in a grid of twelve.
    local refused = load(9)
    assertEqual(#refused.errors, 1, "an index no radio has was accepted: " .. table.concat(refused.errors, "; "))
    assert(
        string.find(refused.errors[1], "clock", 1, true),
        "the refusal does not name the panel: " .. refused.errors[1]
    )
    assert(
        string.find(refused.errors[1], "timer", 1, true),
        "the refusal does not name the setting: " .. refused.errors[1]
    )

    -- The last real index is not refused, which is what stops this being a
    -- rule that merely forbids large numbers.
    local accepted = load(2)
    assertEqual(#accepted.errors, 0, "the last timer a radio has was refused: " .. table.concat(accepted.errors, "; "))
    pump(accepted, 40)
    assertEqual(entryById(accepted, "clock").instance.text, "0:12", "timer 2 was accepted and then not read")

    -- And the runtime case is silent, because it is not the author's mistake:
    -- an index the radio has and the model has not configured draws NO TIMER
    -- with nothing reported.
    resetRadio()
    radio.timers[2] = nil
    local unconfigured = load(2)
    assertEqual(#unconfigured.errors, 0, "a timer the model has not set up was reported as an authoring mistake")
    pump(unconfigured, 40)
    local panel = entryById(unconfigured, "clock").instance
    assertEqual(panel.text, "--:--")
    assertEqual(panel.detail, "NO TIMER")
    assertEqual(panel.stateName, "unavailable")
    resetRadio()
end

local function testContractRejections()
    local widgetPath = makeWidget(
        "contract",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: toobig
    type: heartbeat
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 4
  - id: oldapi
    type: legacy
    col: 2
    row: 0
    colSpan: 1
    rowSpan: 1
  - id: renamed
    type: mismatch
    col: 3
    row: 0
    colSpan: 1
    rowSpan: 1
  - id: absent
    type: nosuchpanel
    col: 2
    row: 1
    colSpan: 1
    rowSpan: 1
  - id: good
    type: placeholder
    col: 3
    row: 1
    colSpan: 1
    rowSpan: 1
  - id: syntax
    type: syntax
    col: 2
    row: 2
    colSpan: 1
    rowSpan: 1
  - id: execution
    type: execution
    col: 3
    row: 2
    colSpan: 1
    rowSpan: 1
  - id: scalar
    type: scalar
    col: 2
    row: 3
    colSpan: 1
    rowSpan: 1
]],
        {
            ["legacy.lua"] = [==[
return {id = "legacy", apiVersion = 99, create = function() return {} end}
]==],
            ["mismatch.lua"] = [==[
return {id = "somethingelse", apiVersion = 1, create = function() return {} end}
]==],
            ["syntax.lua"] = "return {",
            ["execution.lua"] = 'error("module execution failed")',
            ["scalar.lua"] = "return 42",
        }
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)

    assertEqual(#context.panels, 1, "only the valid panel should load")
    assertEqual(context.panels[1].placement.id, "good")
    assertEqual(#context.errors, 7)

    local joined = table.concat(context.errors, "\n")
    assert(string.match(joined, "toobig: panel does not support span 2x4"), joined)
    assert(string.match(joined, "oldapi: incompatible panel API"), joined)
    assert(string.match(joined, "renamed: panel module id somethingelse"), joined)
    assert(string.match(joined, "absent:"), joined)
    assert(string.match(joined, "syntax:"), joined)
    assert(string.match(joined, "execution:.*module execution failed"), joined)
    assert(string.match(joined, "scalar:.*did not return a module table"), joined)
    assert(context.errorLabel, "module failures were not shown")
    pump(context, 5)
    assertEqual(#context.panels, 1, "module failures disabled the valid panel")
    assertEqual(#context.errors, 7, "module failures repeated on refresh")
end

local function testPackageCompatibility()
    local cases = {
        { name = "missing-package", file = "lib/package.lua", error = "package:" },
        { name = "bad-package", file = "lib/package.lua", text = "return {}", error = "incompatible package contract" },
        {
            name = "future-package",
            file = "lib/package.lua",
            text = 'return {version="next",runtimeApi=2,panelApi=1,layoutVersion=1}',
            error = "incompatible package contract",
        },
        {
            name = "mixed-core",
            file = "lib/grid.lua",
            text = "return {RUNTIME_API=2}",
            error = "lib/grid.lua:.*incompatible runtime API",
        },
        {
            name = "unversioned-core",
            file = "lib/grid.lua",
            text = "return {}",
            error = "lib/grid.lua:.*incompatible runtime API",
        },
        {
            name = "mixed-panel-host",
            file = "lib/panel_host.lua",
            text = "return {RUNTIME_API=1,API_VERSION=99}",
            error = "panel host: incompatible panel API",
        },
        {
            name = "future-panel-contract",
            file = "lib/package.lua",
            text = 'return {version="next",runtimeApi=1,panelApi=2,layoutVersion=1}',
            error = "incompatible package contract",
        },
        {
            name = "future-layout-contract",
            file = "lib/package.lua",
            text = 'return {version="next",runtimeApi=1,panelApi=1,layoutVersion=6}',
            error = "incompatible package contract",
        },
        { name = "missing-core", file = "lib/yaml.lua", error = "lib/yaml.lua:" },
    }
    for _, case in ipairs(cases) do
        local path = makeWidget(case.name)
        if case.text then
            writeFile(path .. case.file, case.text)
        else
            assert(os.remove(path .. case.file))
        end
        local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, path)
        assertEqual(context.runtimeFailed, true, case.name)
        assertEqual(#context.panels, 0, case.name)
        local joined = table.concat(context.errors, "\n")
        assert(string.match(joined, case.error), joined)
        assert(context.errorLabel, case.name .. " failure was not shown")
        definition.update(context, { Layout = "Diagnostics", Theme = "modern-dark" })
        pump(context, 5)
        assertEqual(context.stage, nil, case.name .. " attempted to reload a broken runtime")
    end

    local path = makeWidget("mixed-service")
    writeFile(path .. "lib/telemetry_service.lua", "return {RUNTIME_API=99}")
    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, path)
    assert(
        string.match(table.concat(context.errors, "\n"), "telemetry:.*incompatible runtime API"),
        table.concat(context.errors, "\n")
    )
    assert(#context.panels > 0, "incompatible service disabled unrelated panels")

    local diagnostics = assert(loadfile(sourcePath .. "panels/host-diagnostics.lua"))()
    assert(
        string.find(diagnostics.identity(context)[1], "v" .. context.packageInfo.version, 1, true),
        "diagnostics did not report the loaded package version"
    )
end

local function testVersionOneBatteryLoadsWithoutWriting()
    local source = [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: legacy-pack
    type: cell-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      sourceType: cells
      source: Cels
      lowestSource: Cels-
      cells: 4
      reading: lowest
      cellFull: 4.15
]]
    local widgetPath = makeWidget("legacy-battery-migration", source)
    local context = definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "Default", Theme = "modern-dark" },
        widgetPath
    )
    definition.refresh(context)
    local validator = assert(context.layoutValidator)
    local headerStep, panelStep = validator.migrateHeaderStep, validator.migratePanelStep
    local headers, panels, steps = 0, 0, 0
    validator.migrateHeaderStep = function(...)
        headers = headers + 1
        return headerStep(...)
    end
    validator.migratePanelStep = function(...)
        panels = panels + 1
        return panelStep(...)
    end
    while context.stage do
        hostTurn(context)
        steps = steps + 1
        assert(steps < 200, "legacy migration load did not finish")
    end
    validator.migrateHeaderStep, validator.migratePanelStep = headerStep, panelStep
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    assertEqual(headers, 4, "each adjacent header migration still gets its own step")
    assertEqual(panels, 4, "each adjacent panel migration still gets its own step")
    assertEqual(context.document.version, 5)
    local placement = context.document.panels[1]
    assertEqual(placement.type, "rx-battery")
    assertEqual(placement.config.reading, "cell")
    assertEqual(placement.config.lowestSource, nil)
    assertEqual(placement.config.cells, nil)
    assertEqual(placement.config.cellFull, 4.15)
    assertEqual(placement.config.warning, nil)
    local noticed = false
    for _, notice in ipairs(context.notices) do
        noticed = noticed or string.find(notice.text, "migrated in memory", 1, true) ~= nil
    end
    assert(noticed, "the version-1 upgrade notice was not surfaced")

    local handle = assert(hostIo.open(widgetPath .. "layouts/Default.yaml", "r"))
    local unchanged = handle:read("*a")
    handle:close()
    assertEqual(unchanged, source, "loading a migrated layout rewrote its source file")
end

local function testDebriefErrorsAreNotices()
    resetRadio()
    local source = table.concat({
        "version: 5\ngrid:\n  columns: 4\n  rows: 4\n",
        "panels:\n  - id: clock\n    type: flight-timer\n",
        "    col: 0\n    row: 0\n    colSpan: 2\n    rowSpan: 2\n",
        "debrief:\n  tiles:\n",
        "    - title: Link\n      colSpan: 2\n      rowSpan: 2\n      futureTile: kept\n",
        "      series:\n        - source: RQly\n          statistic: min\n          futureSeries: kept\n",
        "    - title: Broken\n      colSpan: 2\n      rowSpan: 2\n",
        "      series:\n        - source: RQly\n          statistic: last\n",
    })
    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, makeWidget("debrief", source))
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    assertEqual(#context.document.debrief.tiles, 1, "the valid debrief tiles were not kept")
    assertEqual(context.document.debrief.tiles[1].title, "Link")
    assertEqual(context.document.debrief.tiles[1].futureTile, "kept")
    assertEqual(context.document.debrief.tiles[1].series[1].futureSeries, "kept")
    local noticed, futureTile, futureSeries = false, false, false
    for _, notice in ipairs(context.notices) do
        noticed = noticed or string.find(notice.text, "debrief tile 2", 1, true) ~= nil
        futureTile = futureTile or string.find(notice.text, "futureTile", 1, true) ~= nil
        futureSeries = futureSeries or string.find(notice.text, "futureSeries", 1, true) ~= nil
    end
    assert(noticed, "the debrief error was not surfaced as a notice")
    assert(futureTile and futureSeries, "unknown settings must be reported")
    assert(entryById(context, "clock"), "a debrief error must not stop the dashboard")

    local bare = createLoaded(
        { x = 0, y = 0, w = 480, h = 272 },
        DEFAULT_OPTIONS,
        makeWidget("no-debrief", "version: 5\ngrid:\n  columns: 4\n  rows: 4\npanels: []\n")
    )
    assertEqual(bare.document.debrief, nil, "a layout without a debrief section gained one")
    local malformed = createLoaded(
        { x = 0, y = 0, w = 480, h = 272 },
        DEFAULT_OPTIONS,
        makeWidget("bad-debrief", "version: 5\ngrid:\n  columns: 4\n  rows: 4\npanels: []\ndebrief: invalid\n")
    )
    assertEqual(malformed.document.debrief, nil)
    assertEqual(#malformed.errors, 0)
    local badNotice = false
    for _, notice in ipairs(malformed.notices) do
        badNotice = badNotice or string.find(notice.text, "debrief must be a mapping", 1, true) ~= nil
    end
    assert(badNotice)
end

local function testRejectedLayouts()
    local cases = {
        { name = "corrupt", yaml = "version: 1\n\tpanels: []\n", error = "tab" },
        {
            name = "future",
            yaml = "version: 99\ngrid:\n  columns: 4\n  rows: 4\npanels: []\n",
            error = "unsupported layout version",
        },
        { name = "empty", yaml = "", error = "empty" },
        { name = "missing", error = "file not found" },
    }
    for _, case in ipairs(cases) do
        local widgetPath = makeWidget("rejected-" .. case.name, case.yaml)
        if case.name == "missing" then
            assert(os.remove(widgetPath .. "layouts/Default.yaml"))
        end
        local context = createLoaded(
            { x = 0, y = 0, w = 480, h = 272 },
            { Layout = "no-such-dashboard", Theme = "modern-dark" },
            widgetPath
        )

        assertEqual(#context.panels, 0, case.name)
        local joined = table.concat(context.errors, "\n")
        assert(string.match(joined, case.error), case.name .. ": " .. joined)
        assert(context.errorLabel, case.name .. " layout failure was not shown")
        assertEqual(context.layoutPath, widgetPath .. "layouts/Default.yaml")
        pump(context, 5)
        assertEqual(table.concat(context.errors, "\n"), joined, case.name .. " failed repeatedly")
    end
end

testContractRejections()
testPackageCompatibility()
testVersionOneBatteryLoadsWithoutWriting()
testRejectedLayouts()
testDebriefErrorsAreNotices()
testTimerIndexIsRefusedAtLoad()
