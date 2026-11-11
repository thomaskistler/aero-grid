-- SPDX-License-Identifier: GPL-2.0-only

local assertions = {}

function assertions.finished(panel)
    if not panel.history or panel.history.failed or #panel.series == 0 then
        return true
    end
    local renderer = panel.columnRenderer
    if not renderer or panel.columnsDecorating then
        return false
    end
    for index in ipairs(panel.columnConsumers or {}) do
        local published = renderer.published[index]
        if not published or published.geometry ~= panel.geometryVersion then
            return false
        end
    end
    return panel.gridVersion == panel.version
end

function assertions.nativeColumns(renderer)
    local count = 0
    for _ in pairs(renderer.objects) do
        count = count + 1
    end
    for _ in pairs(renderer.connections) do
        count = count + 1
    end
    return count
end

function assertions.rectangles(panel, series)
    local renderer, result = panel.columnRenderer, {}
    if not renderer then
        return result
    end
    for index = (series - 1) * renderer.width + 1, series * renderer.width do
        if renderer.visible[index] and not renderer.root.hidden then
            local object = renderer.objects[index]
            local properties = object.properties
            result[#result + 1] = {
                x = properties.x,
                y = properties.y,
                w = properties.w,
                h = properties.h,
                color = properties.color,
                object = object,
            }
        end
    end
    return result
end

function assertions.bounds(panel, series)
    local left, right, top, bottom
    for _, rect in ipairs(assertions.rectangles(panel, series)) do
        left = math.min(left or rect.x, rect.x)
        right = math.max(right or rect.x, rect.x)
        top = math.min(top or rect.y, rect.y)
        bottom = math.max(bottom or rect.y, rect.y + rect.h - 1)
    end
    return left, right, top, bottom
end

function assertions.connections(panel, series)
    local renderer, result = panel.columnRenderer, {}
    if not renderer or renderer.root.hidden then
        return result
    end
    for index = (series - 1) * renderer.width + 1, series * renderer.width do
        if renderer.connected[index] then
            result[#result + 1] = renderer.connections[index].properties.pts
        end
    end
    return result
end

return assertions
