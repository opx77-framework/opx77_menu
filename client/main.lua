--- opx77_menu -- the surface, the input thread, and the one open menu.

OpxMenu = OpxMenu or {}

local Config = OPX_MENU_CONFIG
local Model = OpxMenu.model
local Input = OpxMenu.input

local Runtime = {}
OpxMenu.runtime = Runtime

local RESOURCE = GetCurrentResourceName()

local page

--- True once WebUI.create has refused; the exports read it and refuse too.
local surfaceFailed = false
local pageReady = false

--- The one open menu, or nil.
---@type MenuRecord|nil
local record

local nextHandle = 1

--- owner -> the generation we last saw it at, so a reloaded caller's menu goes
--- away with the code that opened it.
local ownerGenerations = {}
local nextSweepMs = 0
local SWEEP_MS = 1000

--- How much of the viewport height the list may take before it clips. Follows VISIBLE_ROWS
--- rather than being set beside it, where the two could disagree.
local MAX_HEIGHT_VH = 56

--- How long the line under the list stays up, and how often the loop runs while no menu is.
--- Both are cadence, not policy.
local STATUS_MS = 6000
local IDLE_MS = 250

--- Raised beside each menu's own event, so one listener can watch every menu. A name, not a
--- setting: a caller that wants a different one listens on its own.
local GLOBAL_EVENT = "opx77:menu"

local MAX_STATUS = 120

--- Set by anything that changes what is on screen; consumed by the tick.
local dirty = false

--- `Open77.time.monotonic()` is SECONDS on the client, whatever the API
--- reference says; every shipped client resource treats it as seconds.
---@return integer
local function nowMs()
  return math.floor(Open77.time.monotonic() * 1000)
end

--- Raise one payload for a record named explicitly rather than read off the
--- module: a handler may re-enter this file, and must not find `record` set.
---@param owned MenuRecord
---@param entry MenuEntry|nil
---@param action MenuAction
---@param extra table|nil
local function dispatch(owned, entry, action, extra)
  local payload = Model.payload(owned, entry, action)
  if type(extra) == "table" then
    for key, value in pairs(extra) do payload[key] = value end
  end
  local event = (entry and entry.event) or owned.event
  if event then TriggerEvent(event, payload) end
  local global = GLOBAL_EVENT
  if global and global ~= false and global ~= event then
    TriggerEvent(global, payload)
  end
end

---@param entry MenuEntry|nil
---@param action MenuAction
---@param extra table|nil
local function emit(entry, action, extra)
  if record == nil then return end
  dispatch(record, entry, action, extra)
end

--- Where the strip sits, how wide it is, and which theme. Sent once at ready.
local function sendConfig()
  if page == nil or not pageReady then return end
  page:send("menu:config", {
    anchor = Config.ANCHOR,
    width = Config.WIDTH,
    maxHeight = MAX_HEIGHT_VH,
    rows = Config.VISIBLE_ROWS,
  })
end

local function draw()
  dirty = false
  if page == nil or not pageReady then return end
  if record == nil then
    page:send("menu:hide", {})
    return
  end
  local view = Model.view(record)
  if view == nil then return end
  page:send("menu:frame", view)
end

--- Note the caller's generation, and drop its menu if it has reloaded since.
---@param owner string
---@param generation integer
local function noteOwner(owner, generation)
  if ownerGenerations[owner] ~= nil and ownerGenerations[owner] ~= generation then
    if record ~= nil and record.owner == owner then
      Runtime.close(record.handle, "owner_reloaded")
    end
  end
  ownerGenerations[owner] = generation
end

--- Open a menu, replacing this owner's own or -- with `spec.steal` -- another's.
---@param owner string
---@param generation integer
---@param spec MenuSpec
---@return MenuRecord|nil, string|nil
function Runtime.open(owner, generation, spec)
  noteOwner(owner, generation)

  if record ~= nil and record.owner ~= owner and spec.steal ~= true then
    return nil, "menu_busy"
  end

  local built, reason = Model.build(owner, generation, spec)
  if built == nil then return nil, reason end

  if record ~= nil then
    -- Closed, not dropped: the previous owner is entitled to hear it is gone.
    Runtime.close(record.handle, record.owner == owner and "reopened" or "superseded")
  end

  built.handle = nextHandle
  nextHandle = nextHandle + 1
  record = built
  Model.settle(record)
  if spec.status ~= nil then Runtime.setStatus(spec.status) end

  -- Primed: a menu is often opened by a chat command whose ENTER is still down.
  Input.prime()
  draw()
  return record
end

--- Rebuild the open menu from a fresh spec, keeping the player's position.
---@param handle MenuHandle|nil
---@param spec MenuSpec
---@return boolean, string|nil
function Runtime.update(handle, spec)
  if record == nil then return false, "no_menu_open" end
  if handle ~= nil and handle ~= record.handle then return false, "not_open" end
  local ok, reason = Model.rebuild(record, spec)
  if not ok then return false, reason end
  Model.settle(record)
  -- After the rebuild: `setStatus` draws, which is the redraw the rebuild needs.
  if spec.status ~= nil then
    Runtime.setStatus(spec.status)
  else
    draw()
  end
  return true
end

---@param handle MenuHandle|nil
---@param reason string|nil
---@return boolean, string|MenuHandle|nil
function Runtime.close(handle, reason)
  if record == nil then return false, "no_menu_open" end
  if handle ~= nil and handle ~= record.handle then return false, "not_open" end
  local closing = record
  -- Cleared before dispatch: a close handler can re-enter this file.
  record = nil
  draw()
  dispatch(closing, nil, "close", { reason = reason or "closed" })
  return true, closing.handle
end

--- Write, or clear, the transient line under the list. Clearing is `nil`, never
--- an empty string.
---@param text string|nil
---@param ok boolean|nil  false marks a failure. Default true
---@return boolean
function Runtime.setStatus(text, ok)
  if record == nil then return false end
  local clean = text ~= nil and Model.display(text, MAX_STATUS) or nil
  if clean == nil or clean == "" then
    if record.status == nil then return true end
    record.status = nil
  else
    record.status = { text = clean, ok = ok ~= false, atMs = nowMs() }
  end
  draw()
  return true
end

---@return MenuState
function Runtime.snapshot()
  if record == nil then return { open = false } end
  local top = Model.frame(record)
  local entry = Model.item(record)
  local result = {
    open = true,
    handle = record.handle,
    owner = record.owner,
    menu = record.id,
    title = top and top.title or record.title,
    depth = #record.stack,
    index = top and top.index or 1,
    total = top and #top.items or 0,
    itemId = entry and entry.id or nil,
    label = entry and entry.label or nil,
  }
  -- Assigned, not folded above: `x and raw(x) or nil` collapses a false toggle.
  if entry ~= nil then result.value = Model.raw(entry) end
  return result
end

---@return string|nil
function Runtime.owner()
  return record and record.owner or nil
end

--- ENTER. The only place a menu can close itself.
---@return boolean  true when the screen changed
local function activate()
  local entry = Model.item(record)
  if entry == nil or entry.disabled or entry.kind == "separator" then return false end

  local kind = entry.kind

  if kind == "submenu" then
    if Model.push(record, entry) then
      emit(entry, "open")
      return true
    end
    return false
  end

  if kind == "back" then
    if Model.pop(record) then
      emit(entry, "back")
      return true
    end
    Runtime.close(record.handle, "back")
    return false
  end

  if kind == "close" then
    Runtime.close(record.handle, "item")
    return false
  end

  if kind == "toggle" or kind == "choices" or kind == "slider" then
    -- ENTER advances a control rather than doing nothing on it.
    if Model.adjust(entry, 1) then
      emit(entry, "change")
      return true
    end
    return false
  end

  -- Read BEFORE the event: a handler runs inline and may close this menu.
  local closeAfter = entry.close or record.closeOnSelect
  local handle = record.handle
  emit(entry, "select")
  if record == nil then return false end
  if closeAfter then
    Runtime.close(handle, "select")
    return false
  end
  return true
end

--- One tick of the input thread: six level reads and the edge tests.
---@param atMs integer  the frame's clock, read once by the caller
local function tick(atMs)
  if record == nil then return end

  -- Re-primed so nothing typed into the surface that owns the keyboard leaks.
  if Input.captured() then
    Input.prime()
    return
  end

  if Input.poll("DOWN", atMs) and Model.move(record, 1) then dirty = true end
  if Input.poll("UP", atMs) and Model.move(record, -1) then dirty = true end

  if Input.poll("RIGHT", atMs) then
    local entry = Model.item(record)
    if Model.adjust(entry, 1) then
      emit(entry, "change")
      dirty = true
    elseif entry ~= nil and entry.kind == "submenu" and Model.push(record, entry) then
      emit(entry, "open")
      dirty = true
    end
    -- Every branch above can reach a handler that closes the menu.
    if record == nil then return end
  end

  if Input.poll("LEFT", atMs) then
    local entry = Model.item(record)
    -- The row's KIND, not whether the value moved: a slider at its minimum is
    -- false, and falling through would leave the screen under the player.
    if Model.holdsValue(entry) then
      if Model.adjust(entry, -1) then
        emit(entry, "change")
        dirty = true
      end
    elseif Model.pop(record) then
      emit(nil, "back")
      dirty = true
    end
    if record == nil then return end
  end

  if Input.poll("SELECT", atMs) then
    if activate() then dirty = true end
    if record == nil then return end
  end

  if Input.poll("BACK", atMs) then
    if Model.pop(record) then
      emit(nil, "back")
      dirty = true
    else
      Runtime.close(record and record.handle or nil, "back")
      return
    end
  end

  if dirty then draw() end
end

--- The status line clears itself after `STATUS_MS`.
---@param atMs integer
local function expireStatus(atMs)
  if record == nil or record.status == nil then return end
  if atMs - record.status.atMs < STATUS_MS then return end
  record.status = nil
  draw()
end

--- The net under a caller that crashed, was stopped, or reloaded mid-menu. It
--- runs once a SWEEP_MS, so a menu outlives its owner by up to that.
---@param atMs integer
local function sweep(atMs)
  if record == nil then return end
  if atMs < nextSweepMs then return end
  nextSweepMs = atMs + SWEEP_MS
  local owner = record.owner
  local running = GetResourceState(owner) == "running"
  local generation
  if type(Open77.resource) == "table" and type(Open77.resource.generation) == "function" then
    generation = Open77.resource.generation(owner)
  end
  if not running or (generation ~= nil and generation ~= record.generation) then
    Runtime.close(record.handle, "owner_stopped")
  end
end

-- The plugin swallows Escape in the window procedure and raises this instead.
AddEventHandler("open77:pauseKey", function()
  if record ~= nil then Runtime.close(record.handle, "pause") end
end)

-- Raised after any rebind anywhere on the client. Nothing on screen shows a key,
-- so this changes no pixel -- it keeps `Input.keys` current for the `keys` export.
AddEventHandler("open77:keybinds:changed", function()
  Input.refresh()
end)


---@return boolean
function Runtime.unavailable()
  return surfaceFailed
end

AddEventHandler("onClientResourceStart", function(name)
  if name ~= RESOURCE then return end

  local backend, note = Input.attach()
  if backend == "none" then
    Open77.log.error(tostring(note))
  elseif note ~= nil then
    Open77.log.info(tostring(note))
  else
    Open77.log.info("keyboard backend is " .. backend)
  end

  -- Cleared on every start: a reload after a failure must be able to succeed.
  surfaceFailed = false

  local reason
  page, reason = WebUI.create({
    entry = "web/index.html",
    -- "hud", NOT "menu": a hud surface is never focused, so it cannot take input.
    layer = "hud",
    width = 1920,
    height = 1080,
    fps = 30,
    -- Above chat (700) and the toasts (720), below open77_admin's strip (730).
    zIndex = 725,
    transparent = true,
    -- Created VISIBLE: a surface created hidden never uploads a frame once shown.
    visible = true,
  })
  if page == nil then
    -- The exports are already published and the sweep lives in the thread below,
    -- so without this flag a caller is told `ok = true` for a menu nothing draws.
    Open77.log.error("WebUI surface failed: " .. tostring(reason))
    Open77.log.error("  the exports will refuse: there is nothing to draw on.")
    surfaceFailed = true
    return
  end

  page:on("menu:ready", function()
    pageReady = true
    sendConfig()
    draw()
  end)

  page:on("menu:diag", function(payload)
    if type(payload) ~= "table" then return end
    Open77.log.info("page: " .. tostring(payload.text or ""))
  end)

  CreateThread(function()
    while page ~= nil do
      if record ~= nil then
        -- One clock read for the frame. `monotonic` is a host call, and three of them per
        -- frame asked the same question three times to get the same answer.
        local atMs = nowMs()
        tick(atMs)
        expireStatus(atMs)
        sweep(atMs)
        Wait(0)
      else
        Wait(IDLE_MS)
      end
    end
  end)
end)

AddEventHandler("onClientResourceStop", function(name)
  if name ~= RESOURCE then return end
  -- Tell whoever had a menu open, while there is still a Lua state to do it.
  if record ~= nil then Runtime.close(record.handle, "menu_stopped") end
  Input.release()
  page, pageReady = nil, false
end)
