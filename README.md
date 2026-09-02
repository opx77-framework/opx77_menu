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
| `status` | write a transient line under the list |
| `keys` | the keys that drive the menu, for a caller printing its own hint |
| `state` | whether a menu is open and whether it is yours |

Types for every spec, payload and response are in `types.lua`.

### Rules a caller needs

- One menu at a time. `open` answers `menu_busy` when another resource owns the open one,
  unless the spec sets `steal = true`.
- `update`, `close` and `status` answer `not_owner` unless the open menu is yours.
- `state` reports only `open` and `mine` for a menu you do not own.
- The menu closes itself when its owner stops or reloads, within a second.
- Every event is raised on the item's or menu's own `event` name and on `opx77:menu` beside
  it, so one listener can watch every menu.
- The `status` line clears itself after six seconds; `status(nil)` clears it now.
- Limits, all refusals rather than truncations: 200 items per level, 8 levels deep, 400
  items in the whole tree, and a `data` table of at most 64 nodes — keys count as well as
  values — nested at most 4 deep.
- Escape closes the open menu, and the menu stands down whenever another surface has the
  keyboard.

## Configuration

`config.lua`. Anchor, width, and how many rows are drawn at once.

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
