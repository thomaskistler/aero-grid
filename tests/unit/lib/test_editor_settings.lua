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

session.loadPanel = function() return module end
module.settings[#module.settings + 1] = { key = "items", type = "table", maxItems = 3 }
config.items = { { first = shared, second = shared, records = config.records } }
local original = config.items[1]
session.dirty = false
job = assert(editor.startAppendItem(session, "items"))
assert(not editor.advanceAppendItem(job) and #config.items == 1 and not session.dirty)
turns = 1
while not job.done do
    editor.advanceAppendItem(job)
    turns = turns + 1
    assert(turns < 1000)
end
assert(turns > 64 and job.ok and session.dirty and #config.items == 2)
local added = config.items[2]
assert(added ~= original and added.first == added.second and added.first ~= shared and added.first.self == added.first)
assert(added.records ~= original.records and added.records[128].nested[1] == 128)
assert(editor.advanceAppendItem(job) and #config.items == 2, "terminal append cannot repeat the mutation")
session.dirty = false
job = assert(editor.startAppendItem(session, "items"))
session.selected = 0
local completed, ok, reason = editor.advanceAppendItem(job)
assert(completed and not ok and reason and #config.items == 2 and not session.dirty)
session.selected = 1
job = assert(editor.startAppendItem(session, "items"))
local retained = config.items
config.items = { retained[1], retained[2] }
completed, ok, reason = editor.advanceAppendItem(job)
assert(completed and not ok and reason and #retained == 2 and #config.items == 2 and not session.dirty)
assert(editor.appendItem(session, "items"))
job, message = editor.startAppendItem(session, "items")
assert(not job and string.find(message, "maximum", 1, true))
module.settings[#module.settings + 1] = { key = "retired", default = true, legacyFlight = true }
module.settings[#module.settings + 1] = { key = "arm", default = "SAv", legacyArm = true }
for _, armed in ipairs({ false, true }) do
    session.modelArmed = armed and {} or nil
    local fields = editor.settings(session)
    job = assert(editor.startSettings(session))
    while not editor.advanceSettings(job) do end
    assert(#job.settings == #fields and job.byKey.retired == nil)
    for index, field in ipairs(fields) do assert(job.settings[index] == field and job.byKey[field.key] == field) end
end
print("Bounded editor settings snapshots: defaults, graphs, errors and terminal identity passed")
