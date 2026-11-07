-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local base = root .. "/src/WIDGETS/AeroGrid/lib/"
local module = assert(loadfile(base .. "model_settings_store.lua"))()
local writer = assert(loadfile(base .. "verified_file.lua"))()
local config = assert(loadfile(base .. "flight_config.lua"))()
local yaml = assert(loadfile(base .. "yaml.lua"))()
local armed = assert(loadfile(base .. "armed_service.lua"))()
local memory = assert(loadfile(root .. "/tests/support/memory_files.lua"))()
local path = assert(module.path("/WIDGETS/AeroGrid/", "plane.yml"))

local function fixture()
    local files, operations = memory()
    local current = "plane.yml"
    local store = module.new("/WIDGETS/AeroGrid/", yaml, {
        modelFilename = function()
            if current == false then error("identity unavailable") end
            return current
        end,
        flightConfig = config, verifiedFile = writer, armedConfig = armed,
    }, operations)
    return store, files, operations, function(value) current = value end
end

local function same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for key, value in pairs(a) do
        if not same(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

local function finish(store, job)
    for _ = 1, 2000 do
        assert(store:loadWorkBound(job), job.stage)
        local done, document, info = store:advanceLoad(job)
        if done then
            local repeated, repeatedDocument, repeatedInfo = store:advanceLoad(job)
            assert(repeated and repeatedDocument == document and repeatedInfo == info)
            return document, info
        end
        assert(document == nil and info == nil, "pending loads do not publish partial data")
    end
    error("bounded model settings load did not finish")
end

local valid = {
    version = 1, modelFilename = "plane.yml", revision = 7,
    armed = "!L64", sessionReset = "L03", flight = config.defaults(),
}
local text = assert(yaml.serialize(valid))
local edited = string.rep("# retained comment\n", 40) .. string.gsub(text, "flight:\n",
    'flight:\n  history:\n    - name: "obsolete # quoted"\n      values:\n        - 1\n'
        .. '        - false\n  announcements:\n    - "ignored"\n', 1)

for _, primary in ipairs({
    false, text, edited, "", "damaged", "version: 0\n", "version: 99\n",
    string.gsub(text, "plane.yml", "other.yml"),
    text .. "\nversion: 1\n", (string.gsub(text, "ch3", "ch33")),
}) do
    for _, backup in ipairs({ false, text, edited, "damaged" }) do
        local store, files, operations = fixture()
        files[path], files[path .. ".bak"] = primary or nil, backup or nil
        local beforePrimary, beforeBackup = files[path], files[path .. ".bak"]
        for _, name in ipairs({ "write", "rename", "remove" }) do
            operations[name] = function() error("load must not mutate disk") end
        end
        local expected, expectedInfo = store:load("plane.yml")
        local job = assert(store:startLoad("plane.yml"))
        local document, info = finish(store, job)
        assert(same(document, expected) and same(info, expectedInfo), tostring(primary) .. ": load parity")
        assert(files[path] == beforePrimary and files[path .. ".bak"] == beforeBackup)
        assert(files[path .. ".tmp"] == nil)
    end
end

for _, failure in ipairs({ "open", "read", "close" }) do
    local store, files, operations = fixture()
    files[path], files[path .. ".bak"] = text, text
    operations.inject(failure)
    local expected, message = store:load("plane.yml")
    local document, info = finish(store, assert(store:startLoad("plane.yml")))
    assert(same(document, expected) and same(info, message), failure)
end

for stage in pairs(module.LOAD_BOUNDS) do
    if stage ~= "start" then
        for _, unavailable in ipairs({ "other.yml", false }) do
            local store, files, _, setIdentity = fixture()
            files[path] = text
            local job = assert(store:startLoad("plane.yml"))
            while job.stage ~= stage do assert(not store:advanceLoad(job)) end
            setIdentity(unavailable)
            local done, document, message = store:advanceLoad(job)
            assert(done and not document and type(message) == "string")
            assert(string.find(message, unavailable == false and "identity unavailable" or "Model changed", 1, true))
            setIdentity("plane.yml")
            local repeated, result, repeatedMessage = store:advanceLoad(job)
            assert(repeated and not result and repeatedMessage == message)
            assert(files[path] == text and not files[path .. ".tmp"])
        end
    end
end

do
    local store, files, operations, setIdentity = fixture()
    files[path] = text
    setIdentity("other.yml")
    assert(store:load("plane.yml").revision == 7, "synchronous old-model reading remains available")
    local job, message = store:startLoad("plane.yml")
    assert(not job and string.find(message, "Model changed", 1, true))
    setIdentity(false)
    job, message = store:startLoad("plane.yml")
    assert(not job and string.find(message, "identity unavailable", 1, true))
    setIdentity("plane.yml")
    operations.stat = function() error("injected stat failure") end
    job = assert(store:startLoad("plane.yml"), "start performs no disk operations")
    local document, info = finish(store, job)
    assert(not document and string.find(info, "Cannot load model settings:", 1, true))
    assert(string.find(info, "injected stat failure", 1, true))
end

do
    local store, files, _, setIdentity = fixture()
    files[path] = text
    local job = assert(store:startLoad("plane.yml"))
    assert(not store:advanceLoad(job))
    files[path] = string.gsub(text, "revision: 7", "revision: 8")
    local document, info = finish(store, job)
    assert(document.revision == 7, "the reader retains its captured source")
    setIdentity(false)
    local done, repeated, repeatedInfo = store:advanceLoad(job)
    assert(done and repeated == document and repeatedInfo == info, "completed loads remain idempotent")
    assert(string.find(files[path], "revision: 8", 1, true), "load never overwrites a concurrent save")
end

do
    local store, files, operations = fixture()
    files[path] = text
    local closes, close = 0, operations.close
    operations.read = function() error("injected read exception") end
    operations.close = function(handle)
        closes = closes + 1
        return close(handle)
    end
    local document, message = finish(store, assert(store:startLoad("plane.yml")))
    assert(not document and string.find(message, "injected read exception", 1, true))
    assert(closes == 1, "exceptional reads close before returning an error")
    document, message = store:load("plane.yml")
    assert(not document and string.find(message, "injected read exception", 1, true))
    assert(closes == 2, "the shared synchronous reader also releases exceptional handles")
end

print("Bounded model settings load parity and identity checks passed")
