# I AM SO HOT — 版本规划与产品路线图

## 1. 文档目的

本路线图用于指导 I AM SO HOT 后续版本推进。

核心原则：

> 每个版本只解决一个主要问题，不因为“以后可能有用”而提前加入复杂功能。

优先级顺序：

1. **先让用户看懂。**
2. **再让归因可信。**
3. **再让模型更准确。**
4. **最后再做预测和高级能力。**

---

# 2. 总体版本路线

```text
v0.1  Core MVP
│
├── 看温度
├── 看是谁让 Mac 变热
├── 看得懂 App，而不是进程
└── 可以直接 Quit
     │
     ▼
v0.2  Reliability
│
├── 提升 App 归属准确率
├── 降低自身资源消耗
└── 提升后台稳定性
     │
     ▼
v0.3  Heat Attribution
│
├── Relative Heat 更稳定
├── 热记忆模型
└── Estimated +°C 初步可信
     │
     ▼
v0.5  Calibration
│
├── 动态 Baseline
├── GPU
├── 设备自校准
└── 历史记录
     │
     ▼
v0.8  Prediction Preview
│
├── Quit 后冷却趋势
└── What if I quit this?
     │
     ▼
v1.0  Predictive Thermal Monitor
│
├── 完整预测模型
├── 稳定的降温预测
└── 正式版产品闭环
```

---

# 2.1 当前进度

> 每次版本推进后更新本节。更新日期：2026-09-29

## 总览

| 版本 | 状态 | 备注 |
|---|---|---|
| v0.1 | ✅ **已完成**（2026-09-29） | 本机端到端验证通过 |
| v0.2 | ⬜ 未开始 | 下一阶段 |
| v0.3 | ⬜ 未开始 | |
| v0.5 | ⬜ 未开始 | |
| v0.8 | ⬜ 未开始 | |
| v1.0 | ⬜ 未开始 | |

## v0.1 验收核对（对应 §3 验收标准）

### 产品

- [x] 看当前温度 — IOHID 私有 API 实测（43.7–48°C），菜单栏数字 + 面板展示
- [x] 看到 Chrome / Cursor / Docker 等真实 App — Bundle path 归并（Helper/Renderer 不直接出现）
- [x] 不需要理解 Helper / Renderer — 五级归属规则（技术方案 §4.3）
- [x] 找到主要热源 — 压测 4 核 `yes` 正确归因 Other 并以 share 0.95 登顶
- [x] 点击 Quit — `NSRunningApplication.terminate()`，macOS / Other 不提供 Quit

### 技术

- [x] App 排名基本符合真实 CPU 使用 — Heat Share 与 CPU 一致（v0.1 Power Score = CPU）
- [x] Chrome 多进程正确聚合 — sameBundle 最长前缀匹配，单测覆盖
- [x] App 停止后热贡献逐渐衰减 — 热记忆水库（τ = 60s 初始值），单测覆盖
- [x] 自身不出现在热源榜前列 — 自身 PID 排除；实测 RSS 30MB / 后台 CPU 0.0%

### 自适应采样实测（DEBUG CSV）

```text
SLEEP(8s) → 负载 total_cpu 0.51 触发 WATCH(2.5s)
→ 详细采样 app_count 0→39 → 温度 45.5→47.7°C 跟随负载
→ 卸载后降级 SLEEP，热贡献保留并缓慢衰减
```

### 工程状态

- 单元测试：28 个全部通过（ThermalCore）
- 构建：Debug / Release 均通过
- 调试工具：`thermalprobe`（采集验证）、`/tmp/iamsohot-debug.csv`（热模型调参）

## v0.1 已知遗留（进入 v0.2 待办）

1. PID reuse 检测缺失（当前注册表变化时全量清缓存）
2. responsible PID / process coalition 归属未实现（优先级 4 暂缺）
3. 自身 wakeups / 长时间能耗未做 30–60 分钟观测
4. 面板真实截图走查未完成（当前仅验证数据链路）
5. τ = 60s 为初始经验值，未用 CSV 数据做设备级校准
6. Estimated +°C 依赖的 Baseline 为简单 idle EMA（v0.5 做完整动态学习）

---

# 3. v0.1 — Core MVP

## 版本目标

回答一个问题：

> **我的 Mac 为什么这么热？**

用户应该可以在 3–5 秒内知道：

- 当前温度。
- 哪几个 App 是主要热源。
- 能否直接关闭它们。

---

## 必须功能

### 菜单栏

- 菜单栏常驻。
- 只显示当前温度数字。
- 示例：

```text
63°
```

- 不显示动画。
- 不显示额外 CPU / GPU 数据。
- 不做火焰动画或状态动画。

---

### 下拉面板

展示：

- 当前温度。
- 当前热状态。
- 热源 App 排名。
- App 图标。
- App 名称。
- CPU 使用情况。
- Relative Heat / Heat Share。
- 实验性 Estimated `+X°C`。
- Quit。

示例：

```text
I AM SO HOT                 78°C

HEATING YOUR MAC

Google Chrome      +11.2°C
CPU 38%                Quit

Cursor              +6.4°C
CPU 21%                Quit

Docker              +3.1°C
CPU 11%                Quit

macOS               +5.0°C

Other               +2.3°C

Baseline            50.0°C
```

---

## 技术能力

### Process → App

至少支持：

1. PID → NSRunningApplication。
2. Bundle path 匹配。
3. PPID 向上追踪。
4. Helper 归并。
5. 系统进程归类为 macOS。
6. Unknown 归类为 Other。

---

### Heat Attribution

第一版以：

```text
CPU activity
```

为核心。

如果 GPU 数据成本较高，可暂不作为必需项。

使用简单热记忆模型：

\[
H_i(t)=H_i(t-1)e^{-dt/\tau}+P_i(t)
\]

并展示：

```text
Heat Share
Estimated +°C
```

---

### 采样

实现：

- SLEEP
- WATCH
- LIVE

三个模式。

目标：

```text
后台：
5–10 秒一次轻量采样

温度升高：
2–3 秒

用户打开面板：
约 1 秒
```

---

## Quit

- 使用正常 terminate。
- 不默认提供 Force Quit。
- 系统关键进程不允许关闭。

---

## 性能目标

研发预算：

```text
后台 CPU avg       < 0.3%
GPU                0%
Memory             < 50 MB
Disk writes        接近 0
Wakeups            尽可能低
```

---

## 不做

v0.1 明确不做：

- 历史记录。
- 温度预测。
- What if I quit this?
- GPU 强依赖。
- Disk / Network 权重。
- Chrome Tab 级识别。
- Force Quit。
- 高级诊断。
- 长期学习。
- ML。
- 多平台。

---

## 验收标准

### 产品

用户可以：

1. 看当前温度。
2. 看到 Chrome / Cursor / Docker 等真实 App。
3. 不需要理解 Helper / Renderer。
4. 找到最主要热源。
5. 点击 Quit。

### 技术

- App 排名基本符合真实 CPU 使用。
- Chrome 多进程能正确聚合。
- App 停止后热贡献逐渐衰减。
- 自身不会出现在热源榜前列。

---

# 4. v0.2 — Reliability & Efficiency

## 版本目标

让软件变成：

> **可以长期常驻、不会打扰用户的工具。**

这个版本不重点增加新功能。

重点是：

- 准确。
- 稳定。
- 省电。

---

## 功能

### App 归属增强

增加：

- 更完整 Bundle 识别。
- 更强 PPID fallback。
- responsible PID。
- process coalition。
- 常见 XPC / helper 规则。

---

### Ownership Confidence

内部加入：

```text
confidence
method
```

例如：

```text
Chrome Renderer
→ Chrome
confidence: 1.00
method: sameBundle
```

用于：

- Debug。
- 错误分析。
- 后续高级诊断。

默认 UI 不展示。

---

### 缓存优化

实现：

- PID → App 缓存。
- App metadata 缓存。
- 图标缓存。
- Bundle cache。
- PID reuse 检测。

---

### 自身性能优化

重点优化：

- Wakeups。
- Timer 合并。
- 内存。
- Disk IO。
- UI 刷新。

---

## 可加入功能

### Self Impact

高级设置中可开始显示：

```text
I AM SO HOT

CPU        0.18%
Memory       42 MB
```

不一定展示 `+°C`。

---

## 不做

仍不做：

- 长期历史。
- 预测。
- Chrome Tab。
- Estimated Watts。
- 高级 ML。

---

## 验收标准

- 长时间运行无明显 CPU 漂移。
- 不持续写盘。
- Idle wakeups 明显下降。
- Process → App 错配率下降。
- 异常 Helper 明显减少。

---

# 5. v0.3 — Heat Attribution

## 版本目标

从：

> 谁 CPU 高

升级到：

> 谁正在贡献当前热量

---

## 功能

### Heat Reservoir

正式引入热记忆模型。

至少支持：

```text
instant activity
+
recent history
```

避免：

```text
App CPU → 0
Heat → 0
```

这种不自然情况。

---

### Relative Heat

Heat Share 成为主要指标。

例如：

```text
Chrome        42%
Cursor        21%
Docker        11%
macOS         18%
Other          8%
```

---

### Estimated +°C

继续作为：

```text
Experimental
```

展示。

这一阶段目标不是绝对准确，而是：

- 排序稳定。
- 趋势合理。
- 关闭 App 后变化自然。

---

### 双时间常数实验

可以开始内部实验：

```text
fast reservoir
slow reservoir
```

但默认模型是否切换，由测试结果决定。

---

## 验收标准

- CPU benchmark 能成为主要热源。
- Chrome 视频负载能稳定显示。
- Quit 后热贡献逐步衰减。
- 热贡献曲线没有明显抖动。
- Heat Share 比 CPU 排名更符合用户感受。

---

# 6. v0.5 — Calibration & History

## 版本目标

让：

> `+X°C`

从“有趣的估算”

变成：

> **具有实际参考价值的估算。**

---

## 功能

### 动态 Baseline

学习：

```text
这台 Mac 在空闲情况下通常是多少°C
```

规则：

- 只在低负载时更新。
- thermalState nominal。
- 温度稳定。
- 不在高负载期间学习。

---

### 双时间常数

正式引入：

```text
Fast Thermal Reservoir
Slow Thermal Reservoir
```

模拟：

- SoC 快速升温。
- 机身慢速散热。

---

### GPU Attribution

加入 GPU contribution。

目标覆盖：

- 视频。
- Figma。
- 游戏。
- 3D。
- 视频剪辑。
- GPU compute。

---

### Device Calibration

根据：

- Mac 型号。
- 设备历史行为。
- 升温速度。
- 降温速度。

学习：

```text
thermal gain
decay constant
baseline
```

---

### 历史记录

增加简单历史。

建议：

```text
Last 5 min
Last 1 hour
Last 24 hours
```

但 UI 仍保持克制。

---

### 数据持久化

采用：

- 内存 buffer。
- 聚合。
- Batch write。

不每秒写数据库。

---

## 不做

暂不正式上线：

- 精确 Watts。
- Chrome Tab。
- AI / Neural Network。
- 自动关闭 App。

---

## 验收标准

- Baseline 不会因短期高温被污染。
- 同一设备多次测试结果更加稳定。
- GPU workload 能被正确识别。
- Estimated +°C 波动减少。
- 历史记录不会明显增加 IO。

---

# 7. v0.8 — Prediction Preview

## 版本目标

开始回答：

> **如果我关掉它，会发生什么？**

---

## 功能

### Cooling Forecast

用户 Quit App 后：

```text
Current: 78°C

Expected:
70°C in ~25 sec
65°C in ~55 sec
```

---

### What if I quit this?

在执行 Quit 前：

```text
Google Chrome
Estimated +11.2°C

If you quit Chrome:
Expected temperature ~66°C
```

必须显示：

```text
Estimated
```

---

### Prediction Confidence

内部维护：

```text
prediction confidence
```

如果模型不稳定：

不展示精确时间。

可以退化成：

```text
Expected to cool significantly
```

---

## 产品原则

这一版本不能制造“假精确”。

如果误差很大：

宁可显示范围：

```text
Expected: 64–68°C
```

也不显示：

```text
65.2°C
```

---

## 验收标准

- 常见 CPU workload 的降温方向判断正确。
- 预测值不频繁大幅跳动。
- 实测降温趋势与预测方向一致。
- 用户不会误以为这是物理精确值。

---

# 8. v1.0 — Predictive Thermal Monitor

## 版本目标

正式完成产品闭环：

```text
What is happening?
        ↓
Who is causing it?
        ↓
What happens if I stop it?
        ↓
Did the Mac cool down?
```

---

## 核心功能

### 1. Current Temperature

稳定展示当前温度。

### 2. App Attribution

稳定的 App 级热源排名。

### 3. Estimated +°C

经过 calibration。

### 4. Quit

正常退出 App。

### 5. Cooling Prediction

预测降温趋势。

### 6. What if I quit this?

支持决策。

### 7. History

查看近期温度变化。

### 8. Adaptive Monitoring

后台保持低功耗。

---

## 技术能力

成熟版包括：

- Process → App resolver。
- responsible process。
- process coalition。
- CPU attribution。
- GPU attribution。
- Heat Reservoir。
- Dynamic Baseline。
- Device Calibration。
- Predictive Thermal Model。
- Confidence system。

---

## v1.0 成功标准

产品必须能够稳定回答：

> Why is my Mac hot?

并进一步回答：

> What should I close if I want it cooler?

但产品本身不替用户自动关闭软件。

---

# 9. v1.x — 后续增强方向

以下功能不应提前承诺。

统一放入：

**Consider / Research**

---

## 9.1 Chrome / Browser Tab Attribution

目标：

```text
Google Chrome
├── YouTube
├── Google Docs
├── Figma
└── Extensions
```

技术复杂度高。

仅在可稳定实现时考虑。

---

## 9.2 Electron 子任务识别

例如：

- Cursor workspace。
- Slack window。
- Figma task。

---

## 9.3 Estimated Watts

可能展示：

```text
Chrome
Estimated 8.4 W
```

前提：

- 数据足够可信。
- 不增加过高采样成本。

---

## 9.4 Long-term Analytics

例如：

```text
Today

Chrome
Total high-heat time: 1h 42m

Docker
58m
```

但要避免把产品变成复杂分析器。

---

## 9.5 Advanced Diagnostics

面向高级用户：

- PID。
- Bundle ID。
- attribution method。
- confidence。
- CPU/GPU breakdown。
- raw thermal score。

默认隐藏。

---

## 9.6 Force Quit

只作为二级操作。

仅当：

```text
Normal Quit failed
```

后提供。

---

## 9.7 Multi-platform

可能研究：

- Intel Mac。
- Windows。
- Linux。

不进入 macOS 首阶段路线。

---

# 10. 明确暂不规划的功能

为了保持产品克制，以下功能当前不建议进入 Roadmap：

- 自动杀掉高热 App。
- AI 自动决定关闭哪个 App。
- 每秒大量落盘。
- 复杂 Dashboard。
- 多窗口监控中心。
- 60fps 实时图表。
- 桌面 Widget 大量动画。
- 风扇控制。
- CPU 超频 / 降频控制。
- 系统调优工具合集。
- 清理垃圾文件。
- 内存清理。
- 电池管家。

这些都会让产品失去：

> “轻量、专注、回答一个问题”

的核心定位。

---

# 11. 推荐的发布节奏

## 第一阶段

```text
v0.1
↓
v0.2
↓
v0.3
```

重点：

> 把“看懂热源”做得可靠。

不要急于预测。

---

## 第二阶段

```text
v0.5
```

重点：

> 把 `+°C` 做得可信。

---

## 第三阶段

```text
v0.8
↓
v1.0
```

重点：

> 从监控进入预测。

---

# 12. 版本优先级原则

每次考虑新功能时，问四个问题：

### 1. 它是否帮助用户回答：

> 为什么我的 Mac 热？

如果不是，优先级下降。

### 2. 它是否会增加常驻开销？

如果明显增加：

必须证明收益足够大。

### 3. 它是否让 UI 更复杂？

如果是：

优先考虑隐藏到二级页面。

### 4. 它是否提高“可信度”？

优先顺序：

```text
可信
>
功能多
```

---

# 13. 推荐版本定义

最终推荐：

| 版本 | 核心目标 | 状态 |
|---|---|---|
| v0.1 | 看温度、看热源、Quit | ✅ 已完成（2026-09-29） |
| v0.2 | 稳定、省电、归属更准 | ⬜ 未开始 |
| v0.3 | Heat Share / 热记忆 | ⬜ 未开始 |
| v0.5 | Baseline / GPU / 自校准 / 历史 | ⬜ 未开始 |
| v0.8 | 降温预测 Preview | ⬜ 未开始 |
| v1.0 | 完整预测型 Thermal Monitor | ⬜ 未开始 |
| v1.x | 高级诊断与实验功能 | ⬜ 未开始 |

---

# 14. 一句话路线图

```text
v0.1  Tell me who is making my Mac hot.
v0.3  Tell me how much heat they contribute.
v0.5  Learn how my Mac behaves.
v0.8  Tell me what happens if I quit them.
v1.0  Predict how my Mac will cool down.
```

这条路线应作为 I AM SO HOT 后续版本推进的主线。
