# kristal-object-selector-plus

[![license](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue)](LICENSE-APACHE) <img src="https://img.shields.io/github/repo-size/Bli-AIk/kristal-object-selector-plus.svg"/> <img src="https://img.shields.io/github/last-commit/Bli-AIk/kristal-object-selector-plus.svg"/> <img src="https://img.shields.io/github/v/release/Bli-AIk/kristal-object-selector-plus.svg"/> <br>
<img src="https://img.shields.io/badge/Deltarune-001225?style=for-the-badge&labelColor=001225&logo=undertale&logoColor=ff0000" /> <img src="https://img.shields.io/badge/Lua-2C2D72?style=for-the-badge&logo=lua&logoColor=white" /> <img src="https://img.shields.io/badge/Kristal-FF6B35?style=for-the-badge&logo=love2d&logoColor=white" />

**kristal-object-selector-plus** is a development-time scene object editor for Kristal, letting you place and arrange items directly in the game.

Its interaction model is heavily influenced by **Blender**: select an object, press `G` to grab and drag it, `R` to rotate, `S` to scale.

[简体中文](README.md)

## Kristal Version Support

| `kristal`                                                                                                                     | `kristal-object-selector-plus` |
| ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| [v0.11.0-dev](https://github.com/KristalTeam/Kristal/commit/f62afea63ccab02f468c24ac0d096bd8a2c9aa81) (`f62afea`, 2026-08-16) | 0.2.1                          |
| [v0.10.0](https://github.com/KristalTeam/Kristal/commit/752bc0688ba97ca8a256ba9125b7e05a1ca6edbd) (`752bc068`, 2026-06-23)    | 0.1.0 – 0.2.0                  |

## Design

Kristal's debug mode already lets you select objects, but moving them means typing Lua commands in the console to change coordinates, or hot-reloading edited code — painful when you need to repeatedly align objects or fine-tune a UI. kristal-object-selector-plus introduces an undo/redo stack and upgrades the built-in debug object selector into direct manipulation:

- **`G` / `R` / `S`** — move / rotate / scale. Each key enters the corresponding transform mode (press again to exit); entering records the pre-transform state, `Esc` cancels at any time
- **`X` / `Y`** — lock a single axis during a transform; hold Shift and press an axis key to invert (exclude that axis)
- **Numeric input** — type digits during a transform for precise values, applied live: `G` then `32` moves 32 pixels, `.` for decimals, backspace to fix; the mouse stops interfering while typing
- **Snapping** — independent steps for position, rotation, and scale, all configurable
- **Mouse wheel** — quickly scale/rotate the selected object when idle; every notch lands in the undo history
- **Undo/redo** — `Ctrl+Z` / `Ctrl+Y` (also `Ctrl+Shift+Z`); continuous operations (held drags, wheel scrolling) merge into a single history entry when they end, so the stack never floods
- **Delete** — deletes the object, also undoable

Internally it is a small state machine (IDLE → GRAB / ROTATE / SCALE) with a dedicated undo/redo stack: a snapshot is taken when an operation starts and committed only when it ends, so every step rolls back cleanly.

## Install

Install it as a submodule at `libraries/kristal-object-selector-plus`:

```sh
git submodule add https://github.com/Bli-AIk/kristal-object-selector-plus.git libraries/kristal-object-selector-plus
git submodule update --init --recursive
```

Installing as a submodule is the **recommended** way, so the library stays versioned alongside your mod; you can also download the [release source](https://github.com/Bli-AIk/kristal-object-selector-plus/releases), or clone the latest code (rolling updates) and place it in `libraries/kristal-object-selector-plus`.

Enable it for development builds in `mod.json`:

```jsonc
{
  "config": {
    "kristal-object-selector-plus": { "enabled": true },
  },
}
```

Recommended for development builds only. Production packages should set `enabled` to `false` and omit the directory.

## Configuration

Overridable via `lib.json`:

| Key                 | Default | Description              |
| ------------------- | ------: | ------------------------ |
| `snap_grid`         |     `1` | Position grid step.      |
| `snap_angle`        |     `5` | Rotation snap angle.     |
| `snap_scale`        |   `0.1` | Scale snap step.         |
| `fine_factor`       |   `0.1` | Fine adjustment factor.  |
| `wheel_scale_step`  |   `0.1` | Wheel scale step.        |
| `wheel_rotate_step` |     `5` | Wheel rotation step.     |
| `max_undo`          |    `64` | Undo/redo history limit. |

## Verification

```sh
luajit -e 'assert(loadfile("lib.lua"))'
```

## License

Licensed under either of [Apache-2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT), at your option.
