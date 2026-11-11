-- SPDX-License-Identifier: GPL-2.0-only

local renderer = { RUNTIME_API = 1 }
renderer.__index = renderer

function renderer.new(context)
    local self = setmetatable({
        context = context,
        width = context.area.w // 1,
        objects = {},
        connections = {},
        connected = {},
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
    for _, line in pairs(self.connections) do
        lvgl.hide(line)
    end
    self.visible, self.connected, self.published = {}, {}, {}
end

function renderer:destroy()
    lvgl.hide(self.root)
    self.root:clear()
end

local function connection(context, item, bucket, width, from, to)
    if not from or width == 0 then
        return nil
    end
    local left = bucket - width
    local first, last = math.max(0, -left / width), 1
    local delta = to - from
    if delta == 0 then
        if from < item.low or from > item.high then
            return nil
        end
    else
        local a, b = (item.low - from) / delta, (item.high - from) / delta
        first, last = math.max(first, math.min(a, b)), math.min(last, math.max(a, b))
    end
    if first > last then
        return nil
    end
    local area = context.area
    local scale = area.h / (item.high - item.low)
    return {
        {
            area.x + math.floor(left + first * width + 0.5),
            area.y + math.floor((item.high - (from + first * delta)) * scale + 0.5),
        },
        {
            area.x + math.floor(left + last * width + 0.5),
            area.y + math.floor((item.high - (from + last * delta)) * scale + 0.5),
        },
    }
end

local function paintColumn(self, map, series, slot)
    local context, bucket = self.context, slot - 1
    local item, area = context.series[series], context.area
    local index = (series - 1) * self.width + slot
    if map.tags[slot] == slot then
        local bottom = area.y + area.h
        local scale = area.h / (item.high - item.low)
        local top = math.max(area.y, math.min(bottom, (bottom - (map.high[slot] - item.low) * scale + 0.5) // 1))
        local last = math.max(area.y, math.min(bottom, (bottom - (map.low[slot] - item.low) * scale + 0.5) // 1))
        local changes = { x = area.x + bucket, y = top, w = 1, h = last - top + 1 }
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
        local points = connection(context, item, bucket, map.widths[slot], map.froms[slot], map.low[slot])
        if points then
            local line = self.connections[index]
            if line then
                line:set({ pts = points })
                if not self.connected[index] then
                    lvgl.show(line)
                end
            else
                self.connections[index] =
                    lvgl.line(self.seriesRoots[series], { pts = points, thickness = 1, color = item.color })
            end
            self.connected[index] = true
        elseif self.connected[index] then
            lvgl.hide(self.connections[index])
            self.connected[index] = nil
        end
    else
        if self.visible[index] then
            lvgl.hide(self.objects[index])
            self.visible[index] = nil
        end
        if self.connected[index] then
            lvgl.hide(self.connections[index])
            self.connected[index] = nil
        end
    end
end

function renderer:append()
    local context = self.context
    for series, owner in ipairs(context.columnConsumers) do
        owner:append()
        local map, item = owner.map, context.series[series]
        for index, slot in ipairs(map.dirtyList) do
            paintColumn(self, map, series, slot)
            map.dirtyColumns[slot], map.dirtyList[index] = nil, nil
        end
        local published = self.published[series] or {}
        published.map, published.at = map, map.at
        published.revision, published.historyRevision = map.revision, map.historyRevision
        published.geometry, published.low, published.high = context.geometryVersion, item.low, item.high
        published.connectors = map:seamConnectors()
        self.published[series] = published
        item.drawnRevision, item.drawnVersion = map.historyRevision, context.version
    end
end

return renderer
