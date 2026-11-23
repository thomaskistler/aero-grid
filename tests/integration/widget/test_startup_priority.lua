-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local path = root .. "/build/test-widget-fixture/"
local panels = {}
for index = 1, 9 do
    panels[index] = {
        id = "metric-" .. index,
        type = "metric",
        col = (index - 1) % 4,
        row = math.floor((index - 1) / 4),
        colSpan = 1,
        rowSpan = 1,
        config = { metrics = { { source = "Alt" } } },
    }
end
local file = assert(io.open(path .. "layouts/startup-visible.yaml", "w"))
file:write(assert(fixture.module("lib/yaml.lua").serialize({
    version = 5,
    grid = { columns = 4, rows = 4 },
    panels = panels,
})))
file:close()
file = assert(io.open(path .. "layouts/startup-hidden.yaml", "w"))
file:write([[
version: 4
grid:
  columns: 4
  rows: 4
panels:
  - id: flights
    type: flight-counter
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      armSwitch: SFv
      minFlightDuration: 1
      disarmDuration: 1
  - id: chart
    type: chart
    col: 0
    row: 1
    colSpan: 4
    rowSpan: 1
    config:
      metrics:
        - source: Alt
]])
file:close()

local definition
local function setup()
    fixture.reset()
    definition = fixture.module("main.lua")
    fixture.radio.fields.ch3 = { id = 306, name = "ch3" }
    fixture.radio.rssi = 80
    fixture.radio.values[305], fixture.radio.values[306] = -1024, -1024
    model.setGlobalVariable(8, 0, 0)
end

local function create(layout)
    return definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = layout or "startup-visible", Theme = "modern-dark" },
        path
    )
end

local function callback(context, hidden)
    (hidden and definition.background or definition.refresh)(context)
    assert(not context.runtimeFailed, table.concat(context.errors, "; "))
end

local function untilDone(step, done)
    for _ = 1, 200 do
        fixture.tick(5)
        step()
        if done() then
            return
        end
    end
    error("startup priority workload did not finish")
end

setup()
local visible, hidden = create(), create("startup-hidden")
callback(visible, false)
untilDone(function()
    callback(hidden, true)
end, function()
    return hidden.loadConfigured
end)
assert(#visible.panels == 0 and #hidden.panels == 0)
local member = hidden.flightFactory.members[hidden]
assert(not member.pending and not member.error, "hidden declarations must not wait for UI construction")
assert(#member.declarations == 1 and member.declarations[1].armKey == "SFv")
assert(member.declarations[1].settings.minFlightDuration == 1, "migrated flight settings must be retained")
assert(hidden.document.version == hidden.layoutValidator.VERSION)
untilDone(function()
    callback(hidden, true)
    callback(visible, false)
    assert(#hidden.panels == 0, "hidden construction cannot overtake the visible loader")
end, function()
    return not visible.stage
end)
local task = hidden.lifecycleTasks.load
local gate = task.gate
-- Leave construction queued to check that the broker no longer waits for it.
task.gate = function()
    return false
end
local owner = assert(hidden.flightFactory.broker)
untilDone(function()
    callback(hidden, true)
    assert(#hidden.panels == 0)
end, function()
    return owner.state.status == "ready"
end)
fixture.radio.values[305], fixture.radio.values[306] = 1024, 0
untilDone(function()
    callback(hidden, true)
    assert(#hidden.panels == 0, "flight initialization must work while hidden constructors are held")
end, function()
    return owner.state.active
end)
assert(owner.view.count == 1, "flight detection must not depend on hidden UI construction")
task.gate = gate
untilDone(function()
    local loading = visible.stage ~= nil
    callback(hidden, true)
    if loading then
        assert(#hidden.panels == 0)
    end
    callback(visible, false)
end, function()
    return not visible.stage and not hidden.stage
end)
assert(#visible.panels == 9 and #hidden.panels == 2)
assert(#visible.errors == 0 and #hidden.errors == 0)
assert(owner.view.count == 1, "constructing the counter must not duplicate a flight")

-- Hidden construction also waits for the first successful normal visible refresh.
setup()
visible, hidden = create(), create()
untilDone(function()
    callback(visible, false)
    callback(hidden, true)
    if visible.firstRefreshUntil then
        assert(#hidden.panels == 0, "hidden construction cannot delay the first normal visible refresh")
    end
end, function()
    return not visible.stage and visible.firstRefreshUntil ~= nil
end)
untilDone(function()
    callback(hidden, true)
    assert(#hidden.panels == 0)
    callback(visible, false)
end, function()
    return not visible.firstRefreshUntil
end)
untilDone(function()
    callback(hidden, true)
end, function()
    return not hidden.stage
end)
assert(#hidden.panels == 9)

-- A stalled refresh gets only a bounded priority window.
setup()
visible, hidden = create(), create()
untilDone(function()
    callback(visible, false)
    callback(hidden, true)
end, function()
    return not visible.stage and visible.firstRefreshUntil ~= nil
end)
local deadline = visible.firstRefreshUntil
for _, entry in ipairs(visible.panels) do
    entry.nextRefresh = deadline + 1000
end
while getTime() < deadline do
    callback(hidden, true)
    assert(#hidden.panels == 0)
    fixture.tick(5)
end
untilDone(function()
    callback(hidden, true)
end, function()
    return not hidden.stage
end)
assert(#hidden.panels == 9, "a stalled or modal-covered foreground must not starve hidden construction")

-- A deliberately empty visible dashboard has no refresh to wait for.
setup()
visible, hidden = create("Empty"), create()
untilDone(function()
    callback(visible, false)
    callback(hidden, true)
end, function()
    return not visible.stage and not hidden.stage
end)
assert(not visible.firstRefreshUntil and #hidden.panels == 9)

-- A dashboard becoming visible takes priority immediately; it need not wait for the old one.
setup()
visible, hidden = create(), create()
untilDone(function()
    callback(visible, false)
    callback(hidden, true)
end, function()
    return hidden.loadConfigured
end)
local oldCount = #visible.panels
untilDone(function()
    callback(hidden, false)
    callback(visible, true)
    if hidden.stage then
        assert(#visible.panels == oldCount, "the old foreground must yield after a screen switch")
    end
end, function()
    return not hidden.stage and not visible.stage
end)
assert(#visible.panels == 9 and #hidden.panels == 9)

-- With no visible loader, hidden dashboards must still finish.
setup()
visible, hidden = create(), create()
untilDone(function()
    callback(visible, true)
    callback(hidden, true)
end, function()
    return not visible.stage and not hidden.stage
end)
assert(#visible.panels == 9 and #hidden.panels == 9)

-- Two visible widget zones must not block each other's construction.
setup()
visible, hidden = create(), create()
untilDone(function()
    callback(visible, false)
    callback(hidden, false)
end, function()
    return not visible.stage and not hidden.stage
end)
assert(#visible.panels == 9 and #hidden.panels == 9)

-- A failed visible layout must release the hidden loader.
setup()
visible, hidden = create(), create()
callback(visible, false)
visible.layoutStore = {
    read = function()
        return nil, "deliberate layout read failure"
    end,
}
untilDone(function()
    callback(visible, false)
    callback(hidden, true)
end, function()
    return not visible.stage and not hidden.stage
end)
assert(#visible.errors > 0 and #hidden.panels == 9 and #hidden.errors == 0)
