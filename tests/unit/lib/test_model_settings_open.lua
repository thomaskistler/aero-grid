-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local base = root .. "/src/WIDGETS/AeroGrid/lib/"
local ui = assert(loadfile(base .. "model_settings_ui.lua"))()
local storeModule = assert(loadfile(base .. "model_settings_store.lua"))()
local config = assert(loadfile(base .. "flight_config.lua"))()
local armed = assert(loadfile(base .. "armed_service.lua"))()
local yaml = assert(loadfile(base .. "yaml.lua"))()
local writer = assert(loadfile(base .. "verified_file.lua"))()
local support = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
support.constants()
local mock = support.lvgl()
support.lcd()
EVT_VIRTUAL_EXIT = 9106
getFieldInfo = function(value)
    local channel = type(value) == "string" and tonumber(string.match(value, "^ch(%d+)$"))
    return channel and { id = channel + 100 } or nil
end
getSourceIndex = function(value) local info = getFieldInfo(value); return info and info.id end
getSwitchIndex = function() return 0 end
model = { getLogicalSwitch = function() return { func = 17 } end }

local function fixture(mode, legacy)
    local files, operations = assert(loadfile(root .. "/tests/support/memory_files.lua"))()()
    local control = { filename = "plane.yml", errors = {}, closed = 0, published = 0, fullscreen = true }
    local function identity()
        if control.identityError then error("identity unavailable", 0) end
        return control.filename
    end
    local store = storeModule.new("/WIDGETS/AeroGrid/", yaml, {
        modelFilename = identity, flightConfig = config, armedConfig = armed, verifiedFile = writer,
    }, operations)
    local path = assert(storeModule.path("/WIDGETS/AeroGrid/", control.filename))
    local source = assert(yaml.serialize({
        version = 1, modelFilename = control.filename, revision = 12,
        flight = config.defaults(), armed = not legacy and "!L64" or nil, sessionReset = "L03",
    }))
    files[path] = source
    if mode == "recovered" then
        files[path], files[path .. ".bak"] = "version: 0\n", source
    elseif mode == "missing" then
        files[path] = nil
    elseif mode == "invalid" then
        files[path], files[path .. ".bak"] = "version: 0\n", "version: 99\n"
    elseif mode == "edited" then
        files[path] = string.rep("# retained comment\n", 64) .. source
    end
    local initialPrimary, initialBackup = files[path], files[path .. ".bak"]
    local context = {
        root = lvgl.box({ x = 0, y = 0, w = 480, h = 272 }), zone = { w = 480, h = 272 },
        flightConfig = config, armedConfig = armed,
    }
    local state = ui.open(context, { modelFilename = control.filename, revision = 0 }, {
        modelFilename = identity, fullscreen = function() return control.fullscreen end,
        armControl = { switchIndex = function() return 0 end },
        startLoad = function(filename) return store:startLoad(filename) end,
        advanceLoad = function(job) return store:advanceLoad(job) end,
        loadWorkBound = function(job) return store:loadWorkBound(job) end,
        nextLegacyCondition = function(previous)
            local index = (previous or 0) + 1
            if legacy and legacy[index] ~= nil then return index, legacy[index] end
        end,
        startPublication = function(document)
            assert(document.status == nil and document.modelFilename == "plane.yml")
            return { document = document, stage = "commit", count = 0 }
        end,
        advancePublication = function(job)
            if control.identityError or control.filename ~= job.document.modelFilename then
                return true, false, "publication identity unavailable"
            end
            if job.stage == "commit" then
                control.cached, job.stage = job.document, "members"
            else
                job.count = job.count + 1
                if job.count == 3 then
                    control.published = control.published + 1
                    return true, true
                end
            end
            return false
        end,
        error = function(message) control.errors[#control.errors + 1] = message end,
        cancel = function(invalidIdentity)
            control.closed, control.invalidIdentity = control.closed + 1, invalidIdentity
        end,
    })
    local function step()
        assert(ui.workBound(context), ui.stageOf(state))
        ui.advance(context)
        mock.settle()
        assert(files[path] == initialPrimary and files[path .. ".bak"] == initialBackup, "opening never writes")
    end
    return context, state, control, step
end

for _, mode in ipairs({ "primary", "edited", "recovered", "missing", "invalid" }) do
    local context, state, control, step = fixture(mode)
    assert(state.loading and state.build and not state.status.hidden and next(state.controls) == nil)
    for _ = 1, 2000 do
        if not context.modelSettingsUi or not state.loading and not state.build then break end
        if state.controls.motorReversed then
            assert(not state.controls.motorReversed.properties.active())
            state.controls.motorReversed.properties.set(1)
            assert(not state.pending, "programmatic edits into disabled controls are ignored")
        end
        step()
    end
    if mode == "invalid" then
        assert(not context.modelSettingsUi and #control.errors == 1 and not control.cached)
    else
        assert(not state.loading and not state.build and #control.errors == 0 and control.published == 1)
        assert(state.revision == (mode == "missing" and 0 or 12) and not state.values.motorReversed)
        assert(state.controls.motorReversed.properties.active())
        assert(state.loadInfo.recovered == (mode == "recovered") or mode == "missing" and state.loadInfo.missing)
        ui.close(context)
    end
end

for _, legacy in ipairs({ {}, { 0, 0 }, { 1, 1, 1 }, { 1, 2, 1 } }) do
    local context, state, _, step = fixture("primary", legacy)
    for _ = 1, 200 do
        if not state.loading then break end
        step()
    end
    assert(not state.loading and state.armed == nil)
    local message = state.status.properties.text
    assert(string.find(message, (#legacy == 0 or legacy[1] == 0) and "No model Armed"
        or legacy[2] == 2 and "Conflicting old widget" or "Old widget Armed was not imported", 1, true))
    ui.close(context)
end

for _, phase in ipairs({ "start", "read", "legacy", "publish-start", "publish", "setup" }) do
    for _, action in ipairs({ "return", "fullscreen", "model", "identity" }) do
        local context, state, control, step = fixture("primary", { 1, 1, 1 })
        for _ = 1, 200 do
            if state.loading.phase == phase then break end
            step()
        end
        assert(state.loading.phase == phase)
        if action == "return" then ui.handle(context, EVT_VIRTUAL_EXIT)
        elseif action == "fullscreen" then control.fullscreen = false
        elseif action == "model" then control.filename = "other.yml"
        else control.identityError = true end
        for _ = 1, 200 do
            if not context.modelSettingsUi then break end
            step()
        end
        assert(not context.modelSettingsUi and control.closed == 1)
        if action == "model" or action == "identity" then
            assert(#control.errors == 1 and control.invalidIdentity)
        else
            assert(#control.errors == 0)
            assert(control.published == ((phase == "publish" or phase == "setup") and 1 or 0))
        end
    end
end

do
    local context, state = fixture("primary")
    state.loading, state.closing, state.saving = nil, true, { phase = "publish-start" }
    assert(ui.workBound(context) == ui.WORK_BOUNDS["publish-start"], "closing must retain publication work")
    state.saving = { phase = "publish", publication = { stage = "commit" } }
    assert(ui.workBound(context) == ui.WORK_BOUNDS.publish, "confirmed publication cannot borrow a closing bound")
    state.saving = nil
    ui.close(context)
end

print("Bounded Model settings opening: fresh reads, recovery, disabled edits and publication cancellation passed")
