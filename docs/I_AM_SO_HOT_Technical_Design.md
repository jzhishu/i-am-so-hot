# I AM SO HOT — 技术方案文档

## 1. 技术目标

首版技术目标：

1. 在 macOS 上以极低开销获取设备温度与总体负载。
2. 将系统进程稳定映射到用户可理解的 App。
3. 聚合每个 App 的资源使用。
4. 建立可解释、可校准的热量归因模型。
5. 在保证低 CPU、低 Wakeup、低 IO 的前提下运行。
6. 支持从工具中正常退出普通 App。

首版优先：

**macOS + Apple Silicon**

---

## 2. 总体架构

```text
                I AM SO HOT

              Sensor Core
                   │
       ┌───────────┴───────────┐
       │                       │
 Cheap Monitor           Event Monitor
 Temp / Total CPU        App launch/quit
 Thermal State           Process changes
       │                       │
       └───────────┬───────────┘
                   │
             Need analysis?
              │          │
             No         Yes
              │          │
            Sleep   Process Collector
                         │
                    App Resolver
                         │
                    App Aggregator
                         │
                    Thermal Engine
                         │
                      UI State
```

核心原则：

> 默认低成本，必要时才进入详细分析。

---

## 3. 模块划分

### 3.1 Sensor Core

负责获取：

- 当前主要温度
- 总 CPU
- 可选 GPU
- thermalState
- 设备型号
- 电源状态

采集必须分层，避免所有数据同频读取。

### 3.2 Process Collector

负责每次详细采样时获得：

- PID
- PPID
- process name
- executable path
- CPU time / delta
- 可选 GPU time
- wakeups
- 可选 IO

首版优先 CPU，GPU / Wakeups / IO 可分阶段加入。

### 3.3 App Resolver

负责：

`Process → User-facing App`

### 3.4 App Aggregator

将同一 App 下所有进程聚合：

```text
Chrome Main
Chrome Helper
Chrome Renderer
Chrome GPU Process
```

变为：

```text
Google Chrome
```

### 3.5 Thermal Engine

负责：

- App Power Score
- Heat Reservoir
- Heat Share
- Estimated `+°C`
- Baseline
- 模型校准

### 3.6 Menu Bar UI

只消费已经计算好的 ViewModel，不在 UI 层做资源分析。

---

## 4. App 归属算法

### 4.1 输入

```text
ProcessSample
├── pid
├── ppid
├── executablePath
├── processName
├── cpuDelta
├── gpuDelta
├── wakeups
└── io
```

### 4.2 App Registry

通过 macOS App 层建立：

```text
AppIdentity
├── rootPid
├── bundleID
├── localizedName
├── bundlePath
├── executablePath
└── icon
```

### 4.3 匹配优先级

按以下顺序：

1. PID 直接对应已知 NSRunningApplication。
2. executable path 位于某 `.app` Bundle 内。
3. 向上追 PPID，找到可识别 App。
4. 使用 responsible PID / process coalition。
5. 已知 helper / framework 规则。
6. 系统进程规则。
7. Unknown / Background Process。

### 4.4 归属结果

```text
ProcessOwnership
├── appID
├── confidence
└── method
```

示例：

```text
Chrome Renderer
→ Google Chrome
confidence: 1.00
method: sameBundle

Cursor Helper
→ Cursor
confidence: 0.98
method: bundle + ancestor

Unknown XPC Service
→ Photoshop
confidence: 0.82
method: responsiblePID
```

### 4.5 缓存

昂贵归属逻辑只在以下事件发生时运行：

- 新 PID 出现。
- App 启动。
- App 退出。
- PID reuse（v0.2 已实现：进程启动时间戳 `pbi_start_tvsec` 变化 →
  仅失效该 PID 缓存 `invalidateCache(for:)`，同时保护 CPU 差分不被复用污染）。
- 缓存失效。

后续采样直接：

`PID → cached AppID`

避免重复：

- 文件系统扫描。
- Bundle metadata 读取。
- Icon 加载。
- PPID traversal。

---

## 5. 资源采集策略

### 5.1 不使用持续全量重型采样

开发阶段可使用 `powermetrics`：

- 验证 CPU/GPU/energy 指标。
- 校准热模型。
- 对比 responsible PID / coalition。
- 做 ground truth 近似参考。

生产主循环不应依赖高频完整 `powermetrics --show-all`。

### 5.2 生产版优先数据

优先使用：

- Mach / proc statistics
- NSWorkspace
- NSRunningApplication
- ProcessInfo
- 轻量温度读取方式

### 5.3 首版优先级

必须：

- Total CPU
- Per-process CPU
- Temperature
- Thermal state

增强：

- GPU
- Wakeups

后续：

- Disk IO
- Network

理由：

绝大多数显著发热场景已经可通过 CPU / GPU 捕获。

---

## 6. 自适应采样

### 6.1 SLEEP

条件：

- 面板关闭。
- 温度正常。
- Total CPU 较低。
- thermalState nominal。

建议：

- 5–10 秒采样。
- 只采总体 CPU、温度、thermal state。
- 不做完整 per-process attribution。

### 6.2 WATCH

触发：

- 温度超过动态阈值。
- Total CPU / GPU 明显升高。
- `dT/dt` 明显为正。
- thermalState 变化。

建议：

- 2–3 秒一次。
- 启用详细进程采样。
- 聚合 App。
- 更新 Heat Share。

### 6.3 LIVE

触发：

- 用户打开菜单栏 Popover。

建议：

- App 排名：约 1 秒。
- 热模型：约 1 秒。
- 温度：2–5 秒。
- GPU / IO：2–5 秒或更慢。

关闭面板后降级。

---

## 7. 调度策略

不要为不同指标创建大量独立高频 Timer。

错误示例：

```text
CPU timer         1.0s
GPU timer         1.3s
Temp timer        2.0s
UI timer          0.5s
IO timer          1.7s
```

正确方向：

```text
Single Scheduler

tick
│
├── CPU
├── process delta
├── thermal model
├── UI state
│
├── every N ticks → temperature
├── every M ticks → GPU
└── every K ticks → secondary metrics
```

目标：

- 合并 wakeups。
- 批量完成工作。
- 让 CPU 尽快重新 idle。

---

## 8. App Power Score

首版不直接声称获得真实瓦数。

定义：

\[
P_i(t)
=
w_c C_i
+
w_g G_i
+
w_w W_i
+
w_{io} IO_i
\]

其中：

- \(C_i\)：CPU activity
- \(G_i\)：GPU activity
- \(W_i\)：wakeups
- \(IO_i\)：IO activity

v0.1 可以简化为：

\[
P_i(t)
=
w_c C_i
+
w_g G_i
\]

若 GPU 获取成本较高，首版甚至可先：

\[
P_i(t)=C_i
\]

然后逐步增强。

### 8.1 初始权重

权重不是物理常数。

只用于首版相对归因，必须通过实测校准。

---

## 9. 热记忆模型

### 9.1 为什么需要热记忆

App 停止工作后：

- CPU 可以立刻下降。
- 设备温度不会立刻下降。

所以 App 热贡献不能直接等于当前 CPU。

### 9.2 单时间常数

\[
H_i(t)
=
H_i(t-1)e^{-\Delta t/\tau}
+
P_i(t)\Delta t
\]

其中：

- \(H_i\)：App 当前热储量。
- \(P_i\)：App 当前 Power Score。
- \(\tau\)：散热时间常数。

### 9.3 双时间常数

推荐后续升级：

\[
H_i
=
aH_{fast,i}
+
(1-a)H_{slow,i}
\]

\[
H_{fast}(t)
=
H_{fast}(t-1)e^{-dt/\tau_f}
+
P_i(t)
\]

\[
H_{slow}(t)
=
H_{slow}(t-1)e^{-dt/\tau_s}
+
P_i(t)
\]

初始可尝试：

```text
τ_fast ≈ 10–20s
τ_slow ≈ 60–120s
```

参数必须以真实设备实验为准。

---

## 10. Heat Share

计算：

\[
Share_i
=
\frac{H_i}
{\sum_j H_j}
\]

例如：

```text
Chrome       39%
Cursor       21%
Docker       10%
macOS        20%
Other        10%
```

Heat Share 应作为首版最可信指标。

---

## 11. Baseline

> **v2 修订（2026-09-30）**：本节替代原「idle 温度 EMA」方案。
> 原方案无物理锚点：会出现 baseline 高于实测温度、被负载后的降温尾巴污染、
> 收敛速度追不上实际降温等问题（v0.1 截图走查实测确认）。

### 11.1 定义

Baseline：

> 当前设备在相同环境下、没有显著高负载软件时的预计温度。

### 11.2 传感器分层（v2 的物理基础）

Apple Silicon 通过 IOHID 暴露多个温度传感器，实测分两层：

- **快层**（die 传感器，如 `PMU tdie*` / `PMU TP*`）：SoC 核心温度，随负载秒级波动。
  作为「当前温度」主指标。
- **慢层**（电池/机身传感器，如 `gas gauge battery`、部分 `tdev`）：
  随环境分钟级漂移，几乎不受瞬时负载影响，实测比 die 低约 8–10°C。
  作为 baseline 的物理锚点。

### 11.3 计算

\[
B(t) = T_{slow}(t) + \delta
\]

- \(T_{slow}\)：慢层锚点。取非 die、非校准类（tcal）传感器的最低值，多传感器取最低可自然剔除电池充电发热等异常。
- \(\delta\)：die 与慢层在确认 idle 且温度稳定时学习到的偏移量（本机约 9°C），EMA 慢速更新，并钳制在合理区间（如 2–15°C）。

无慢层传感器的设备（如 Intel Mac）退化为不对称 EMA（§11.4 同规则，直接作用于 B）。

### 11.4 不对称跟踪（结构性保证）

物理上 baseline 不可能高于当前温度（App 热贡献非负）：

- 当 \(T < B\)：\(\delta\)（或退化模式的 B）**快速下修**追向 T，时间常数约 1 分钟级。
- 当 \(T \ge B\)：只允许在 idle + 温度稳定时**慢速上调**。

效果：结构上几乎不可能出现 baseline 高于当前温度。

### 11.5 学习条件（\(\delta\) 更新门槛）

\(\delta\) 只在全部满足时更新：

- Total CPU low
- thermalState nominal
- **温度稳定**（近期窗口内波动很小，排除负载后的降温尾巴）
- 慢层锚点无异常（多传感器取最低已大部分覆盖；充电场景在 v0.5 进一步建模）

### 11.6 v0.5 增强方向

- 充电状态 / 外接显示器 / 屏幕亮度等环境因子建模
- 长期历史与多环境 profile

---

## 12. Estimated +°C

> **v2 修订（2026-09-30）**：原 \(\Delta T_i = Share_i \times \max(0, T - B)\) 替换为
> \(\Delta T_i = g \cdot H_i\)。原公式在 T ≤ baseline 时全体塌缩为 0（v0.1 实测），
> 且无法表达「低于 baseline 的温热状态」下 App 的真实贡献。

### 12.1 计算

\[
\Delta T_i = g \cdot H_i
\]

- \(H_i\)：App 热记忆水库（§9，不变）。
- \(g\)：设备级温升系数（°C / 单位热储量），在线回归校准（§14）。

性质：

- App 有持续负载时贡献恒为正，不存在塌缩。
- Heat Share 由 \(H_i\) 天然导出（\(Share_i = H_i / \sum_j H_j\)），继续作为排序与相对比例指标。

### 12.2 自检等式

\[
B + \sum_i g \cdot H_i \approx T_{current}
\]

预测与实测的偏差是模型健康度指标与校准数据源，Debug 面板展示 estimated vs actual。

### 12.3 展示

> **v2.1 修订（2026-09-30）**：展示层硬性原则——用户看到的账必须平。
> 面板展示的 Baseline 为**残差**（T_current − ΣΔT_i），模型 baseline（慢锚点+δ）
> 转为内部校准用途，两者差异即模型误差（第三步校准信号）。
> 列表完整化（前 8 名 + N more apps 聚合行），保证：
> **Baseline + Σ行项目 = Current 恒成立**，且 Baseline 结构上不可能高于 Current。
> 精度规则：恒等式区域的 Current 与 Baseline / 行项目同精度（0.1°C），
> 避免整数舍入造成视觉上的不等；菜单栏与面板头部保持整数。

```text
Google Chrome      +4.6°C
Cursor             +2.1°C
Docker             +1.1°C
macOS              +0.4°C
2 more apps        +0.2°C

Baseline           34.9°C
Current            43.3°C
```

必须标记为：

`Estimated`

---

## 13. 进阶热模型

未来可拟合设备自身参数：

\[
C\frac{dT}{dt}
=
P-k(T-T_{ambient})
\]

或：

\[
\frac{dT}{dt}
=
\alpha P
-
\beta(T-T_{baseline})
\]

其中：

- \(\alpha\)：设备升温增益。
- \(\beta\)：设备散热能力。

通过长期采样可逐步估计。

> **v2 修订（2026-09-30）**：本模型从「未来可做」升级为热模型 v2 的常态机制——
> 它是温升系数 g 与散热时间常数 τ 在线校准的基础（§12 / §14）。

---

## 14. 模型在线校准

> **v2 修订（2026-09-30）**：g（温升系数）成为第一校准对象，
> 配套 baseline 偏移 δ 与散热时间常数 τ。
>
> **v2.2 修订（2026-09-30）：g 在线校准已实现（第三步提前完成）**。采用 RLS
> 递归最小二乘（`GainCalibrator`）：观测 y = T实测 − 模型baseline，回归量
> x = ΣH，模型 y ≈ g·x；遗忘因子 ~10 分钟窗口；护栏（仅在 ΣH > 0.5 core·s
> 且 totalCPU > 5% 时回归）防怠速除噪；g 钳制 [0.005, 0.05]；
> 校准值持久化 UserDefaults（节流保存：变化 > 0.0005 且间隔 > 60s）。
> 实测：6 核压测 g 从 0.016 在线收敛到 0.025，同负载点 est 误差 4.1 → 1.4°C，
> 展示 Baseline 负载漂移 +5.5°C → ~1°C。单元测试含收敛性 / 护栏 / 钳制。

观测：

```text
real dT/dt，以及稳态附近的 (ΣP, T - B) 样本
```

预测：

```text
predicted dT/dt = α·ΣP − β·(T − B)
```

损失：

\[
Loss
=
(dT/dt-\hat{dT/dt})^2
\]

用于逐步校准（按优先级）：

- **g（温升系数）**：✅ 已实现（RLS，见上）
- **δ（baseline 偏移）**：✅ 已实现（仅 idle + 温度稳定时慢速学习，§11.5）
- **τ（散热时间常数）**：⏸ 暂缓。散热阶段实测 chassis 散热慢于 τ=60，
  未来需要时优先考虑双时间常数（fast/slow reservoir，§9）而非单纯调 τ
- CPU weight / GPU weight（v0.5 GPU 接入后）

异常样本剔除：环境突变（如暴晒）、电池充电发热段不参与校准。

校准数据链：DEBUG CSV（每次 tick 记录 T / B / ΣH / 预测误差）→ 离线拟合初值 → 在线回归收敛。

首版不建议引入神经网络或复杂 ML。

优先使用：

- EMA
- 一阶模型
- 小规模 regression
- 可解释参数

---

## 15. Thermal State

使用：

```swift
ProcessInfo.processInfo.thermalState
```

状态：

- nominal
- fair
- serious
- critical

用途：

1. UI 辅助状态。
2. 模型 sanity check。
3. WATCH 模式触发。
4. 调整采样频率。

---

## 16. Quit 实现

普通 App：

```swift
NSRunningApplication.terminate()
```

原则：

- 首选正常退出。
- 不默认强杀。
- 不允许对关键系统进程提供 Quit。

若未来支持 Force Quit：

- 仅在正常 Quit 失败后提供。
- 明确提示数据风险。

---

## 17. 数据结构建议

```text
ProcessSample
├── pid
├── parentPid
├── responsiblePid
├── executablePath
├── cpuTime
├── gpuTime
├── wakeups
├── diskIO
└── networkIO

        ↓

ProcessOwnership
├── appID
├── confidence
└── method

        ↓

AppSample
├── bundleID
├── name
├── icon
├── processes[]
├── cpu
├── gpu
├── wakeups
└── io

        ↓

AppPower
├── instantaneousScore
└── estimatedWatts?   // future

        ↓

AppThermalState
├── fastReservoir
├── slowReservoir
├── heatShare
└── estimatedDeltaC
```

---

## 18. 历史数据策略

首版不需要高频持久化。

内存保留短期数据。

未来：

```text
最近 5 分钟      2–5 秒/点
最近 1 小时     30 秒/点
最近 24 小时     5 分钟/点
```

落盘：

- batch write
- 30–60 秒一批
- 或更低频

避免每秒 SQLite INSERT。

---

## 19. UI 性能约束

菜单栏：

- 只显示数字。
- 仅在温度值实际变化或刷新周期到达时更新。

Popover：

- 无动画。
- 无粒子。
- 无 60fps 动态曲线。
- 列表更新约 1Hz 即可。
- 图标缓存。

UI 层不得直接触发重型系统采样。

---

## 20. 性能预算

以下为研发目标。

### SLEEP

```text
CPU avg          < 0.2–0.3%
GPU               0%
Memory           < 50 MB
Disk writes       ≈ 0
Wakeups           尽可能低
```

### LIVE

```text
CPU avg          < 1%
GPU               ≈ 0%
UI update          ~1Hz
```

最终必须通过真实 Apple Silicon 设备验证。

---

## 21. 性能验证

开发阶段持续测试：

- Activity Monitor
- Instruments
- Energy Log
- Time Profiler
- System Trace
- powermetrics

必须测试：

### Idle

I AM SO HOT 后台运行 30–60 分钟。

观察：

- CPU
- wakeups
- memory
- energy impact
- 温度变化

### Load

人为运行：

- CPU benchmark
- Chrome 视频
- 编译任务
- Docker
- GPU workload

观察：

- App 排名
- Heat Share
- Estimated +°C
- 关闭 App 后热量衰减

### Self-impact

确保：

> I AM SO HOT 不会出现在 Top Heat Contributor 前列。

若自身长期占用明显 CPU，则视为性能 bug。

---

## 22. 开发阶段推荐顺序

### Phase 1 — Collector

先完成：

- 温度
- Total CPU
- per-process CPU

### Phase 2 — Resolver

完成：

- PID → App
- Bundle 聚合
- PPID fallback
- cache

### Phase 3 — Relative Heat

先只做：

```text
Chrome 42%
Cursor 21%
Docker 11%
```

确认排序可信。

### Phase 4 — Estimated +°C

增加：

- baseline
- thermal reservoir
- heat share → ΔT

### Phase 5 — Adaptive Monitoring

实现：

- SLEEP
- WATCH
- LIVE

并做性能预算。

### Phase 6 — Quit

加入：

- terminate
- system process protection

---

## 23. 技术风险

### 风险 1：温度读取接口

macOS 对底层传感器并非全部提供稳定公开 API。

需要单独验证：

- Apple Silicon 型号覆盖。
- 权限。
- 沙盒限制。
- API 稳定性。

### 风险 2：GPU 进程归因

GPU attribution 可能比 CPU 更难获得或成本更高。

MVP 应允许 GPU 缺失。

### 风险 3：App ownership

XPC / daemon / helper 场景可能无法 100% 正确归属。

需要：

- confidence
- fallback
- System / Other

### 风险 4：+°C 被用户误认为实测

UI 必须持续明确：

`Estimated`

### 风险 5：自身能耗

任何新增指标必须通过性能预算评估。

如果一个指标只能小幅提升准确率，却显著增加 wakeups，应放弃或降低采样频率。

---

## 24. 最终技术原则

### 原则一

**进程识别优先于进程展示。**

用户看到的是 App，不是 PID。

### 原则二

**先做相对归因，再做绝对温度估算。**

Heat Share 比 `+°C` 更容易做准。

### 原则三

**模型必须有热记忆。**

CPU 降到 0 不代表热量瞬间消失。

### 原则四

**采集成本比模型计算成本重要。**

真正昂贵的是读数据，不是 EMA 数学运算。

### 原则五

**默认低功耗，按需进入详细模式。**

SLEEP → WATCH → LIVE。

### 原则六

**A thermal monitor should not generate thermal problems.**

如果 I AM SO HOT 本身导致明显温升，则架构失败。
