-- SPDX-License-Identifier: GPL-2.0-only

local replay = {}

function replay.advance(context, load)
    local state = context.videoReplayLoading
    if not state then
        local result, message = load(context.path, "replay/manifest.lua")
        assert(result, message)
        result.model = "FMS Ranger"
        context.videoReplayLoading = { result = result, tile = 1, series = 1 }
        return
    end
    local tile = state.result.tiles[state.tile]
    local entry = tile.series[state.series]
    assert(string.match(entry.replayFile, "^replay/series%-%d+%-%d+%.lua$"), "Invalid replay file")
    local stored, message = load(context.path, entry.replayFile)
    assert(stored, message)
    local rect = context.grid.rect(context.zone, {
        col = 0, row = 0, colSpan = tile.config.colSpan, rowSpan = tile.config.rowSpan,
    }, 4, 4, 4)
    local fonts = context.themeBuilder.typography(tile.config.colSpan, tile.config.rowSpan)
    local width = context.themeBuilder.frame(context.theme, rect, fonts).content
    assert(width == stored.width, "Replay needs the original fullscreen chart width")
    local columns = context.chartColumns.new(stored.width, stored.window, nil, { passive = true })
    for key, value in pairs(stored) do
        columns[key] = value
    end
    entry.columns, entry.replayFile = columns, nil
    state.series = state.series + 1
    if state.series > #tile.series then
        state.tile, state.series = state.tile + 1, 1
    end
    if state.tile > #state.result.tiles then
        context.videoReplayResult = state.result
        context.videoReplayLoading = nil
    end
end

return replay
