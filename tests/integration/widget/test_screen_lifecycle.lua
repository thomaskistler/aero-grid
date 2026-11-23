-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local hostIo = fixture.hostIo
local lvglMock = fixture.lvglMock
local radio = fixture.radio
local resetRadio = fixture.reset
local tick = fixture.tick
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local writeFile = fixture.writeFile
local makeWidget = fixture.makeWidget
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local entryById = fixture.entryById
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    return fixture.createLoaded(zone, options, path, definition)
end

local function testMultipleScreens()
    local previous = radio.modelFilename
    local widgetPath = makeWidget(
        "screens",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: fallback
    type: placeholder
    col: 0
    row: 0
    colSpan: 4
    rowSpan: 4
]]
    )

    writeFile(
        widgetPath .. "layouts/alpha.yaml",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: alt
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          label: Alt
          precision: 0
]]
    )

    writeFile(
        widgetPath .. "layouts/beta.yaml",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: pack
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: RxBt
          label: Pack
          precision: 1
  - id: mode
    type: flight-mode
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
]]
    )

    -- A user layout lives outside the widget folder. A test package is not
    -- under WIDGETS/, so its SD root is the package itself.
    os.execute("mkdir -p '" .. widgetPath .. "AEROGRID/layouts'")
    writeFile(
        widgetPath .. "AEROGRID/layouts/alpha.yaml",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: speed
    type: metric
    col: 0
    row: 0
    colSpan: 4
    rowSpan: 2
    config:
      metrics:
        - source: GSpd
          label: Speed
          precision: 0
]]
    )

    --- Ids of the panels an instance actually built.
    local function idsOf(context)
        local ids = {}
        for index, entry in ipairs(context.panels) do
            ids[index] = entry.placement.id
        end
        table.sort(ids)
        return table.concat(ids, ",")
    end

    --- An instance renders one page, not a stack of them it could swap.
    local function visiblePages(context)
        local count = 0
        for _, child in ipairs(context.root.children) do
            if not child.hidden then
                count = count + 1
            end
        end
        return count
    end

    resetRadio()
    radio.modelFilename = "model1.yml"
    local userAlpha = widgetPath .. "AEROGRID/layouts/alpha.yaml"
    local saved = assert(hostIo.open(userAlpha, "r"))
    local userYaml = saved:read("a")
    saved:close()
    os.remove(userAlpha)

    -- Two layouts, one model: two separate screens of the same radio.
    local alpha = createLoaded(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "alpha", Theme = "modern-dark" },
        widgetPath
    )
    local beta = createLoaded(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "beta", Theme = "modern-dark" },
        widgetPath
    )

    assertEqual(alpha.layoutPath, widgetPath .. "layouts/alpha.yaml")
    assertEqual(beta.layoutPath, widgetPath .. "layouts/beta.yaml")
    assertEqual(idsOf(alpha), "alt")
    assertEqual(idsOf(beta), "mode,pack")

    -- Nothing may be shared but the modules themselves. A service registry held
    -- at module scope would hand one dashboard the other's subscriptions.
    assert(alpha.root ~= beta.root, "two instances share a root")
    assert(alpha.page ~= beta.page, "two instances share a page")
    assert(alpha.serviceRuntime ~= beta.serviceRuntime, "two instances share a service registry")
    assert(
        alpha.serviceRuntime.byId.telemetry ~= beta.serviceRuntime.byId.telemetry,
        "two instances share a telemetry service, and so share subscriptions"
    )

    -- Running them together must not let either disturb the other.
    for _ = 1, 60 do
        tick(20)
        definition.refresh(alpha)
        definition.refresh(beta)
    end

    assertEqual(#alpha.errors, 0, table.concat(alpha.errors, "\n"))
    assertEqual(#beta.errors, 0, table.concat(beta.errors, "\n"))
    assertEqual(idsOf(alpha), "alt", "an instance changed what it rendered")
    assertEqual(idsOf(beta), "mode,pack", "an instance changed what it rendered")
    assertEqual(entryById(alpha, "alt").instance.value.properties.text, "100")
    assertEqual(entryById(beta, "pack").instance.value.properties.text, "24.0")

    -- Each instance renders exactly one page and offers no way to turn it.
    -- Paging between dashboards is EdgeTX sliding between custom screens, not
    -- anything this host does, so an event must not be able to change the page.
    assertEqual(visiblePages(alpha), 1, "an instance rendered more than one page")
    assertEqual(visiblePages(beta), 1, "an instance rendered more than one page")
    assertEqual(definition.event(alpha, 34), false, "the host consumed an event it has no page to turn with")
    assertEqual(
        alpha.layoutPath,
        widgetPath .. "layouts/alpha.yaml",
        "an event changed which layout an instance was showing"
    )
    assertEqual(visiblePages(alpha), 1, "an event added a page")

    -- A layout saved on the radio shadows the shipped one of the same name, on
    -- every model: the name is the identity, not the model.
    writeFile(userAlpha, userYaml)
    radio.modelFilename = "other.yml"
    local switched = createLoaded(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "alpha", Theme = "modern-dark" },
        widgetPath
    )
    assertEqual(switched.layoutPath, userAlpha)
    assertEqual(idsOf(switched), "speed")
    assertEqual(#switched.errors, 0, table.concat(switched.errors, "\n"))

    -- A name with no file falls back to the shipped default rather than
    -- failing to load.
    radio.modelFilename = "third.yml"
    local fallback = createLoaded(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "gamma", Theme = "modern-dark" },
        widgetPath
    )
    assertEqual(fallback.layoutPath, widgetPath .. "layouts/Default.yaml")
    assertEqual(idsOf(fallback), "fallback")

    -- The instances created before the switch are untouched by it, because
    -- nothing about them was keyed on a global.
    assertEqual(idsOf(alpha), "alt", "a later instance disturbed an earlier one")
    assertEqual(alpha.layoutPath, widgetPath .. "layouts/alpha.yaml")

    os.remove(userAlpha)
    radio.modelFilename = previous
end

local function testEventConsumption()
    local widgetPath = makeWidget(
        "consumer",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: eater
    type: eater
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
  - id: pulse
    type: heartbeat
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
]],
        {
            ["eater.lua"] = [==[
local eater = {id = "eater", supportedSpans = {"any"}}
function eater.create(parent, rect, settings, services)
  return {panel = services.primitives.panel(parent, rect, services.theme,
    services.state("normal", "cyan")), seen = 0}
end
function eater.event(context)
  context.seen = context.seen + 1
  return true
end
return eater
]==],
        }
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.panels, 2)

    lvglMock.setFullScreen(true)
    assertEqual(definition.event(context, 32), true, "event was not accepted")
    assertEqual(entryById(context, "eater").instance.seen, 0, "native entry cannot dispatch synchronously")
    for _ = 1, 30 do
        definition.refresh(context)
        if not context.inputQueue then
            break
        end
    end
    assertEqual(entryById(context, "eater").instance.seen, 1)
    -- The later panel must never see a consumed event.
    assertEqual(entryById(context, "pulse").instance.events, 0)
    lvglMock.setFullScreen(false)
end

testMultipleScreens()
testEventConsumption()
