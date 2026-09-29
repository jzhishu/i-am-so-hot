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
- PID reuse。
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

### 11.1 定义

Baseline：

> 当前设备在相同环境下、没有显著高负载软件时的预计温度。

### 11.2 不应固定写死

Baseline 受到：

- Mac 型号
- 环境温度
- 充电状态
- 外接显示器
- 屏幕亮度
- 机身散热条件
- 长时间负载历史

影响。

### 11.3 动态学习

只在系统满足 idle 条件时学习：

```text
Total CPU low
GPU low
thermalState nominal
temperature stable
```

更新：

\[
B_t
=
(1-\alpha)B_{t-1}
+
\alpha T_t
\]

其中 \(\alpha\) 非常小。

避免高负载期间污染 baseline。

---

## 12. Estimated +°C

定义额外温升：

\[
\Delta T
=
\max(0, T_{current}-T_{baseline})
\]

每个 App：

\[
\Delta T_i
=
Share_i
\cdot
\Delta T
\]

即：

\[
\boxed{
\Delta T_i
=
(T-T_{baseline})
\frac{H_i}{\sum_j H_j}
}
\]

最终展示：

```text
Google Chrome      +11.2°C
Cursor              +6.4°C
Docker              +3.1°C
macOS               +5.0°C
Other               +2.3°C

Baseline             50.0°C
Current              78.0°C
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

---

## 14. 模型在线校准

观测：

```text
real dT/dt
```

预测：

```text
predicted dT/dt
```

损失：

\[
Loss
=
(dT/dt-\hat{dT/dt})^2
\]

用于逐步校准：

- CPU weight
- GPU weight
- \(\tau\)
- thermal gain

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
