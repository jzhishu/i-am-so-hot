# AGENTS.md — I AM SO HOT

> 本文件是 AI Coding Agent 在本仓库工作时的项目说明与文档索引。
> 新会话开始时请先阅读本文件，再按需查阅 `docs/` 下的详细文档。

---

## 1. 项目概述

**I AM SO HOT** 是一款 macOS 菜单栏常驻轻量工具（首版优先支持 Apple Silicon），核心定位是回答一个问题：

> **到底是谁把我的 Mac 搞热了？**

产品能力：

1. 菜单栏持续显示当前设备温度（只显示数字，如 `78°`）。
2. 点击后在克制风格的面板中展示 App 级热源排名。
3. 将底层进程（Helper / Renderer / XPC 等）聚合为用户可识别的 App。
4. 以 Relative Heat / Heat Share / 实验性 Estimated `+X°C` 展示热贡献。
5. 支持从面板中正常退出（Quit）高热 App。

产品**不是**一个更漂亮的 Activity Monitor，而是软件级热量归因工具。

---

## 2. 仓库结构

```text
i-am-so-hot/
├── AGENTS.md               # 本文件：Agent 说明 + 文档索引
├── IAmSoHot.xcworkspace/   # 开发入口：App 工程 + ThermalCore 包
├── IAmSoHot.xcodeproj/     # App 工程（com.jzhishu.iamsohot，LSUIElement 菜单栏 App）
├── IAmSoHot/               # App 源码（AppDelegate / MenuBarController / Popover）
├── Packages/
│   └── ThermalCore/        # SPM 本地包：Sensor/Collector/Resolver/ThermalEngine/Scheduler
│       ├── Sources/ThermalCore/
│       └── Tests/ThermalCoreTests/
└── docs/                   # 产品与技术文档
    ├── I_AM_SO_HOT_PRD.md
    ├── I_AM_SO_HOT_Technical_Design.md
    ├── I_AM_SO_HOT_Roadmap.md
    └── I_AM_SO_HOT_Tech_Stack.md
```

> **开发入口是 `IAmSoHot.xcworkspace`**（workspace 成员包含 App 工程与 ThermalCore 包）。
> 常用命令：
> - 构建：`xcodebuild -workspace IAmSoHot.xcworkspace -scheme IAmSoHot build`
> - 单元测试：`swift test --package-path Packages/ThermalCore`

---

## 3. 技术要点速览（详见技术方案文档）

- **平台**：macOS 14+（Apple Silicon 优先），Swift + AppKit（NSStatusItem/NSPopover）+ SwiftUI 面板；详见[技术选型与发布策略](docs/I_AM_SO_HOT_Tech_Stack.md)。
- **架构**：Sensor Core → Cheap Monitor / Event Monitor → Process Collector → App Resolver → App Aggregator → Thermal Engine → UI State。原则：默认低成本，必要时才进入详细分析。
- **自适应采样**：`SLEEP`（5–10s 低频）→ `WATCH`（2–3s，温度升高）→ `LIVE`（面板打开，~1Hz），关闭面板自动降级。
- **热量模型**：Power Score（v0.1 可只用 CPU）→ 热记忆水库 `H(t) = H(t-1)·e^(-Δt/τ) + P(t)·Δt` → Heat Share → Estimated `+°C` = Share × (当前温度 − 动态 Baseline)。
- **App 归属**：PID → NSRunningApplication → Bundle path → PPID 追溯 → responsible PID / coalition → 规则兜底（macOS / Other），带 confidence + method，并做缓存。
- **Quit**：优先 `NSRunningApplication.terminate()`，系统关键进程不可 Quit，首版不做一级 Force Quit。

---

## 4. 产品原则（写代码 / 改方案时必须遵守）

1. **面向用户，而不是面向进程**：展示 Chrome / Cursor / Docker，而不是 PID 与 Helper 进程名。
2. **克制**：菜单栏只有数字；面板无动画、无火焰特效、无 60fps 图表、无复杂渐变。
3. **可解释**：所有 `+X°C` 必须标注 `Estimated`，不得描述为实测值；Heat Share 是首版最可信指标。
4. **监控软件不能成为热源**：A thermal monitor should not generate thermal problems. 任何新指标都要过性能预算。
5. **先做相对归因，再做绝对温度估算**。
6. **采集成本 > 模型计算成本**：合并 timer、批量采样、缓存归属结果，让 CPU 尽快回到 idle。

### 性能预算（工程目标）

| 状态 | CPU avg | GPU | Memory | Disk write | UI 刷新 |
|---|---|---|---|---|---|
| 后台 / SLEEP | < 0.2–0.3% | 0% | < 50 MB | ≈ 0 | 仅值变化时 |
| 面板打开 / LIVE | < 1% | ≈ 0% | — | — | ~1Hz |

---

## 5. 当前版本目标（v0.1 Core MVP）

必须交付：

1. 菜单栏常驻，只显示温度数字。
2. 克制的下拉面板（当前温度 + 热状态 + App 热源排名 + Quit）。
3. Process → App 识别与聚合（Chrome 多进程 → Google Chrome）。
4. CPU 为核心的 Heat Share + 实验性 Estimated `+X°C`。
5. SLEEP / WATCH / LIVE 自适应采样。
6. 普通 App 的 Quit（terminate），系统进程保护。
7. 满足性能预算，自身不出现在热源榜前列。

**v0.1 明确不做**：历史记录、温度预测、What-if、GPU 强依赖、Chrome Tab 级识别、Force Quit、ML、多平台。

开发顺序（来自技术方案）：

```text
Phase 1 Collector（温度 / Total CPU / per-process CPU）
→ Phase 2 Resolver（PID → App + 缓存）
→ Phase 3 Relative Heat（先验证排序可信）
→ Phase 4 Estimated +°C（baseline + 热记忆）
→ Phase 5 Adaptive Monitoring（三种采样模式）
→ Phase 6 Quit（terminate + 系统保护）
```

---

## 6. 版本路线图摘要

| 版本 | 核心目标 |
|---|---|
| v0.1 | 看温度、看热源、Quit（Core MVP） |
| v0.2 | 稳定、省电、App 归属更准（Reliability） |
| v0.3 | Heat Share / 热记忆模型（Heat Attribution） |
| v0.5 | 动态 Baseline / GPU / 设备自校准 / 历史（Calibration） |
| v0.8 | 降温预测 Preview / What if I quit this? |
| v1.0 | 完整预测型 Thermal Monitor |
| v1.x | Chrome Tab 归因、Electron 子任务、Estimated Watts、高级诊断等（Research） |

新功能评估四问：是否帮助回答「为什么我的 Mac 热」？是否增加常驻开销？是否让 UI 更复杂？是否提高可信度？（可信度 > 功能多）

---

## 7. 文档索引

| 文件 | 说明 | 何时阅读 |
|---|---|---|
| [docs/I_AM_SO_HOT_PRD.md](docs/I_AM_SO_HOT_PRD.md) | 产品需求文档：产品定位、目标用户、信息架构、App 归因、Quit、自适应采样、MVP 范围、成功标准 | 做任何功能 / UI 决策前 |
| [docs/I_AM_SO_HOT_Technical_Design.md](docs/I_AM_SO_HOT_Technical_Design.md) | 技术方案：模块架构、App 归属算法、采集与调度策略、热模型公式、Estimated +°C、校准、性能预算与验证、开发顺序、技术风险 | 写代码 / 改架构前必读 |
| [docs/I_AM_SO_HOT_Roadmap.md](docs/I_AM_SO_HOT_Roadmap.md) | 版本路线图：v0.1 → v1.0 各版本目标、验收标准、明确不做的功能、发布节奏 | 评估新需求归属版本时 |
| [docs/I_AM_SO_HOT_Tech_Stack.md](docs/I_AM_SO_HOT_Tech_Stack.md) | 技术选型与发布策略：Swift + AppKit/SwiftUI、工程结构、温度/进程采集选型、调试方式、Developer ID 分发与 Sparkle 更新链路、已确认决策 | 工程初始化、选型有疑问、准备发布时 |

---

## 8. 给 Agent 的工作约定

- **文档优先**：需求不明时先查 PRD；实现方案不明时先查技术方案；是否该做某功能先查 Roadmap。
- **与文档冲突时**：不要擅自偏离既定方案，先向用户确认是改文档还是改实现，并保持文档与代码同步。
- **性能敏感**：任何增加采样频率、新增指标、新增 Timer 的改动，都必须对照性能预算说明理由。
- **UI 克制**：不主动添加动画、图表、颜色装饰；信息优先级高于视觉效果。
- **术语统一**：`Heat Share`、`Estimated +°C`、`Baseline`、`SLEEP / WATCH / LIVE`、`macOS / Other` 归类等术语与文档保持一致。
- **语言**：代码注释与文档使用中文（与现有文档一致）；代码标识符使用英文。
