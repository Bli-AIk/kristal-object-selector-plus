# kristal-object-selector-plus

[![license](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue)](LICENSE-APACHE) <img src="https://img.shields.io/github/repo-size/Bli-AIk/kristal-object-selector-plus.svg"/> <img src="https://img.shields.io/github/last-commit/Bli-AIk/kristal-object-selector-plus.svg"/> <img src="https://img.shields.io/github/v/release/Bli-AIk/kristal-object-selector-plus.svg"/> <br>
<img src="https://img.shields.io/badge/Deltarune-001225?style=for-the-badge&labelColor=001225&logo=undertale&logoColor=ff0000" /> <img src="https://img.shields.io/badge/Lua-2C2D72?style=for-the-badge&logo=lua&logoColor=white"/> <img src="https://img.shields.io/badge/Kristal-3B3B3B?style=for-the-badge"/>

**kristal-object-selector-plus** 是一个面向 Kristal v0.11.0-dev（`f62afea`）开发期的场景对象编辑器，让你直接在游戏里摆放物品。

它的交互方式深受 **Blender** 的影响：选中一个对象，按 `G` 抓起来拖、按 `R` 转、按 `S` 缩放。

| 简体中文 | English                 |
| -------- | ----------------------- |
| 简体中文 | [English](README_en.md) |

## Kristal 版本支持

| `kristal`                                                                                                                          | `kristal-object-selector-plus` |
| ---------------------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| [v0.11.0-dev](https://github.com/KristalTeam/Kristal/commit/f62afea63ccab02f468c24ac0d096bd8a2c9aa81) (`f62afea`, 2026-08-16) | 0.2.0                          |

## 设计思路

Kristal 的调试模式自带对象选中，但调整位置只能控制台打 Lua 改坐标，或改代码热更新——需要反复对轴、反复调整某些界面时非常不友好。kristal-object-selector-plus 引入了撤销/重做栈，是对内置 debug 对象选择器的进一步升级和拓展，把「选中对象 → 直接操作」补了回来：

- **`G` / `R` / `S`** —— 移动 / 旋转 / 缩放。三键进入对应变换模式，再按一次退出；进入时自动记录操作前状态，`Esc` 随时取消
- **`X` / `Y`** —— 变换期间锁定单个轴；先按 Shift 再按轴键则反选（排除该轴）
- **数字输入** —— 变换中直接敲数字精确指定，实时生效：`G` 后输入 `32` 就是移动 32 像素，`.` 输小数，退格修正，输入状态下鼠标不再干扰
- **吸附** —— 位置、角度、比例各有独立步长，均可配置
- **滚轮** —— 空闲时对选中对象快速缩放/旋转，每次滚动都计入撤销
- **撤销/重做** —— `Ctrl+Z` / `Ctrl+Y`（也支持 `Ctrl+Shift+Z`）；连续操作（按住拖拽、滚轮连滚）只在结束时合并成一条历史，不会刷爆撤销栈
- **Delete** —— 删除对象，同样可撤销

实现上是一台小状态机（IDLE → GRAB / ROTATE / SCALE）加独立的撤销/重做栈：每次操作开始前拍快照，结束后才提交，保证每一步都能干净地回退。

## 安装

作为子模块安装到 Mod 的 `libraries/kristal-object-selector-plus`：

```sh
git submodule add https://github.com/Bli-AIk/kristal-object-selector-plus.git libraries/kristal-object-selector-plus
git submodule update --init --recursive
```

以子模块方式安装为**建议方式**，便于跟随版本更新；也可以直接下载 [Release 源码](https://github.com/Bli-AIk/kristal-object-selector-plus/releases)，或克隆仓库最新代码（滚动更新）后放入 `libraries/kristal-object-selector-plus`。

在 Mod 的 `mod.json` 中启用开发期配置：

```jsonc
{
  "config": {
    "kristal-object-selector-plus": {
      "enabled": true,
    },
  },
}
```

推荐只在开发构建中启用。生产发行包应将 `enabled` 设为 `false`，并移除该目录。

## 配置

`lib.json` 提供以下可覆盖配置：

| 键                  | 默认值 | 说明                 |
| ------------------- | -----: | -------------------- |
| `snap_grid`         |    `1` | 位置网格步长。       |
| `snap_angle`        |    `5` | 旋转吸附角度。       |
| `snap_scale`        |  `0.1` | 缩放吸附步长。       |
| `fine_factor`       |  `0.1` | 精细调节倍率。       |
| `wheel_scale_step`  |  `0.1` | 滚轮缩放步长。       |
| `wheel_rotate_step` |    `5` | 滚轮旋转步长。       |
| `max_undo`          |   `64` | 撤销和重做历史上限。 |

## 验证

```sh
luajit -e 'assert(loadfile("lib.lua"))'
```

## 许可证

本项目可任选以下许可证使用：

- [Apache License, Version 2.0](LICENSE-APACHE)
- [MIT License](LICENSE-MIT)
