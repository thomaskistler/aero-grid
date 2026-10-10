-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local equal = assertions.assertEqual
local fixture = WidgetFixture.new()
local panel = fixture.module("panels/state.lua")
local host = fixture.module("lib/panel_host.lua")
local widgetPath = root .. "/build/test-widgets/state-panel/"
os.execute("mkdir -p '" .. widgetPath .. "' && cp -R '" .. root .. "/src/WIDGETS/AeroGrid/.' '" .. widgetPath .. "'")

local function entry(source, label, middle)
    local states = { { switch = string.upper(source) .. "^", text = "LOW" } }
    if middle then
        states[#states + 1] = { switch = string.upper(source) .. "-", text = middle }
    end
    states[#states + 1] = { switch = string.upper(source) .. "v", text = "HIGH" }
    return { label = label, states = states }
end

for count = 1, 3 do
    local entries = {}
    for index = 1, count do
        entries[index] = entry("sa", "MODE", "MID")
    end
    equal(#panel.validateSettings({ entries = entries }), 0)
end
local invalid = {
    {},
    { entries = {} },
    { entries = { entry("sa", "MODE"), entry("sb", "RATE"), entry("sf", "FLAP"), entry("sa", "EXTRA") } },
    { entries = { [1] = entry("sa", "MODE"), [3] = entry("sb", "RATE") } },
    { entries = { extra = entry("sa", "MODE") } },
    { entries = { "bad" } },
    { entries = { entry("RxBt", "MODE") } },
    { entries = { entry("sa", "") } },
    { entries = { entry("sa", "LINE\nBREAK") } },
    { entries = { { label = "MODE" } } },
    { entries = { { label = "MODE", states = {} } } },
}
for _, states in ipairs({
    { "bad" },
    { { switch = "sa", text = "LOW" } },
    { { switch = "SA^", text = "" } },
    { { switch = "SA^", text = "LINE\nBREAK" } },
    { { switch = "SA^", text = true } },
    { { switch = "SA^", text = "LOW", background = "red" } },
    { { switch = "SA^", text = "LOW", source = "sa" } },
    { [1] = { switch = "SA^", text = "LOW" }, [3] = { switch = "SAv", text = "HIGH" } },
    { extra = { switch = "SA^", text = "LOW" } },
    { {}, {}, {}, {} },
}) do
    invalid[#invalid + 1] = { entries = { { label = "MODE", states = states } } }
end
for index, settings in ipairs(invalid) do
    assert(#panel.validateSettings(settings) > 0, "accepted invalid text configuration " .. index)
end
local _, warnings = host.resolveSettings(panel, { entries = { entry("sa", "MODE") }, unknown = true })
assert(#warnings > 0, "unknown top-level key was accepted")
_, warnings = host.resolveSettings(panel, { entries = { entry("sa", "MODE") }, accent = "critical" })
assert(#warnings > 0, "text cannot request alarm accent")

local function feed(value)
    return { known = true, available = true, fresh = true, value = value }
end
local priority = {
    label = "PRIORITY",
    states = {
        { switch = "L01", text = "FIRST", background = "critical" },
        { switch = "L02", text = "SECOND", background = "warning" },
        { switch = "L03", text = "THIRD" },
    },
}
equal(#panel.validateSettings({ entries = { priority } }), 0)
local value, status, background = panel.reading(priority, { feed(true), feed(true), feed(true) })
equal(value, "FIRST", "first true condition wins when multiple conditions match")
equal(background, "critical")
value, status, background = panel.reading(priority, { feed(false), feed(true), feed(true) })
equal(value, "SECOND", "false conditions fall through in order")
equal(background, "warning")
equal(panel.reading(priority, { feed(false), feed(false), feed(true) }), "THIRD")
equal(panel.reading(priority, { feed(false), feed(false), feed(false) }), "UNMAPPED")
equal(panel.reading(priority, { {}, feed(true), feed(true) }), "--", "unknown earlier condition blocks fallthrough")
equal(panel.reading(priority, { feed(true), {}, {} }), "FIRST", "unknown later conditions do not override a winner")
local stale = feed(false)
stale.fresh = false
equal(panel.reading(priority, { stale, feed(true), feed(true) }), "--", "stale earlier condition blocks fallthrough")

local function create(entries, cols, rows, theme)
    fixture.reset()
    fixture.radio.rssi = 0
    local lines = {
        "version: 1",
        "grid:",
        "  columns: 4",
        "  rows: 4",
        "panels:",
        "  - id: state",
        "    type: state",
        "    col: 1",
        "    row: 1",
        "    colSpan: " .. (cols or 2),
        "    rowSpan: " .. (rows or 2),
        "    config:",
        "      accent: green",
        "      entries:",
    }
    for _, item in ipairs(entries) do
        lines[#lines + 1] = "        - label: " .. item.label
        lines[#lines + 1] = "          states:"
        for _, condition in ipairs(item.states) do
            lines[#lines + 1] = "            - switch: " .. condition.switch
            lines[#lines + 1] = '              text: "' .. condition.text .. '"'
            if condition.background then
                lines[#lines + 1] = "              background: " .. condition.background
            end
        end
    end
    local file = assert(io.open(widgetPath .. "layouts/Default.yaml", "w"))
    file:write(table.concat(lines, "\n") .. "\n")
    file:close()
    local context = fixture.createLoaded(nil, { Layout = "main", Theme = theme or "modern-dark" }, widgetPath)
    fixture.pump(context, 20)
    equal(#context.errors, 0, table.concat(context.errors, "; "))
    local instance = assert(fixture.instanceOf(context, "state"))
    return context, instance
end

local function fits(instance, object)
    local properties = object.properties
    local font = properties.font()
    equal(object.lines, 1, "text must never wrap")
    equal(object.replacedFontRefs, nil, "font callbacks leaked")
    local width = instance.themeBuilder.measureText(font, properties.text)
    assert(width <= properties.w, "text was clipped")
    assert(properties.x >= instance.area.frame.pad, "text left the content box")
    assert(
        properties.x + width <= instance.panel.root.properties.w - instance.area.frame.padRight,
        "text left the panel"
    )
end

local twoPosition = entry("sf", "MODE")
twoPosition.states = { { switch = "SF^", text = "DISARMED" }, { switch = "SFv", text = "ARMED" } }
local context, instance = create({ twoPosition })
equal(instance.text, "DISARMED")
equal(instance.stateName, "normal")
equal(instance.panel.accent.properties.color, instance.theme.color.green)
equal(context.serviceRuntime.byId.telemetry.count, 0)
equal(context.serviceRuntime.byId.control.count, 2)
equal(context.serviceRuntime.byId.navigation.count, 0)
local font = instance.value.properties.font()
fits(instance, instance.value)
equal(panel.reading(twoPosition, nil), "--", "missing source service asserted a switch state")
fixture.radio.values[305] = 1024
fixture.pump(context, 20)
equal(instance.text, "ARMED")
equal(instance.value.properties.font(), font, "switch movement changed the font")
fixture.radio.values[305] = 0
fixture.pump(context, 20)
equal(instance.text, "UNMAPPED", "two-position mapping treated a middle as an end")
equal(instance.stateName, "unavailable")
fixture.radio.values[305] = 42
fixture.pump(context, 20)
equal(instance.text, "UNMAPPED", "non-switch numeric value was inferred as a position")
fixture.radio.values[305] = nil
fixture.pump(context, 20)
equal(instance.text, "--", "absent source reused a stale switch label")
fixture.radio.values[305] = -1024
fixture.pump(context, 20)
equal(instance.text, "DISARMED")
local writes = instance.value.writes
panel.refresh(instance)
equal(instance.value.writes, writes, "unchanged text was repainted")

context, instance = create({ entry("sa", "MODE", "MID"), entry("sb", "RATE", "MID") })
equal(instance.text, "HIGH")
equal(instance.supporting[2].properties.text, "RATE MID", "middle must be live with no receiver")
assert(instance.showSupporting)
fits(instance, instance.supporting[2])

context, instance = create({
    twoPosition,
    entry("sa", "RATE", "MID"),
    entry("sb", "FLAP", "MID"),
})
equal(context.serviceRuntime.byId.control.count, 8)
equal(instance.supporting[2].properties.text, "RATE HIGH")
equal(instance.supporting[3].properties.text, "FLAP MID")
fixture.radio.values[300], fixture.radio.values[301] = -1024, 1024
fixture.pump(context, 20)
equal(instance.text, "DISARMED")
equal(instance.supporting[2].properties.text, "RATE LOW", "supporting transition lost while primary was unchanged")
equal(instance.supporting[3].properties.text, "FLAP HIGH")
fixture.radio.values[300], fixture.radio.values[301] = 0, nil
fixture.pump(context, 20)
equal(instance.supporting[2].properties.text, "RATE MID")
equal(instance.supporting[3].properties.text, "FLAP --")
equal(instance.stateName, "normal", "supporting source changed primary state")
fixture.radio.values[301] = 37
fixture.pump(context, 20)
equal(instance.supporting[3].properties.text, "FLAP ?", "supporting unmapped value was hidden or inferred")
fits(instance, instance.value)
fits(instance, instance.supporting[2])
fits(instance, instance.supporting[3])
local originalFont = instance.value.properties.font()
local originalCallback = instance.value.properties.font
local originalRect = { x = 0, y = 0, w = instance.panel.root.properties.w, h = instance.panel.root.properties.h }
panel.update(instance, { x = 0, y = 0, w = 95, h = 65 })
assert(not instance.showSupporting)
assert(instance.supporting[2].hidden and instance.supporting[3].hidden)
local hiddenWrites = instance.supporting[2].writes
fixture.radio.values[300] = 1024
fixture.pump(context, 20)
equal(instance.supporting[2].writes, hiddenWrites, "hidden supporting text was repainted")
panel.update(instance, originalRect)
assert(instance.showSupporting)
equal(instance.supporting[2].properties.text, "RATE HIGH", "restored row used old text")
equal(instance.value.properties.font(), originalFont, "font failed to restore after resize")
equal(instance.value.properties.font, originalCallback, "resize replaced the retained font callback")
fits(instance, instance.value)
fits(instance, instance.supporting[2])
fits(instance, instance.supporting[3])
for _ = 1, 30 do
    panel.update(instance, { x = 0, y = 0, w = 95, h = 65 })
    panel.update(instance, originalRect)
end
equal(instance.value.properties.font, originalCallback)
fits(instance, instance.value)
fits(instance, instance.supporting[2])
fits(instance, instance.supporting[3])

context, instance = create({ entry("sz", "MODE", "MID") })
equal(instance.text, "--", "unknown source asserted a switch state")
equal(instance.stateName, "unavailable")
assert(not instance.feeds[1][1].known)
fixture.radio.fields.sz = { id = 300, name = "sz", desc = "Test switch" }
fixture.pump(context, 30)
equal(instance.text, "HIGH", "newly available source was never retried")
fixture.radio.fields.sz = nil
local proportional = entry("sa", "MODE", "ready")
proportional.states[1].text, proportional.states[3].text = "iiiiiiiiiiii", "WWWW"
context, instance = create({ proportional })
font = instance.value.properties.font()
for _, raw in ipairs({ -1024, 0, 1024 }) do
    fixture.radio.values[300] = raw
    fixture.pump(context, 20)
    equal(instance.value.properties.font(), font)
    fits(instance, instance.value)
end
local excessive = entry("sa", "MODE", "MID")
excessive.states[3].text = string.rep("W", 100)
excessive.states[3].background = "active"
context, instance = create({ excessive })
equal(instance.text, "NO FIT", "oversized mode text was clipped or shortened silently")
equal(instance.stateName, "unavailable")
equal(instance.panel.surfaceColor, instance.theme.color.surface, "NO FIT clears the configured mode")
fits(instance, instance.value)
panel.update(instance, { x = 0, y = 0, w = 2000, h = 200 })
equal(instance.text, excessive.states[3].text, "enlargement did not restore the exact text")
equal(instance.stateName, "active", "enlargement restores the winning mode")
fits(instance, instance.value)

context, instance = create({ entry("sa", "MODE", "MID"), entry("sa", "RATE", "MID") }, 2, 1)
equal(context.serviceRuntime.byId.control.count, 3, "identical switches did not share a subscription")
assert(instance.area.showSide, "compact text failed to use shared supporting side stack")
fits(instance, instance.value)
fits(instance, instance.supporting[2])
assert(context.serviceRuntime.byId.control.revision > 0)
assert(not context.serviceRuntime.byId.control.failed)

local colored = entry("sa", "MODE", "MID")
colored.states[1].text, colored.states[3].text = "SAME", "SAME"
colored.states[1].background, colored.states[3].background = "warning", "active"
local supporting = entry("sb", "RATE", "MID")
supporting.states[2].background = "critical"
context, instance = create({ colored, supporting })
equal(instance.text, "SAME")
equal(instance.stateName, "active", "main entry determines the panel mode")
equal(instance.panel.surfaceColor, instance.theme.alertColor.active)
equal(instance.panel.accentColor, instance.theme.color.blue)
equal(instance.badgeText, "IN-FLIGHT", "active uses the shared presentation")
equal(instance.backgrounds, nil, "no individual reading background rectangles remain")
equal(
    instance.supporting[2].properties.color,
    instance.theme.color.text,
    "colored supporting reading uses primary text contrast"
)
fixture.radio.values[300] = -1024
fixture.pump(context, 20)
equal(instance.text, "SAME")
equal(
    instance.panel.surfaceColor,
    instance.theme.alertColor.warning,
    "mode-only transitions repaint when the text stays unchanged"
)
equal(instance.stateName, "warning", "supporting critical condition does not override the main mode")
equal(instance.panel.accentColor, instance.theme.color.amber)
equal(instance.badgeText, "", "warning mode does not display WARN")
fits(instance, instance.value)
fits(instance, instance.supporting[2])
panel.update(instance, { x = 0, y = 0, w = 95, h = 65 })
equal(instance.supporting[2].hidden, true)
equal(instance.panel.surfaceColor, instance.theme.alertColor.warning, "mode survives compact reflow")
fits(instance, instance.value)
panel.update(instance, { x = 0, y = 0, w = 240, h = 130 })
equal(instance.supporting[2].hidden, false)
fits(instance, instance.value)
fits(instance, instance.supporting[2])
fixture.radio.values[300] = 0
fixture.pump(context, 20)
equal(instance.stateName, "normal", "supporting critical mode cannot change a normal panel")
equal(instance.panel.surfaceColor, instance.theme.color.surface, "normal restores the panel background")
equal(instance.panel.accentColor, instance.theme.color.green, "normal restores the configured sidebar")
equal(instance.badgeText, "")
fixture.radio.values[300] = nil
fixture.pump(context, 20)
equal(instance.text, "--")
equal(instance.panel.surfaceColor, instance.theme.color.surface, "unavailable clears the previous mode")
equal(instance.panel.accentColor, instance.theme.color.textFaint)
equal(instance.badgeText, "N/A")

context, instance = create({ priority })
assert(instance.text == "UNMAPPED" or instance.text == "?", "false logical switches leave the entry unmapped")
fixture.radio.logicalSwitches[1], fixture.radio.logicalSwitches[2] = true, true
fixture.pump(context, 20)
equal(instance.text, "FIRST", "logical switches use the same priority evaluation")
equal(instance.panel.surfaceColor, instance.theme.alertColor.critical)
equal(instance.panel.accentColor, instance.theme.color.critical)
equal(instance.badgeText, "", "critical mode does not display CRIT")
fixture.radio.logicalSwitches[1] = false
fixture.pump(context, 20)
equal(instance.text, "SECOND")
fixture.radio.logicalSwitches[2] = false
fixture.pump(context, 20)
assert(instance.text == "UNMAPPED" or instance.text == "?", "no match does not retain previous reading")
equal(instance.panel.surfaceColor, instance.theme.color.surface, "no match clears previous mode")

for _, theme in ipairs({ "modern-dark", "modern-light" }) do
    for _, background in ipairs({ "active", "warning", "critical" }) do
        colored.states[3].background = background
        context, instance = create({ colored, supporting }, 2, 2, theme)
        equal(instance.theme.mode, theme)
        local expected = instance.state(background, instance.settings.accent)
        equal(instance.panel.surfaceColor, expected.surface)
        equal(instance.panel.background.properties.color, expected.surface)
        equal(instance.panel.accentColor, expected.accent)
        equal(instance.panel.accent.properties.color, expected.accent)
        equal(instance.value.properties.color, instance.theme.color.text)
        equal(instance.label.properties.color, expected.label)
        equal(
            instance.badgeText,
            background == "active" and expected.badge or "",
            "warning and critical omit their badges"
        )
        for _, width in ipairs({ 112, 232, 352, 472 }) do
            for _, height in ipairs({ 56, 122 }) do
                panel.update(instance, { x = 0, y = 0, w = width, h = height })
                equal(instance.panel.surfaceColor, expected.surface)
                fits(instance, instance.value)
                if not instance.supporting[2].hidden then
                    fits(instance, instance.supporting[2])
                end
            end
        end
    end
end

os.execute("rm -rf '" .. widgetPath .. "'")
fixture.reset()
