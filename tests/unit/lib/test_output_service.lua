-- SPDX-License-Identifier: GPL-2.0-only

local root = ... or "."
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local support = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local control = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/control_service.lua"))()

local fields = {
    [1] = { id = 1, name = "ail" },
    [2] = { id = 2, name = "ele" },
    [3] = { id = 3, name = "input1" },
    ["trim-ail"] = { id = 4 },
    ["trim-ele"] = { id = 5 },
}
local raw, trimRaw, mode, switch, reads = 512, 256, 0, true, 0
local outputName = "AIL"
-- EdgeTX api_model.cpp returns MixData.carryTrim unchanged (false = enabled)
-- and -ExpoData.trimSource (0 = auto, -1 = off, 1..4 = R/E/T/A).
local mixes = { { source = 1, carryTrim = false, weight = 100 } }
local inputs = { { source = 1, trimSource = 0 } }
local env = support.environment({
    getFieldInfo = function(source)
        return fields[source]
    end,
    getOutputValue = function(index)
        equal(index, 0)
        return raw
    end,
    getValue = function()
        return trimRaw
    end,
    getFlightMode = function()
        return mode
    end,
    getSwitchValue = function()
        return switch
    end,
    model = {
        getOutput = function(index)
            equal(index, 0)
            return { name = outputName }
        end,
        getMix = function(_, line)
            reads = reads + 1
            return mixes[line + 1]
        end,
        getInput = function(_, line)
            reads = reads + 1
            return inputs[line + 1]
        end,
    },
})
local service = control.new(env, support)
local feed = service:output(0)
equal(service:output(0), feed)
equal(service.count, 1)
equal(service.interval, 10, "output subscriptions use the fast service cadence")
assert(not feed.available)
assert(not feed.nameReady, "new subscriptions must not publish unresolved captions")
assert(not pcall(function()
    feed.raw = 1
end), "output snapshots must be immutable")
local now = 0
local function settle()
    for _ = 1, 150 do
        now = now + 20
        local before = reads
        service:update(now)
        assert(reads - before <= 6, "metadata reads must respect the service poll cap")
    end
end
settle()
equal(feed.name, "AIL")
assert(feed.nameReady, "resolved output names must be marked ready")
equal(feed.raw, 512)
equal(feed.fraction, 0.5)
equal(feed.trim.name, "trim-ail")
equal(feed.trim.fraction, 0.25)
local metadataReads = reads
raw, trimRaw = 768, 512
service:update(now + 10)
equal(feed.fraction, 0.75, "outputs update between ordinary control polls")
equal(feed.trim.fraction, 0.25, "trims retain their slower polling cadence")
equal(reads, metadataReads, "output metadata retains its slower polling cadence")
now = now + 20
service:update(now)
equal(feed.trim.fraction, 0.5, "trims update on the next ordinary control poll")
assert(reads > metadataReads, "metadata scanning resumes on the ordinary control poll")
local rows = {}
assert(service:describe(rows) >= 1, "output subscriptions must remain safe in service diagnostics")
raw = -1536
settle()
equal(feed.fraction, -1.5, "extended outputs must retain their actual percentage")
for _, invalid in ipairs({ false, "0", 0 / 0, math.huge }) do
    raw = invalid
    settle()
    assert(not feed.available)
end
raw = nil
settle()
assert(not feed.available)
raw = 0
settle()
assert(feed.available)
equal(feed.fraction, 0)

mixes[1].source = 3
settle()
equal(feed.trim.name, "trim-ail", "virtual inputs must resolve to their trim")
inputs[1].trimSource = 2
settle()
equal(feed.trim.name, "trim-ele", "explicit input trim overrides must be honored")
inputs[1].trimSource = -1
settle()
equal(feed.trim, nil)
inputs[1].trimSource = 0
inputs[2] = { source = 2, trimSource = 0 }
settle()
equal(feed.trim, nil, "different side/conditional trims must not produce a guessed arrow")
inputs[2] = nil
mixes[1].carryTrim = true
settle()
equal(feed.trim, nil, "carryTrim true is the firmware's disable bit")
mixes[1].carryTrim = false
mixes[2] = { source = 2, carryTrim = false, weight = 100 }
settle()
equal(feed.trim, nil, "multi-axis mixes have no single corresponding trim")
mixes[2].multiplex = 2
settle()
equal(feed.trim.name, "trim-ele", "replace mixes discard earlier trim associations")
mixes[2].weight = 0
settle()
equal(feed.trim, nil, "a zero-weight replace mix must discard the earlier trim")
mixes[2].weight = 100
mixes[2].carryTrim = true
settle()
equal(feed.trim, nil, "an untrimmed replace mix must discard the earlier trim")
mixes[2] = nil
mixes[1].switch = 7
switch = false
settle()
equal(feed.trim, nil)
switch = true
mixes[1].flightModes = 2
mode = 1
settle()
equal(feed.trim, nil, "flight mode masks exclude disabled lines")
mode = 0
settle()
equal(feed.trim.name, "trim-ail")

outputName = ""
mixes[1].flightModes = 0
mixes[1].source = 3
inputs[1].inputName = "Aileron"
settle()
equal(feed.name, "Aileron", "unnamed outputs inherit the configured input name")
mixes[1].carryTrim = true
settle()
equal(feed.name, "Aileron", "name resolution must not depend on trim being enabled")
equal(feed.trim, nil)
mixes[1].name = "Roll"
settle()
equal(feed.name, "Roll", "a named mix takes precedence over its input")
outputName = "Servo"
settle()
equal(feed.name, "Servo", "an explicit output name takes precedence over inferred names")
outputName, mixes[1].name = "", nil
inputs[1].inputName = nil
inputs[1].name = "Input line"
settle()
equal(feed.name, "Input line", "input line names are used when the input is unnamed")
inputs[1].name = nil
settle()
equal(feed.name, "ail", "unnamed inputs fall back to their source")
mixes[1].source = 1
settle()
equal(feed.name, "ail", "direct stick mixes expose their source name")
mixes[2] = { source = 2, carryTrim = true, weight = 100 }
settle()
equal(feed.name, "", "different active source names must not produce a guessed label")
mixes[2].multiplex = 2
settle()
equal(feed.name, "ele", "replace mixes discard earlier inferred names")
mixes[2] = nil
mixes[1].switch = 7
switch = false
settle()
equal(feed.name, "", "disabled mixes do not contribute names")
switch = true
mixes[1].carryTrim = false

-- Long model configurations must remain bounded, including nested input scans.
for index = 1, 64 do
    mixes[index] = { source = 3, carryTrim = false, weight = 100 }
    inputs[index] = { source = 1, trimSource = 0 }
end
settle()

local missing = control.new({}, support)
equal(missing.interval, 20, "services without outputs retain their original cadence")
local absent = missing:output(0)
missing:update(0)
assert(not absent.available)
assert(absent.nameReady, "missing metadata APIs must resolve to an unnamed channel")
assert(not pcall(function()
    service:output(32)
end))
