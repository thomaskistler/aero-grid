-- SPDX-License-Identifier: GPL-2.0-only

local storeModule = {
    RUNTIME_API = 1,
    VERSION = 1,
}

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, entry in pairs(value) do
        result[key] = copy(entry)
    end
    return result
end

local function validIdentity(filename)
    return type(filename) == "string" and string.find(filename, "%S") ~= nil and not string.find(filename, "%z")
end

function storeModule.path(widgetPath, modelFilename)
    if not validIdentity(modelFilename) then
        return nil, "Model filename unavailable; reload the model before saving settings"
    end
    local base = string.sub(widgetPath, -1) == "/" and widgetPath or widgetPath .. "/"
    local root = string.match(base, "^(.*/)WIDGETS/[^/]+/$") or base
    local encoded = string.gsub(modelFilename, ".", function(character)
        return string.format("%02x", string.byte(character))
    end)
    return root .. "AEROGRID/models/" .. encoded .. ".yaml"
end

local function dependency(path, name)
    local filename = path .. (string.sub(path, -1) == "/" and "" or "/") .. "lib/" .. name .. ".lua"
    return assert((loadScript or loadfile)(filename))()
end

function storeModule.new(widgetPath, yaml, env, fileOps)
    env = env or {}
    local writer = env.verifiedFile or dependency(widgetPath, "verified_file")
    local config = env.flightConfig or dependency(widgetPath, "flight_config")
    local armed = env.armedConfig or dependency(widgetPath, "armed_service")
    local operations = writer.operations(fileOps)
    local instance = {}
    local function identity(filename)
        local current
        if env.modelFilename then
            current = env.modelFilename()
        elseif model and type(model.getInfo) == "function" then
            local info = model.getInfo()
            current = type(info) == "table" and info.filename
        end
        if not validIdentity(filename) or current ~= filename then
            return false, "Model changed or filename unavailable; reload Model settings"
        end
        return true
    end
    local function validate(document, filename)
        if type(document) ~= "table" or document.version ~= storeModule.VERSION then
            return nil, "Unsupported model settings schema; expected version 1"
        end
        if document.modelFilename ~= filename then
            return nil, "Model settings filename identity mismatch"
        end
        local revision = document.revision
        if type(revision) ~= "number" or revision < 0 or revision % 1 ~= 0 or revision > 2147483646 then
            return nil, "Invalid model settings revision"
        end
        for key in pairs(document) do
            if
                key ~= "version"
                and key ~= "modelFilename"
                and key ~= "revision"
                and key ~= "flight"
                and key ~= "armed"
                and key ~= "sessionReset"
            then
                return nil, "Unknown model settings field: " .. tostring(key)
            end
        end
        if document.armed ~= nil and not armed.valid(document.armed) then
            return nil, "Armed must be blank, a physical switch position, or a logical switch (L01-L64)"
        end
        if document.sessionReset ~= nil and not armed.valid(document.sessionReset) then
            return nil, "Session reset must be blank, a physical switch position, or a logical switch (L01-L64)"
        end
        if document.flight ~= nil then
            if type(document.flight) ~= "table" then
                return nil, "flight must be a configuration table"
            end
            document.flight.announcements = nil
            document.flight.history = nil
            local defaults = config.defaults()
            for key in pairs(document.flight) do
                if defaults[key] == nil then
                    return nil, "Unknown flight setting: " .. tostring(key)
                end
            end
            local resolved = config.resolve(document.flight)
            local errors = config.validate(resolved)
            if #errors > 0 then
                return nil, table.concat(errors, "; ")
            end
            document.flight = resolved
            if
                document.sessionReset ~= nil
                and document.sessionReset ~= ""
                and resolved.flightSwitch ~= ""
                and string.gsub(document.sessionReset or "", "^!", "") == resolved.flightSwitch
            then
                return nil, "Flight status switch cannot be the Session reset input"
            end
        end
        return copy(document)
    end
    local function loadDocument(filename)
        local path, pathError = storeModule.path(widgetPath, filename)
        if not path then
            return nil, pathError
        end
        local errors, found = {}, false
        for _, suffix in ipairs({ "", ".bak" }) do
            if operations.stat(path .. suffix) then
                found = true
                local content, readError = writer.read(path .. suffix, operations)
                local document, parseError
                if content then
                    document, parseError = yaml.parse(content)
                end
                local normalized, validationError
                if document then
                    normalized, validationError = validate(document, filename)
                end
                if normalized then
                    local recovered = suffix ~= ""
                    return normalized,
                        {
                            filename = path .. suffix,
                            recovered = recovered,
                            notice = recovered and "Recovered previous model settings from backup; review and Save"
                                or nil,
                        }
                end
                errors[#errors + 1] = tostring(validationError or parseError or readError)
            end
        end
        if found then
            return nil, "Cannot load model settings: " .. table.concat(errors, "; ")
        end
        return { version = 1, modelFilename = filename, revision = 0 }, { filename = path, missing = true }
    end
    function instance:load(filename)
        local ok, document, info = pcall(loadDocument, filename)
        if not ok then
            return nil, "Cannot load model settings: " .. tostring(document)
        end
        return document, info
    end
    function instance:startSave(filename, baseRevision, flight, armedCondition, sessionReset)
        local job = {
            stage = "read", filename = filename, baseRevision = baseRevision,
            armed = armedCondition, sessionReset = sessionReset, suffix = "",
            observed = {}, errors = {},
        }
        if type(flight) ~= "table" then
            job.error = "Choose flight settings before saving"
        else
            local defaults, frozen = config.defaults(), {}
            for key, value in pairs(flight) do
                if defaults[key] == nil and key ~= "history" and key ~= "announcements" then
                    job.error = "Unknown flight setting: " .. tostring(key)
                    break
                end
                frozen[key] = value
            end
            job.flight = frozen
        end
        return job
    end
    local function rejected(job, message)
        job.errors[#job.errors + 1] = tostring(message)
        job.tokens, job.position, job.line, job.commentWork, job.parseWork = nil, nil, nil, nil, nil
        if job.suffix == "" then
            job.suffix, job.stage, job.content, job.parsed = ".bak", "read", nil, nil
        else
            return true, false, "Cannot load model settings: " .. table.concat(job.errors, "; ")
        end
        return false
    end
    local function advanceJob(job)
        local matches, identityError = identity(job.filename)
        if not matches then
            return true, false, identityError
        elseif job.error then
            return true, false, job.error
        end
        if job.stage == "read" then
            job.path = job.path or assert(storeModule.path(widgetPath, job.filename))
            local filename = job.path .. job.suffix
            local exists = not not operations.stat(filename)
            local content, readError
            if exists then
                job.found = true
                content, readError = writer.read(filename, operations)
            end
            job.observed[filename] = { exists = exists, content = content }
            if content then
                job.content, job.stage = content, "parse"
            elseif exists then
                return rejected(job, readError)
            elseif job.suffix == "" then
                job.suffix = ".bak"
            elseif job.found then
                return true, false, "Cannot load model settings: " .. table.concat(job.errors, "; ")
            else
                job.previous = { version = 1, modelFilename = job.filename, revision = 0 }
                if job.loadOnly then
                    job.missing = true
                    return true, true, job.previous
                end
                job.stage = "prepare"
            end
        elseif job.stage == "parse" or job.stage == "roundtrip" then
            local roundtrip = job.stage == "roundtrip"
            job.tokens = job.tokens or {}
            local position, line, parseError, commentWork = yaml.tokenizeChunk(
                roundtrip and job.serialized or job.content,
                job.position or 1, job.line or 1, 4, job.tokens, 64, job.commentWork)
            job.position, job.line, job.commentWork = position, line, commentWork
            if parseError then
                if roundtrip then return true, false, parseError end
                return rejected(job, parseError)
            elseif not position then
                job.stage = roundtrip and "roundtrip_build" or "build"
            end
        elseif job.stage == "build" or job.stage == "roundtrip_build" then
            local roundtrip = job.stage == "roundtrip_build"
            local pending, parsed, parseError = yaml.buildChunk(job.tokens, job.parseWork, 4)
            job.parseWork = pending
            if parseError then
                if roundtrip then return true, false, parseError end
                return rejected(job, parseError)
            elseif not pending then
                job.parsed, job.stage = parsed, roundtrip and "verify" or "previous"
                job.tokens, job.position, job.line, job.commentWork = nil, nil, nil, nil
            end
        elseif job.stage == "previous" then
            local previous, validationError = validate(job.parsed, job.filename)
            if not previous then
                return rejected(job, validationError)
            end
            if job.loadOnly then
                return true, true, previous
            end
            job.previous, job.recovered, job.stage = previous, job.suffix ~= "", "prepare"
        elseif job.stage == "prepare" then
            if job.previous.revision ~= job.baseRevision then
                return true, false, "Model settings changed in another dashboard; close and reopen Model settings"
            end
            local document, validationError = validate({
                version = 1, modelFilename = job.filename, revision = job.baseRevision + 1,
                flight = job.flight,
                armed = job.armed == nil and job.previous.armed or job.armed,
                sessionReset = job.sessionReset == nil and job.previous.sessionReset or job.sessionReset,
            }, job.filename)
            if not document then
                return true, false, validationError
            end
            job.document, job.stage = document, "serialize"
        elseif job.stage == "serialize" then
            local text, serializeError = yaml.serialize(job.document)
            if not text then
                return true, false, serializeError
            end
            job.serialized, job.stage = text, "roundtrip"
        elseif job.stage == "verify" then
            local checked, checkError = validate(job.parsed, job.filename)
            if not checked then
                return true, false, checkError
            end
            job.checked, job.stage = checked, "install"
        elseif job.stage == "install" then
            local function guard(afterRotation)
                local current, currentError = identity(job.filename)
                if not current then
                    return false, currentError
                end
                if afterRotation then
                    if operations.stat(job.path) then
                        return false, "Model settings changed during save; cancel and reload"
                    end
                else
                    for filename, observed in pairs(job.observed) do
                        local exists = not not operations.stat(filename)
                        local content = exists and writer.read(filename, operations) or nil
                        if exists ~= observed.exists or content ~= observed.content then
                            return false, "Model settings changed during save; cancel and reload"
                        end
                    end
                end
                return true
            end
            local saved, saveError = writer.write(job.path, job.serialized, operations, guard, job.recovered)
            if not saved then
                return true, false, saveError
            end
            matches, identityError = identity(job.filename)
            if not matches then
                return true, false, identityError
            end
            return true, true, copy(job.checked)
        else
            error("invalid model settings save stage: " .. tostring(job.stage))
        end
        return false
    end
    function instance:advanceSave(job)
        if job.done then
            return true, job.saved, job.result
        end
        local ok, done, saved, result = pcall(advanceJob, job)
        if not ok then
            done, saved, result = true, false, "Cannot save model settings: " .. tostring(done)
        end
        if done then
            job.done, job.saved, job.result = true, saved, result
        end
        return done, saved, result
    end
    function instance:startLoad(filename)
        local ok, matches, identityError = pcall(identity, filename)
        if not ok then
            return nil, "Cannot load model settings: " .. tostring(matches)
        elseif not matches then
            return nil, identityError
        end
        return {
            stage = "read", filename = filename, suffix = "",
            observed = {}, errors = {}, loadOnly = true,
        }
    end
    function instance:advanceLoad(job)
        if job.done then
            return true, job.document, job.result
        end
        local ok, done, loaded, result = pcall(advanceJob, job)
        if not ok then
            done, loaded, result = true, false, "Cannot load model settings: " .. tostring(done)
        end
        if not done then
            return false
        end
        job.done = true
        if loaded then
            job.document = result
            if job.missing then
                job.result = { filename = job.path, missing = true }
            else
                local recovered = job.suffix ~= ""
                job.result = {
                    filename = job.path .. job.suffix,
                    recovered = recovered,
                    notice = recovered and "Recovered previous model settings from backup; review and Save" or nil,
                }
            end
        else
            job.result = result
        end
        return true, job.document, job.result
    end
    function instance:loadWorkBound(job)
        return storeModule.LOAD_BOUNDS[job.stage]
    end
    function instance:saveWorkBound(job)
        return storeModule.SAVE_BOUNDS[job.stage]
    end
    function instance:cancelSave(job)
        if job.done then
            return false, "Model settings save has already finished"
        end
        job.done, job.saved, job.result = true, false, "Model settings save cancelled"
        return true
    end
    function instance:save(filename, baseRevision, flight, armedCondition, sessionReset)
        local ok, job = pcall(self.startSave, self, filename, baseRevision, flight, armedCondition, sessionReset)
        if not ok then
            return false, "Cannot save model settings: " .. tostring(job)
        end
        while true do
            local done, saved, result = self:advanceSave(job)
            if done then
                return saved, result
            end
        end
    end
    return instance
end

function storeModule.bindCosts(costs)
    storeModule.SAVE_BOUNDS = costs:group("settings-store-save", {
        "read", "parse", "build", "previous", "prepare", "serialize", "roundtrip",
        "roundtrip_build", "verify", "install"
    })
    storeModule.LOAD_BOUNDS = costs:group("settings-store-load", {
        "start", "read", "parse", "build", "previous"
    })
end

return storeModule
