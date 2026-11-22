-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local lvglMock = fixture.lvglMock
local appZone = fixture.lvglMock.appZone
local fullScreenZone = fixture.lvglMock.fullScreenZone
local resetRadio = fixture.reset
local MENU_BUTTON_HEIGHT = fixture.firmware.MENU_HEADER_HEIGHT_PX
local MENU_BUTTON_WIDTH = fixture.firmware.MENU_HEADER_BUTTONS_LEFT
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local makeWidget = fixture.makeWidget
local addTheme = fixture.addTheme
local themeModule = fixture.module("lib/theme.lua")
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local entryById = fixture.entryById
local pump = fixture.pump
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    local context = fixture.createLoaded(zone, options, path, definition)
    assert(
        fixture.pumpUntil(context, function()
            return not context.theme or context.runtimeFailed or context.aerogridMenu
        end),
        "menu icon preparation never finished"
    )
    return context
end
assert(
    themeModule.setCatalog(
        assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
    )
)

local function testCreateFailureIsCleaned()
    local widgetPath = makeWidget(
        "halfbuilt",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: broken
    type: halfbuilt
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
  - id: safe
    type: placeholder
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
]],
        {
            ["halfbuilt.lua"] = [==[
local halfbuilt = {id = "halfbuilt", supportedSpans = {"any"}}
function halfbuilt.create(parent, rect, settings, services)
  services.primitives.panel(parent, rect, services.theme,
    services.state("normal", "cyan"))
  error("failed after drawing", 0)
end
return halfbuilt
]==],
        }
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)

    assertEqual(#context.panels, 1, "failed panel must not be kept")
    assertEqual(context.panels[1].placement.id, "safe")
    assert(string.match(table.concat(context.errors, "\n"), "failed after drawing"))
end

local function testFailureIsolation()
    local widgetPath = makeWidget(
        "exploder",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: boom
    type: exploder
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
  - id: safe
    type: placeholder
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
]],
        {
            ["exploder.lua"] = [==[
local exploder = {id = "exploder", supportedSpans = {"any"}}
function exploder.create(parent, rect, settings, services)
  return {panel = services.primitives.panel(parent, rect, services.theme,
    services.state("normal", "cyan"))}
end
function exploder.refresh()
  error("exploder failed", 0)
end
return exploder
]==],
        }
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    assertEqual(#context.panels, 2)

    pump(context, 1)

    local boom = entryById(context, "boom")
    local safe = entryById(context, "safe")
    assertEqual(boom.failed, true, "failing panel was not disabled")
    assert(string.match(boom.error, "exploder failed"), boom.error)
    assertEqual(safe.failed, nil, "healthy panel was disabled")
    assertEqual(#context.errors, 1, "failure was not reported exactly once")
    assert(context.errorLabel, "failure was not shown")

    -- Further refreshes must stay quiet and keep the healthy panel running.
    pump(context, 2)
    assertEqual(#context.errors, 1, "failure was reported repeatedly")
    assertEqual(#context.panels, 2)
end

local function testErrorsClearTheMenuButton()
    local widgetPath = makeWidget(
        "overlay",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: boom
    type: exploder
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
]],
        {
            ["exploder.lua"] = [==[
local exploder = {id = "exploder", supportedSpans = {"any"}}
function exploder.create(parent, rect, settings, services)
  return {panel = services.primitives.panel(parent, rect, services.theme,
    services.state("normal", "cyan"))}
end
function exploder.refresh()
  error("exploder failed", 0)
end
return exploder
]==],
        }
    )

    --- Report whether a box intersects the corner the button covers.
    local function underButton(properties, text)
        local width = themeModule.textWidth(SMLSIZE, text)
        local height = themeModule.fontHeight(SMLSIZE)
        return properties.x < MENU_BUTTON_WIDTH
            and properties.y < MENU_BUTTON_HEIGHT
            and properties.x + width > 0
            and properties.y + height > 0
    end

    local context = createLoaded(appZone(), DEFAULT_OPTIONS, widgetPath)
    pump(context, 1)

    assert(context.reserved, "App mode did not reserve the menu button corner")
    assertEqual(context.reserved.w, MENU_BUTTON_WIDTH, "reserved width")
    assertEqual(context.reserved.h, MENU_BUTTON_HEIGHT, "reserved height")

    local label = assert(context.errorLabel, "failure was not shown at all")
    local text = table.concat(context.errors, "\n")
    assert(
        not underButton(label.properties, text),
        "the error overlay is drawn under the EdgeTX menu button, at ("
            .. label.properties.x
            .. ","
            .. label.properties.y
            .. ")"
    )
    -- Clearing the button must not push it off the screen either.
    assert(
        label.properties.y + themeModule.fontHeight(SMLSIZE) <= 272,
        "the error overlay was pushed off the bottom of the display"
    )

    -- Outside App mode the button is either hidden or drawn above the widget, so
    -- nothing is reserved and the overlay keeps the whole zone.
    local plain = createLoaded(fullScreenZone(), DEFAULT_OPTIONS, widgetPath)
    pump(plain, 1)
    assertEqual(plain.reserved, nil, "a Full screen zone reserved a corner")
    assertEqual(assert(plain.errorLabel).properties.y, 8, "the overlay gave up room it did not have to")

    -- A radio whose button is not 45 px must still be measured rather than
    -- assumed. EdgeTX scales MENU_HEADER_HEIGHT per display class, so a host
    -- that never unshifts the constant falls back to this file's 480 x 272
    -- guess and is wrong everywhere else; only a different height can catch it.
    local wideButton = 62
    MENU_HEADER_HEIGHT = wideButton * 65536
    local wide = createLoaded(appZone(), DEFAULT_OPTIONS, widgetPath)
    assertEqual(
        assert(wide.reserved, "no corner reserved on a wider display").h,
        wideButton,
        "the button height was assumed rather than read"
    )
    assertEqual(wide.reserved.w, 65, "the width kept clear does not match MENU_HEADER_BUTTONS_LEFT")
    MENU_HEADER_HEIGHT = MENU_BUTTON_HEIGHT * 65536

    -- A zone that moves out from under the button releases the reservation, and
    -- the overlay it already created follows.
    lvglMock.setAppMode(true)
    local moving = createLoaded(appZone(), DEFAULT_OPTIONS, widgetPath)
    pump(moving, 1)
    local moved = assert(moving.errorLabel).properties.y
    assert(moved > 8, "App mode overlay was not moved clear")
    moving.zone.yabs = MENU_BUTTON_HEIGHT
    moving.zone.h = 272 - MENU_BUTTON_HEIGHT
    pump(moving, 4)
    assertEqual(moving.reserved, nil, "reservation survived the zone moving")
    assertEqual(moving.errorLabel.properties.y, 8, "the overlay did not follow the zone out from under the button")
    lvglMock.setAppMode(false)
end

local function testNoticesAreNotErrors()
    local custom = makeWidget(
        "custom-theme",
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
  - id: boom
    type: exploder
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
]],
        {
            ["exploder.lua"] = [==[
local exploder = {id = "exploder", supportedSpans = {"any"}}
function exploder.create(parent, rect, settings, services)
  return {panel = services.primitives.panel(parent, rect, services.theme,
    services.state("normal", "cyan"))}
end
function exploder.refresh()
  error("exploder failed", 0)
end
return exploder
]==],
        }
    )
    addTheme(custom, "notice-test", { colors = { surface = 0xFFFFFF } })

    resetRadio()
    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, { Layout = "main", Theme = "notice-test" }, custom)
    assertEqual(context.theme.mode, "notice-test")

    -- The deliberately light mock roles guarantee the legibility pass engages,
    -- so a test that saw no notices would not be testing anything.
    assert(#context.notices > 0, "the legibility pass recorded nothing")
    local corrected = false
    for _, notice in ipairs(context.notices) do
        assert(
            notice.severity == "info" or notice.severity == "warning",
            "notice carried no usable severity: " .. tostring(notice.severity)
        )
        if string.match(notice.text, "corrected for contrast") then
            corrected = true
        end
    end
    assert(corrected, "no contrast correction was recorded on a custom palette")
    assertEqual(
        #context.errors,
        0,
        "the legibility pass was reported as a failure: " .. table.concat(context.errors, "\n")
    )
    assertEqual(context.errorLabel, nil, "a notice put a banner on the screen")

    -- A panel that genuinely fails must still reach the overlay, so the
    -- fix cannot have been "stop reporting things".
    pump(context, 1)
    assertEqual(#context.errors, 1, "a real failure stopped being reported")
    assert(string.match(context.errors[1], "exploder failed"), context.errors[1])
    assert(context.errorLabel, "a real failure was not shown")
end

local function testRuntimeFailureIsContained()
    local widgetPath = makeWidget("brokenruntime")
    os.execute("rm -f '" .. widgetPath .. "lib/layout_store.lua'")

    local context = definition.create({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)

    definition.refresh(context)
    assertEqual(context.runtimeFailed, true)
    assertEqual(context.stage, nil, "a broken runtime must not stage a load")
    assert(string.match(table.concat(context.errors, "\n"), "runtime module failed"))

    -- Changing an option previously restaged a load that indexed a nil module.
    definition.update(context, { Layout = "other", Theme = "modern-dark" })
    assertEqual(context.reloadState, nil, "a broken runtime must not restage")

    for _ = 1, 5 do
        local ok, err = pcall(definition.refresh, context)
        assert(ok, "refresh raised after a runtime failure: " .. tostring(err))
    end
    local ok, err = pcall(definition.background, context)
    assert(ok, "background raised after a runtime failure: " .. tostring(err))
    assertEqual(#context.panels, 0)
end

testCreateFailureIsCleaned()
testFailureIsolation()
testErrorsClearTheMenuButton()
testNoticesAreNotErrors()
testRuntimeFailureIsContained()
