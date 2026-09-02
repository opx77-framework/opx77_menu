resource "opx77_menu"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true

-- Swapping a live CEF surface mid-session is unstable, so a generation change reconnects.
reload_policy "reconnect"

-- Load order is manifest order: config first, model before input, main before exports.
client_script "config.lua"
client_script "client/model.lua"
client_script "client/input.lua"
client_script "client/main.lua"
client_script "client/exports.lua"

web_ui_page "web/index.html"
web_ui_auto_create false -- client/main.lua creates it, so a failure is one logged line
web_files { "web/**" }

permissions {
  -- `Open77.input.isDown` and `isCaptured`. The menu never takes focus, so no webui.
  "input.actions",
}
