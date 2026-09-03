--- The surface, the input thread, and the one open menu.

OpxMenu = OpxMenu or {}

local Config = OPX_MENU_CONFIG
local Text = OpxMenu.Text
local Model = OpxMenu.model
local Input = OpxMenu.input

local Runtime = {}
OpxMenu.runtime = Runtime

local RESOURCE = GetCurrentResourceName()

local page

--- True once WebUI.create has refused; the exports refuse too.
local surfaceFailed = false
local pageReady = false

--- The one open menu, or nil.
---@type MenuRecord|nil
local record

local nextHandle = 1

--- owner -> the generation last seen, so a reloaded caller's menu goes away with it.
local ownerGenerations = {}
local nextOwnerSweepMs = 0
local OWNER_SWEEP_MS = 1000

--- How much of the viewport height the list may take before it clips.
local MAX_HEIGHT_VH = 56

--- How long the status line stays up, and the loop's idle period while no menu is open.
local STATUS_MS = 6000
local IDLE_MS = 250

--- Raised beside each menu's own event, so one listener can watch every menu.
local GLOBAL_EVENT = "opx77:menu"

local MAX_STATUS = 120

--- Set by anything that changes what is on screen; consumed by the tick.
local dirty = false

--- The scheduler clock in milliseconds; `monotonic` answers SECONDS. A non-finite reading is
--- dropped rather than propagated: a NaN would expire nothing, an infinity everything.
---@return integer
local lastMs = 0
local function nowMs()
  local read, seconds = pcall(Open77.time.monotonic)
  if read and type(seconds) == "number" and seconds == seconds and
    seconds >= 0 and seconds < math.huge then
    lastMs = math.floor(seconds * 1000)
  end
  return lastMs
end

--- Raise one payload for an explicitly named record; a handler may re-enter this file.
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
  if GLOBAL_EVENT ~= event then TriggerEvent(GLOBAL_EVENT, payload) end
end

---@param entry MenuEntry|nil
---@param action MenuAction
---@param extra table|nil
local function emit(entry, action, extra)
  if record == nil then return end
  dispatch(record, entry, action, extra)
end

--- True while `page:send` is failing, so a dead surface is logged once, not every frame.
local sendFailing = false

--- One write to the page. Guarded: `page:send` raises, and both the exports and the input
--- thread reach it.
---@param name string
---@param payload table
local function send(name, payload)
  if page == nil or not pageReady then return end
  local ok, reason = pcall(page.send, page, name, payload)
  if ok then
    sendFailing = false
    return
  end
  if not sendFailing then
    Open77.log.error(("the page write %s failed: %s"):format(name, tostring(reason)))
  end
  sendFailing = true
end

--- Send the layout to the page. Once, at ready: none of it changes while the resource runs.
local function sendConfig()
  send("menu:config", {
    anchor = Config.ANCHOR,
    width = Config.WIDTH,
    maxHeight = MAX_HEIGHT_VH,
  })
end

local function draw()
  dirty = false
  if page == nil or not pageReady then return end
  if record == nil then
    send("menu:hide", {})
    return
  end
  local view = Model.view(record)
  if view == nil then return end
  send("menu:frame", view)
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

--- Open a menu, replacing this owner's own or, with `spec.steal`, another's.
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
    -- Closed, not dropped: the previous owner is told its menu is gone.
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
  -- `setStatus` draws, which is the redraw the rebuild needs.
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

--- Write, or clear with `nil`, the transient line under the list.
---@param text string|nil
---@param ok boolean|nil  false marks a failure. Default true
---@return boolean
function Runtime.setStatus(text, ok)
  if record == nil then return false end
  local clean = text ~= nil and Text.clean(text, MAX_STATUS) or nil
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
  -- Assigned, not folded above: `x and raw(x) or nil` would collapse a false toggle.
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
    if Model.adjust(entry, 1) then
      emit(entry, "change")
      return true
    end
    return false
  end

  -- Read before the event: a handler runs inline and may close this menu.
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

--- One tick of the input thread.
---@param atMs integer  the frame's clock, read once by the caller
local function tick(atMs)
  if record == nil then return end

  -- Re-primed so nothing typed into the surface that owns the keyboard leaks in.
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
    -- Kind, not whether the value moved: a slider at its minimum must not pop the screen.
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

--- Clear the status line once `STATUS_MS` has passed.
---@param atMs integer
local function expireStatus(atMs)
  if record == nil or record.status == nil then return end
  if atMs - record.status.atMs < STATUS_MS then return end
  record.status = nil
  draw()
end

--- Close the menu when its owner has stopped or reloaded. Runs once per `SWEEP_MS`.
---@param atMs integer
local function sweep(atMs)
  if record == nil then return end
  if atMs < nextOwnerSweepMs then return end
  nextOwnerSweepMs = atMs + OWNER_SWEEP_MS
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

--- One frame of the open menu. Every call it makes is a host call, so the thread runs it
--- under `pcall`: a raise here would end input for the session.
local function frameTick()
  -- One clock read per frame: `monotonic` is a host call.
  local atMs = nowMs()
  tick(atMs)
  expireStatus(atMs)
  sweep(atMs)
end

--- One pass of a forever-thread. A raise from a host call would otherwise end that loop for
--- the session, so it is logged once per run of failures and the loop carries on.
---@param label string
---@param body fun()
---@param failing boolean  whether the previous pass already failed
---@return boolean failing
local function guarded(label, body, failing)
  local ok, reason = pcall(body)
  if ok then return false end
  if not failing then Open77.log.error(("%s failed: %s"):format(label, tostring(reason))) end
  return true
end

-- The plugin swallows Escape and raises this instead.
AddEventHandler("open77:pauseKey", function()
  if record ~= nil then Runtime.close(record.handle, "pause") end
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
    -- "hud", not "menu": a hud surface is never focused, so it cannot take input.
    layer = "hud",
    width = 1920,
    height = 1080,
    fps = 30,
    -- Above chat (700) and the toasts (720), below open77_admin's strip (730).
    zIndex = 725,
    transparent = true,
    -- Created visible: a surface created hidden never uploads a frame once shown.
    visible = true,
  })
  if page == nil then
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
    local failing = false
    while page ~= nil do
      if record == nil then
        Wait(IDLE_MS)
      else
        failing = guarded("the menu frame", frameTick, failing)
        -- Backed off while it fails: whatever raised will raise again next frame.
        Wait(failing and IDLE_MS or 0)
      end
    end
  end)
end)

AddEventHandler("onClientResourceStop", function(name)
  if name ~= RESOURCE then return end
  -- Tell whoever had a menu open, while there is still a Lua state to do it.
  if record ~= nil then Runtime.close(record.handle, "menu_stopped") end
  page, pageReady = nil, false
end)
