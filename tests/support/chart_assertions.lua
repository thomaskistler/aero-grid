-- SPDX-License-Identifier: GPL-2.0-only

local assertions = {}

function assertions.finished(panel)
    if not panel.history or panel.history.failed or #panel.series == 0 then
        return true
    end
    local renderer = panel.mipmapRenderer
    if not renderer or not panel.mipmapPrepared or renderer.jobs or panel.mipmapDecorating or panel.viewWork then
        return false
    end
    for index, owner in ipairs(panel.mipmapConsumers or {}) do
        local published = renderer.published[index]
        if owner.rebuildJob or not published or published.geometry ~= panel.geometryVersion then
            return false
        end
    end
    return panel.gridVersion == panel.version
end

function assertions.rectangles(panel, series)
    local renderer, result = panel.mipmapRenderer, {}
    if not renderer then
        return result
    end
    for index = (series - 1) * renderer.width + 1, series * renderer.width do
        if renderer.visible[index] and not renderer.root.hidden then
            local object = renderer.objects[index]
            local properties = object.properties
            local group = renderer.groups[renderer.membership[index]]
            result[#result + 1] = {
                x = properties.x + group.properties.x,
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

return assertions
