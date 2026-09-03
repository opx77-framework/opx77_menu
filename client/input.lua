--- The keyboard: an edge-detecting state machine over `Open77.input.isDown`.

OpxMenu = OpxMenu or {}

--- The six actions and the key each drives. Not configurable: the platform has no
--- key-mapping API.
local KEYS = {
  UP = "up", DOWN = "down", LEFT = "left", RIGHT = "right",
  SELECT = "enter", BACK = "backspace",
}

--- Milliseconds before a held key repeats, then between repeats.
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

--- Resolved once by `Input.attach`; `isHeld` runs six times a frame.
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
  -- `isDown` answers `false, "permission_denied:..."` rather than raising, but a raise here
  -- would abandon the resource start that calls this, before the surface is created.
  local probed, answer, refusal = pcall(input.isDown, KEYS.SELECT)
  if not probed then return false, tostring(answer) end
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

--- Pick a backend once, at resource start. "none" means input.actions was not granted.
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

--- Does somebody else own the keyboard -- chat's composer, the pause menu, a panel.
---@return boolean
function Input.captured()
  if isCaptured == nil then return false end
  return isCaptured() == true
end

local function primeAll()
  for index = 1, #ACTIONS do
    local action = ACTIONS[index]
    local entry = state[action]
    local down = isHeld(action)
    entry.down = down
    entry.suppressed = down
    entry.nextAtMs = 0
  end
end

--- Record the current physical state without firing anything, so a key pressed
--- elsewhere cannot leak into the menu.
function Input.prime()
  -- Guarded: the `open` export reaches this, outside the input thread's own pcall.
  pcall(primeAll)
end

--- True on the down-transition, then on the auto-repeat cadence. A key already down
--- when the menu opened stays false until released.
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
