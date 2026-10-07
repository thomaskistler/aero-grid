-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local layoutStore = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/layout_store.lua"))()
local yaml = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/yaml.lua"))()
local layout = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/layout.lua"))()
local grid = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/grid.lua"))()

local function memoryFiles()
    local files = {}
    local failRenameTo
    local operations = {}
    function operations.open(filename, mode)
        if mode == "w" then
            return { filename = filename, mode = mode }
        end
        if files[filename] then
            return { filename = filename, mode = mode }
        end
        return nil, "not found"
    end
    function operations.read(handle, size)
        local content = files[handle.filename]
        return content and string.sub(content, 1, size) or nil
    end
    function operations.write(handle, content)
        files[handle.filename] = content
        return true
    end
    function operations.close()
        return true
    end
    function operations.stat(filename)
        local content = files[filename]
        return content and { size = #content } or nil
    end
    function operations.remove(filename)
        files[filename] = nil
        return true
    end
    function operations.rename(from, to)
        if failRenameTo == to then
            return nil, "injected rename failure"
        end
        if not files[from] then
            return nil, "source missing"
        end
        if files[to] then
            return nil, "destination exists"
        end
        files[to] = files[from]
        files[from] = nil
        return true
    end
    function operations.failNextRenameTo(filename)
        failRenameTo = filename
    end
    return files, operations
end

local function makeDocument(label)
    return {
        version = 1,
        grid = { columns = 4, rows = 4 },
        panels = {
            {
                id = "panel",
                type = "example",
                col = 0,
                row = 0,
                colSpan = 1,
                rowSpan = 1,
                config = { label = label },
            },
        },
    }
end

local function testCommitAndBackup()
    local files, operations = memoryFiles()
    local saved, saveError, filename =
        layoutStore.save("/widget", "model.yml", "main", makeDocument("first"), yaml, layout, grid, operations)
    assert(saved, saveError)
    assert(files[filename])
    assert(not files[filename .. ".bak"])

    saved, saveError = layoutStore.save(
        "/widget",
        "model.yml",
        "main",
        makeDocument("second"),
        yaml,
        layout,
        grid,
        operations
    )
    assert(saved, saveError)
    local backup = assert(yaml.parse(files[filename .. ".bak"]))
    assert(backup.panels[1].config.label == "first")
    local primary = assert(yaml.parse(files[filename]))
    assert(primary.panels[1].config.label == "second")
end

local function testFailedCommitLeavesBackup()
    local files, operations = memoryFiles()
    local filename = layoutStore.path("/widget", "model.yml", "main")
    files[filename] = assert(yaml.serialize(makeDocument("last good")))
    operations.failNextRenameTo(filename)
    local saved, saveError = layoutStore.save(
        "/widget",
        "model.yml",
        "main",
        makeDocument("new"),
        yaml,
        layout,
        grid,
        operations
    )
    assert(not saved and string.find(saveError, "injected", 1, true))
    assert(not files[filename])
    local preserved = assert(yaml.parse(files[filename .. ".bak"]))
    assert(preserved.panels[1].config.label == "last good")
end

local function testFutureVersionIsNotSaved()
    local files, operations = memoryFiles()
    local saved, saveError = layoutStore.save(
        "/widget",
        "model.yml",
        "main",
        { version = 99, grid = { columns = 4, rows = 4 }, panels = {} },
        yaml,
        layout,
        grid,
        operations
    )
    assert(not saved and string.find(saveError, "validation", 1, true))
    assert(next(files) == nil)
end

testCommitAndBackup()
testFailedCommitLeavesBackup()
testFutureVersionIsNotSaved()
