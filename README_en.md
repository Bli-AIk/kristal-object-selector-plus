# object-editor

[![license](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue)](LICENSE-APACHE)

**object-editor** is a development-time scene object editor for Kristal v0.10.x. It adds drag, scale, rotation, snapping, numeric input, and undo/redo to Kristal's debug object workflow.

[简体中文](README.md)

## Install

```sh
git submodule add https://github.com/Bli-AIk/object-editor.git libraries/object-editor
git submodule update --init --recursive
```

Enable it only for development builds in `mod.json`:

```jsonc
{
  "config": {
    "object-editor": {"enabled": true}
  }
}
```

Production packages should disable the library and omit its directory.

## License

Licensed under either of [Apache-2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT), at your option.
