--- opx77_menu -- the public surface. Client-side, because `exports` exist only
--- on the client; a server resource calls this from its own client half.

local Config = OPX_MENU_CONFIG
local Runtime = OpxMenu.runtime
--- One definition, in client/model.lua.
local validName = OpxMenu.model.validName

---@param ok boolean
---@param values table|nil
---@return MenuResponse
local function response(ok, values)
  values = values or {}
  values.ok = ok == true
  return values
end

--- Who is calling, and at which generation of their code. Both come from the
--- host, so a caller can neither claim to be another resource nor outlive its
--- own reload.
---@return string|nil owner, string|integer generation  the reason, when owner is nil
local function caller()
  local owner = GetInvokingResource()
  local generation = GetInvokingResourceGeneration()
  if not validName(owner, 64) or type(generation) ~= "number" then
    return nil, "export_call_required"
  end
  return owner, generation
end

--- Refuse everything when the surface never came up: the exports are published
--- by this file whether or not WebUI.create succeeded, and the tick that sweeps
--- a stopped owner is not running either.
---@return MenuResponse|nil
local function unavailable()
  if Runtime.unavailable and Runtime.unavailable() then
    return response(false, { error = "no_surface" })
  end
  return nil
end

--- Open a menu. Refused whole if the spec is bad; `error` names where.
---@param spec MenuSpec
---@return MenuOpened
exports("open", function(spec)
  local gone = unavailable()
  if gone then return gone end
  local owner, generation = caller()
  if not owner then return response(false, { error = generation }) end
  if type(spec) ~= "table" then return response(false, { error = "spec_must_be_a_table" }) end

  local record, reason = Runtime.open(owner, generation, spec)
  if record == nil then return response(false, { error = reason }) end
  return response(true, { handle = record.handle, id = record.id, items = record.nodes })
end)

--- Rebuild an open menu from a fresh spec, keeping the player where they are.
--- Only the fields present in the patch change; `items` is all-or-nothing.
---@param handle MenuHandle|MenuSpec|nil  omit for "my menu, whichever handle it has"
---@param spec MenuSpec|nil
---@return MenuResponse
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
---@return MenuResponse
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

--- What is on screen. `mine` is the field a caller branches on.
---@return MenuState
exports("state", function()
  local owner = caller()
  local snapshot = Runtime.snapshot()
  local mine = owner ~= nil and snapshot.owner == owner

  -- Open and nothing else: what is inside a menu is not a third resource's.
  if not mine then
    return response(true, { open = snapshot.open, mine = false })
  end

  snapshot.mine = true
  snapshot.ok = true
  return snapshot
end)

--- Write the transient line under the list. It clears itself after `STATUS_MS`, a constant
--- in client/main.lua and not an operator setting; `status(nil)` clears it now.
---@param text string|nil
---@param ok boolean|nil  false marks a failure, which changes its colour
---@return MenuResponse
exports("status", function(text, ok)
  local gone = unavailable()
  if gone then return gone end
  local owner, generation = caller()
  if not owner then return response(false, { error = generation }) end
  if Runtime.owner() == nil then return response(false, { error = "no_menu_open" }) end
  if Runtime.owner() ~= owner then return response(false, { error = "not_owner" }) end
  -- Type-checked here: a table would sanitise to nil and silently CLEAR the line.
  if text ~= nil and type(text) ~= "string" and type(text) ~= "number" then
    return response(false, { error = "invalid_status" })
  end
  Runtime.setStatus(text, ok)
  return response(true, {})
end)

--- The keys that currently drive the menu, and which backend reads them. A resource that
--- prints its own "press ENTER" hint should print what this says.
---@return MenuResponse  `backend` string, `keys` table<string, string>
exports("keys", function()
  local keys = {}
  for action, key in pairs(OpxMenu.input.keys) do keys[action] = key end
  return response(true, { backend = OpxMenu.input.backend, keys = keys })
end)
