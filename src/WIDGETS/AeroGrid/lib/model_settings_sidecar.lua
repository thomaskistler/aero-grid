-- SPDX-License-Identifier: GPL-2.0-only

local sidecar = {}
local seeded = false
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

function sidecar.validId(id)
    return type(id) == "string" and string.match(id, "^AG[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$") ~= nil
end

function sidecar.path(widgetPath, id)
    if not sidecar.validId(id) then
        return nil, "Invalid model settings ID"
    end
    local base = string.sub(widgetPath, -1) == "/" and widgetPath or widgetPath .. "/"
    local root = string.match(base, "^(.*/)WIDGETS/[^/]+/$") or base
    return root .. "AEROGRID/models/" .. id .. ".yaml"
end

local function generate(env)
    if not seeded then
        local clock = env.getDateTime and env.getDateTime() or {}
        local seed = (env.getTime and env.getTime() or 0) % 65537
        for _, key in ipairs({ "year", "mon", "day", "hour", "min", "sec" }) do
            seed = (seed * 75 + (clock[key] or 0)) % 65537
        end
        math.randomseed(seed)
        seeded = true
    end
    local id = "AG"
    for _ = 1, 4 do
        local index = math.random(1, #alphabet)
        id = id .. string.sub(alphabet, index, index)
    end
    return id
end

function sidecar.new(widgetPath, env, writer, operations)
    local backend = {}
    local function name()
        local output = env.getOutput and env.getOutput(31)
        if type(output) ~= "table" or type(output.name) ~= "string" then
            return nil, "CH32 output unavailable; reload Model settings"
        end
        return output.name, output
    end
    function backend:read(_, backup)
        local id, message = name()
        if not id then
            return nil, message
        end
        local info = { token = id, missing = true }
        if id == "" then
            return nil, info
        elseif not sidecar.validId(id) then
            info.blocked = true
            info.notice = "Clear the CH32 name to save model settings"
            return nil, info
        end
        local path = assert(sidecar.path(widgetPath, id)) .. (backup and ".bak" or "")
        info.filename = path
        if not operations.stat(path) then
            return nil, info
        end
        info.missing, info.recovered = nil, backup or nil
        local text, readError = writer.read(path, operations)
        return text, info, readError
    end
    function backend:check(info)
        local current, message = name()
        if current == nil then
            return false, message
        end
        if current ~= info.token then
            return false, "CH32 name changed; close and reopen Model settings"
        end
        if info.blocked then
            return false, "Clear the CH32 name to save model settings"
        end
        return true
    end
    function backend:write(_, text, info, guard)
        local valid, message = self:check(info)
        if not valid then
            return false, message
        end
        local claim = info.token == "" or info.foreign
        local id = info.token
        if claim then
            id = nil
            for _ = 1, 64 do
                local candidate = env.generateId and env.generateId() or generate(env)
                if not sidecar.validId(candidate) then
                    return false, "Invalid model settings ID"
                end
                local path = assert(sidecar.path(widgetPath, candidate))
                if not operations.stat(path) and not operations.stat(path .. ".bak") and candidate ~= info.token then
                    id = candidate
                    break
                end
            end
            if not id then
                return false, "Cannot allocate model settings ID; retry saving"
            end
        end
        local target = assert(sidecar.path(widgetPath, id))
        local function guarded(afterRotation)
            local ok, err = self:check(info)
            if not ok then
                return false, err
            end
            if (claim or afterRotation) and operations.stat(target) then
                return false, "Model settings changed during save; cancel and reload"
            end
            return guard(afterRotation and not claim)
        end
        local saved, saveError = writer.write(target, text, operations, guarded, info.recovered and not claim)
        if not saved then
            return false, saveError
        end
        if claim then
            local ok, err = self:check(info)
            if not ok then
                return false, err
            end
            ok, err = guard(false)
            if not ok then
                return false, err
            end
            local current, output = name()
            if current ~= info.token then
                return false, "CH32 name changed; close and reopen Model settings"
            end
            if not env.setOutput then
                return false, "CH32 write unavailable"
            end
            -- EdgeTX clears the whole channel before applying this table.
            output.name = id
            env.setOutput(31, output)
            if name() ~= id then
                return false, "Cannot verify CH32 settings ID; reload and retry saving"
            end
        else
            return self:check(info)
        end
        return true
    end
    return backend
end

return sidecar
