#!/usr/bin/env python3
"""Regenerates ../preview.html from the resource's own files.

    python3 tools/build-preview.py        # then open preview.html in a browser

`preview.html` is a DEV ARTEFACT, not part of the resource: it sits at the
repository root rather than under `web/`, so `web_files { "web/**" }` does not
match it and it is never shipped to a client.

It is generated rather than hand-written so it cannot drift, and it is as close
to the shipped page as a browser can get: `web/open77-ui.css`, `web/menu.css`
and `web/menu.js` are all inlined VERBATIM, the strip's markup is lifted out of
`web/index.html`, and the page runs on the real `<body>` exactly as it does in
game -- same `opacity` gate, same `pointer-events: none`, same `position: fixed`
strip measured in real px and real vh. The scene is painted on `<html>`, which
is the one element the page's own stylesheet leaves alone below the root, so it
stays visible when the menu closes and the body fades out.

Two things are not the resource:

  * the `Open77` bridge is shimmed, so `menu:config` / `menu:frame` can be
    delivered from this page instead of from Lua;
  * navigation is a stand-in for client/model.lua, because in game the keyboard
    is read in Lua and the page only draws. Where a rule matters -- skipping
    separators and disabled rows, the scroll window, the slider clamp and snap
    -- it is the same rule.

Re-run this after touching config.lua or anything under web/.
"""
import base64, json, pathlib, re

ROOT = pathlib.Path(__file__).resolve().parent.parent
BACKGROUND = ROOT / "tools/preview-bg.jpg"

tokens = (ROOT / "web/open77-ui.css").read_text(encoding="utf-8")
menucss = (ROOT / "web/menu.css").read_text(encoding="utf-8")
menujs = (ROOT / "web/menu.js").read_text(encoding="utf-8")
index = (ROOT / "web/index.html").read_text(encoding="utf-8")
config = (ROOT / "config.lua").read_text(encoding="utf-8")
mainlua = (ROOT / "client/main.lua").read_text(encoding="utf-8")

# --- config.lua, so the preview shows what is actually configured -----------
def scalar(name, cast=str):
    match = re.search(r"^\s*%s\s*=\s*([^,\n]+)," % name, config, re.M)
    if match is None:
        raise SystemExit("config.lua: %s not found" % name)
    return cast(match.group(1).strip().strip('"'))

def constant(name, cast=str):
    match = re.search(r"^local\s+%s\s*=\s*(\S+)" % name, mainlua, re.M)
    if match is None:
        raise SystemExit("client/main.lua: %s not found" % name)
    return cast(match.group(1).strip().strip('"'))

# Not part of `menu:config`. Lua expires the status line on its own tick; the
# page only needs the number to fake that tick with a timer.
STATUS_MS = constant("STATUS_MS", int)

# Not part of `menu:config` either: Lua sends the window, so the page never
# needs the row count. The driver below stands in for Lua and does.
ROWS = scalar("VISIBLE_ROWS", int)

# Exactly the fields client/main.lua sends in `menu:config`, and no others.
CFG = {
    "anchor": scalar("ANCHOR"),
    "width": scalar("WIDTH", int),
    "maxHeight": constant("MAX_HEIGHT_VH", int),
}

# --- the strip's markup, lifted out of the real page ------------------------
strip = re.search(r'<div class="strip" id="strip">.*?\n</div>\n', index, re.S)
if strip is None:
    raise SystemExit("web/index.html: the strip markup was not found")
strip = strip.group(0)

background = base64.b64encode(BACKGROUND.read_bytes()).decode()

# The only CSS this page adds. `web/menu.css` deliberately leaves <html>
# transparent so the game shows through; here the game is a still, and this is
# the one rule that says so. It comes after menu.css, so it wins on order at
# equal specificity -- and it is the ONLY thing overridden.
scene_css = """
/* ==========================================================================
   The scene. Everything above this line is the resource, unedited.
   ========================================================================== */
html {
  background: #000 url("data:image/jpeg;base64,__BACKGROUND__") center / cover no-repeat;
}
"""

driver_js = r"""
/* --------------------------------------------------------------- preview --
 * A stand-in for client/model.lua + client/main.lua, so the page above is
 * driven by the same payloads Lua sends. Not part of the resource.
 *
 *   arrows / enter / backspace   navigate, exactly as in game
 *   A                            cycle the anchor
 *   M                            swap the sample menu
 *
 * The two letters are here so a design can be compared without a control
 * panel on screen; nothing draws them, and the game never sees them.
 */
(function () {
  "use strict";

  var CONFIG = __CONFIG__;
  var SAMPLES = __SAMPLES__;
  var STATUS_MS = __STATUS_MS__;
  var ROWS = __ROWS__;
  var ANCHORS = ["top-left", "top-right", "left", "right"];

  /* --------------------------------------------------------------- model */
  function kindOf(item) {
    if (item.separator) return "separator";
    if (item.items) return "submenu";
    if (typeof item.toggle === "boolean") return "toggle";
    if (item.choices) return "choices";
    if (item.slider) return "slider";
    if (item.back) return "back";
    if (item.close) return "close";
    return "action";
  }

  function normalize(items) {
    return items.map(function (item, index) {
      var entry = Object.assign({}, item);
      entry.id = item.id || "item_" + (index + 1);
      entry.kind = kindOf(item);
      if (entry.kind === "choices") entry.selected = item.selected || 1;
      if (entry.kind === "submenu") {
        entry.title = item.title || item.label;
        entry.items = normalize(item.items);
      }
      if (entry.kind === "slider") entry.slider = Object.assign({}, item.slider);
      return entry;
    });
  }

  function valueOf(entry) {
    if (entry.kind === "toggle") return entry.toggle ? "ON" : "OFF";
    if (entry.kind === "choices") return entry.choices[entry.selected - 1];
    if (entry.kind === "slider") {
      var slider = entry.slider;
      var text = slider.value % 1 === 0
        ? String(Math.floor(slider.value))
        : slider.value.toFixed(2);
      return text + (slider.suffix || "");
    }
    return entry.value;
  }

  function selectable(entry) {
    return entry && entry.kind !== "separator" && !entry.disabled;
  }

  var menu = null;
  var sample = 0;
  var status = null;
  var statusTimer = 0;
  var names = Object.keys(SAMPLES);

  function open(name) {
    var spec = SAMPLES[name];
    menu = {
      id: spec.id, title: spec.title, event: spec.event,
      items: normalize(spec.items)
    };
    menu.stack = [{ items: menu.items, title: spec.title, index: 1 }];
    // The resource resolves `cursor` in Lua; here it is one line, and it is
    // what lets a sample open on the row it should open on.
    if (spec.cursor !== undefined) {
      for (var index = 0; index < menu.items.length; index += 1) {
        if (menu.items[index].id === spec.cursor) { menu.stack[0].index = index + 1; break; }
      }
    }
    settle();
    say(null);
  }

  function frame() { return menu.stack[menu.stack.length - 1]; }
  function item() { return frame().items[frame().index - 1]; }

  function settle() {
    var top = frame();
    if (selectable(top.items[top.index - 1])) return;
    for (var index = 1; index <= top.items.length; index += 1) {
      if (selectable(top.items[index - 1])) { top.index = index; return; }
    }
  }

  function move(delta) {
    var top = frame();
    var total = top.items.length;
    var index = top.index;
    for (var step = 0; step < total; step += 1) {
      index = ((index - 1 + delta + total) % total) + 1;
      if (selectable(top.items[index - 1])) { top.index = index; return true; }
    }
    return false;
  }

  function adjust(entry, delta) {
    if (!entry || entry.disabled) return false;
    if (entry.kind === "toggle") { entry.toggle = !entry.toggle; return true; }
    if (entry.kind === "choices") {
      var total = entry.choices.length;
      if (total <= 1) return false;
      entry.selected = ((entry.selected - 1 + delta + total) % total) + 1;
      return true;
    }
    if (entry.kind === "slider") {
      var slider = entry.slider, before = slider.value;
      var value = Math.min(slider.max, Math.max(slider.min, slider.value + slider.step * delta));
      value = slider.min + Math.round((value - slider.min) / slider.step) * slider.step;
      slider.value = Math.min(slider.max, value);
      return slider.value !== before;
    }
    return false;
  }

  /* The same window as Model.view: the cursor is kept near the middle except
     at the two ends, so the list scrolls under a roughly stationary cursor. */
  function windowFirst(index, total, rows) {
    if (total <= rows) return 1;
    var first = index - Math.floor(rows / 2);
    if (first < 1) first = 1;
    if (first > total - rows + 1) first = total - rows + 1;
    return first;
  }

  function draw() {
    var top = frame();
    var total = top.items.length;
    var first = windowFirst(top.index, total, ROWS);
    var rows = [];
    for (var index = first; index <= Math.min(first + ROWS - 1, total); index += 1) {
      var entry = top.items[index - 1];
      rows.push({
        label: entry.label,
        value: valueOf(entry),
        arrow: entry.kind === "submenu" || undefined,
        spin: (entry.kind === "choices" || entry.kind === "slider" ||
               entry.kind === "toggle") || undefined,
        rule: entry.kind === "separator" || undefined,
        off: entry.disabled || undefined,
        on: index === top.index || undefined
      });
    }
    var selected = top.items[top.index - 1];
    Open77.__deliver("menu:frame", {
      status: status ? status.text : undefined,
      statusBad: status && status.bad ? true : undefined,
      title: top.title,
      trail: menu.stack.length > 1
        ? menu.stack.map(function (f) { return f.title; }).join(" / ")
        : undefined,
      rows: rows,
      first: first,
      total: total,
      index: top.index,
      depth: menu.stack.length,
      hint: selected ? selected.description : undefined
    });
  }

  /* Lua clears the line after STATUS_MS, on its own tick. The page has no
     tick, so a timer stands in for one. */
  function say(text, bad) {
    status = text ? { text: text, bad: bad } : null;
    window.clearTimeout(statusTimer);
    if (status) {
      statusTimer = window.setTimeout(function () { status = null; draw(); }, STATUS_MS);
    }
    draw();
  }

  /* ---------------------------------------------------------- navigation */
  function activate() {
    var entry = item();
    if (!entry || entry.disabled || entry.kind === "separator") return;
    if (entry.kind === "submenu") {
      menu.stack.push({ items: entry.items, title: entry.title, index: 1 });
      settle();
    } else if (entry.kind === "back") {
      if (menu.stack.length > 1) menu.stack.pop();
    } else if (entry.kind === "close") {
      Open77.__deliver("menu:hide", {});
      return;
    } else {
      if (!adjust(entry, 1) && entry.demo) say(entry.demo.status, entry.demo.bad);
    }
    draw();
  }

  var NAVIGATE = {
    ArrowDown: function () { if (move(1)) draw(); },
    ArrowUp: function () { if (move(-1)) draw(); },
    ArrowRight: function () {
      var entry = item();
      if (adjust(entry, 1)) draw();
      else if (entry && entry.kind === "submenu") activate();
    },
    ArrowLeft: function () {
      var entry = item();
      if (adjust(entry, -1)) draw();
      else if (menu.stack.length > 1) { menu.stack.pop(); draw(); }
    },
    Enter: activate,
    Backspace: function () {
      if (menu.stack.length > 1) { menu.stack.pop(); draw(); }
      else Open77.__deliver("menu:hide", {});
    }
  };

  /* -------------------------------------------------------------- config */
  var live = Object.assign({}, CONFIG);
  function sendConfig() { Open77.__deliver("menu:config", live); }

  var SWITCH = {
    a: function () {
      live.anchor = ANCHORS[(ANCHORS.indexOf(live.anchor) + 1) % ANCHORS.length];
      sendConfig();
    },
    m: function () {
      sample = (sample + 1) % names.length;
      open(names[sample]);
    }
  };

  document.addEventListener("keydown", function (event) {
    var navigate = NAVIGATE[event.key];
    if (navigate) {
      event.preventDefault();
      if (document.body.classList.contains("open")) navigate();
      else open(names[sample]);
      return;
    }
    var swap = SWITCH[event.key.toLowerCase()];
    if (swap) { event.preventDefault(); swap(); }
  });

  sendConfig();
  open(names[sample]);
})();
"""

SAMPLES = {
    # A ripperdoc chair: the one screen in Night City that is a menu of choices
    # with prices, prerequisites and a cost you cannot buy back. It exercises
    # every item kind the resource has -- an action, a submenu, a toggle, a
    # choice list, a slider, captions, a locked row with a reason, and a close.
    "ripperdoc": {
        "id": "ripper.chair", "title": "RIPPERDOC",
        "event": "ripper:menu",
        "items": [
            {"separator": True, "label": "Operating system"},
            {"id": "sandevistan", "label": "Sandevistan MK.4", "value": "INSTALLED",
             "event": "ripper:install",
             "description": "Slows time to 25% for 8 seconds. 15s cooldown.",
             "demo": {"status": "Already in the slot."}},
            {"id": "berserk", "label": "Berserk MK.2", "value": "28 000 ED",
             "event": "ripper:install",
             "description": "Replaces the Sandevistan. Both share the operating system slot.",
             "demo": {"status": "Not enough eddies. You have 11 240.", "bad": True}},

            {"separator": True, "label": "Implants"},
            {"id": "cortex", "label": "Frontal cortex", "value": "2 / 3", "items": [
                {"id": "raminfra", "label": "RAM Upgrade", "value": "INSTALLED"},
                {"id": "memboost", "label": "Memory Boost", "value": "9 400 ED"},
                {"id": "limbic", "label": "Limbic System Enhancement", "value": "LOCKED",
                 "disabled": True, "description": "Requires Intelligence 12. You have 9."},
                {"separator": True},
                {"id": "back", "label": "Back", "back": True},
            ]},

            {"separator": True, "label": "Tuning"},
            {"id": "camo", "label": "Optical camo", "toggle": True,
             "description": "Draws 6 RAM while active."},
            {"id": "kerenzikov", "label": "Kerenzikov window",
             "slider": {"min": 0.5, "max": 4, "step": 0.5, "value": 2, "suffix": " s"},
             "description": "Longer windows raise heat build-up."},
            {"id": "coolant", "label": "Coolant grade",
             "choices": ["Standard", "Cryo", "Thermal"], "selected": 1},

            {"separator": True, "label": "Locked"},
            {"id": "heart", "label": "Second Heart", "disabled": True,
             "description": "Street Cred 40 required. You are at 28."},

            {"id": "leave", "label": "Leave the chair", "close": True},
        ],
    },
    # The other shape a menu takes here: a long list the window has to page
    # through, with a cost against each row.
    "quickhacks": {
        "id": "net.deck", "title": "QUICKHACKS",
        "event": "net:menu", "cursor": "overheat",
        "items": ([{"separator": True, "label": "Covert"}] + [
            {"id": key, "label": name, "value": cost + " RAM", "event": "net:queue"}
            for key, name, cost in [
                ("ping", "Ping", "1"), ("whistle", "Whistle", "2"),
                ("memory_wipe", "Memory Wipe", "6"), ("reboot_optics", "Reboot Optics", "5"),
                ("sonic_shock", "Sonic Shock", "3"), ("request_data", "Request Data", "2"),
                ("distract", "Distract Enemies", "1"),
            ]
        ] + [{"separator": True, "label": "Combat"}] + [
            {"id": key, "label": name, "value": cost + " RAM", "event": "net:queue"}
            for key, name, cost in [
                ("overheat", "Overheat", "4"), ("short_circuit", "Short Circuit", "6"),
                ("contagion", "Contagion", "8"), ("synapse", "Synapse Burnout", "12"),
                ("weapon_glitch", "Weapon Glitch", "5"), ("cripple", "Cripple Movement", "6"),
                ("detonate", "Detonate Grenade", "9"),
            ]
        ] + [{"separator": True, "label": "Ultimate"}] + [
            {"id": key, "label": name, "value": cost + " RAM", "event": "net:queue"}
            for key, name, cost in [
                ("system_reset", "System Reset", "14"), ("cyberpsycho", "Cyberpsychosis", "18"),
                ("suicide", "Suicide", "16"), ("detonate_all", "Detonate Grenades", "20"),
            ]
        ] + [{"separator": True, "label": "Deck"}] + [
            {"id": "ram", "label": "RAM recovery",
             "slider": {"min": 0, "max": 100, "step": 5, "value": 45, "suffix": "%"}},
            {"id": "autoreveal", "label": "Auto-reveal on scan", "toggle": True},
            {"id": "close", "label": "Close deck", "close": True},
        ]),
    },
}

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OPX//77 Menu Strip</title>
<!-- The three faces the tokens name first. In game none of them resolve -- no
     font is bundled with any resource and there is no network -- and the stacks
     fall through to Bahnschrift and Cascadia Mono. -->
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Rajdhani:wght@400;600;700&family=Saira:wght@400;600;700&family=IBM+Plex+Mono:wght@400;700&display=swap">
<style>
/* ==========================================================================
   web/open77-ui.css -- verbatim
   ========================================================================== */
{tokens}
/* ==========================================================================
   web/menu.css -- verbatim
   ========================================================================== */
{menucss}
{scene_css.replace("__BACKGROUND__", background)}
</style>
</head>

<body>

{strip}
<script>
/* The host's bridge, shimmed: `__deliver` is where Lua would be. */
window.Open77 = (function () {{
  var handlers = {{}};
  return {{
    on: function (channel, handler) {{ handlers[channel] = handler; }},
    emit: function () {{}},
    ready: function () {{}},
    __deliver: function (channel, payload) {{
      if (handlers[channel]) handlers[channel](payload);
    }}
  }};
}})();
</script>
<script>
/* ==========================================================================
   web/menu.js -- verbatim
   ========================================================================== */
{menujs}
</script>
<script>
{driver_js.replace("__CONFIG__", json.dumps(CFG)).replace("__SAMPLES__", json.dumps(SAMPLES)).replace("__STATUS_MS__", str(STATUS_MS)).replace("__ROWS__", str(ROWS))}
</script>
</body>
</html>
"""

out = ROOT / "preview.html"
out.write_text(html, encoding="utf-8")
print("wrote %s (%.0f KB)" % (out, len(html) / 1024))
print("anchor=%s width=%spx rows=%s" % (CFG["anchor"], CFG["width"], ROWS))
