/* opx77_menu -- the strip's page. A renderer and nothing else: Lua reads the
 * keyboard, keeps the frame stack, and pushes the window of rows it wants drawn.
 */
(function () {
  "use strict";

  // CEF console output does not reach the client log, and the WebUI bridge
  // swallows every exception thrown inside an `Open77.on` handler.
  var reportCount = 0;
  var reporting = false;

  function describe(value) {
    try {
      if (value instanceof Error) return (value.name || "Error") + ": " + value.message;
      if (value === null || value === undefined) return String(value);
      if (typeof value === "object") return Object.prototype.toString.call(value);
      return String(value);
    } catch (ignored) { return "<undescribable>"; }
  }

  function report(text) {
    if (reporting || reportCount >= 20) return;
    reporting = true;
    reportCount += 1;
    try {
      window.Open77.emit("menu:diag", { text: String(text).slice(0, 400) });
    } catch (ignored) { /* nowhere left to complain to */ }
    reporting = false;
  }

  window.addEventListener("error", function (event) {
    report("uncaught " + (event.message || "?") + " at line " + (event.lineno || 0));
  });
  (function (original) {
    console.error = function () {
      report(Array.prototype.map.call(arguments, describe).join(" "));
      try { original.apply(console, arguments); } catch (ignored) { /* no console */ }
    };
  })(console.error);

  // An empty Lua table arrives as `{}`, not `[]`, and `value || []` would keep
  // it: `.forEach` then throws and aborts the whole render.
  function list(value) { return Array.isArray(value) ? value : []; }

  function text(value) { return value === null || value === undefined ? "" : String(value); }

  var elements = {
    strip: document.getElementById("strip"),
    title: document.getElementById("title"),
    trail: document.getElementById("trail"),
    list: document.getElementById("list"),
    hint: document.getElementById("hint"),
    status: document.getElementById("status")
  };

  var ANCHORS = {
    "top-left": "anchor-top-left",
    "top-right": "anchor-top-right",
    "left": "anchor-left",
    "right": "anchor-right"
  };

  function applyConfig(payload) {
    payload = payload || {};

    var anchor = ANCHORS[text(payload.anchor)] || ANCHORS["top-left"];
    elements.strip.className = "strip " + anchor;

    var width = Number(payload.width);
    if (isFinite(width) && width > 0) {
      elements.strip.style.setProperty("--strip-width", Math.round(width) + "px");
    }
    var maxHeight = Number(payload.maxHeight);
    if (isFinite(maxHeight) && maxHeight > 0) {
      elements.strip.style.setProperty("--strip-max-height", Math.round(maxHeight) + "vh");
    }

  }

  /* One <li> per window SLOT, created once and rewritten in place. Rebuilding
   * the list every frame would make every transition in menu.css dead code: a
   * new element has no previous computed style to animate from.
   */
  var slots = [];

  function span(className) {
    var node = document.createElement("span");
    node.className = className;
    return node;
  }

  function slot(index) {
    var entry = slots[index];
    if (entry !== undefined) return entry;
    entry = {
      node: document.createElement("li"),
      label: span("label"),
      value: span("value"),
      // Always present, even when blank, so every label starts at the same x.
      mark: span("mark-col")
    };
    entry.node.appendChild(entry.label);
    entry.node.appendChild(entry.value);
    entry.node.appendChild(entry.mark);
    // Its position in the window, for the stylesheet's open stagger. Set once:
    // a slot never changes position.
    entry.node.style.setProperty("--slot", index);
    slots[index] = entry;
    elements.list.appendChild(entry.node);
    return entry;
  }

  function render(payload) {
    payload = payload || {};
    var rows = list(payload.rows);

    elements.title.textContent = text(payload.title) || "MENU";

    // Upper-cased and nothing else: Lua owns the separator, so re-splitting on
    // "/" here would double every space and cut a title containing one.
    elements.trail.textContent = text(payload.trail).toUpperCase();

    for (var index = 0; index < rows.length; index += 1) {
      var row = rows[index] || {};
      var entry = slot(index);

      var classes = "row";
      if (row.rule) classes += " rule";
      if (row.off) classes += " off";
      if (row.on) classes += " on";
      // A class rather than `:has(.label:empty)`, whose support on this client
      // build is not something to bet the layout on.
      if (row.rule && text(row.label) === "") classes += " blank";
      entry.node.className = classes;
      entry.node.hidden = false;

      entry.label.textContent = text(row.label);
      entry.value.textContent = row.rule ? "" : text(row.value);
      // `>` descends, `< >` means LEFT and RIGHT change the value beside it.
      entry.mark.textContent = row.arrow ? ">" : (row.spin ? "\u2039\u203A" : "");
    }

    // Slots past the end of a shorter frame. The class is reset too: a hidden
    // slot that kept `on` would come back selected under a longer menu.
    for (var spare = rows.length; spare < slots.length; spare += 1) {
      slots[spare].node.className = "row";
      slots[spare].node.hidden = true;
    }

    // The three numbers the scroll rail is drawn from; the stylesheet does the
    // arithmetic.
    var total = Number(payload.total) || 0;
    var first = Number(payload.first) || 1;
    elements.list.style.setProperty("--first", first);
    elements.list.style.setProperty("--rows", rows.length);
    elements.list.style.setProperty("--total", total);
    elements.list.classList.toggle("paged", total > rows.length);

    elements.hint.textContent = text(payload.hint);

    // Only the failure flag crosses the bridge; a status with nothing said about
    // it is a success.
    elements.status.textContent = text(payload.status);
    elements.status.className = payload.statusBad ? "status bad" : "status";

    document.body.classList.add("open");
  }

  function hide() {
    document.body.classList.remove("open");
    // Blanked on hide, not on the next open: the strip fades out over 150ms, and
    // a frame arriving during that fade would show the previous menu's rows.
    for (var index = 0; index < slots.length; index += 1) {
      slots[index].node.className = "row";
      slots[index].node.hidden = true;
    }
    elements.list.classList.remove("paged");
    elements.hint.textContent = "";
    elements.status.textContent = "";
  }

  Open77.on("menu:config", function (payload) {
    try { applyConfig(payload); } catch (error) { report("config: " + describe(error)); }
  });

  Open77.on("menu:frame", function (payload) {
    try { render(payload); } catch (error) { report("render: " + describe(error)); }
  });

  Open77.on("menu:hide", function () {
    try { hide(); } catch (error) { report("hide: " + describe(error)); }
  });

  // Emitted whatever happened above: Lua drops every message until the page has
  // reported ready.
  try { Open77.ready(); } catch (error) { report("ready: " + describe(error)); }
  Open77.emit("menu:ready", {});
})();
