-- SPDX-License-Identifier: GPL-2.0-only

local renderer = { RUNTIME_API = 1 }
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

function renderer:reset()
    for _, object in pairs(self.objects) do
        lvgl.hide(object)
    end
    self.visible, self.published = {}, {}
end

function renderer:destroy()
    lvgl.hide(self.root)
    self.root:clear()
end

--- Data columns span their incoming value too, so adjacent columns join without
--- line objects; a hold is one rectangle across skipped columns at the held value.
local function paintColumn(self, map, series, slot)
    local context = self.context
    local item, area = context.series[series], context.area
    local index = (series - 1) * self.width + slot
    local kind = map.kinds[slot]
    if kind == "data" or kind == "hold" then
        local low, high, from = map.low[slot], map.high[slot], map.froms[slot]
        if from then
            low, high = math.min(low, from), math.max(high, from)
        end
        local bottom = area.y + area.h
        local scale = area.h / (item.high - item.low)
        local top = math.max(area.y, math.min(bottom, (bottom - (high - item.low) * scale + 0.5) // 1))
        local last = math.max(area.y, math.min(bottom, (bottom - (low - item.low) * scale + 0.5) // 1))
        local changes = { x = area.x + slot - 1, y = top, w = map.widths[slot], h = last - top + 1 }
        local object = self.objects[index]
        if object then
            object:set(changes)
            if not self.visible[index] then
                lvgl.show(object)
            end
        else
            changes.color, changes.filled, changes.thickness = item.color, true, 0
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

function renderer:append()
    local context = self.context
    for series, owner in ipairs(context.columnConsumers) do
        owner:append()
        local map = owner.map
        for index, slot in ipairs(map.dirtyList) do
            paintColumn(self, map, series, slot)
            map.dirtyColumns[slot], map.dirtyList[index] = nil, nil
        end
        publish(self, series, map)
    end
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
        while count > 0 and painted < limit do
            local slot = list[count]
            list[count], map.dirtyColumns[slot] = nil, nil
            paintColumn(self, map, series, slot)
            count, painted = count - 1, painted + 1
        end
        publish(self, series, map)
        complete = complete and count == 0
    end
    return painted, complete
end

--- Hide previously drawn columns, at most `limit` objects per call.
---@return integer visited
---@return boolean complete
function renderer:sweep(limit)
    local index, visited = self.sweepIndex or 1, 0
    local last = #self.context.series * self.width
    while index <= last and visited < limit do
        if self.visible[index] then
            lvgl.hide(self.objects[index])
            self.visible[index] = nil
        end
        index, visited = index + 1, visited + 1
    end
    self.sweepIndex = index <= last and index or nil
    if index > last then
        self.published = {}
    end
    return visited, index > last
end

return renderer
