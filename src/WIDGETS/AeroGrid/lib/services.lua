-- SPDX-License-Identifier: GPL-2.0-only

--- Shared data service registry, scheduler, and snapshot plumbing.
---
--- The host owns polling so components never read EdgeTX sources themselves.
--- Two rules keep that affordable inside EdgeTX's 20000-instruction callback
--- budget, which every service update shares with every component refresh:
---
--- 1. A service only reads what a loaded component actually subscribed to. A
---    service with no subscriptions is skipped entirely, so a dashboard of
---    metrics never pays for GPS, trims, or global variables.
--- 2. At most one service is updated per host cycle, chosen round robin among
---    those due, and each service further caps how many subscriptions it
---    refreshes in one update. Per-callback cost is therefore bounded by the
---    caps rather than by how much the layout asks for.
---
--- Components receive immutable views. The service mutates its own state table
--- in place, which costs no allocation per cycle, and hands out a proxy whose
--- writes raise. Services update before components refresh, so a component
--- sees one consistent set of readings for the cycle.

---@class AeroGridServiceInstance
---@field id string Service name used in the services table.
---@field interval integer Ticks of 10ms between updates.
---@field due integer Tick at which this service is next due.
---@field revision integer Incremented on every completed update.
---@field count integer Number of live subscriptions.
---@field failed? boolean Set after an update raises, which retires the service.
---@field update fun(self: AeroGridServiceInstance, now: integer)

local services = {}

--- Service modules loaded by the host, in the order they are staged.
--- Each entry's `id` becomes the key in the services table handed to a
--- component, so a component reads `services.telemetry`, `services.model`,
--- and so on.
services.DEFINITIONS = {
  {id = "telemetry", file = "lib/telemetry_service.lua"},
  {id = "model", file = "lib/model_service.lua"},
  {id = "control", file = "lib/control_service.lua"},
  {id = "extrema", file = "lib/extrema_service.lua"},
  {id = "navigation", file = "lib/navigation_service.lua"},
}

--- Refuse writes to a published snapshot.
local function readOnly()
  error("service snapshots are read-only", 2)
end

--- Publish a mutable state table as an immutable view.
--- Reads fall through to the live state, so the service can keep updating in
--- place without allocating a fresh table every cycle, while a component
--- cannot corrupt data another component is also reading.
---@param state table
---@return table view
function services.snapshot(state)
  return setmetatable({}, {
    __index = state,
    __newindex = readOnly,
    -- Hide the metatable so a component cannot reach the mutable state.
    __metatable = false,
  })
end

--- Read a global EdgeTX function, tolerating firmware that lacks it.
---@param value any
---@return function?
local function callable(value)
  if type(value) == "function" then return value end
  return nil
end

--- Collect the EdgeTX entry points the services use.
--- Everything is resolved once and every entry may be absent: a radio without
--- GPS, global variables, or a sensor table must degrade rather than raise.
--- Tests pass overrides instead of installing globals.
---@param overrides? table
---@return table env
function services.environment(overrides)
  overrides = type(overrides) == "table" and overrides or {}

  local modelApi = overrides.model
  if type(modelApi) ~= "table" then modelApi = model end
  if type(modelApi) ~= "table" then modelApi = {} end

  return {
    getValue = callable(overrides.getValue) or callable(getValue),
    getFieldInfo = callable(overrides.getFieldInfo) or callable(getFieldInfo),
    getRSSI = callable(overrides.getRSSI) or callable(getRSSI),
    getFlightMode = callable(overrides.getFlightMode) or callable(getFlightMode),
    getTime = callable(overrides.getTime) or callable(getTime),
    -- A global like `getValue`, not part of the model API: `etxlib` is in
    -- `_global_symbols` and reached through _G's __index
    -- (`radio/src/thirdparty/lua/src/linit.c`), so a widget sees it directly.
    getGeneralSettings = callable(overrides.getGeneralSettings)
      or callable(getGeneralSettings),
    getInfo = callable(modelApi.getInfo),
    getTimer = callable(modelApi.getTimer),
    getSensor = callable(modelApi.getSensor),
    getGlobalVariable = callable(modelApi.getGlobalVariable),
    getGlobalVariableDetails = callable(modelApi.getGlobalVariableDetails),
  }
end

--- Create the registry that owns every service instance.
---@param env table Result of services.environment.
---@return table runtime
function services.runtime(env)
  return {env = env, order = {}, byId = {}, cursor = 1, updates = 0}
end

--- Add one constructed service to the registry.
--- Services are phase staggered on registration for the same reason components
--- are: without it every service falls due on the same frame and the host pays
--- their combined cost in one callback.
---@param runtime table
---@param instance AeroGridServiceInstance
---@param now integer
function services.register(runtime, instance, now)
  local order = runtime.order
  order[#order + 1] = instance
  runtime.byId[instance.id] = instance
  instance.due = now + (#order - 1)
end

--- Update at most one due service.
--- Returns the service updated so the host can report a failure exactly once,
--- and so tests can observe the scheduling instead of inferring it.
---@param runtime table
---@param now integer
---@return string? id
---@return string? error
function services.update(runtime, now)
  local order = runtime.order
  local count = #order
  if count == 0 then return nil end

  local cursor = runtime.cursor
  if cursor > count then cursor = 1 end

  for _ = 1, count do
    local instance = order[cursor]
    cursor = cursor % count + 1

    -- An idle service costs nothing: nothing loaded references it.
    if instance and not instance.failed and instance.count > 0
        and now >= instance.due then
      instance.due = now + instance.interval
      runtime.cursor = cursor
      runtime.updates = runtime.updates + 1

      -- A source that misbehaves must not raise inside a widget callback, and
      -- a service that fails once is retired rather than left to fail forever.
      local ok, updateError = pcall(instance.update, instance, now)
      if not ok then
        instance.failed = true
        return instance.id, tostring(updateError)
      end

      instance.revision = instance.revision + 1
      return instance.id
    end
  end

  runtime.cursor = cursor
  return nil
end

--- Report whether any registered service has subscriptions.
---@param runtime table
---@return boolean
function services.active(runtime)
  for _, instance in ipairs(runtime.order) do
    if instance.count > 0 and not instance.failed then return true end
  end
  return false
end

--- Convert a tick count into whole seconds of age.
---@param now integer
---@param since? integer
---@return number?
function services.age(now, since)
  if type(since) ~= "number" then return nil end
  return (now - since) / 100
end

--- Fill one diagnostic row in a reusable array, returning the next position.
--- Rows are reused so a diagnostic view allocates nothing per refresh.
---@param rows table
---@param index integer
---@param label string
---@param text string
---@return integer
function services.row(rows, index, label, text)
  local row = rows[index]
  if not row then
    row = {}
    rows[index] = row
  end
  row.label = label
  row.text = text
  return index + 1
end

return services
