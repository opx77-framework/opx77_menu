--- Configuration for opx77_menu: where the strip sits, and how big it is.

OPX_MENU_CONFIG = {
  -- "top-left" | "top-right" | "left" | "right"; the last two are mid-height. No bottom
  -- anchor: the list grows downward. Anything unrecognised falls back to "top-left".
  ANCHOR = "top-left",
  WIDTH = 340, -- strip width in pixels, at a 1920-wide surface
  VISIBLE_ROWS = 9, -- rows drawn at once; a longer list scrolls around the cursor
}
