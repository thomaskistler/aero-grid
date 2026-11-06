-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local editor = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/editor.lua"))()
local shared = { enabled = false }
shared.self = shared
local module = {
    settings = {
        { key = "a", default = shared }, { key = "b", default = shared },
        { key = "enabled", default = true }, { key = "missing" },
    },
    drawerGroups = { { key = "pack", sourceType = "pack" }, { key = "pack", sourceType = "other" } },
}
local config = { enabled = false, first = shared, second = shared, records = {} }
config.source, config.cells = "Cels", 0
for index = 1, 128 do config.records[index] = { label = "row" .. index, nested = { index } } end
local session = {
    selected = 1, draft = { panels = { { type = "test", config = config } } },
    loadPanel = function() return module end,
    panelHost = { validateModule = function() return true end },
}
local _, expected = editor.settings(session)
local pending = assert(editor.startSettings(session))
local turns, actual, definition, groups = 0
while not actual do
    turns = turns + 1
    local done, result, schema, indexed = editor.advanceSettings(pending)
    if done then actual, definition, groups = result, schema, indexed end
    assert(turns < 1000)
end
assert(turns > 64 and definition == module and actual ~= config)
assert(actual.enabled == false and actual.missing == nil)
assert(actual.first == actual.second and actual.first ~= shared and actual.first.self == actual.first)
assert(actual.a ~= actual.b and actual.a.self == actual.a and actual.b.self == actual.b)
assert(expected.a ~= expected.b and #actual.records == #expected.records)
assert(groups.pack == module.drawerGroups[1], "the first group wins, matching synchronous summaries")
assert(editor.drawerSummary(session, "pack", actual, definition, groups) == editor.drawerSummary(session, "pack"))
for index, record in ipairs(actual.records) do
    assert(record ~= config.records[index] and record.label == expected.records[index].label)
    assert(record.nested ~= config.records[index].nested and record.nested[1] == index)
end
local done, repeated, repeatedModule = editor.advanceSettings(pending)
assert(done and repeated == actual and repeatedModule == module)
assert(config.a == nil and config.b == nil and not session.dirty, "snapshots never mutate the draft")
session.selected = 0
local job, message = editor.startSettings(session)
assert(not job and message == "no panel is selected")
session.selected = 1
session.loadPanel = function() return nil, "panel unavailable" end
job, message = editor.startSettings(session)
assert(not job and message == "panel unavailable")
print("Bounded editor settings snapshots: defaults, graphs, errors and terminal identity passed")
