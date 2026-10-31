-- SPDX-License-Identifier: GPL-2.0-only

return function()
    local files, operations = {}, {}
    local fault, hook
    function operations.inject(name, callback)
        fault, hook = name, callback
    end
    local function fail(name, ...)
        if fault == name then
            if hook then
                hook(...)
                fault, hook = nil, nil
                return false
            end
            return true
        end
        return false
    end
    function operations.open(filename, mode)
        if fail("open", filename, mode) then
            return nil, "injected open failure"
        end
        if mode == "w" then
            return { filename = filename }
        end
        if files[filename] ~= nil then
            return { filename = filename }
        end
        return nil, "not found"
    end
    function operations.read(handle, size)
        if fail("read", handle.filename) then
            return nil
        end
        local content = files[handle.filename]
        if content ~= nil then
            return string.sub(content, 1, size)
        end
    end
    function operations.write(handle, content)
        if fail("write", handle.filename) then
            return nil, "injected write failure"
        end
        files[handle.filename] = content
        return true
    end
    function operations.close()
        if fail("close") then
            return false, "injected close failure"
        end
        return true
    end
    function operations.stat(filename)
        return files[filename] ~= nil and { size = #files[filename] } or nil
    end
    function operations.remove(filename)
        if fail("remove", filename) then
            return false, "injected remove failure"
        end
        files[filename] = nil
        return true
    end
    function operations.rename(from, to)
        if fail("rename", from, to) then
            return false, "injected rename failure"
        end
        if files[from] == nil then
            return false, "source missing"
        end
        if files[to] ~= nil then
            return false, "destination exists"
        end
        files[to], files[from] = files[from], nil
        return true
    end
    return files, operations
end
