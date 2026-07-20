# object-editor

[![license](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue)](LICENSE-APACHE) <img src="https://img.shields.io/github/repo-size/Bli-AIk/object-editor.svg"/> <img src="https://img.shields.io/github/last-commit/Bli-AIk/object-editor.svg"/>  
<img src="https://img.shields.io/badge/Lua-2C2D72?style=for-the-badge&logo=lua&logoColor=white"/> <img src="https://img.shields.io/badge/Kristal-3B3B3B?style=for-the-badge"/>

> 当前状态：开发可用

**object-editor** 是一个面向 Kristal v0.10.x 的开发期场景对象编辑器。它扩展 Kristal 的调试对象选择流程，提供拖拽、缩放、旋转、网格吸附、数值输入与撤销/重做。

| 简体中文 | English |
| --- | --- |
| 简体中文 | [English](README_en.md) |

## 安装

作为子模块安装到 Mod 的 `libraries/object-editor`：

```sh
git submodule add https://github.com/Bli-AIk/object-editor.git libraries/object-editor
git submodule update --init --recursive
```

在 Mod 的 `mod.json` 中启用开发期配置：

```jsonc
{
  "config": {
    "object-editor": {
      "enabled": true
    }
  }
}
```

推荐只在开发构建中启用。生产发行包应将 `enabled` 设为 `false`，并移除该目录。

## 配置

`lib.json` 提供以下可覆盖配置：

| 键 | 默认值 | 说明 |
| --- | ---: | --- |
| `snap_grid` | `1` | 位置网格步长。 |
| `snap_angle` | `5` | 旋转吸附角度。 |
| `snap_scale` | `0.1` | 缩放吸附步长。 |
| `fine_factor` | `0.1` | 精细调节倍率。 |
| `wheel_scale_step` | `0.1` | 滚轮缩放步长。 |
| `wheel_rotate_step` | `5` | 滚轮旋转步长。 |
| `max_undo` | `64` | 撤销和重做历史上限。 |

## 验证

```sh
luajit -e 'assert(loadfile("lib.lua"))'
```

## 许可证

本项目可任选以下许可证使用：

- [Apache License, Version 2.0](LICENSE-APACHE)
- [MIT License](LICENSE-MIT)
