-- SPDX-License-Identifier: GPL-2.0-only

local renderer = { RUNTIME_API = 1, PAINT_LIMIT = 12 }
renderer.__index = renderer

function renderer.new(context)
    local self = setmetatable({
        context = context,
        width = context.area.w // 1,
        objects = {},
        visible = {},
        seriesRoots = {},
        published = {},
    }, renderer)
    self.root = lvgl.box(context.plotRoot, { x = 0, y = 0, w = context.rect.w, h = context.rect.h })
    for series = 1, #context.series do
        self.seriesRoots[series] = lvgl.box(self.root, { x = 0, y = 0, w = context.rect.w, h = context.rect.h })
    end
    return self
end

function renderer:destroy()
    lvgl.hide(self.root)
    self.root:clear()
end

--- Data columns span their incoming value too, so adjacent columns join without
--- line objects; a hold is one rectangle across skipped columns at the held value.
--- Per-series drawing constants, read once per batch rather than per column.
local function style(self, series)
    local context = self.context
    local item, area = context.series[series], context.area
    return {
        low = item.low,
        scale = area.h / (item.high - item.low),
        top = area.y,
        bottom = area.y + area.h,
        x = area.x - 1,
        color = item.color,
    }
end

local function paintColumn(self, map, series, slot, look)
    local index = (series - 1) * self.width + slot
    local kind = map.kinds[slot]
    if kind == "data" or kind == "hold" then
        local low, high, from = map.low[slot], map.high[slot], map.froms[slot]
        if from then
            low, high = math.min(low, from), math.max(high, from)
        end
        local bottom = look.bottom
        local top = math.max(look.top, math.min(bottom, (bottom - (high - look.low) * look.scale + 0.5) // 1))
        local last = math.max(look.top, math.min(bottom, (bottom - (low - look.low) * look.scale + 0.5) // 1))
        local changes = { x = look.x + slot, y = top, w = map.widths[slot], h = last - top + 1 }
        local object = self.objects[index]
        if object then
            object:set(changes)
            if not self.visible[index] then
                lvgl.show(object)
            end
        else
            changes.color, changes.filled, changes.thickness = look.color, true, 0
            self.objects[index] = lvgl.rectangle(self.seriesRoots[series], changes)
        end
        self.visible[index] = true
    elseif self.visible[index] then
        lvgl.hide(self.objects[index])
        self.visible[index] = nil
    end
end

local function publish(self, series, map)
    local context, item = self.context, self.context.series[series]
    local published = self.published[series] or {}
    published.map, published.at = map, map.at
    published.revision, published.historyRevision = map.revision, map.historyRevision
    published.geometry, published.low, published.high = context.geometryVersion, item.low, item.high
    published.connectors = map:seamConnectors()
    self.published[series] = published
    item.drawnRevision, item.drawnVersion = map.historyRevision, context.version
end

--- Append new samples and draw changed columns; `deferPaint` keeps them pending
--- for a layer about to replace this one.
---@return integer appended Queued samples taken across all series.
function renderer:append(deferPaint)
    local context = self.context
    local appended = 0
    for series, owner in ipairs(context.columnConsumers) do
        appended = appended + owner:append()
        local map = owner.map
        if context.checkRange then
            -- Lets the chart seed or grow automatic bounds before columns are drawn.
            context.checkRange(context, series, map)
        end
        local look = not deferPaint and map.dirtyList[1] and style(self, series)
        if look then
            -- A bounded batch per append; any backlog is drawn on later appends.
            local list = map.dirtyList
            local count = math.min(#list, renderer.PAINT_LIMIT)
            for index = 1, count do
                local slot = list[index]
                paintColumn(self, map, series, slot, look)
                map.dirtyColumns[slot] = nil
            end
            table.move(list, count + 1, #list + count, 1)
        end
        publish(self, series, map)
    end
    return appended
end

--- Paint at most `limit` pending columns of maps filled without live samples,
--- starting with series `first` so no series waits behind the others.
---@return integer painted
---@return boolean complete
function renderer:paint(limit, first)
    local owners = self.context.columnConsumers
    local painted, complete = 0, true
    for offset = 0, #owners - 1 do
        local series = ((first or 1) + offset - 1) % #owners + 1
        local map = owners[series].map
        local list, count = map.dirtyList, #map.dirtyList
        local look = count > 0 and painted < limit and style(self, series)
        while count > 0 and painted < limit do
            local slot = list[count]
            list[count], map.dirtyColumns[slot] = nil, nil
            paintColumn(self, map, series, slot, look)
            count, painted = count - 1, painted + 1
        end
        publish(self, series, map)
        complete = complete and count == 0
    end
    return painted, complete
end

--- Paint completed columns of shared maps in slot order at this layer's scale,
--- at most `limit` per call; `final` also paints each map's newest column.
---@return integer painted
---@return boolean complete
function renderer:paintSlots(limit, first, final)
    local owners = self.context.columnConsumers
    local painted, complete = 0, true
    for offset = 0, #owners - 1 do
        local series = ((first or 1) + offset - 1) % #owners + 1
        local owner = owners[series]
        local map = owner.map
        local through = (map.last or -1) + (final and 1 or 0)
        local slot = owner.next or 1
        local look = slot <= through and painted < limit and style(self, series)
        while slot <= through and painted < limit do
            paintColumn(self, map, series, slot, look)
            slot, painted = slot + 1, painted + 1
        end
        owner.next = slot
        publish(self, series, map)
        complete = complete and slot > through
    end
    return painted, complete
end

--- Hide previously drawn columns, at most `limit` objects per call; a reset
--- sweeps the old columns away in bounded steps.
---@return integer visited
---@return boolean complete
function renderer:sweep(limit)
    local visited = 0
    while visited < limit do
        local index = next(self.visible)
        if not index then
            self.published = {}
            return visited, true
        end
        lvgl.hide(self.objects[index])
        self.visible[index], visited = nil, visited + 1
    end
    return visited, false
end

return renderer
