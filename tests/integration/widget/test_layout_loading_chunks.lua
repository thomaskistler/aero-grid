-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
local lines = { "version: 5", "grid:", "  columns: 4", "  rows: 4" }
for index = 1, 128 do
    lines[#lines + 1] = "metadata_" .. index .. ': "retained # text" # ' .. string.rep("comment ", 24)
end
lines[#lines + 1] = "retained:\n  - item: first\n    values:\n      - one\n      - two"
lines[#lines + 1] = "panels:\n  - id: readings\n    type: metric\n    col: 0\n    row: 0\n    colSpan: 4\n    rowSpan: 4\n"
    .. "    config:\n      metrics:"
for _, sourceName in ipairs({ "Alt", "Curr", "VFAS" }) do
    lines[#lines + 1] = "        - source: "
        .. sourceName
        .. "\n          label: Reading\n          unit: x\n          precision: 1"
        .. "\n          rangeMin: 0\n          rangeMax: 100\n          warning: 80"
        .. "\n          critical: 95\n          direction: rising"
end
local source = table.concat(lines, "\n")
local function create()
    fixture.reset()
    local context = definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "review-flight-mode", Theme = "modern-dark" },
        root .. "/build/test-widget-fixture/"
    )
    assert(fixture.pumpUntil(context, function(value)
        return value.stage == "read"
    end, 150, 10))
    local read = context.layoutStore.readCandidates
    context.layoutStore.readCandidates = function()
        return source, nil, "chunked.yaml", "user"
    end
    context.dashboardLoader.advanceLoad(context)
    context.layoutStore.readCandidates = read
    return context
end

local context, seen = create(), {}
for _ = 1, 1000 do
    if not context.stage then
        break
    end
    seen[context.stage] = (seen[context.stage] or 0) + 1
    fixture.tick(10)
    definition.refresh(context)
end
assert(not context.stage and #context.errors == 0, table.concat(context.errors, "; "))
for _, stage in ipairs({ "tokenize", "header", "header-parse", "header-validate", "header-finalize" }) do
    assert(seen[stage] and seen[stage] > 1, stage .. " must advance incrementally")
end
assert(seen["panel-tokens"] > 1 and seen["panel-parse"] > 1)
local expected, errors = context.layoutValidator.validate(assert(context.yaml.parse(source)), context.grid)
assert(#errors == 0)
assert(
    context.yaml.serialize(context.document) == context.yaml.serialize(expected),
    "bounded loading must preserve all accepted metadata and sequence values"
)
assert(#context.panels == 1 and context.panels[1].placement.id == "readings")

for _, stage in ipairs({
    "tokenize",
    "header",
    "header-parse",
    "header-validate",
    "header-finalize",
    "panel-tokens",
    "panel-parse",
}) do
    context = create()
    assert(
        fixture.pumpUntil(context, function(value)
            return value.stage == stage
        end, 800, 10),
        stage
    )
    context.dashboardLoader.beginLoad(context)
    assert(
        context.stage == "theme-read" and not context.headerWork and not context.pendingItem and not context.commentWork,
        stage .. ": replacement loads must discard all parser continuations"
    )
end
print("Layout loading: bounded header/item parsing, unknown metadata parity and replacement cancellation passed")
