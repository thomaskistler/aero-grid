-- SPDX-License-Identifier: GPL-2.0-only

local storeModule = { VERSION = 1 }

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

local function dependency(path, name)
    local filename = path .. (string.sub(path, -1) == "/" and "" or "/") .. "lib/" .. name .. ".lua"
    return assert((loadScript or loadfile)(filename))()
end

local sidecarModule
local function sidecar(path)
    if not sidecarModule then
        sidecarModule = dependency(path, "model_settings_sidecar")
    end
    return sidecarModule
end

function storeModule.path(widgetPath, id)
    return sidecar(widgetPath).path(widgetPath, id)
end

function storeModule.new(widgetPath, yaml, env, fileOps)
    env = env or {}
    local config = env.flightConfig or dependency(widgetPath, "flight_config")
    local counter = env.flightCount or dependency(widgetPath, "flight_count")
    local flightDefaults = config.defaults()
    local armed = env.armedConfig or dependency(widgetPath, "armed_service")
    local writer = env.verifiedFile or dependency(widgetPath, "verified_file")
    local operations = writer.operations(fileOps)
    local api = model or {}
    local backend = (env.sidecar or sidecar(widgetPath)).new(widgetPath, {
        getOutput = env.getOutput or api.getOutput,
        setOutput = env.setOutput or api.setOutput,
        getTime = env.getTime or getTime,
        getDateTime = env.getDateTime or getDateTime,
        generateId = env.generateId,
    }, writer, operations)
    local instance = { counter = counter, operations = operations }
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
                and key ~= "flightCount"
            then
                return nil, "Unknown model settings field: " .. tostring(key)
            end
        end
        if document.flightCount ~= nil and not counter.valid(document.flightCount) then
            return nil, "Flight count must be an integer in 0.." .. counter.MAX
        end
        if document.flightCount ~= nil then
            document.flightCount = math.floor(document.flightCount)
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
            document.flight.liveDangerously = nil
            for key in pairs(document.flight) do
                if flightDefaults[key] == nil then
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
        if not validIdentity(filename) then
            return nil, "Model filename unavailable; reload the model before saving settings"
        end
        local errors, found, firstInfo, firstContent = {}, false, nil, nil
        for _, backup in ipairs({ false, true }) do
            local content, info, readError = backend:read(filename, backup)
            if type(info) ~= "table" then
                return nil, info
            end
            if not firstInfo then
                firstInfo, firstContent = info, content
            end
            if info.token ~= firstInfo.token then
                return nil, "Model settings identity changed during load; reload Model settings"
            end
            if not info.missing then
                found = true
                local document, parseError
                if content then
                    document, parseError = yaml.parse(content)
                end
                local normalized, validationError
                if document then
                    if validIdentity(document.modelFilename) then
                        normalized, validationError = validate(document, document.modelFilename)
                    else
                        validationError = "Model settings filename unavailable"
                    end
                end
                if normalized then
                    info.content = content
                    info.primaryContent, info.primaryMissing = firstContent, firstInfo.missing == true
                    info.foreign = normalized.modelFilename ~= filename
                    normalized.modelFilename = filename
                    info.notice = info.recovered and "Recovered previous model settings from backup; review and Save"
                        or info.notice
                    return normalized, info
                end
                errors[#errors + 1] = tostring(validationError or parseError or readError)
            end
        end
        if found then
            return nil, "Cannot load model settings: " .. table.concat(errors, "; ")
        end
        firstInfo.primaryContent, firstInfo.primaryMissing = firstContent, true
        return { version = 1, modelFilename = filename, revision = 0 }, firstInfo
    end
    function instance:load(filename)
        local ok, document, info = pcall(loadDocument, filename)
        if not ok then
            return nil, "Cannot load model settings: " .. tostring(document)
        end
        return document, info
    end
    local function prepare(self, filename, baseRevision, flight, armedCondition, sessionReset)
        local matches, identityError = identity(filename)
        if not matches then
            return false, identityError
        end
        if type(flight) ~= "table" then
            return false, "Choose flight settings before saving"
        end
        local previous, info = self:load(filename)
        if not previous then
            return false, info
        end
        local writable, backendError = backend:check(info)
        if not writable then
            return false, backendError
        end
        if previous.revision ~= baseRevision then
            return false, "Model settings changed in another dashboard; close and reopen Model settings"
        end
        local document, validationError = validate({
            version = 1,
            modelFilename = filename,
            revision = baseRevision + 1,
            flight = copy(flight),
            armed = armedCondition == nil and previous.armed or armedCondition,
            sessionReset = sessionReset == nil and previous.sessionReset or sessionReset,
            flightCount = previous.flightCount,
        }, filename)
        if not document then
            return false, validationError
        end
        local serialized, serializeError = yaml.serialize(document)
        if not serialized then
            return false, serializeError
        end
        local parsed, parseError = yaml.parse(serialized)
        if not parsed then
            return false, parseError
        end
        local checked, checkError = validate(parsed, filename)
        if not checked then
            return false, checkError
        end
        return true,
            {
                filename = filename,
                baseRevision = baseRevision,
                serialized = serialized,
                document = checked,
                info = info,
            }
    end
    -- The write guard rechecks identity and the live revision, so a commit may follow its prepare in a later callback.
    local function commit(self, prepared)
        local filename = prepared.filename
        local function guard(afterRotation)
            local current, currentError = identity(filename)
            if not current then
                return false, currentError
            end
            local matches, backendError = backend:check(prepared.info)
            if not matches then
                return false, backendError
            end
            if afterRotation then
                return true
            end
            -- Comparing the original bytes also guards revisions, without
            -- reparsing/validating the document at every filesystem boundary.
            local content, info, readError = backend:read(filename)
            if type(info) ~= "table" then
                return false, info
            end
            local expected = prepared.info
            if readError then
                return false, readError
            end
            if
                content ~= expected.primaryContent
                or (info.missing == true) ~= expected.primaryMissing
                or info.token ~= expected.token
            then
                return false, "Model settings changed during save; cancel and reload"
            end
            if expected.recovered then
                content, info, readError = backend:read(filename, true)
                if type(info) ~= "table" then
                    return false, info
                end
                if readError then
                    return false, readError
                end
                if content ~= expected.content or info.token ~= expected.token then
                    return false, "Model settings changed during save; cancel and reload"
                end
            end
            return true
        end
        local saved, saveError = backend:write(filename, prepared.serialized, prepared.info, guard)
        if not saved then
            return false, saveError
        end
        local matches, identityError = identity(filename)
        if not matches then
            return false, identityError
        end
        return true, copy(prepared.document)
    end
    local function protected(step, ...)
        local ok, saved, result, deferred = pcall(step, ...)
        if not ok then
            return false, "Cannot save model settings: " .. tostring(saved)
        end
        return saved, result, deferred
    end
    --- Validates and serializes a save; returns `true, prepared` or `false, message`.
    function instance:prepare(filename, baseRevision, flight, armedCondition, sessionReset)
        local ok, prepared = protected(prepare, self, filename, baseRevision, flight, armedCondition, sessionReset)
        if ok then
            prepared.baseCount = prepared.document.flightCount
        end
        return ok, prepared
    end
    --- Writes a prepared save; returns `true, document` or `false, message`.
    function instance:commit(prepared)
        return protected(commit, self, prepared)
    end
    function instance:save(filename, baseRevision, flight, armedCondition, sessionReset)
        local prepared, result = self:prepare(filename, baseRevision, flight, armedCondition, sessionReset)
        if not prepared then
            return false, result
        end
        return self:commit(result)
    end
    function instance:prepareCount(filename, expected, value, imported)
        return protected(function()
            local matches, message = identity(filename)
            if not matches then
                return false, message
            end
            local previous, info = self:load(filename)
            if not previous then
                return false, info
            end
            local writable, backendError = backend:check(info)
            if not writable then
                return false, backendError
            end
            if previous.flightCount ~= expected then
                return false, "Flight count changed before save; reload the model"
            end
            previous.flightCount = value
            if imported and previous.flight == nil and imported.flight then
                previous.flight = imported.flight
            end
            if imported and previous.armed == nil then
                previous.armed = imported.armed
            end
            local document, validationError = validate(previous, filename)
            if not document then
                return false, validationError
            end
            local serialized, serializeError = yaml.serialize(document)
            if not serialized then
                return false, serializeError
            end
            return true,
                {
                    filename = filename,
                    baseRevision = document.revision,
                    baseCount = expected,
                    document = document,
                    serialized = serialized,
                    info = info,
                }
        end)
    end
    local function adopt(self, filename, accepted, expectedInfo)
        local matches, identityError = identity(filename)
        if not matches then
            return false, identityError
        end
        local document, info = self:load(filename)
        if not document then
            return false, info
        end
        if not info.foreign then
            return true, document
        end
        if expectedInfo then
            local valid, message = backend:check(expectedInfo)
            if not valid then
                return false, message
            end
        end
        if not accepted or document.revision ~= accepted.revision then
            return false, "Model settings changed before linking; reload Model settings"
        end
        local serialized, message = yaml.serialize(document)
        if not serialized then
            return false, message
        end
        return commit(self, {
            filename = filename,
            baseRevision = document.revision,
            serialized = serialized,
            document = document,
            info = info,
        })
    end
    function instance:adopt(filename, document, info)
        return protected(adopt, self, filename, document, info)
    end
    return instance
end

return storeModule
