-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local equal = assertions.assertEqual
local fixture = WidgetFixture.new()
local panel = fixture.module("panels/text.lua")
local host = fixture.module("lib/panel_host.lua")
local widgetPath = root .. "/build/test-widgets/text-panel/"
os.execute("mkdir -p '" .. widgetPath .. "' && cp -R '" .. root .. "/src/WIDGETS/AeroGrid/.' '" .. widgetPath .. "'")

local function entry(source, label, middle)
    return { source = source, label = label, positions = { up = "LOW", middle = middle, down = "HIGH" } }
end

for count = 1, 3 do
    local entries = {}
    for index = 1, count do
        entries[index] = entry("sa", "MODE", "MID")
    end
    equal(#panel.validateSettings({ texts = entries }), 0)
end
local invalid = {
    {},
    { texts = {} },
    { texts = { entry("sa", "MODE"), entry("sb", "RATE"), entry("sf", "FLAP"), entry("sa", "EXTRA") } },
    { texts = { [1] = entry("sa", "MODE"), [3] = entry("sb", "RATE") } },
    { texts = { extra = entry("sa", "MODE") } },
    { texts = { "bad" } },
    { texts = { { source = 300, label = "MODE", positions = { up = "A", down = "B" } } } },
    { texts = { entry("RxBt", "MODE") } },
    { texts = { entry("SA", "MODE") } },
    { texts = { entry("sa", "") } },
    { texts = { entry("sa", "LINE\nBREAK") } },
    { texts = { { source = "sa", label = "MODE" } } },
    { texts = { { source = "sa", label = "MODE", positions = { up = "A" } } } },
    { texts = { { source = "sa", label = "MODE", positions = { up = "A", down = "" } } } },
    { texts = { { source = "sa", label = "MODE", positions = { up = "A", down = "B", middle = false } } } },
    { texts = { { source = "sa", label = "MODE", positions = { up = "A", down = "B", other = "C" } } } },
    { texts = { { source = "sa", label = "MODE", positions = { up = "A", down = "B", [0] = "C" } } } },
    { texts = { { source = "sa", label = "MODE", text = "STATIC", positions = { up = "A", down = "B" } } } },
}
for index, settings in ipairs(invalid) do
    assert(#panel.validateSettings(settings) > 0, "accepted invalid text configuration " .. index)
end
local _, warnings = host.resolveSettings(panel, { texts = { entry("sa", "MODE") }, unknown = true })
assert(#warnings > 0, "unknown top-level key was accepted")
_, warnings = host.resolveSettings(panel, { texts = { entry("sa", "MODE") }, accent = "critical" })
assert(#warnings > 0, "text cannot request alarm accent")

local function create(entries, cols, rows)
    fixture.reset()
    fixture.radio.rssi = 0
    local lines = {
        "version: 1",
        "grid:",
        "  columns: 4",
        "  rows: 4",
        "panels:",
        "  - id: text",
        "    type: text",
        "    col: 1",
        "    row: 1",
        "    colSpan: " .. (cols or 2),
        "    rowSpan: " .. (rows or 2),
        "    config:",
        "      accent: green",
        "      texts:",
    }
    for _, item in ipairs(entries) do
        lines[#lines + 1] = "        - source: " .. item.source
        lines[#lines + 1] = "          label: " .. item.label
        lines[#lines + 1] = "          positions:"
        for _, position in ipairs({ "up", "middle", "down" }) do
            if item.positions[position] then
                lines[#lines + 1] = "            " .. position .. ': "' .. item.positions[position] .. '"'
            end
        end
    end
    local file = assert(io.open(widgetPath .. "layouts/Default.yaml", "w"))
    file:write(table.concat(lines, "\n") .. "\n")
    file:close()
    local context = fixture.createLoaded(nil, nil, widgetPath)
    fixture.pump(context, 20)
    equal(#context.errors, 0, table.concat(context.errors, "; "))
    local instance = assert(fixture.instanceOf(context, "text"))
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
twoPosition.positions = { up = "DISARMED", down = "ARMED" }
local context, instance = create({ twoPosition })
equal(instance.text, "DISARMED")
equal(instance.stateName, "normal")
equal(instance.panel.accent.properties.color, instance.theme.color.green)
equal(context.serviceRuntime.byId.telemetry.count, 1)
equal(context.serviceRuntime.byId.control.count, 0)
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
equal(context.serviceRuntime.byId.telemetry.count, 3)
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
assert(not instance.feeds[1].known)
fixture.radio.fields.sz = { id = 300, name = "sz", desc = "Test switch" }
fixture.pump(context, 30)
equal(instance.text, "HIGH", "newly available source was never retried")
fixture.radio.fields.sz = nil
local known = { known = true, available = true, fresh = true, telemetry = true, value = 1024 }
equal(panel.reading(twoPosition, known), "--", "telemetry sensor masqueraded as switch")

local proportional = entry("sa", "MODE", "ready")
proportional.positions.up, proportional.positions.down = "iiiiiiiiiiii", "WWWW"
context, instance = create({ proportional })
font = instance.value.properties.font()
for _, raw in ipairs({ -1024, 0, 1024 }) do
    fixture.radio.values[300] = raw
    fixture.pump(context, 20)
    equal(instance.value.properties.font(), font)
    fits(instance, instance.value)
end
local excessive = entry("sa", "MODE", "MID")
excessive.positions.down = string.rep("W", 100)
context, instance = create({ excessive })
equal(instance.text, "NO FIT", "oversized mode text was clipped or shortened silently")
equal(instance.stateName, "unavailable")
fits(instance, instance.value)
panel.update(instance, { x = 0, y = 0, w = 2000, h = 200 })
equal(instance.text, excessive.positions.down, "enlargement did not restore the exact text")
fits(instance, instance.value)

context, instance = create({ entry("sa", "MODE", "MID"), entry("sa", "RATE", "MID") }, 2, 1)
equal(context.serviceRuntime.byId.telemetry.count, 1, "identical switches did not share a subscription")
assert(instance.area.showSide, "compact text failed to use shared supporting side stack")
fits(instance, instance.value)
fits(instance, instance.supporting[2])
assert(context.serviceRuntime.byId.telemetry.revision > 0)
assert(not context.serviceRuntime.byId.telemetry.failed)

os.execute("rm -rf '" .. widgetPath .. "'")
fixture.reset()
