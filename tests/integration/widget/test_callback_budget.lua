-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local developmentLayoutsPath = root .. "/tests/fixtures/layouts/development/"
local hostIo = fixture.hostIo
local setTextMeasurement = fixture.lcdMock.setTextMeasurement
local setPropertyValidation = fixture.lvglMock.setPropertyValidation
local setCallCounting = fixture.lvglMock.setCallCounting
local tick = fixture.tick
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local makeWidget = fixture.makeWidget
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local definition = fixture.module("main.lua")
local galleryFile = assert(hostIo.open(root .. "/tests/fixtures/layouts/default-gallery.yaml", "r"))
local galleryPath = makeWidget("default-gallery", galleryFile:read("*a"))
galleryFile:close()

local reflowDone = fixture.reflowDone

local function testInstructionBudget()
    local BUDGET = 20000
    local CEILING = BUDGET * 0.75

    local function measure(fn, ...)
        local ticks = 0
        -- The mock's property validation stands in for `parseParam`, which is C++
        -- and costs a script nothing. Counting it here would measure the fixture.
        setPropertyValidation(false)
        setCallCounting(false)
        -- `lcd.sizeText` is C on a radio and free to a script; here it sums the
        -- string in Lua. Swapped for a stand-in that answers the same number from
        -- a cache, so the measurement is of the dashboard rather than of the
        -- fixture's arithmetic.
        setTextMeasurement(false)
        -- Count exactly as the firmware does: a hook every 200 instructions.
        debug.sethook(function()
            ticks = ticks + 1
        end, "", 200)
        local ok, err = pcall(fn, ...)
        debug.sethook()
        setTextMeasurement(true)
        setCallCounting(true)
        setPropertyValidation(true)
        assert(ok, "callback raised: " .. tostring(err))
        return ticks * 200
    end

    --- Build a layout that fills the grid with single-cell metrics.
    local function fullGridLayout(count, panelType)
        panelType = panelType or "metric"
        local lines = { "version: 1", "grid:", "  columns: 4", "  rows: 4", "panels:" }
        for i = 1, count do
            local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
            lines[#lines + 1] = "  - id: m" .. i
            lines[#lines + 1] = "    type: " .. panelType
            lines[#lines + 1] = "    col: " .. col
            lines[#lines + 1] = "    row: " .. row
            lines[#lines + 1] = "    colSpan: 1"
            lines[#lines + 1] = "    rowSpan: 1"
            lines[#lines + 1] = "    config:"
            if panelType == "metric" then
                lines[#lines + 1] = "      metrics:"
                lines[#lines + 1] = "        - source: S" .. i
                lines[#lines + 1] = "          label: Metric " .. i
                lines[#lines + 1] = "          unit: V"
                lines[#lines + 1] = "          rangeMin: 0"
                lines[#lines + 1] = "          rangeMax: 100"
                lines[#lines + 1] = "          warning: 80"
                lines[#lines + 1] = "          critical: 90"
                lines[#lines + 1] = "          precision: 1"
                lines[#lines + 1] = "      visual: bar"
                lines[#lines + 1] = "      accent: cyan"
            else
                lines[#lines + 1] = "      label: Metric " .. i
                lines[#lines + 1] = "      unit: V"
                lines[#lines + 1] = "      accent: cyan"
                lines[#lines + 1] = "      rangeMin: 0"
                lines[#lines + 1] = "      rangeMax: 100"
                lines[#lines + 1] = "      warning: 80"
                lines[#lines + 1] = "      critical: 90"
                lines[#lines + 1] = "      precision: 1"
                lines[#lines + 1] = "      visual: bar"
                -- A distinct live source per cell, so the telemetry service really does
                -- carry sixteen subscriptions rather than sixteen names it rejects.
                lines[#lines + 1] = "      source: S" .. i
            end
        end
        return table.concat(lines, "\n") .. "\n"
    end

    --- Every service, exercised at the largest layout the schema permits.
    --- The four services are spread across sixteen single-cell diagnostic
    --- panels, each subscribing to something different, so the measurement
    --- covers the whole service layer rather than telemetry alone.
    local PROBE_SPECS = {
        { service = "navigation", source = "GPS" },
        { service = "model", index = 0 },
        { service = "control", source = "trim-ail", index = 0 },
        { service = "telemetry", source = "RxBt" },
    }

    --- Build a layout that fills the grid with service diagnostic panels.
    local function probeGridLayout()
        local lines = { "version: 1", "grid:", "  columns: 4", "  rows: 4", "panels:" }
        for i, spec in ipairs(PROBE_SPECS) do
            local col, row = (i - 1) % 2 * 2, math.floor((i - 1) / 2) * 2
            lines[#lines + 1] = "  - id: p" .. i
            lines[#lines + 1] = "    type: service-probe"
            lines[#lines + 1] = "    col: " .. col
            lines[#lines + 1] = "    row: " .. row
            lines[#lines + 1] = "    colSpan: 2"
            lines[#lines + 1] = "    rowSpan: 2"
            lines[#lines + 1] = "    config:"
            lines[#lines + 1] = "      service: " .. spec.service
            lines[#lines + 1] = "      label: Probe " .. i
            if spec.source then
                lines[#lines + 1] = "      source: " .. spec.source
            end
            lines[#lines + 1] = "      index: " .. (spec.index or 0)
        end
        return table.concat(lines, "\n") .. "\n"
    end

    --- Build a layout that fills the grid with one panel type.
    --- Every core panel has to be measured at the largest layout the schema
    --- permits, not at the span the shipped dashboard happens to use.
    ---@param panelType string
    ---@param configFor fun(index: integer): string[] Config lines for one cell.
    local function typedGridLayout(panelType, configFor)
        local lines = { "version: 1", "grid:", "  columns: 4", "  rows: 4", "panels:" }
        for i = 1, 16 do
            local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
            lines[#lines + 1] = "  - id: c" .. i
            lines[#lines + 1] = "    type: " .. panelType
            lines[#lines + 1] = "    col: " .. col
            lines[#lines + 1] = "    row: " .. row
            lines[#lines + 1] = "    colSpan: 1"
            lines[#lines + 1] = "    rowSpan: 1"
            lines[#lines + 1] = "    config:"
            for _, line in ipairs(configFor(i)) do
                lines[#lines + 1] = "      " .. line
            end
        end
        return table.concat(lines, "\n") .. "\n"
    end

    --- Every core panel, at sixteen single cells, with the services each one
    --- must genuinely drive while it is measured.
    local CORE_EXERCISES = {
        {
            type = "state",
            services = { "control" },
            config = function()
                local lines = { "entries:" }
                for _, source in ipairs({ "sf", "sa", "sb" }) do
                    lines[#lines + 1] = "  - label: MODE"
                    lines[#lines + 1] = "    states:"
                    lines[#lines + 1] = "      - switch: " .. string.upper(source) .. "^"
                    lines[#lines + 1] = "        text: LOW"
                    if source ~= "sf" then
                        lines[#lines + 1] = "      - switch: " .. string.upper(source) .. "-"
                        lines[#lines + 1] = "        text: MID"
                    end
                    lines[#lines + 1] = "      - switch: " .. string.upper(source) .. "v"
                    lines[#lines + 1] = "        text: HIGH"
                end
                return lines
            end,
        },
        {
            type = "metric",
            services = { "telemetry" },
            config = function(index)
                return {
                    "metrics:",
                    "  - source: S" .. index,
                    "    label: " .. (index % 2 == 0 and "ALT" or "SPD"),
                    "    rangeMin: 0",
                    "    rangeMax: " .. (index % 2 == 0 and "400" or "200"),
                    "accent: " .. (index % 2 == 0 and "green" or "cyan"),
                }
            end,
        },
        {
            type = "flight-timer",
            services = { "model" },
            config = function(index)
                return { "timer: " .. ((index - 1) % 3), "warning: 60", "critical: 20" }
            end,
        },
        {
            type = "flight-mode",
            services = { "model" },
            -- Sixteen single cells with no optional mode-number labels.
            config = function()
                return { "label: Mode" }
            end,
        },
        {
            type = "tx-battery",
            services = { "model" },
            config = function()
                -- No optional percentage labels in this resource baseline.
                return { "packEmpty: 6.6", "packFull: 8.4", "warning: 7.0" }
            end,
        },
        {
            type = "trim-panel",
            services = { "control" },
            config = function()
                -- Three axes are always present, making this the panel's fixed
                -- maximum object set.
                return { "readout: percent", "scale: auto" }
            end,
        },
        {
            type = "model-identity",
            services = { "model" },
            -- No optional model-label objects in this resource baseline.
            config = function()
                return { "presentation: both" }
            end,
        },
        {
            -- Every panel walks a cells table on every refresh, so sixteen of them
            -- is the worst case for the one panel that does per-entry work.
            type = "rx-battery",
            services = { "telemetry" },
            config = function(index)
                return {
                    "source: Cels",
                    "warning: 3.5",
                    "critical: " .. (index % 2 == 0 and "3.3" or "3.4"),
                }
            end,
        },
        {
            type = "link-status",
            services = { "telemetry" },
            config = function(index)
                return {
                    "rssiSource: " .. (index % 2 == 0 and "RSSI" or "1RSS"),
                    "qualitySource: RQly",
                    "reading: " .. (index % 2 == 0 and "auto" or "rssi"),
                    "extrema: source",
                }
            end,
        },
        {
            -- Four distinct GPS sources, so the navigation service really carries
            -- more than one subscription and pays for its trigonometry.
            type = "navigation",
            services = { "navigation", "telemetry" },
            config = function(index)
                local sources = { "GPS", "GPS2", "GPS3", "GPS4" }
                return {
                    "source: " .. sources[(index - 1) % 4 + 1],
                    "presentation: detailed",
                }
            end,
        },
    }

    local worst, worstName = 0, "none"
    local worstSteady, worstSteadyName = 0, "none"
    local worstReflow, worstReflowName = 0, "none"
    local worstOther, worstOtherName = 0, "none"

    local function record(name, cost)
        assert(
            cost < CEILING,
            string.format(
                "%s used %d instructions, over the %d ceiling (firmware limit %d)",
                name,
                cost,
                CEILING,
                BUDGET
            )
        )
        if cost > worst then
            worst = cost
            worstName = name
        end
        -- Steady state runs on every frame, so track it separately.
        if string.find(name, "steady", 1, true) and cost > worstSteady then
            worstSteady = cost
            worstSteadyName = name
        end
        -- Reflow is tracked apart from everything else because `REFLOW_BATCH`
        -- decides it and nothing else, so it is the one cost the dashboard can
        -- move by changing a constant. See the assertion after the exercises.
        if string.find(name, "reflow", 1, true) then
            if cost > worstReflow then
                worstReflow = cost
                worstReflowName = name
            end
        elseif cost > worstOther then
            worstOther = cost
            worstOtherName = name
        end
    end

    --- Load one widget package end to end, measuring every callback.
    ---@param expectedServices? string[] Services this layout must actually run.
    local function exercise(label, path, expectedPanels, expectedServices)
        local zone = { x = 0, y = 0, w = 480, h = 272 }
        local context
        record(
            label .. " create",
            measure(function()
                context = definition.create(zone, DEFAULT_OPTIONS, path)
            end)
        )
        local steps = 0
        while context.stage do
            local stage = context.stage
            record(label .. " refresh/" .. stage, measure(definition.refresh, context))
            steps = steps + 1
            assert(steps < 400, label .. ": staged load never finished")
        end

        assertEqual(#context.panels, expectedPanels, label .. ": panel count")
        assertEqual(#context.errors, 0, label .. ": " .. table.concat(context.errors, "\n"))

        -- Steady state must be measured across real frames, advancing the clock,
        -- or rate limiting makes every sampled frame trivially cheap and the
        -- measurement meaningless. Sample enough frames to include the worst.
        local before = {}
        for index, entry in ipairs(context.panels) do
            before[index] = entry.nextRefresh
        end

        local revisions = {}
        for id, instance in pairs(context.serviceRuntime.byId) do
            revisions[id] = instance.revision
        end

        for _ = 1, 60 do
            tick(1)
            record(label .. " refresh/steady", measure(definition.refresh, context))
        end

        -- Prove the sampled frames actually did work. A scheduling bug that
        -- silently stopped dispatching would otherwise make this test pass by
        -- measuring nothing at all.
        for index, entry in ipairs(context.panels) do
            assert(
                entry.nextRefresh ~= before[index],
                label .. ": " .. entry.placement.id .. " was never refreshed during the sample"
            )
        end

        -- The same applies to the services, whose updates are charged to these
        -- very callbacks: a layout that subscribed to nothing would measure the
        -- service layer at zero and hide whatever it really costs.
        for _, id in ipairs(expectedServices or {}) do
            local instance = context.serviceRuntime.byId[id]
            assert(instance, label .. ": the " .. id .. " service was never built")
            assert(instance.count > 0, label .. ": nothing subscribed to the " .. id .. " service")
            assert(
                instance.revision > revisions[id],
                label .. ": the " .. id .. " service never updated during the sample"
            )
            assert(not instance.failed, label .. ": the " .. id .. " service failed")
        end

        record(label .. " background", measure(definition.background, context))
        record(label .. " event", measure(definition.event, context, 32))

        zone.w = 320
        zone.h = 240
        local passes = 0
        repeat
            record(label .. " refresh/reflow", measure(definition.refresh, context))
            passes = passes + 1
            assert(passes < 400, label .. ": reflow never finished")
        until reflowDone(context)
        return context
    end

    exercise("gallery", galleryPath, 10, { "telemetry", "model", "control", "navigation" })
    exercise("full grid", makeWidget("budget-16", fullGridLayout(16)), 16, { "telemetry" })
    local linkReview = assert(hostIo.open(developmentLayoutsPath .. "review-link-status.yaml", "r"))
    local linkReviewYaml = linkReview:read("a")
    linkReview:close()
    exercise("link review", makeWidget("budget-link-review", linkReviewYaml), 6, { "telemetry" })
    exercise(
        "ELRS4 link x16",
        makeWidget(
            "budget-elrs4",
            typedGridLayout("link-status", function()
                return {
                    "protocol: elrs4",
                    "qualitySource: RQly",
                    "rssiSource: 1RSS",
                    "modeSource: RFMD",
                    "snrSource: RSNR",
                    "powerSource: TPWR",
                    "qualityWarning: 90",
                    "qualityCritical: 70",
                    "marginWarning: 10",
                    "marginCritical: 5",
                }
            end)
        ),
        16,
        { "telemetry" }
    )

    -- Every core panel, one type at a time, at sixteen single cells. A
    -- panel measured only at the span the shipped dashboard uses would hide
    -- exactly the cost that matters: sixteen of it on one screen.
    for _, spec in ipairs(CORE_EXERCISES) do
        exercise(
            spec.type .. " x16",
            makeWidget("budget-" .. spec.type, typedGridLayout(spec.type, spec.config)),
            16,
            spec.services
        )
    end

    -- Four 2x2 diagnostic panels: the most service probes the schema permits.
    exercise(
        "service probes",
        makeWidget("budget-probes", probeGridLayout()),
        4,
        { "telemetry", "model", "control", "navigation" }
    )

    -- Four 2x2 diagnostics panels, which is the worst case for the view that
    -- reports on the host. It must not cost the dashboard anything when it is
    -- not showing, which it cannot, because a panel no layout places is
    -- never loaded; the question this answers is the other half, that it does
    -- not become the most expensive thing on the dashboard when it is.
    local diagnosticsGrid = { "version: 1", "grid:", "  columns: 4", "  rows: 4", "panels:" }
    local sections = { "identity", "theme", "panels", "sources" }
    for index = 1, 4 do
        local col, row = (index - 1) % 2 * 2, math.floor((index - 1) / 2) * 2
        for _, line in ipairs({
            "  - id: d" .. index,
            "    type: host-diagnostics",
            "    col: " .. col,
            "    row: " .. row,
            "    colSpan: 2",
            "    rowSpan: 2",
            "    config:",
            "      section: " .. sections[index],
        }) do
            diagnosticsGrid[#diagnosticsGrid + 1] = line
        end
    end
    exercise("host diagnostics x4", makeWidget("budget-diagnostics", table.concat(diagnosticsGrid, "\n") .. "\n"), 4)

    -- A layout whose panels all demand every frame defeats staggering, so
    -- the per-frame cap is the only thing bounding cost. Prove it holds.
    local greedyPath = makeWidget("budget-greedy", fullGridLayout(16, "greedy"), {
        ["greedy.lua"] = [==[
local greedy = {
  id = "greedy",
  supportedSpans = {"any"},
  refreshInterval = 0,
  -- Declared because the shared grid layout writes them, and an undeclared
  -- key is now reported rather than ignored.
  settings = {
    -- Every key `fullGridLayout` writes, because an undeclared key is now
    -- reported rather than ignored and this fixture stands in for a real
    -- panel.
    {key = "label", type = "string", default = ""},
    {key = "source", type = "string", default = ""},
    {key = "unit", type = "string", default = ""},
    {key = "precision", type = "number", default = 0},
    {key = "visual", type = "string", default = "bar"},
    {key = "rangeMin", type = "number", default = 0},
    {key = "rangeMax", type = "number", default = 100},
    {key = "warning", type = "number"},
    {key = "critical", type = "number"},
    {key = "accent", type = "string", default = "cyan"},
  },
}
function greedy.create(parent, rect, settings, services)
  local panel = services.primitives.panel(parent, rect, services.theme,
    services.state("normal", "cyan"))
  return {panel = panel, ticks = 0, label = services.primitives.label(
    panel.root, services.theme, {x = 4, y = 4, w = 40, text = "0",
    font = services.fonts.label})}
end
function greedy.refresh(context)
  context.ticks = context.ticks + 1
  context.label:set({text = tostring(context.ticks)})
end
return greedy
]==],
    })
    exercise("greedy", greedyPath, 16)

    -- A reflow must not be the most expensive thing the dashboard does.
    --
    -- This pins the conclusion of measuring `REFLOW_BATCH` rather than a number
    -- somebody liked. Reflow cost is linear in the batch, so it is the one
    -- callback whose cost is chosen rather than earned, and choosing it larger
    -- than the work it competes with buys nothing: the dashboard still cannot
    -- start faster than its slowest loader stage. The measurements below are
    -- live, so a change to panel geometry or build cost re-evaluates whether
    -- this batch size still buys anything.
    --
    -- It is deliberately a comparison and not a ceiling. A ceiling that the old
    -- value also satisfied would prove nothing, and a ceiling chosen today
    -- becomes a number nobody dares touch. If the loader is ever made cheaper,
    -- this starts failing, and that is correct: it would mean reflow had become
    -- the binding constraint again and the batch is due another measurement.
    -- Without this, the comparison below passes when nothing reflowed at all:
    -- a zero is less than everything. Found by breaking the recording and
    -- watching the comparison stay green.
    assert(worstReflow > 0, "no reflow callback was measured, so the comparison below proves nothing")
    assert(worstOther > 0, "no other callback was measured")

    assert(
        worstReflow < worstOther,
        string.format(
            "%s used %d, more than the dashboard's most expensive other callback"
                .. " (%s at %d), so REFLOW_BATCH is set higher than it buys anything",
            worstReflowName,
            worstReflow,
            worstOtherName,
            worstOther
        )
    )

    print(string.format("  budget headroom: worst callback %s used %d of %d", worstName, worst, BUDGET))
    print(string.format("  steady state:    worst frame %s used %d of %d", worstSteadyName, worstSteady, BUDGET))
    print(
        string.format(
            "  reflow:          worst %s used %d, against %s at %d",
            worstReflowName,
            worstReflow,
            worstOtherName,
            worstOther
        )
    )
end

-- Warm the native stand-ins and module cache explicitly rather than depending
-- on unrelated integration scenarios having run before the budget measurement.
local warmup = fixture.createLoaded(nil, DEFAULT_OPTIONS, galleryPath, definition)
fixture.pump(warmup, 60)
fixture.reset()
testInstructionBudget()
