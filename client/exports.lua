--- The public export surface. Every call answers a MenuResponse and never raises; `error`
--- is one of the codes in types.lua. Client-side only: called from a caller's client half.

local Runtime = OpxMenu.runtime
local validName = OpxMenu.model.validName
local validStatus = OpxMenu.model.validStatus

---@param ok boolean
---@param values table|nil
---@return MenuResponse
local function response(ok, values)
  values = values or {}
  values.ok = ok == true
  return values
end

--- Who is calling, and at which generation of their code, both from the host.
---@return string|nil owner
---@return string|integer generation  the refusal reason when owner is nil
local function caller()
  local owner = GetInvokingResource()
  local generation = GetInvokingResourceGeneration()
  if not validName(owner, 64) or type(generation) ~= "number" then
    return nil, "export_call_required"
  end
  return owner, generation
end

--- Refuse everything when the WebUI surface never came up.
---@return MenuResponse|nil
local function unavailable()
  if Runtime.unavailable and Runtime.unavailable() then
    return response(false, { error = "no_surface" })
  end
  return nil
end

--- Open a menu. Refused whole if any row is malformed; `error` names why.
---@param spec MenuSpec
---@return MenuOpened  `error` is "menu_busy" when another resource owns the open menu
exports("open", function(spec)
  local gone = unavailable()
  if gone then return gone end
  local owner, generation = caller()
  if not owner then return response(false, { error = generation }) end
  if type(spec) ~= "table" then return response(false, { error = "spec_must_be_a_table" }) end

  local record, reason = Runtime.open(owner, generation, spec)
  if record == nil then return response(false, { error = reason }) end
  return response(true, { handle = record.handle, id = record.id, nodes = record.nodes })
end)

--- Rebuild an open menu from a fresh spec, keeping the player where they are.
--- Only the fields present in the patch change; `items` is all-or-nothing.
---@param handle MenuHandle|MenuSpec|nil  omit for "my menu, whichever handle it has"
---@param spec MenuSpec|nil
---@return MenuResponse  "not_owner" unless the open menu belongs to the caller
exports("update", function(handle, spec)
  local gone = unavailable()
  if gone then return gone end
  local owner, generation = caller()
  if not owner then return response(false, { error = generation }) end
  if spec == nil and type(handle) == "table" then
    handle, spec = nil, handle
  end
  if type(spec) ~= "table" then return response(false, { error = "spec_must_be_a_table" }) end
  if Runtime.owner() == nil then return response(false, { error = "no_menu_open" }) end
  if Runtime.owner() ~= owner then return response(false, { error = "not_owner" }) end

  local ok, reason = Runtime.update(handle, spec)
  if not ok then return response(false, { error = reason }) end
  return response(true, {})
end)

--- Close your own menu. A caller may not close another resource's.
---@param handle MenuHandle|nil
---@return MenuResponse  "not_owner" unless the open menu belongs to the caller
exports("close", function(handle)
  local gone = unavailable()
  if gone then return gone end
  local owner, generation = caller()
  if not owner then return response(false, { error = generation }) end
  if Runtime.owner() == nil then return response(false, { error = "no_menu_open" }) end
  if Runtime.owner() ~= owner then return response(false, { error = "not_owner" }) end

  local ok, reason = Runtime.close(handle, "caller")
  if not ok then return response(false, { error = reason }) end
  return response(true, {})
end)

--- What is on screen. Only `open` and `mine` are filled in for a menu the caller
--- does not own.
---@return MenuState
exports("state", function()
  local owner = caller()
  local snapshot = Runtime.snapshot()
  local mine = owner ~= nil and snapshot.owner == owner

  if not mine then
    return response(true, { open = snapshot.open, mine = false })
  end

  snapshot.mine = true
  snapshot.ok = true
  return snapshot
end)

--- Write the transient line under the list; `setStatus(nil)` clears it now.
---@param text string|nil  cleared automatically after six seconds
---@param ok boolean|nil  false marks a failure, which changes its colour
---@return MenuResponse  "not_owner" unless the open menu belongs to the caller
exports("setStatus", function(text, ok)
  local gone = unavailable()
  if gone then return gone end
  local owner, generation = caller()
  if not owner then return response(false, { error = generation }) end
  if Runtime.owner() == nil then return response(false, { error = "no_menu_open" }) end
  if Runtime.owner() ~= owner then return response(false, { error = "not_owner" }) end
  if not validStatus(text) then return response(false, { error = "invalid_status" }) end
  Runtime.setStatus(text, ok)
  return response(true, {})
end)

--- The keys that drive the menu, for a caller printing its own hint.
---@return MenuKeys
exports("keys", function()
  local keys = {}
  for action, key in pairs(OpxMenu.input.keys) do keys[action] = key end
  return response(true, { backend = OpxMenu.input.backend, keys = keys })
end)
