-- SPDX-License-Identifier: GPL-2.0-only

local root, batch = ...
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
fixture.reset()
fixture.radio.rssi, fixture.radio.values[300] = 80, 1024
local definition = fixture.module("main.lua")
local function load(path, ...)
    local base = string.sub(path, 1, 6) == "tests/" and root .. "/" or root .. "/src/WIDGETS/AeroGrid/"
    return assert(loadfile(base .. path))(...)
end
local Stress = load("tests/support/chart_mipmap_stress.lua", load)
local path = root .. "/build/test-widget-fixture/"
local lines = { "version: 3", "grid:", "  columns: 4", "  rows: 4", "panels:" }
for chart = 1, 2 do
    lines[#lines + 1] = string.format(
        "  - id: chart%d\n    type: chart\n    col: 0\n    row: %d\n    colSpan: 4\n    rowSpan: 2\n"
            .. "    config:\n      armSwitch: SAv\n      metrics:",
        chart,
        (chart - 1) * 2
    )
    for series = 1, 3 do
        local index = (chart - 1) * 3 + series
        local name = "Q" .. index
        fixture.radio.fields[name] = { id = 5000 + index, name = name, unit = 1 }
        fixture.radio.values[5000 + index] = index / 10
        lines[#lines + 1] = "        - source: " .. name .. "\n          precision: 3"
    end
end
fixture.radioMock.indexFields()
local file = assert(io.open(path .. "layouts/mipmap-stress.yaml", "w"))
io.write(file, table.concat(lines, "\n") .. "\n")
io.close(file)
os.execute("mkdir -p '" .. path .. "AEROGRID/models'")
local filename = model.getInfo().filename
local modelPath = assert(fixture.module("lib/model_settings_store.lua").path(path, filename))
local modelFile = assert(io.open(modelPath, "w"))
io.write(
    modelFile,
    assert(fixture.module("lib/yaml.lua").serialize({
        version = 1,
        revision = 0,
        modelFilename = filename,
        armed = "SAv",
    }))
)
io.close(modelFile)
local context = fixture.createLoaded(
    { x = 0, y = 0, w = 480, h = 272 },
    { Layout = "mipmap-stress", Theme = "modern-dark" },
    path
)
local workload = Stress.new(context, 800, batch or 64)
while true do
    fixture.tick(5)
    if workload:prepare(definition.refresh) then
        break
    end
end
for _, operation in ipairs(Stress.operations) do
    if operation == "scroll" then
        workload.scrollIndex = 1
        while not workload:prepareScroll(definition.refresh) do
            fixture.tick(5)
        end
    end
    repeat
        fixture.tick(5)
    until workload:prepareOperation(definition.refresh)
    workload:begin(operation)
    local worst, samples = 0, {}
    repeat
        fixture.tick(5)
        fixture.lvglMock.setPropertyValidation(false)
        fixture.lvglMock.setCallCounting(false)
        fixture.lcdMock.setTextMeasurement(false)
        local instructions = 0
        debug.sethook(function()
            instructions = instructions + 100
        end, "", 100)
        local complete = workload:step(definition.refresh)
        debug.sethook()
        fixture.lvglMock.setPropertyValidation(true)
        fixture.lvglMock.setCallCounting(true)
        fixture.lcdMock.setTextMeasurement(true)
        assert(#context.errors == 0, table.concat(context.errors, "\n"))
        fixture.lvglMock.settle()
        worst = math.max(worst, instructions)
        samples[#samples + 1] = instructions
    until complete
    workload:verify()
    local row = workload.rows[#workload.rows]
    row.instructions, row.callback_instructions = worst, samples
    print(
        string.format(
            "STRESS op=%s turns=%d callbacks=%d ms=%d instructions=%d inputs=%d catchups=%d group_moves=%d",
            operation,
            row.turns,
            row.callbacks,
            row.setter_complete_ms,
            worst,
            row.input_events,
            row.catchups,
            row.group_moves
        )
    )
end
assert(workload.history.count == 24)
local observations = 0
for _, row in ipairs(workload.rows) do
    observations = observations + row.input_events
end
assert(observations > 0, "continuous service input was not exercised")
print("Real service/Smart competing-chart correctness checks passed")
return workload.rows
