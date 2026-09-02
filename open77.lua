resource "opx77_menu"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true

-- "reconnect", like every resource that owns a CEF surface: swapping a live surface while
-- gameplay runs has historically been unstable, so a generation change takes the session
-- through a clean reconnect. See opx77_chat's manifest for the rule in full and for who
-- states it; a resource without a surface -- opx77_core, opx77_weather, opx77_elevators --
-- declares "local" instead.
reload_policy "reconnect"

-- Load order is manifest order: config before everything, model before input,
-- main before exports.
client_script "config.lua"
client_script "client/model.lua"
client_script "client/input.lua"
client_script "client/main.lua"
client_script "client/exports.lua"

web_ui_page "web/index.html"
web_ui_auto_create false -- client/main.lua creates it, so a failure is one logged line
web_files { "web/**" }

permissions {
  -- `Open77.input.isDown` and `isCaptured`. The menu polls
  -- the keyboard and never takes focus, so it needs no webui permission.
  "input.actions",
}
