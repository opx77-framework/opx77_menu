--- opx77_menu -- operator configuration.

OPX_MENU_CONFIG = {
  -- Where the strip sits. Four values, and they are NOT the four corners the other
  -- resources take: "top-left" | "top-right" | "left" | "right", where the last two are
  -- mid-height against that edge. There is no bottom corner here -- a list that grows
  -- downward from a bottom anchor runs off the screen. web/menu.js falls back to "top-left"
  -- for anything it does not recognise, and logs nothing.
  ANCHOR = "top-left",
  WIDTH = 340, -- strip width in pixels, at a 1920-wide surface
  VISIBLE_ROWS = 9, -- rows drawn at once; a longer list scrolls around the cursor
}
