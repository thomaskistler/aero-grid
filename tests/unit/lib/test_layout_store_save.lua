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

    saved, saveError =
        layoutStore.save("/widget", "model.yml", "main", makeDocument("second"), yaml, layout, grid, operations)
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
    local saved, saveError =
        layoutStore.save("/widget", "model.yml", "main", makeDocument("new"), yaml, layout, grid, operations)
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

local function testStagedSave()
    local files, operations = memoryFiles()
    local document = makeDocument("staged")
    document.theme = { mode = "modern" }
    document.panels[2] = {
        id = "second",
        type = "example",
        col = 1,
        row = 0,
        colSpan = 1,
        rowSpan = 1,
        config = { future = { enabled = true } },
    }
    local state = layoutStore.startSave("/widget", "model.yml", "main", document, yaml, layout, grid, operations)
    for _ = 1, 3 do
        local done = layoutStore.advanceSave(state)
        assert(not done and next(files) == nil, "staging must not write before validation finishes")
    end
    local done, saved, saveError = layoutStore.advanceSave(state)
    assert(done and saved, saveError)
    local parsed = assert(yaml.parse(files[state.filename]))
    assert(parsed.theme.mode == "modern")
    assert(parsed.panels[2].config.future.enabled == true, "unknown keys must survive staged save")
    assert(not files[state.filename .. ".tmp"])
    local previousContent = files[state.filename]

    local broken = makeDocument("broken")
    broken.panels[2] = broken.panels[1]
    state = layoutStore.startSave("/widget", "model.yml", "main", broken, yaml, layout, grid, operations)
    for _ = 1, 3 do
        done, saved, saveError = layoutStore.advanceSave(state)
        if done then
            break
        end
    end
    assert(done and not saved and saveError, "overlapping/duplicate placements must not be saved")
    assert(files[state.filename] == previousContent, "failed staging must preserve primary")
end

local function testRadioFileOperations()
    local files, operations = memoryFiles()
    local originalIo, originalOs, originalStat, originalRename, originalDelete = io, os, fstat, rename, del
    io, os, fstat = operations, nil, operations.stat
    rename = function(from, to)
        return operations.rename(from, to) and 0 or 4
    end
    del = function(filename)
        return operations.remove(filename) and 0 or 4
    end
    local saved, saveError, filename =
        layoutStore.save("/widget", "model.yml", "radio", makeDocument("first"), yaml, layout, grid)
    assert(saved, saveError)
    saved, saveError = layoutStore.save("/widget", "model.yml", "radio", makeDocument("second"), yaml, layout, grid)
    assert(saved and files[filename .. ".bak"], saveError)
    rename = function()
        return 7
    end
    saved, saveError = layoutStore.save("/widget", "model.yml", "radio", makeDocument("third"), yaml, layout, grid)
    assert(not saved and string.find(saveError, "filesystem error 7", 1, true))
    io, os, fstat, rename, del = originalIo, originalOs, originalStat, originalRename, originalDelete
end

local function testTemporaryMismatch()
    local files, operations = memoryFiles()
    local filename = layoutStore.path("/widget", "model.yml", "verify")
    files[filename] = assert(yaml.serialize(makeDocument("old")))
    local previousContent = files[filename]
    local read = operations.read
    operations.read = function(handle, size)
        local content = read(handle, size)
        return content and string.gsub(content, "new", "bad") or nil
    end
    local saved, saveError =
        layoutStore.save("/widget", "model.yml", "verify", makeDocument("new"), yaml, layout, grid, operations)
    assert(not saved and string.find(saveError, "differs", 1, true))
    assert(files[filename] == previousContent and not files[filename .. ".bak"])
    assert(not files[filename .. ".tmp"], "mismatching temporary file must be removed")
end

testCommitAndBackup()
testFailedCommitLeavesBackup()
testFutureVersionIsNotSaved()
testStagedSave()
testRadioFileOperations()
testTemporaryMismatch()
