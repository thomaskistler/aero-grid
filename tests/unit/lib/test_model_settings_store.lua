-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local base = root .. "/src/WIDGETS/AeroGrid"
local module = assert(loadfile(base .. "/lib/model_settings_store.lua"))()
local writer = assert(loadfile(base .. "/lib/verified_file.lua"))()
local config = assert(loadfile(base .. "/lib/flight_config.lua"))()
local yaml = assert(loadfile(base .. "/lib/yaml.lua"))()
local memory = assert(loadfile(root .. "/tests/support/memory_files.lua"))()
local sidecar = assert(loadfile(base .. "/lib/model_settings_sidecar.lua"))()

local function fixture()
    local files, operations = memory()
    local current = "plane.yml"
    local channel =
        { name = "AGTEST", min = -800, max = 900, offset = 25, ppmCenter = 10, symetrical = 1, revert = 1, curve = 2 }
    local state = { channel = channel, disarmed = true, writes = 0, id = "AGNEW1" }
    local env = {
        modelFilename = function()
            return current
        end,
        flightConfig = config,
        flightCount = assert(loadfile(base .. "/lib/flight_count.lua"))(),
        verifiedFile = writer,
        armedConfig = assert(loadfile(base .. "/lib/armed_service.lua"))(),
        getOutput = function(index)
            assert(index == 31)
            local result = {}
            for key, value in pairs(state.channel) do
                result[key] = value
            end
            return result
        end,
        setOutput = function(index, output)
            assert(index == 31)
            state.writes = state.writes + 1
            -- luaModelSetOutput memclears the whole channel before applying keys.
            -- EdgeTX 2.12 radio/src/lua/api_model.cpp: luaModelSetOutput.
            state.channel =
                { name = "", min = -1000, max = 1000, offset = 0, ppmCenter = 0, symetrical = 0, revert = 0 }
            if not state.reject then
                for key, value in pairs(output) do
                    state.channel[key] = value
                end
            end
        end,
        isDisarmed = function()
            return state.disarmed
        end,
        generateId = function()
            return state.generate and state.generate() or state.id
        end,
    }
    env.sidecar = sidecar
    local store = module.new("/WIDGETS/AeroGrid/", yaml, env, operations)
    return store, files, operations, function(value)
        current = value
    end, state, env
end

local function path(filename)
    return assert(sidecar.path("/WIDGETS/AeroGrid/", filename or "AGTEST"))
end

do
    local store, files = fixture()
    local document, info = store:load("plane.yml")
    assert(info.missing and document.revision == 0 and document.flight == nil)
    assert(next(files) == nil, "opening a model draft must not create configuration")
    local saved, result = store:save("plane.yml", 0, config.defaults(), "SFv", "!L01")
    assert(saved, result)
    assert(result.revision == 1 and result.modelFilename == "plane.yml")
    assert(result.flight.motorSource == "ch3" and result.flight.history == nil)
    assert(result.flight.smartDetection == false)
    assert(result.flight.requireReceiver == true)
    assert(result.armed == "SFv" and store:load("plane.yml").armed == "SFv")
    assert(result.sessionReset == "!L01" and store:load("plane.yml").sessionReset == "!L01")
    result.flight.motorSource = "ch1"
    assert(store:load("plane.yml").flight.motorSource == "ch3", "published tables must not mutate disk state")
    local draft = config.defaults()
    draft.flightSwitch = "L64"
    draft.smartDetection = true
    draft.requireReceiver = false
    saved, result = store:save("plane.yml", 1, draft)
    assert(saved and result.revision == 2, result)
    assert(result.armed == "SFv", "flight-only callers preserve saved model arming")
    assert(result.sessionReset == "!L01", "old callers preserve the reset switch")
    assert(store:load("plane.yml").flight.smartDetection == true, "Smart survives verified save/reload")
    assert(store:load("plane.yml").flight.requireReceiver == false, "receiver opt-out survives verified save/reload")
    assert(yaml.parse(files[path() .. ".bak"]).flight.requireReceiver == true)
    assert(yaml.parse(files[path() .. ".bak"]).flight.smartDetection == false)
    assert(yaml.parse(files[path() .. ".bak"]).revision == 1)
    saved, result = store:save("plane.yml", 1, draft)
    assert(not saved and string.find(result, "reopen", 1, true))
    assert(yaml.parse(files[path()]).revision == 2)
    local prepared, staged = store:prepare("plane.yml", 2, draft)
    assert(prepared and yaml.parse(files[path()]).revision == 2, "prepare does not write")
    assert(store:save("plane.yml", 2, draft))
    saved, result = store:commit(staged)
    assert(not saved and string.find(result, "changed during save", 1, true), result)
    assert(yaml.parse(files[path()]).revision == 3, "a stale prepared save cannot overwrite a newer one")
end

do
    local store = fixture()
    local function count(expected, value, imported)
        local ok, prepared = store:prepareCount("plane.yml", expected, value, imported)
        assert(ok, prepared)
        local saved, document = store:commit(prepared)
        assert(saved, document)
        return document
    end
    local document = count(nil, 0)
    assert(document.flightCount == 0 and document.flight == nil and document.armed == nil)
    assert(not store:prepareCount("plane.yml", nil, 123), "zero must never be treated as uninitialized")
    assert(store:save("plane.yml", 0, config.resolve({ countSource = "gv8gv9" }), "", "L02"))
    document = count(0, 1000, { flight = { motorSource = "ch1" }, armed = "SFv" })
    assert(document.flight.countSource == "gv8gv9" and document.flight.motorSource == "ch3")
    assert(document.armed == "" and document.sessionReset == "L02")
    assert(document.revision == 1, "counts do not change the drawer's settings revision")
    local ok, prepared = store:prepare("plane.yml", 1, config.defaults())
    assert(ok)
    count(1000, 1001)
    local saved, message = store:commit(prepared)
    assert(not saved and string.find(message, "changed", 1, true))
    assert(store:load("plane.yml").flightCount == 1001, "a stale drawer cannot overwrite a newer count")
    ok, prepared = store:prepareCount("plane.yml", 1001, 1002)
    assert(ok)
    assert(store:save("plane.yml", 1, config.resolve({ motorSource = "ch5" })))
    assert(not store:commit(prepared), "a count cannot overwrite newer configuration")
    document = count(1001, 1002)
    assert(document.flight.motorSource == "ch5")
    assert(not store:prepareCount("plane.yml", 1002, 16777216), "radio-safe numeric bound is enforced")
end

do
    local store = fixture()
    local ok, prepared = store:prepareCount("plane.yml", nil, 4123, {
        flight = { motorSource = "ch5", minFlightDuration = 12 },
        armed = "SFv",
    })
    assert(ok, prepared)
    local saved, document = store:commit(prepared)
    assert(saved, document)
    assert(document.flightCount == 4123 and document.armed == "SFv" and document.flight.motorSource == "ch5")
    assert(store:load("plane.yml").flightCount == 4123, "restart reloads the committed total")
    local preparedCount, large = store:prepareCount("plane.yml", 4123, 16777215.0)
    assert(preparedCount, large)
    assert(string.find(large.serialized, "flightCount: 16777215\n", 1, true))
    assert(store:commit(large))
    assert(store:load("plane.yml").flightCount == 16777215, "large totals round-trip without float formatting loss")
end

do
    local store = fixture()
    for _, value in ipairs({ 123, "ch5", "sa", "L00", "L65", "!ch3", "SF", true }) do
        local saved = store:save("plane.yml", 0, config.defaults(), value)
        assert(not saved, "non-switch arming must not be persisted: " .. tostring(value))
        assert(
            not store:save("plane.yml", 0, config.defaults(), nil, value),
            "invalid reset input must not be persisted"
        )
    end
    local saved, result = store:save("plane.yml", 0, config.defaults(), "!L64")
    assert(saved and result.armed == "!L64", result)
    saved, result = store:save("plane.yml", 1, config.defaults(), "")
    assert(saved and result.armed == "", "explicit None must survive save/reload and suppress legacy switches")
    assert(store:load("plane.yml").armed == "")
    saved, result = store:save("plane.yml", 2, config.defaults(), nil, "")
    assert(saved and result.sessionReset == "", "None disables session reset")
    local output = config.defaults()
    output.flightSwitch = "L01"
    for _, input in ipairs({ "L01", "!L01" }) do
        saved, result = store:save("plane.yml", 3, output, nil, input)
        assert(not saved and string.find(result, "Session reset input", 1, true))
    end
end

do
    for _, invalid in ipairs({ "", " \n", "a\0b", "agTEST", "AGABC", "AGABCDE", "../AGABCD", "AGab12", "AG12_3" }) do
        assert(not sidecar.path("/WIDGETS/AeroGrid/", invalid))
    end
    assert(not sidecar.path("/WIDGETS/AeroGrid/", nil))
    local identities = { "AGABCD", "AG1234", "AGZ0A9" }
    local seen = {}
    for _, filename in ipairs(identities) do
        local encoded = path(filename)
        assert(not seen[encoded] and encoded == "/AEROGRID/models/" .. filename .. ".yaml")
        seen[encoded] = true
    end
end

for _, history in ipairs({ true, false }) do
    local store, files = fixture()
    local legacy = config.defaults()
    legacy.smartDetection = nil
    legacy.requireReceiver = nil
    legacy.announcements = true
    legacy.history = history
    legacy.liveDangerously = history
    files[path()] = assert(yaml.serialize({ version = 1, modelFilename = "plane.yml", revision = 3, flight = legacy }))
    assert(store:load("plane.yml").flight.smartDetection == false, "existing model files keep standard detection")
    assert(store:load("plane.yml").flight.requireReceiver == true, "existing model files still require a receiver")
    local loaded = store:load("plane.yml")
    assert(loaded.flight.announcements == nil, "obsolete audio settings are ignored")
    assert(loaded.flight.history == nil, "obsolete CSV settings must not prevent loading existing model files")
    assert(loaded.flight.liveDangerously == nil, "the removed Pre-release setting is ignored")
    assert(config.key(loaded.flight) == config.key(config.defaults()), "obsolete audio settings cannot cause conflicts")
    assert(store:save("plane.yml", 3, loaded.flight))
    assert(yaml.parse(files[path()]).flight.announcements == nil, "obsolete audio settings are not persisted")
    assert(yaml.parse(files[path()]).flight.history == nil, "obsolete CSV settings are not persisted")
    assert(yaml.parse(files[path()]).flight.liveDangerously == nil)
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
    local loaded, info = store:load("plane.yml")
    assert(loaded.modelFilename == "plane.yml" and info.foreign)
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
        { "requireReceiver", 1 },
        { "requireReceiver", "false" },
        { "smartDetection", 1 },
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

do
    local store, files, operations, _, state = fixture()
    state.channel.name = ""
    local original = {}
    for key, value in pairs(state.channel) do
        original[key] = value
    end
    local document, info = store:load("plane.yml")
    assert(info.missing and document.revision == 0 and state.writes == 0 and next(files) == nil)
    state.disarmed = false
    local saved, message = store:save("plane.yml", 0, config.defaults())
    assert(not saved and string.find(message, "Disarm", 1, true) and next(files) == nil and state.writes == 0)
    state.disarmed = true
    operations.inject("rename")
    assert(not store:save("plane.yml", 0, config.defaults()))
    assert(state.channel.name == "" and state.writes == 0)
    operations.inject(nil)
    local rename = operations.rename
    operations.rename = function(from, to)
        assert(state.channel.name == "", "record is installed before claiming CH32")
        return rename(from, to)
    end
    assert(store:save("plane.yml", 0, config.defaults()))
    assert(state.channel.name == "AGNEW1" and state.writes == 1 and files[path("AGNEW1")])
    for key, value in pairs(original) do
        assert(key == "name" or state.channel[key] == value, "CH32 field lost: " .. key)
    end
    assert(store:load("plane.yml").revision == 1)
end

do
    local store, files, _, _, state = fixture()
    state.channel.name = "MOTOR"
    local document, info = store:load("plane.yml")
    assert(document.revision == 0 and info.blocked and state.writes == 0 and next(files) == nil)
    local saved, message = store:save("plane.yml", 0, config.defaults())
    assert(not saved and string.find(message, "Clear the CH32 name", 1, true))
    assert(state.channel.name == "MOTOR" and state.writes == 0)
end

do
    local store, files, _, switch, state = fixture()
    assert(store:save("plane.yml", 0, config.defaults(), "SFv"))
    assert(state.writes == 0, "missing record with an existing AG ID needs no channel write")
    local original = files[path()]
    switch("copy.yml")
    local document, info = store:load("copy.yml")
    assert(info.foreign and document.modelFilename == "copy.yml" and document.revision == 1)
    assert(files[path()] == original and state.writes == 0, "loading a copy must be read-only")
    state.disarmed = false
    local saved, message, deferred = store:adopt("copy.yml", document)
    assert(not saved and deferred and string.find(message, "Disarm", 1, true))
    assert(state.channel.name == "AGTEST" and files[path()] == original)
    state.disarmed = true
    assert(store:adopt("copy.yml", document))
    assert(state.channel.name == "AGNEW1" and state.channel.min == -800 and state.channel.curve == 2)
    assert(files[path()] == original and yaml.parse(files[path("AGNEW1")]).modelFilename == "copy.yml")
    assert(store:adopt("copy.yml", document) and state.writes == 1, "adoption is idempotent")
    assert(store:save("copy.yml", 1, config.defaults(), ""))
    assert(yaml.parse(files[path()]).armed == "SFv" and yaml.parse(files[path("AGNEW1")]).armed == "")
    switch("plane.yml")
    state.channel.name = "AGTEST"
    assert(store:load("plane.yml").armed == "SFv")
end

do
    local store, files, operations, switch, state = fixture()
    assert(store:save("plane.yml", 0, config.defaults()))
    local original = files[path()]
    switch("moved.yml")
    local document = assert(store:load("moved.yml"))
    operations.inject("write")
    assert(not store:adopt("moved.yml", document))
    assert(state.writes == 0 and files[path()] == original)
    operations.inject(nil)
    state.reject = true
    local saved, message = store:adopt("moved.yml", document)
    assert(not saved and string.find(message, "verify CH32", 1, true))
    assert(files[path()] == original and files[path("AGNEW1")], "failed claim leaves only an orphan")
    state.channel.name, state.reject, state.id = "AGTEST", false, "AGNEW2"
    assert(store:adopt("moved.yml", document))
    assert(state.channel.name == "AGNEW2" and files[path()] == original)
end

do
    local store, files, _, _, state = fixture()
    state.channel.name = ""
    files[path("AGUSED")] = "occupied"
    files[path("AGBAK1") .. ".bak"] = "occupied"
    local candidates = { "AGUSED", "AGBAK1", "AGFREE" }
    local index = 0
    state.generate = function()
        index = index + 1
        return candidates[index]
    end
    assert(store:save("plane.yml", 0, config.defaults()))
    assert(state.channel.name == "AGFREE" and index == 3)
    state.channel.name = ""
    state.generate = function()
        return "../bad"
    end
    local saved, message = store:save("plane.yml", 0, config.defaults())
    assert(not saved and string.find(message, "Invalid", 1, true) and state.writes == 1)
    state.generate = function()
        return "AGUSED"
    end
    saved, message = store:save("plane.yml", 0, config.defaults())
    assert(not saved and string.find(message, "allocate", 1, true))
end

do
    local store, files, operations, _, state, env = fixture()
    local prepared, staged = store:prepare("plane.yml", 0, config.defaults())
    assert(prepared)
    state.channel.name = "AGELSE"
    local saved, message = store:commit(staged)
    assert(not saved and string.find(message, "CH32 name changed", 1, true) and next(files) == nil)
    state.channel.name = "AGTEST"
    local other = module.new("/WIDGETS/AeroGrid/", yaml, env, operations)
    assert(other:save("plane.yml", 0, config.defaults()))
    assert(not store:commit(staged), "separate instances share revision guards")
    prepared, staged = store:prepare("plane.yml", 1, config.defaults())
    assert(prepared)
    operations.inject("read", function(filename)
        if string.match(filename, "%.tmp$") then
            state.channel.name = "OTHER"
        end
    end)
    saved, message = store:commit(staged)
    assert(not saved and string.find(message, "CH32 name changed", 1, true))
    assert(yaml.parse(files[path()]).revision == 1 and state.writes == 0)
end

for _, failure in ipairs({ "armed", "channel", "model" }) do
    local store, files, operations, switch, state = fixture()
    state.channel.name = ""
    operations.inject("read", function(filename)
        if string.match(filename, "%.tmp$") then
            if failure == "armed" then
                state.disarmed = false
            elseif failure == "channel" then
                state.channel.name = "OTHER"
            else
                switch("other.yml")
            end
        end
    end)
    local saved, _, deferred = store:save("plane.yml", 0, config.defaults())
    assert(not saved and state.writes == 0 and not files[path("AGNEW1")], failure)
    assert(deferred == (failure == "armed"), failure)
end

do
    local store, files, operations, switch, state = fixture()
    assert(store:save("plane.yml", 0, config.defaults()))
    switch("copy.yml")
    local accepted, info = store:load("copy.yml")
    state.channel.name = "AGELSE"
    files[path("AGELSE")] = files[path()]
    local saved, message = store:adopt("copy.yml", accepted, info)
    assert(not saved and string.find(message, "CH32 name changed", 1, true) and state.writes == 0)
    state.channel.name = "AGTEST"
    assert(store:save("copy.yml", 1, config.defaults()), "saving a foreign draft also forks")
    assert(state.channel.name == "AGNEW1" and yaml.parse(files[path()]).revision == 1)
end

for _, failure in ipairs({ "open", "write", "close", "read", "rename" }) do
    local store, files, operations, _, state = fixture()
    state.channel.name = ""
    operations.inject(failure)
    local saved, message = store:save("plane.yml", 0, config.defaults())
    assert(not saved and type(message) == "string" and state.writes == 0, failure)
    assert(state.channel.name == "" and state.channel.min == -800 and not files[path("AGNEW1")], failure)
end

do
    local store, files = fixture()
    assert(store:save("plane.yml", 0, config.defaults()))
    local ok, prepared = store:prepare("plane.yml", 1, config.defaults())
    assert(ok)
    files[path()] = string.gsub(files[path()], "ch3", "ch4")
    local saved, message = store:commit(prepared)
    assert(not saved and string.find(message, "changed", 1, true), "guard even same-revision external edits")
    assert(yaml.parse(files[path()]).flight.motorSource == "ch4")
end

do
    local store, files, _, switch, state = fixture()
    assert(store:save("plane.yml", 0, config.defaults()))
    assert(store:save("plane.yml", 1, config.defaults()))
    local backup = files[path() .. ".bak"]
    files[path()] = "damaged"
    switch("copy.yml")
    local document, info = store:load("copy.yml")
    assert(document.revision == 1 and info.recovered and info.foreign)
    assert(store:adopt("copy.yml", document, info))
    assert(state.channel.name == "AGNEW1" and files[path()] == "damaged" and files[path() .. ".bak"] == backup)
end

do
    local store, files, _, _, state = fixture()
    state.channel.name = ""
    files["/AEROGRID/models/706c616e652e796d6c.yaml"] =
        assert(yaml.serialize({ version = 1, modelFilename = "plane.yml", revision = 9 }))
    local document, info = store:load("plane.yml")
    assert(document.revision == 0 and info.missing and state.writes == 0, "legacy dev records are not imported")
end

do
    local store, _, _, _, state = fixture()
    state.channel.name, state.channel.curve = "", nil
    assert(store:save("plane.yml", 0, config.defaults()))
    assert(state.channel.curve == nil, "claiming an ID must not assign an unconfigured output curve")
end
