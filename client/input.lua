--- opx77_menu -- the keyboard. One edge-detecting state machine over two
--- backends: engine key mappings where the client offers them, polling otherwise.

OpxMenu = OpxMenu or {}

local Config = OPX_MENU_CONFIG

--- The six actions and the key each starts on. Not configurable: these are the keys everyone
--- already tries on a list, and under the mappings backend the player rebinds them from
--- Pause -> Settings -> KEY BINDINGS, which is the answer an operator would want anyway.
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

--- The six actions, in the order they are registered.
local ACTIONS = { "UP", "DOWN", "LEFT", "RIGHT", "SELECT", "BACK" }

--- action -> the id it registers under with the engine. Derived once: three call sites
--- each built `"menu." .. action:lower()` for themselves, which is three chances to spell
--- it differently and a string allocated per action per call.
local ACTION_IDS = {}
for index = 1, #ACTIONS do
  local action = ACTIONS[index]
  ACTION_IDS[action] = "menu." .. action:lower()
end

--- Human labels for the rebinding UI, which every running resource shares.
local ACTION_NAMES = {
  UP = "Menu: move up",
  DOWN = "Menu: move down",
  LEFT = "Menu: back / value down",
  RIGHT = "Menu: open / value up",
  SELECT = "Menu: select",
  BACK = "Menu: back",
}

local state = {}
for index = 1, #ACTIONS do
  state[ACTIONS[index]] = { down = false, suppressed = false, nextAtMs = 0 }
end

--- Set by `Input.attach`: "mappings", "poll" or "none".
---@type string
Input.backend = "none"

--- action -> the key that actually drives it: the configured key when polling,
--- the player's rebind under mappings. Read by the `keys` export.
---@type table<string, string>
Input.keys = {}

--- Live level state for the mapping backend, maintained from the two edges.
local held = {}

--- Resolved once by `Input.attach`. `isHeld` runs six times a frame and `captured` once,
--- and walking `Open77.input` on each read was a table lookup and a `type` call per read
--- for a function that cannot change while the resource is running.
local isDown = nil
local isCaptured = nil

---@return table|nil
local function api()
  return type(Open77) == "table" and type(Open77.input) == "table" and Open77.input or nil
end

--- Register the six actions. All or nothing: a half-registered menu where SELECT
--- works and BACK does not is worse than polling.
---@return boolean, string|nil
local function attachMappings()
  local input = api()
  local register = input and input.registerKeyMapping
  if type(register) ~= "function" then return false, "no_register_key_mapping" end

  local registered = {}
  local count = 0
  for index = 1, #ACTIONS do
    local action = ACTIONS[index]
    local key = KEYS[action]
    local ok, effective = register({
      id = ACTION_IDS[action],
      name = ACTION_NAMES[action],
      key = key,
      -- Both edges: without `hold` no up edge arrives and auto-repeat cannot
      -- be synthesised.
      hold = true,
      onPressed = function() held[action] = true end,
      onReleased = function() held[action] = false end,
    })
    if ok ~= true then
      for done = 1, count do
        if type(input.unregisterKeyMapping) == "function" then
          input.unregisterKeyMapping(registered[done])
        end
      end
      return false, tostring(effective or "rejected")
    end
    count = count + 1
    registered[count] = ACTION_IDS[action]
    Input.keys[action] = tostring(effective or key):upper()
    held[action] = false
  end
  return true
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
  if Input.backend == "mappings" then return held[action] == true end
  if Input.backend == "poll" and isDown ~= nil then
    return isDown(KEYS[action]) == true
  end
  return false
end

--- Pick a backend once, at resource start.
---
--- Mappings whenever the host has them, polling otherwise. This was an operator setting with
--- three values and no reason for any of them: mappings are strictly better -- the engine
--- owns dispatch and the player can rebind from the pause menu -- and polling is the fallback
--- for a host without them, not a preference.
---@return string backend, string|nil note  why it fell back, for main.lua to log
function Input.attach()
  local note

  local input = api()
  isDown = input ~= nil and type(input.isDown) == "function" and input.isDown or nil
  isCaptured = input ~= nil and type(input.isCaptured) == "function" and input.isCaptured or nil

  local ok, reason = attachMappings()
  if ok then
    Input.backend = "mappings"
    return Input.backend
  end
  note = "key mappings unavailable (" .. tostring(reason) .. "), polling instead"

  ok, reason = attachPolling()
  if ok then
    Input.backend = "poll"
    return Input.backend, note
  end

  Input.backend = "none"
  return Input.backend, "the keyboard cannot be read (" .. tostring(reason) ..
    ") -- the manifest must grant input.actions"
end

--- Re-read the effective keys after the engine says a binding moved.
---@return boolean  true when any key changed
function Input.refresh()
  if Input.backend ~= "mappings" then return false end
  local input = api()
  if input == nil or type(input.keyFor) ~= "function" then return false end
  local changed = false
  for index = 1, #ACTIONS do
    local action = ACTIONS[index]
    local key = input.keyFor(ACTION_IDS[action])
    if key ~= nil then
      key = tostring(key):upper()
      if key ~= Input.keys[action] then
        Input.keys[action] = key
        changed = true
      end
    end
  end
  return changed
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
    local down
    if Input.backend == "mappings" then
      -- Cleared, not sampled: a key released during capture sends no up edge.
      held[action] = false
      down = false
    else
      down = isHeld(action)
    end
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

--- Hand the six actions back to the engine.
function Input.release()
  if Input.backend ~= "mappings" then return end
  local input = api()
  if input == nil or type(input.unregisterKeyMapping) ~= "function" then return end
  for index = 1, #ACTIONS do
    input.unregisterKeyMapping(ACTION_IDS[ACTIONS[index]])
  end
end
