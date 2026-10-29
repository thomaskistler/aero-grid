-- SPDX-License-Identifier: GPL-2.0-only

local verifiedFile = { RUNTIME_API = 1 }

local function radioOperation(operation)
    if type(operation) ~= "function" then
        return nil
    end
    return function(...)
        local result = operation(...)
        if result == 0 then
            return true
        end
        return false, "filesystem error " .. tostring(result)
    end
end

function verifiedFile.operations(fileOps)
    return fileOps
        or {
            open = io.open,
            read = io.read,
            write = io.write,
            close = io.close,
            rename = radioOperation(_G.rename) or (os and os.rename),
            remove = radioOperation(_G.del) or (os and os.remove),
            stat = fstat,
            mkdir = _G.mkdir,
        }
end

function verifiedFile.read(filename, fileOps)
    local operations = verifiedFile.operations(fileOps)
    local info = operations.stat(filename)
    local size = type(info) == "table" and info.size
    if not size then
        return nil, "file not found: " .. filename
    end
    local handle, openError = operations.open(filename, "r")
    if not handle then
        return nil, openError or ("cannot open: " .. filename)
    end
    local content = operations.read(handle, size)
    operations.close(handle)
    if type(content) ~= "string" or #content ~= size then
        return nil, "cannot read: " .. filename
    end
    return content
end

--- The guard is checked after readback and immediately before installing.
function verifiedFile.write(filename, serialized, fileOps, guard, preserveBackup)
    local operations = verifiedFile.operations(fileOps)
    for _, name in ipairs({ "open", "read", "write", "close", "rename", "remove", "stat" }) do
        if type(operations[name]) ~= "function" then
            return false, "file operation unavailable: " .. name, filename
        end
    end
    if type(operations.mkdir) == "function" then
        local parent = ""
        for segment in string.gmatch(string.match(filename, "^(.*)/[^/]*$") or "", "[^/]+") do
            parent = parent .. "/" .. segment
            if not operations.stat(parent) then
                operations.mkdir(parent)
            end
        end
    end
    local temporary, backup = filename .. ".tmp", filename .. ".bak"
    local handle, openError = operations.open(temporary, "w")
    if not handle then
        return false, openError or ("cannot open temporary file: " .. temporary), filename
    end
    local written, writeError = operations.write(handle, serialized)
    local closed, closeError = operations.close(handle)
    if not written or writeError or closed == false or closeError then
        operations.remove(temporary)
        return false, writeError or closeError or "cannot write temporary file", filename
    end
    local content, readError = verifiedFile.read(temporary, operations)
    if content ~= serialized then
        operations.remove(temporary)
        return false, readError or "temporary file differs from validated content", filename
    end
    if guard then
        local valid, guardError = guard()
        if not valid then
            operations.remove(temporary)
            return false, guardError, filename
        end
    end
    if operations.stat(filename) then
        if preserveBackup then
            local removed, removeError = operations.remove(filename)
            if not removed then
                operations.remove(temporary)
                return false, removeError or "cannot replace damaged file", filename
            end
        else
            if operations.stat(backup) then
                local removed, removeError = operations.remove(backup)
                if not removed then
                    operations.remove(temporary)
                    return false, removeError or "cannot replace file backup", filename
                end
            end
            local rotated, rotateError = operations.rename(filename, backup)
            if not rotated then
                operations.remove(temporary)
                return false, rotateError or "cannot preserve previous file", filename
            end
        end
    end
    if guard then
        local valid, guardError = guard(true)
        if not valid then
            operations.remove(temporary)
            return false, guardError, filename
        end
    end
    local committed, commitError = operations.rename(temporary, filename)
    if not committed then
        return false, commitError or "cannot install validated file", filename
    end
    return true, nil, filename
end

return verifiedFile
