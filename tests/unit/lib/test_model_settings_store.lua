-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local base = root .. "/src/WIDGETS/AeroGrid"
local module = assert(loadfile(base .. "/lib/model_settings_store.lua"))()
local writer = assert(loadfile(base .. "/lib/verified_file.lua"))()
local config = assert(loadfile(base .. "/lib/flight_config.lua"))()
local yaml = assert(loadfile(base .. "/lib/yaml.lua"))()
local memory = assert(loadfile(root .. "/tests/support/memory_files.lua"))()

local function fixture()
    local files, operations = memory()
    local current = "plane.yml"
    local store = module.new("/WIDGETS/AeroGrid/", yaml, {
        modelFilename = function()
            return current
        end,
        flightConfig = config,
        verifiedFile = writer,
    }, operations)
    return store, files, operations, function(value)
        current = value
    end
end

local function path(filename)
    return assert(module.path("/WIDGETS/AeroGrid/", filename or "plane.yml"))
end

do
    local store, files = fixture()
    local document, info = store:load("plane.yml")
    assert(info.missing and document.revision == 0 and document.flight == nil)
    assert(next(files) == nil, "opening a model draft must not create configuration")
    local saved, result = store:save("plane.yml", 0, config.defaults())
    assert(saved, result)
    assert(result.revision == 1 and result.modelFilename == "plane.yml")
    assert(result.flight.motorSource == "ch3" and result.flight.history)
    result.flight.motorSource = "ch1"
    assert(store:load("plane.yml").flight.motorSource == "ch3", "published tables must not mutate disk state")
    local draft = config.defaults()
    draft.flightSwitch = "L64"
    saved, result = store:save("plane.yml", 1, draft)
    assert(saved and result.revision == 2, result)
    assert(yaml.parse(files[path() .. ".bak"]).revision == 1)
    saved, result = store:save("plane.yml", 1, draft)
    assert(not saved and string.find(result, "reload", 1, true))
    assert(yaml.parse(files[path()]).revision == 2)
end

do
    assert(not module.path("/WIDGETS/AeroGrid/", nil))
    assert(not module.path("/WIDGETS/AeroGrid/", ""))
    assert(not module.path("/WIDGETS/AeroGrid/", " \n"))
    assert(not module.path("/WIDGETS/AeroGrid/", "a\0b"))
    local identities = { "plane.yml", "plane.yaml", "Plane.yml", "../plane.yml", "a/b", "a-b", "a.b", "a_b" }
    local seen = {}
    for _, filename in ipairs(identities) do
        local encoded = path(filename)
        assert(not seen[encoded] and string.match(encoded, "/models/%x+%.yaml$"))
        seen[encoded] = true
    end
end

do
    local store, files = fixture()
    files[path()] = "invalid: [yaml"
    local document, message = store:load("plane.yml")
    assert(not document and string.find(message, "Cannot load", 1, true))
    local saved = store:save("plane.yml", 0, config.defaults())
    assert(not saved, "corruption must not silently become defaults")
    files[path()] = assert(yaml.serialize({ version = 99, revision = 0, modelFilename = "plane.yml" }))
    assert(not store:load("plane.yml"))
    files[path()] = assert(yaml.serialize({ version = 1, revision = 0, modelFilename = "other.yml" }))
    assert(not store:load("plane.yml"))
end

do
    local store, files, operations = fixture()
    assert(store:save("plane.yml", 0, config.defaults()))
    assert(store:save("plane.yml", 1, config.defaults()))
    files[path()] = "damaged"
    local document, info = store:load("plane.yml")
    assert(document.revision == 1 and info.recovered and info.notice)
    operations.inject("rename")
    local saved = store:save("plane.yml", 1, config.defaults())
    assert(not saved)
    assert(yaml.parse(files[path() .. ".bak"]).revision == 1, "failed recovery must retain the good backup")
    operations.inject(nil)
    assert(store:save("plane.yml", 1, config.defaults()))
    assert(store:load("plane.yml").revision == 2)
end

for _, failure in ipairs({ "open", "write", "close", "read", "rename" }) do
    local store, files, operations = fixture()
    operations.inject(failure)
    local saved, message = store:save("plane.yml", 0, config.defaults())
    assert(not saved and type(message) == "string", failure)
    assert(files[path()] == nil, failure .. " published a failed save")
end

do
    local store, files, operations, switchModel = fixture()
    operations.inject("read", function(filename)
        if string.match(filename, "%.tmp$") then
            switchModel("other.yml")
        end
    end)
    local saved, message = store:save("plane.yml", 0, config.defaults())
    assert(not saved and string.find(message, "Model changed", 1, true))
    assert(files[path()] == nil and files[path() .. ".tmp"] == nil)
    assert(not store:save("plane.yml", 0, config.defaults()))
end

do
    local store, files, operations = fixture()
    operations.inject("read", function(filename)
        assert(string.match(filename, "%.tmp$"))
        files[path()] = assert(yaml.serialize({
            version = 1,
            modelFilename = "plane.yml",
            revision = 1,
            flight = config.defaults(),
        }))
    end)
    local saved, message = store:save("plane.yml", 0, config.defaults())
    assert(not saved and string.find(message, "changed", 1, true))
    assert(yaml.parse(files[path()]).revision == 1)
end

do
    local store = fixture()
    for _, entry in ipairs({
        { "armSwitch", "SF^" },
        { "ownership", true },
        { "motorReversed", 1 },
        { "motorSource", "ch33" },
        { "flightSwitch", "!L01" },
        { "flightSwitch", "L00" },
        { "flightSwitch", "L65" },
        { "minMotorPercent", 100 },
        { "disarmDuration", 0 },
    }) do
        local draft = config.defaults()
        draft[entry[1]] = entry[2]
        local saved, message = store:save("plane.yml", 0, draft)
        assert(not saved and type(message) == "string", entry[1])
    end
    assert(store:save("plane.yml", 0, {}), "optional omitted fields resolve through current defaults")
end

do
    local store, files, operations, switchModel = fixture()
    assert(store:save("plane.yml", 0, config.defaults()))
    local previous = files[path()]
    operations.inject("rename", function(from)
        if from == path() then
            switchModel("other.yml")
        end
    end)
    local saved, message = store:save("plane.yml", 1, config.defaults())
    assert(not saved and string.find(message, "Model changed", 1, true))
    assert(files[path() .. ".bak"] == previous and files[path() .. ".tmp"] == nil)
end

do
    local store, files, operations = fixture()
    local read = operations.read
    operations.read = function(handle, size)
        local content = read(handle, size)
        return content and string.gsub(content, "ch3", "ch4")
    end
    local saved, message = store:save("plane.yml", 0, config.defaults())
    assert(not saved and string.find(message, "differs", 1, true))
    assert(files[path()] == nil and files[path() .. ".tmp"] == nil)
    operations.read = read
    operations.write = function()
        error("injected SD exception")
    end
    saved, message = store:save("plane.yml", 0, config.defaults())
    assert(not saved and string.find(message, "SD exception", 1, true))
end

do
    local _, files, operations = fixture()
    local layouts = assert(loadfile(base .. "/lib/layout_store.lua"))(writer)
    local layout = assert(loadfile(base .. "/lib/layout.lua"))()
    local grid = assert(loadfile(base .. "/lib/grid.lua"))()
    local document = { version = 5, grid = { columns = 4, rows = 4 }, panels = {} }
    assert(layouts.save("/WIDGETS/AeroGrid/", "Layout-A", document, yaml, layout, grid, operations))
    assert(layouts.save("/WIDGETS/AeroGrid/", "Layout-B", document, yaml, layout, grid, operations))
    for filename in pairs(files) do
        assert(
            not string.find(filename, "/models/", 1, true),
            "layout Save/Save As must not configure model flight settings"
        )
    end
end
