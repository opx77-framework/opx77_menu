--- opx77_menu -- the keyboard. One edge-detecting state machine over the only input the
--- platform offers: polling Open77.input.isDown on a fixed set of keys.

OpxMenu = OpxMenu or {}

--- The six actions and the key each drives. Not configurable: these are the keys everyone
--- already tries on a list, and the platform exposes no key-mapping API to rebind them.
local KEYS = {
  UP = "up", DOWN = "down", LEFT = "left", RIGHT = "right",
  SELECT = "enter", BACK = "backspace",
}

--- Feel, tuned in game rather than guessed. Milliseconds before a held key repeats, then
--- between repeats.
local REPEAT_DELAY_MS = 260
local REPEAT_INTERVAL_MS = 55

local Input = {}
OpxMenu.input = Input

--- The six actions, in the order they are polled.
local ACTIONS = { "UP", "DOWN", "LEFT", "RIGHT", "SELECT", "BACK" }

local state = {}
for index = 1, #ACTIONS do
  state[ACTIONS[index]] = { down = false, suppressed = false, nextAtMs = 0 }
end

--- Set by `Input.attach`: "poll" or "none".
---@type string
Input.backend = "none"

--- action -> the key that drives it. Read by the `keys` export.
---@type table<string, string>
Input.keys = {}

--- Resolved once by `Input.attach`. `isHeld` runs six times a frame and `captured` once,
--- and walking `Open77.input` on each read was a table lookup and a `type` call per read
--- for a function that cannot change while the resource is running.
local isDown = nil
local isCaptured = nil

---@return table|nil
local function api()
  return type(Open77) == "table" and type(Open77.input) == "table" and Open77.input or nil
end

---@return boolean, string|nil
local function attachPolling()
  local input = api()
  if input == nil or type(input.isDown) ~= "function" then
    return false, "no_is_down"
  end
  -- `isDown` answers `false, "permission_denied:..."` rather than raising.
  local _, refusal = input.isDown(KEYS.SELECT)
  if refusal ~= nil then return false, tostring(refusal) end
  for index = 1, #ACTIONS do
    local action = ACTIONS[index]
    Input.keys[action] = tostring(KEYS[action]):upper()
  end
  return true
end

--- Is the key behind this action down, right now.
---@param action string
---@return boolean
local function isHeld(action)
  if Input.backend == "poll" and isDown ~= nil then
    return isDown(KEYS[action]) == true
  end
  return false
end

--- Pick a backend once, at resource start. Polling is the only backend the platform offers;
--- "none" means the manifest did not grant input.actions.
---@return string backend, string|nil note  why it fell back, for main.lua to log
function Input.attach()
  local input = api()
  isDown = input ~= nil and type(input.isDown) == "function" and input.isDown or nil
  isCaptured = input ~= nil and type(input.isCaptured) == "function" and input.isCaptured or nil

  local ok, reason = attachPolling()
  if ok then
    Input.backend = "poll"
    return Input.backend
  end

  Input.backend = "none"
  return Input.backend, "the keyboard cannot be read (" .. tostring(reason) ..
    ") -- the manifest must grant input.actions"
end

--- Does somebody else own the keyboard -- chat's composer, the pause menu, an
--- operator panel. The menu stands down rather than fighting for the arrow keys.
---@return boolean
function Input.captured()
  if isCaptured == nil then return false end
  return isCaptured() == true
end

--- Record the current physical state without firing anything. Run on open and on
--- every captured tick, so a key pressed into chat cannot leak out of it.
function Input.prime()
  for index = 1, #ACTIONS do
    local action = ACTIONS[index]
    local entry = state[action]
    local down = isHeld(action)
    entry.down = down
    entry.suppressed = down
    entry.nextAtMs = 0
  end
end

--- True on the down-transition, then on the auto-repeat cadence. False for a key
--- already down when this menu started listening, until it has been released.
---@param action string
---@param atMs integer
---@return boolean
function Input.poll(action, atMs)
  local entry = state[action]
  if entry == nil then return false end
  local down = isHeld(action)
  if not down then
    entry.down = false
    entry.suppressed = false
    return false
  end
  if not entry.down then
    entry.down = true
    if entry.suppressed then return false end
    entry.nextAtMs = atMs + REPEAT_DELAY_MS
    return true
  end
  if entry.suppressed then return false end
  if atMs >= entry.nextAtMs then
    entry.nextAtMs = atMs + REPEAT_INTERVAL_MS
    return true
  end
  return false
end
