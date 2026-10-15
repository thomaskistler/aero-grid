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
        layoutStore.save("/widget", "main", makeDocument("first"), yaml, layout, grid, operations)
    assert(saved, saveError)
    assert(files[filename])
    assert(not files[filename .. ".bak"])

    saved, saveError = layoutStore.save("/widget", "main", makeDocument("second"), yaml, layout, grid, operations)
    assert(saved, saveError)
    local backup = assert(yaml.parse(files[filename .. ".bak"]))
    assert(backup.panels[1].config.label == "first")
    local primary = assert(yaml.parse(files[filename]))
    assert(primary.panels[1].config.label == "second")
end

local function testFailedCommitLeavesBackup()
    local files, operations = memoryFiles()
    local filename = layoutStore.path("/widget", "main")
    files[filename] = assert(yaml.serialize(makeDocument("last good")))
    operations.failNextRenameTo(filename)
    local saved, saveError = layoutStore.save("/widget", "main", makeDocument("new"), yaml, layout, grid, operations)
    assert(not saved and string.find(saveError, "injected", 1, true))
    assert(not files[filename])
    local preserved = assert(yaml.parse(files[filename .. ".bak"]))
    assert(preserved.panels[1].config.label == "last good")
end

local function testFutureVersionIsNotSaved()
    local files, operations = memoryFiles()
    local saved, saveError = layoutStore.save(
        "/widget",
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

local function testExplicitSavePersistsMigratedBattery()
    local files, operations = memoryFiles()
    local document = {
        version = 1,
        grid = { columns = 4, rows = 4 },
        panels = {
            {
                id = "pack",
                type = "cell-battery",
                col = 0,
                row = 0,
                colSpan = 2,
                rowSpan = 2,
                config = {
                    sourceType = "cells",
                    source = "Cels",
                    lowestSource = "Cels-",
                    cells = 4,
                    reading = "average",
                    cellFull = 4.15,
                },
            },
        },
    }
    local saved, saveError, filename = layoutStore.save("/widget", "upgraded", document, yaml, layout, grid, operations)
    assert(saved, saveError)
    local persisted = assert(yaml.parse(files[filename]))
    assert(persisted.version == 3)
    assert(persisted.panels[1].type == "rx-battery")
    assert(persisted.panels[1].config.reading == "cell")
    assert(persisted.panels[1].config.lowestSource == nil)
    assert(persisted.panels[1].config.cells == nil)
    assert(persisted.panels[1].config.cellFull == 4.15)
    assert(persisted.panels[1].config.cellWarning == nil, "save materialized an omitted old default")
end

local function testStagedSaveMigratesLegacyBattery()
    local files, operations = memoryFiles()
    local document = {
        version = 1,
        grid = { columns = 4, rows = 4 },
        panels = {
            {
                id = "legacy",
                type = "cell-battery",
                col = 0,
                row = 0,
                colSpan = 2,
                rowSpan = 2,
                config = {
                    sourceType = "cells",
                    source = "Cels",
                    cells = 4,
                    lowestSource = "Cels-",
                    reading = "lowest",
                },
            },
        },
    }
    local state = layoutStore.startSave("/widget", "legacy-staged", document, yaml, layout, grid, operations)
    local done, saved, saveError
    local calls = 0
    repeat
        done, saved, saveError = layoutStore.advanceSave(state)
        calls = calls + 1
        if calls == 1 then
            assert(not done and state.header.version == 1, "header setup must not apply a migration chain")
        elseif calls == 2 then
            assert(not done and state.header.version == 2, "one header step runs in one save cycle")
        elseif calls == 3 then
            assert(not done and state.header.version == 3, "second header step runs in its own save cycle")
        elseif calls == 5 then
            assert(not done and state.pendingPanel.type == "rx-battery", "one panel step runs in one save cycle")
        end
    until done
    assert(calls == 8, "staged legacy save should use separate header, panel, validation and persistence cycles")
    assert(saved, saveError)
    local persisted = assert(yaml.parse(files[state.filename]))
    assert(persisted.version == 3)
    assert(persisted.panels[1].type == "rx-battery")
    assert(persisted.panels[1].config.reading == "cell")
    assert(persisted.panels[1].config.cells == nil)
    assert(persisted.panels[1].config.lowestSource == nil)
end

local function testStagedSave()
    local files, operations = memoryFiles()
    local document = makeDocument("staged")
    document.version = 3
    document.panels[2] = {
        id = "second",
        type = "example",
        col = 1,
        row = 0,
        colSpan = 1,
        rowSpan = 1,
        config = { future = { enabled = true } },
    }
    local state = layoutStore.startSave("/widget", "main", document, yaml, layout, grid, operations)
    for _ = 1, 3 do
        local done = layoutStore.advanceSave(state)
        assert(not done and next(files) == nil, "staging must not write before validation finishes")
    end
    local done, saved, saveError = layoutStore.advanceSave(state)
    assert(done and saved, saveError)
    local parsed = assert(yaml.parse(files[state.filename]))
    assert(parsed.version == 3, "staged save did not write the current layout schema")
    assert(parsed.panels[2].config.future.enabled == true, "unknown keys must survive staged save")
    assert(not files[state.filename .. ".tmp"])
    local previousContent = files[state.filename]

    local broken = makeDocument("broken")
    broken.version = 3
    broken.panels[2] = broken.panels[1]
    state = layoutStore.startSave("/widget", "main", broken, yaml, layout, grid, operations)
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
    local saved, saveError, filename = layoutStore.save("/widget", "radio", makeDocument("first"), yaml, layout, grid)
    assert(saved, saveError)
    saved, saveError = layoutStore.save("/widget", "radio", makeDocument("second"), yaml, layout, grid)
    assert(saved and files[filename .. ".bak"], saveError)
    rename = function()
        return 7
    end
    saved, saveError = layoutStore.save("/widget", "radio", makeDocument("third"), yaml, layout, grid)
    assert(not saved and string.find(saveError, "filesystem error 7", 1, true))
    io, os, fstat, rename, del = originalIo, originalOs, originalStat, originalRename, originalDelete
end

local function testCurrentBatteryNormalization()
    local files, operations = memoryFiles()
    local document = makeDocument("RX")
    document.version = 2
    local panel = document.panels[1]
    panel.type = "rx-battery"
    panel.config = {
        sourceType = "pack",
        source = "RxBt",
        cells = 6,
        reading = "cell",
        visual = "none",
        showPack = false,
        showCount = true,
        showDelta = true,
        cellFull = 4.15,
        warning = 3.55,
        critical = 3.25,
        cellEmpty = 3.1,
    }
    local saved, err, filename = layoutStore.save("/widget", "rx", document, yaml, layout, grid, operations)
    assert(saved, err)
    assert(
        not string.find(files[filename], "sourceType", 1, true),
        "current-version Save must strip selector before encoding"
    )
    local persisted = assert(yaml.parse(files[filename]))
    local config = persisted.panels[1].config
    assert(persisted.version == 3 and config.sourceType == nil)
    assert(config.source == "RxBt" and config.cells == 6 and config.visual == "none")
    assert(config.showDelta == true and config.showPack == false and config.showCount == true)
    assert(
        config.cellFull == 4.15
            and config.cellWarning == 3.55
            and config.cellCritical == 3.25
            and config.cellEmpty == 3.1
    )
    assert(config.warning == nil and config.critical == nil, "Save must persist only current threshold keys")
    local loaded, errors = layout.validate(persisted, grid)
    assert(loaded and #errors == 0 and loaded.panels[1].config.showDelta == true)
end

local function testTemporaryMismatch()
    local files, operations = memoryFiles()
    local filename = layoutStore.path("/widget", "verify")
    files[filename] = assert(yaml.serialize(makeDocument("old")))
    local previousContent = files[filename]
    local read = operations.read
    operations.read = function(handle, size)
        local content = read(handle, size)
        return content and string.gsub(content, "new", "bad") or nil
    end
    local saved, saveError = layoutStore.save("/widget", "verify", makeDocument("new"), yaml, layout, grid, operations)
    assert(not saved and string.find(saveError, "differs", 1, true))
    assert(files[filename] == previousContent and not files[filename .. ".bak"])
    assert(not files[filename .. ".tmp"], "mismatching temporary file must be removed")
end

testCommitAndBackup()
testFailedCommitLeavesBackup()
testFutureVersionIsNotSaved()
testExplicitSavePersistsMigratedBattery()
testStagedSave()
testStagedSaveMigratesLegacyBattery()
testRadioFileOperations()
testTemporaryMismatch()
testCurrentBatteryNormalization()
