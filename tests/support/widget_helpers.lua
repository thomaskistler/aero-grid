-- SPDX-License-Identifier: GPL-2.0-only

local helpers = {}

function helpers.pump(context, count, step, tick, refresh)
    for _ = 1, count do
        tick(step or 20)
        refresh(context)
    end
end

function helpers.createLoaded(definition, zone, options, path)
    local context = definition.create(zone, options, path)
    local guard = 0
    while context.stage do
        definition.refresh(context)
        guard = guard + 1
        assert(guard < 200, "staged load never finished")
    end
    return context
end

function helpers.entryById(context, id)
    for _, entry in ipairs(context.panels or {}) do
        if entry.placement and entry.placement.id == id then
            return entry
        end
    end
end

function helpers.panelOf(entry)
    if not entry then
        return nil
    end
    return entry.instance
        and entry.instance.panel
        and entry.instance.panel.root
        and entry.instance.panel.root.properties
end

return helpers
