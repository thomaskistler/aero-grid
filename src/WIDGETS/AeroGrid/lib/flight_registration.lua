-- SPDX-License-Identifier: GPL-2.0-only

local registration = { RUNTIME_API = 1 }

function registration.configure(context)
    local member = context.flightFactory.members[context]
    if not member then
        return
    end
    local declarations = {}
    local retained = context.document.legacyFlightArms or {}
    assert(type(retained) == "table", "legacyFlightArms must be a mapping")
    local settingsBySource = {}
    for _, placement in ipairs(context.flightSources or {}) do
        local values = placement.config or {}
        if values._legacyFlight or values.armSwitch and values.armSwitch ~= "" then
            retained[placement.id] = values.armSwitch or ""
        end
        if values._legacyFlight then
            settingsBySource[placement.id] = context.flightConfig.resolve(values)
        end
    end
    context.document.legacyFlightArms = next(retained) and retained or nil
    local armed = context.serviceRuntime.byId.armed
    for source, condition in pairs(retained) do
        assert(
            type(source) == "string" and type(condition) == "string",
            "legacyFlightArms entries must name retained switches"
        )
        local view = armed:state(condition)
        declarations[#declarations + 1] = {
            source = source,
            armKey = view.key,
            armIndex = context.nativeArmed ~= 0 and context.nativeArmed or nil,
            settings = settingsBySource[source],
        }
    end
    if #declarations == 0 then
        local view = armed:state()
        declarations[1] = {
            source = "Armed",
            armKey = view.key,
            armIndex = context.nativeArmed ~= 0 and context.nativeArmed or nil,
        }
    end
    member.declarations, member.pending, member.error = declarations, false, nil
    member.modelFilename, member.layoutName = context.modelFilename or member.modelFilename, context.layoutName
    context.flightFactory.revision = (context.flightFactory.revision or 0) + 1
end

return registration
