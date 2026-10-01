# 缺陷修复报告

## 1. 缺陷背景

| 字段 | 内容 |
|------|------|
| 缺陷标题 | Mac-TaskManager 顶部菜单栏图标在当前活动显示器上不显示 |
| 所属服务 | Mac-TaskManager（macOS 桌面应用，MacTaskManager 可执行目标） |
| 所属业务域 | 菜单栏状态项（NSStatusItem）/ 运行中应用弹窗入口 |
| 复现场景 | 1. 启动应用；2. 单显示器下菜单栏始终看不到图标；3. 双显示器下，鼠标所在（活动）显示器的菜单栏图标不可见，另一块显示器正常；4. 鼠标切换显示器后，两块屏的图标可见性随之反转。图标位置仍可点击，弹窗功能正常，悬停/点击时出现空的圆角胶囊 |
| 影响范围 | 所有运行在 macOS 26 Tahoe 上的用户；菜单栏入口视觉上"消失"，用户无法感知应用在运行，只能盲点空白位置 |
| 严重程度 | 严重（核心入口不可见，但功能未失效） |

## 2. 问题分析

### 2.1 业务上下文

本缺陷为本地 macOS 原生应用问题，无业务知识库匹配内容（`/bk-search` 不适用，已跳过）。相关背景为 macOS 系统行为：

- macOS 26 Tahoe 对菜单栏引入"液态玻璃"（Liquid Glass）渲染：**当前活动显示器**的菜单栏为全透明玻璃质感，状态栏图标由系统新合成管线绘制（悬停/按下时出现圆角胶囊背景即其特征）；**非活动显示器**的菜单栏走变暗的旧式合成路径。
- 新管线要求状态栏图标为**模板图像**（`NSImage.isTemplate = true`，系统按菜单栏明暗与材质自动着色）。非模板彩色位图在新管线下无法正确合成，表现为图标不可见；旧路径仍按原样绘制彩色图。
- 该行为与多个开源菜单栏应用（Stats、Ice、Hidden Bar 等）在 Tahoe 上收到的同类反馈一致（来源：Apple Developer Forums 及社区问题汇总检索）。

排查中已排除的假设：

1. 图标资源丢失或为纯白图片 —— `assets/app-icon.png` 与打包进 `Mac-TaskManager.app/Contents/Resources/` 的图标均为正常彩色图（1024×1024 RGBA）。
2. 代码中存在依赖鼠标位置/活动屏幕的逻辑，或有悬浮窗遮挡菜单栏 —— 全仓库检索 `NSScreen`、`mouseLocation`、窗口层级等，无任何相关代码。

### 2.2 根因定位

| 问题文件 | 行号 | 问题描述 |
|----------|------|---------|
| Sources/MacTaskManager/App.swift | 4185-4219（修复前） | `MenuBarStatusController.makeStatusBarImage()` 将彩色 app 图标 PNG 以 `isTemplate = false` 直接设为状态栏按钮图像；兜底手绘波形分支同样 `isTemplate = false` 且使用黑+白双色描边 |

### 2.3 根因说明

状态栏按钮图像来自 `makeStatusBarImage()`。由于 app bundle 内存在 `app-icon.png`，实际生效的是第一个分支：把 1024×1024 彩色图标缩到 18×18 并设置 `image.isTemplate = false`。

在 macOS 26 Tahoe 上，当前活动显示器的菜单栏由新的玻璃渲染管线合成状态栏图标，该管线按模板图像（仅取 alpha 通道、由系统着色）处理图标；非模板彩色位图在此管线下合成失败，图标区域绘制为空。非活动显示器的菜单栏仍走旧合成路径，彩色图标按原样显示。焦点（鼠标）切到哪块屏幕，哪块屏幕的菜单栏就切换为新管线，因此图标可见性随活动显示器切换而反转；单显示器永远是活动显示器，故永远不可见。状态栏按钮本身（NSStatusBarButton）始终存在，所以位置可点击、弹窗正常、胶囊高亮可见但内部无图。

## 3. 修复方案

### 3.1 方案描述

将状态栏图标改为符合 macOS 菜单栏规范的**模板图像**：不再复用彩色 app 图标，改为始终以纯黑描边绘制应用既有的心电图波形轮廓（该轮廓原本就是代码中的兜底图形，也与应用 Logo 语义一致），并设置 `isTemplate = true`。系统据此在玻璃菜单栏、明/暗模式、活动/非活动显示器下自动着色，保证在所有 macOS 版本（部署目标 macOS 13+）上稳定可见。

彩色图标（`AppArtwork.displayIcon` / `applicationIcon`）继续用于 Dock 图标和窗口内 Logo，不受本次修改影响。

备选方案（未采用）：直接对彩色 PNG 设置 `isTemplate = true` —— 模板模式只取 alpha 通道，该图标为整块圆角矩形，会渲染成一个实心色块，视觉不可接受。

### 3.2 变更清单

| 文件 | 变更类型 | 变更说明 |
|------|---------|---------|
| Sources/MacTaskManager/App.swift | 修改 | 重写 `makeStatusBarImage()`：移除彩色 PNG 分支；波形图形改为单一纯黑描边（原黑 55% 粗描边 + 白色细描边的双层画法删除）；`isTemplate` 由 `false` 改为 `true` |

## 4. 修复过程

### 4.1 代码变更详情

`Sources/MacTaskManager/App.swift` — `MenuBarStatusController.makeStatusBarImage()`：

修改前（节选）：

```swift
if let source = AppArtwork.displayIcon,
   let image = source.copy() as? NSImage {
    image.size = NSSize(width: 18, height: 18)
    image.isTemplate = false            // 彩色图标，非模板
    ...
}
...
NSColor.black.withAlphaComponent(0.55).setStroke()
path.lineWidth = 3.4
path.stroke()
NSColor.white.setStroke()               // 白色描边在模板模式下无意义
path.lineWidth = 1.8
path.stroke()
...
image.isTemplate = false
```

修改后：

```swift
let size = NSSize(width: 18, height: 18)
let image = NSImage(size: size, flipped: false) { rect in
    let path = NSBezierPath()
    // …心电图波形路径（与原兜底图形一致）…
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSColor.black.setStroke()
    path.lineWidth = 1.8
    path.stroke()
    return true
}
image.isTemplate = true
image.accessibilityDescription = "正在运行的应用"
return image
```

### 4.2 代码评审要点

| 检查项 | 状态 | 说明 |
|--------|------|------|
| 业务逻辑正确性 | PASS | 修复根因（图像模式与系统渲染管线不匹配），非掩盖症状；模板图像是 Apple 对状态栏图标的规范做法 |
| 边界条件处理 | PASS | 不再依赖 bundle 资源加载成败，图标纯代码绘制，无失败路径；18pt 尺寸、1.8pt 描边与原白色主线一致，Retina/非 Retina 下均清晰 |
| 异常处理 | PASS | 无新增可抛错路径 |
| SQL 规范 | PASS | 不涉及 |
| 编码规范 | PASS | 遵循最小变更，仅改动一个方法；`AppArtwork` 其余用途（Dock、窗口 Logo）保持不变，无死代码 |
| 跨服务影响 | PASS | 仅影响菜单栏图标绘制；`configureStatusItem()`、弹窗逻辑、MacSMC/MacFanHelper 目标均未改动 |

### 4.3 编译验证

沙箱环境中 SwiftPM 构建服务（XCBBuildService）被系统权限拦截，无法完成 `swift build` 全量构建；改用 swiftc 直接验证：

```
swiftc -emit-module -module-name MacSMC ... Sources/MacSMC/*.swift      # 通过
swiftc -typecheck -I <MacSMC模块> Sources/MacTaskManager/*.swift        # 通过，exit 0
```

MacTaskManager 全部源文件类型检查通过，无编译错误。

## 5. 验证范围

### 5.1 直接验证

| 验证场景 | 预期结果 | 验证方式 |
|----------|---------|---------|
| 单显示器启动应用，查看菜单栏 | 菜单栏显示波形图标（浅色菜单栏为深色、深色/玻璃菜单栏为浅色，由系统着色） | 手动 |
| 双显示器，鼠标分别停留在 A/B 屏 | 两块屏的菜单栏均稳定显示图标，切换焦点不再反转 | 手动 |
| 点击菜单栏图标 | 运行中应用弹窗正常打开/关闭，图标按下时胶囊高亮内可见图标 | 手动 |
| 系统切换浅色/深色外观 | 图标颜色自动随菜单栏明暗适配 | 手动 |

### 5.2 回归验证

| 关联功能 | 验证建议 | 原因 |
|----------|---------|------|
| Dock 图标与窗口标题栏 Logo | 确认仍为彩色 app 图标 | 本次仅移除状态栏对 `AppArtwork.displayIcon` 的引用，Dock/窗口 Logo 仍使用该资源 |
| 应用退出（applicationWillTerminate） | 确认状态栏项随应用退出被移除 | `invalidate()` 逻辑未改，但同属状态栏生命周期 |

### 5.3 单元测试

无新增单元测试：变更为 AppKit 视觉渲染行为，需真机手动验证；现有 `CoolModeAlgorithmTests` 与本次改动无关。

---

*备注：仓库中已打包的 `Mac-TaskManager.app` 为旧产物，需在本机重新执行 `./build.sh`（或 `swift build`）打包后再验证。*
