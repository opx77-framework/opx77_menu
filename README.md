# opx77_menu

> [!WARNING]
> **This project is currently in early development and is not considered production-ready.**
>
> The API, architecture, features, and internal systems are subject to change at any time without prior notice. Breaking changes may be introduced as development progresses.
>
> **Do not rely on the current API for production resources yet.**

A keyboard-driven menu service for **Opx77**. One resource owns the surface; every other resource opens a menu through an export and is told which row the player chose.

Built for a platform with no cursor: the strip is drawn on the HUD layer, never focused, and navigated entirely from the arrow keys.

## Features

- Rows, submenus, toggles, choice lists and sliders
- Fixed arrow-key navigation, read through `Open77.input.isDown`
- Four screen anchors, chosen to avoid the platform's own chat and notification bands
- One menu at a time, with an owner-generation sweep behind it

## Exports

The exports are client-side only: a server resource calls them from its own client half.

| Export | Does |
|---|---|
| `open` | open a menu, refusing the spec whole if any row is malformed |
| `update` | replace the rows of a menu you own |
| `close` | close it |
| `state` | whether a menu is open and whether it is yours |
| `setStatus` | write the transient line under the list |
| `keys` | the keys that drive the menu, for a caller printing its own hint |

Every export answers `{ ok = boolean, error = string|nil }` and never raises; `error` is a stable code, never player-facing text. `open` adds `handle`, `id` and `nodes`, the size of the tree it built. Types for every spec, payload and response are in `types.lua`.

### Rules a caller needs

- One menu at a time. `open` answers `menu_busy` when another resource owns the open one, unless the spec sets `steal = true`.
- `update`, `close` and `setStatus` answer `not_owner` unless the open menu is yours.
- `state` reports only `open` and `mine` for a menu you do not own.
- The menu closes itself when its owner stops or reloads, within a second.
- The status line clears itself after six seconds; `setStatus(nil)` clears it now. A status, from `setStatus` or from a spec's `status` field, is text or a number: anything else answers `invalid_status` rather than silently clearing the line.
- Limits, all refusals rather than truncations: 200 items per level, 8 levels deep, 400 nodes in the whole tree, and a `data` table of at most 64 nodes — keys count as well as values — nested at most 4 deep.
- A label, value or description longer than its limit is cut to it, counted in characters so a cut never splits one.
- Escape closes the open menu, and the menu stands down whenever another surface has the keyboard.
- `reportFocus = true` in the spec adds the `focus` action, described under Events. It is off by default and a caller that does not set it is never sent one.

## Events

Every event is raised on the item's own `event` name, or the menu's where the item has none, and on `opx77:menu` beside it, so one listener can watch every menu. One payload shape for all of them, `MenuPayload` in `types.lua`: which menu, which row, and the row's current `value`. The `action` is `select`, `change`, `open`, `back`, `focus` or `close`.

### `focus`, and why it is opt-in

`focus` names the row the cursor has just moved onto, so a caller can follow the keyboard rather than wait for a choice. Set `reportFocus = true` in the spec to receive it; it is off by default, and a caller that leaves it off pays nothing.

- It is raised only where the cursor genuinely moved. A wrap onto the same row, a screen with one selectable row, and every other keystroke raise nothing.
- UP and DOWN raise it. Descending into a submenu and popping back out already report themselves as `open` and `back`, and raise no `focus` beside them.
- A held arrow key repeats every 55ms, so an opted-in handler runs at that cadence on a long list. Keep it cheap, and do not open, update or close the menu from it unless you mean to.

## Configuration

`config.lua`. Anchor, width, and how many rows are drawn at once.

## Locales

There is no `locales/` here and no `LOCALE` in `config.lua`, and that is deliberate: this resource renders the caller's own text, in whatever language the caller chose. The only strings it owns are `Open77.log` lines and the error codes, and neither is translated.

## Community & Support

Join the Open77 and Opx77 communities to discover the platform, share your projects, and connect with other developers.

<!-- TODO: replace with the final URLs before publication. -->

* [Open77](#)
* [Open77 GitHub](#)
* [OPX Discord](#)

## License

opx77_menu is licensed under the [**MIT License**](LICENSE).

Copyright © 2026 **Luis MOUTA**.

<p align="center">
    <sub>opx77_menu is an independent community project and is not affiliated with or endorsed by CD PROJEKT RED.</sub>
</p>
