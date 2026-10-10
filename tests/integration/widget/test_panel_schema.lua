-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local definition = fixture.module("main.lua")

for _, source in ipairs({
    "version: 1\ngrid:\n  columns: 4\n  rows: 4\n",
    "version: 1\ngrid:\n  columns: 4\n  rows: 4\ncomponents:\n  - id: clock\n    type: flight-timer\n",
}) do
    fixture.reset()
    local context = definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "Default", Theme = "modern-dark" },
        root .. "/src/WIDGETS/AeroGrid/"
    )
    context.source = source
    context.tokens = {}
    context.readPosition = 1
    context.readLine = 1
    context.stage = "tokenize"
    local guard = 0
    while context.stage do
        definition.refresh(context)
        guard = guard + 1
        assert(guard < 20, "invalid layout never finished loading")
    end
    assertions.assertEqual(#context.panels, 0)
    assertions.assertEqual(#context.errors, 1)
    assertions.assertEqual(context.errors[1], "panels must be a sequence")
end
