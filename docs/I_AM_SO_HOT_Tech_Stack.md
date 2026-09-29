# I AM SO HOT — 技术选型与发布策略

## 1. 文档目的

在 v0.1 编码开始前，固化以下决策：

1. 语言、框架与工程结构。
2. 关键技术点（温度读取、进程采集、App 归属）的实现选型。
3. 本地开发与调试方式。
4. 签名、公证、分发与自动更新链路。

决策前提：产品原则 **"A thermal monitor should not generate thermal problems"**（见 PRD §4.4），任何选型都必须过性能预算。

---

## 2. 语言与 UI 框架

| 决策项 | 选择 | 理由 |
|---|---|---|
| 语言 | **Swift** | Mach API（`proc_pidinfo` / `task_info`）、IOKit（温度）、`NSRunningApplication`、`ProcessInfo.thermalState` 均为 Swift 一等公民场景 |
| 菜单栏骨架 | **AppKit** | `NSStatusItem` / `NSPopover` 是 AppKit 专属，菜单栏工具绕不开 |
| Popover 内部 UI | **SwiftUI** | 面板为简单列表 + 按钮，~1Hz 刷新无压力；如遇性能问题降级为 NSStackView |
| 不选 | Electron / RN macOS / Catalyst | 与自身性能预算（后台 CPU < 0.3%、Memory < 50 MB）直接冲突 |

### 最低系统版本

- 目标：**macOS 14 Sonoma+**（Apple Silicon 优先；Intel Mac 不做主动适配，但不刻意屏蔽）

---

## 3. 工程结构

Xcode Workspace + App 工程 + SwiftPM 本地包分层（已初始化）：

```text
IAmSoHot.xcworkspace/         # 开发入口（成员：App 工程 + ThermalCore 包）
IAmSoHot.xcodeproj/           # App Target：com.jzhishu.iamsohot，LSUIElement
IAmSoHot/                     # App 源码
├── IAmSoHotApp.swift         # @main AppDelegate
├── MenuBarController.swift   # NSStatusItem + NSPopover
└── Popover/PopoverView.swift # SwiftUI 面板

Packages/
└── ThermalCore/              # SPM 本地包：纯逻辑，不依赖 UI
    ├── Sources/ThermalCore/
    │   ├── Sensor/           # 温度、Total CPU、thermalState
    │   ├── Collector/        # Process Collector
    │   ├── Resolver/         # Process → App 归属
    │   ├── Aggregator/       # App 聚合
    │   ├── ThermalEngine/    # Power Score / Heat Reservoir / Share / +°C
    │   └── Scheduler/        # SLEEP / WATCH / LIVE 自适应采样
    └── Tests/ThermalCoreTests/
```

> 注意：必须通过 **workspace** 构建（`xcodebuild -workspace IAmSoHot.xcworkspace`），
> 单独 `-project` 构建无法解析本地包产品。

原则：

- ThermalCore **不 import AppKit/SwiftUI**，采集与模型可单元测试。
- UI 层只消费 ViewModel，不触发重型采样（技术方案 §19）。
- 依赖管理：SwiftPM，尽量少依赖；预期第三方依赖仅 **Sparkle 2**。

---

## 4. 关键技术点选型

### 4.1 温度读取（本项目最大技术风险，见技术方案 §23）

Apple Silicon 无公开温度 API，可选路径：

| 方案 | 说明 | 结论 |
|---|---|---|
| `IOHIDEventSystemClient` 私有 API | Stats / Hot / SMCKit 等开源软件的通行做法，Apple Silicon 上覆盖好 | ✅ **v0.1 采用** |
| SMC（`AppleSMC`） | Apple Silicon 上键值体系与 Intel 完全不同，覆盖差 | 备选 |
| `ProcessInfo.thermalState` | 只有 4 档状态，无温度值 | 兜底 + sanity check |

风险隔离措施：

- 封装 `TemperatureProvider` 协议，IOHID 实现只是其中一个 provider。
- 温度读取失败时 UI 降级为只显示 thermalState，不影响其他功能。
- 参考实现：SMCKit、Hot、Stats（均为开源，可读源码验证）。

### 4.2 进程与负载采集

- `libproc`：`proc_listallpids` / `proc_pidinfo`（PID、PPID、路径、CPU time）。
- `host_processor_info` / `host_statistics`：Total CPU。
- **生产主循环不使用 `powermetrics`**（需 root、开销大）；仅开发期用于校准与 ground truth 对照（技术方案 §5.1）。
- GPU / Wakeups / IO：v0.1 可缺失，按 Roadmap v0.5 再加入。

### 4.3 App 归属

按技术方案 §4.3 的匹配优先级实现：

```text
NSRunningApplication → Bundle path → PPID 链 → responsible PID / coalition
→ helper 规则 → 系统规则 → Unknown/Other
```

带 `confidence` + `method`，PID → AppID 缓存，事件驱动失效。

### 4.4 退出 App

`NSRunningApplication.terminate()`，系统关键进程不提供 Quit（技术方案 §16）。

---

## 5. 本地开发与调试

### 5.1 环境

- macOS 15+ / Xcode 16+。
- **必须真机 Apple Silicon**：模拟器无温度传感器，温度链路无法验证。

### 5.2 调试手段

- **日志**：`os_log`，按 subsystem 分类（`sensor` / `resolver` / `thermal` / `scheduler`），Console.app 过滤。
- **已踩过的坑**（v0.1 实测）：
  1. Xcode 26 的 Debug Dylib 特性会让 Debug 二进制变成空壳（`__debug_blank_executor_main`），CLI 验证需 `xcodebuild ... ENABLE_DEBUG_DYLIB=NO`；在 Xcode 里 Run 无此问题。
  2. `@main` + `NSApplicationDelegate` 在直接执行二进制时 `applicationDidFinishLaunching` 不触发 → 使用显式 `main.swift`。
  3. `proc_taskinfo.pti_total_*` 单位是 **mach absolute time**（Apple Silicon 125/3 ns/tick），需 `mach_timebase_info` 换算。
- **DEBUG CSV 导出**：`/tmp/iamsohot-debug.csv`，每次 tick 记录 mode/temp/cpu/baseline/top_app，用于对照实测温度曲线校准 τ。
- **自监控 Debug 面板**（Debug 构建专属，隐藏入口）：
  - 自身 CPU / Memory / Wakeups
  - 归属缓存命中率、归属 method 分布
  - 当前采样模式（SLEEP / WATCH / LIVE）与切换记录
- **热模型调参**：Debug 开关将 `H_i` / Share / Baseline / 实测温度按采样点导出 CSV，对照温度曲线校准 τ。
- **性能验证**：Instruments（Time Profiler / Energy Log / System Trace）+ `powermetrics`，按技术方案 §21 的 Idle / Load / Self-impact 三场景执行。

### 5.3 测试

- ThermalCore 纯逻辑用 XCTest：
  - 热水库衰减（`H(t) = H(t-1)·e^(-Δt/τ) + P(t)·Δt`）
  - Heat Share / Estimated +°C 计算
  - 归属规则匹配（含 Chrome Helper 聚合用例）
  - 采样模式升降级状态机
- 采集层通过协议 mock，不依赖真实进程环境。

---

## 6. 发布与交付

### 6.1 关键结论：不走 Mac App Store

App Store 沙盒禁止：枚举其他进程、读取温度传感器私有 API、terminate 其他 App——本产品三项核心能力全部与沙盒冲突。

→ **Developer ID 直连分发。**

### 6.2 交付链路

```text
Xcode Archive
  → Developer ID Application 签名（Hardened Runtime）
  → xcrun notarytool 公证 + stapler 装订
  → 打包 DMG（create-dmg）
  → GitHub Releases / 官网下载
  → Sparkle 2 自动更新（EdDSA 签名 appcast）
```

要点：

1. **签名**：Developer ID Application 证书 + Hardened Runtime；若温度/进程调用需要，按需追加 `com.apple.security.cs.*` entitlement（实测后再定，保持最小授权）。
2. **公证**：`xcrun notarytool submit --wait` + `xcrun stapler staple`，脚本化。
3. **自动更新**：Sparkle 2，appcast 托管于 GitHub Pages / 仓库 Release。
4. **前置条件**：Apple Developer Program 账号（$99/年）。

### 6.3 发布节奏（对齐 Roadmap）

| 阶段 | 渠道 |
|---|---|
| v0.1 – v0.3 | GitHub Releases 公开 beta，重点收集 App 归属准确率反馈 |
| v0.5 起 | 简单官网落地页 + Sparkle 全量推送 |
| v1.0 | 正式发布 |

### 6.4 CI/CD

- GitHub Actions macOS runner：跑 ThermalCore 测试 + Archive。
- 签名证书 / notarytool 凭据 / Sparkle 私钥存 GitHub Secrets。
- v0.1 阶段允许手工 Archive，CI 自动化在 v0.2 前补齐。

---

## 7. 已确认决策记录

| # | 决策 | 结论 |
|---|---|---|
| 1 | 温度读取接受 IOHID 私有 API | ✅ 接受（同类开源软件通行做法，协议隔离风险） |
| 2 | 分发方式 | ✅ Developer ID + 公证 + Sparkle 直连分发，不上 Mac App Store |
| 3 | Popover UI | ✅ SwiftUI |
| 4 | 工程结构 | ✅ Xcode App + ThermalCore SPM 本地包 |
| 5 | 最低系统版本 | macOS 14+，Apple Silicon 优先 |

---

## 8. 待办（工程初始化时执行）

1. ~~创建 Xcode 工程 + ThermalCore SPM 包骨架~~（已完成：workspace + 工程 + 15 个单元测试）
2. 确定签名 Team（Bundle ID 已定：com.jzhishu.iamsohot）。
3. 验证 IOHID 温度读取在目标机型上的可用性（Phase 1 的第一步）。
4. 搭建 Debug 自监控面板。
5. 注册 Apple Developer Program（如尚未拥有，发布前才需要）。
