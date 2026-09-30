# I AM SO HOT — 产品需求文档（PRD）

## 1. 产品概述

**产品名称：** I AM SO HOT  
**平台：** macOS（首版优先支持 Apple Silicon）  
**产品形态：** 菜单栏常驻工具  
**核心定位：** 用最直观、最低打扰的方式告诉用户：

> 我的 Mac 现在有多热？  
> 是哪些软件正在让它变热？  
> 我能否直接关掉这些软件？

I AM SO HOT 不试图成为一个复杂的系统监控器，而是把 macOS 中较难理解的进程与资源数据，转换成普通用户可以直接理解的“软件级热量归因”。

---

## 2. 产品目标

### 2.1 核心目标

1. 在 macOS 菜单栏持续展示当前设备温度。
2. 点击菜单栏后，在下拉面板中查看当前温度状态。
3. 将系统进程归并为用户可识别的软件，而不是直接展示复杂的进程名称。
4. 估算每个软件当前的热贡献，并以相对比例和实验性的 `+X°C` 形式展示。
5. 用户可以直接从工具中正常退出导致高热的软件。
6. 软件自身必须足够轻量，不能因为监控行为明显增加设备发热或续航负担。

### 2.2 非目标

首版不追求：

- 完整替代 Activity Monitor。
- 精确测量每个 App 在物理意义上贡献了多少摄氏度。
- 展示大量底层传感器。
- 高频动画。
- 复杂图表。
- 60fps 实时刷新。
- 深度 Chrome Tab 级别归因。
- Windows / Linux 支持。
- 全功能系统性能分析。

---

## 3. 目标用户

### 3.1 核心用户

经常遇到以下情况的 Mac 用户：

- MacBook 突然变热。
- 电池掉电速度突然变快。
- 风扇转速升高。
- 不知道哪个软件正在消耗资源。
- Activity Monitor 中看到大量 Helper / Renderer / XPC 等进程，但不知道它们对应哪个软件。
- 希望快速判断“应该关掉哪个软件”。

### 3.2 典型场景

#### 场景 A：Mac 突然发热

用户发现 Mac 很热，看菜单栏：

`78°`

点击后看到：

- Google Chrome `+11.2°C`
- Cursor `+6.4°C`
- Docker `+3.1°C`

用户关闭 Chrome，观察温度逐渐下降。

#### 场景 B：用户看到陌生进程

系统底层显示：

`Google Chrome Helper (Renderer)`

I AM SO HOT 不直接展示这个名字，而是将其归并为：

`Google Chrome`

#### 场景 C：用户希望快速降温

用户在面板中直接点击：

`Quit`

正常退出对应 App。

---

## 4. 产品原则

### 4.1 面向用户，而不是面向进程

Activity Monitor 给用户看的是系统进程。

I AM SO HOT 应该给用户看：

- Chrome
- Cursor
- Figma
- Docker
- Zoom

而不是：

- Chrome Helper
- Renderer
- XPC Service
- WebContent
- PID 18273

### 4.2 克制

首版 UI 应保持极简。

- 菜单栏只显示温度数字。
- 下拉面板无动画。
- 不使用粒子、火焰等动态效果。
- 不做持续高频 Graph redraw。
- 颜色和状态提示应克制。
- 信息优先级高于视觉装饰。

### 4.3 可解释

任何“热贡献”都必须明确是估算。

推荐用词：

- Estimated Heat Contribution
- Estimated +°C
- Heat Share

避免表达：

- Measured +°C
- Exact Temperature Contribution

### 4.4 监控软件不能成为热源

产品原则：

> A thermal monitor should not generate thermal problems.

后台运行时应尽可能接近 idle。

---

## 5. 信息架构

### 5.1 菜单栏

首版只展示一个数字：

`63°`

或：

`78°`

不展示：

- 图标动画
- 火焰动画
- CPU 百分比
- 多项状态
- 文本标签

目标是低干扰、低刷新成本。

---

## 6. 下拉面板

点击菜单栏数字后打开 Popover。

### 6.1 首版结构

> **v2 修订（2026-09-30）**：面板数字必须构成恒等式——用户看到的账必须平。
> Baseline 展示残差（Current − ΣApps），列表完整化（前 8 名 + N more apps），
> 保证 Baseline + Σ行项目 = Current 恒成立。

```text
I AM SO HOT                         78°C

HEATING YOUR MAC

Google Chrome   CPU 38% · Heat 39%    +11.2°C   Quit
Cursor          CPU 21% · Heat 22%     +6.4°C   Quit
Docker          CPU 11% · Heat 11%     +3.1°C   Quit
macOS           CPU 5%  · Heat 18%     +5.0°C
Other           CPU 3%  · Heat 10%     +2.3°C

Baseline                              50.0°C
Current                               78.0°C
```

### 6.2 UI 约束

首版：

- 无动画。
- 无实时动态火焰。
- 无复杂渐变。
- 无 60fps 图表。
- 默认不展示进程树。
- 默认只展示 App 级别。
- App 图标可展示。
- 数值变化以低频刷新完成。

---

## 7. App 级归因

### 7.1 用户看到的对象

系统进程：

```text
Google Chrome
Google Chrome Helper
Google Chrome Helper (Renderer)
Google Chrome Helper (GPU)
```

产品中聚合显示：

```text
Google Chrome
17 processes
CPU 42%
Estimated +11.2°C
```

### 7.2 展开详情

首版可选支持点击 App 查看：

- App 名称
- App 图标
- Bundle ID
- 当前 CPU
- 当前 GPU
- 关联进程数量
- Estimated Heat Contribution

进程明细属于二级信息，不应抢占首页。

---

## 8. Quit 功能

### 8.1 默认操作

每个普通第三方 App 支持：

`Quit`

优先使用正常退出，而不是强制终止。

### 8.2 Force Quit

首版不作为一级操作。

如未来加入：

1. 用户先执行 Quit。
2. 软件未退出。
3. 二次提供 Force Quit。
4. 明确提示可能丢失未保存数据。

### 8.3 系统进程

以下类型默认不提供 Quit：

- kernel_task
- launchd
- WindowServer
- 系统核心服务
- 其他关键 macOS 进程

它们归并显示为：

`macOS`

---

## 9. 热量展示

### 9.1 首版主要指标

每个 App 展示：

- CPU
- 可选 GPU
- Heat Share
- 实验性 Estimated `+X°C`

### 9.2 温度组成

> **v2 修订（2026-09-30）**：原「Current = Baseline + Apps + System + Other」
> 概念模型替换为带物理锚点的热模型 v2（详见技术方案 §11–§14）。

概念模型：

```text
Current Temperature
≈
Baseline（慢速传感器锚点 + idle 学习偏移）
+
Σ 每个 App 的 Estimated +°C（g × 热储量）
```

例如：

```text
Baseline（锚点）      34.9°C
Google Chrome        +4.6°C
Cursor               +2.1°C
Docker               +1.1°C
macOS                +0.4°C
其他长尾              +0.2°C
────────────────────────────
Estimated Current    43.3°C   ≈ 实测 43.3°C
```

性质：

- Baseline 由慢速温度传感器（电池/机身）锚定，结构上不会出现高于当前温度的情况。
- Estimated `+X°C` 由 g × H_i 计算，App 有持续负载时贡献恒为正，不会在低温时全体塌缩为 0。
- Baseline + ΣApps ≈ Current 是模型的自检等式，预测误差用于在线校准，不作为 UI 需要凑平的账。

### 9.3 精度声明

`+X°C` 是通过资源使用、历史负载和温度响应模型得到的估算值，不应被描述为传感器直接测量结果。

模型通过对比预测温度（Baseline + Σ 贡献）与实测温度持续自我校准，设备使用时间越长，估算越贴近该设备的实际散热特性。

---

## 10. 自适应采样模式

产品根据状态自动切换采样强度。

### SLEEP

适用：

- 温度正常。
- 用户未打开面板。
- 总体负载较低。

行为：

- 低频采样。
- 目标周期约 5–10 秒。
- 不做高成本进程分析。

### WATCH

适用：

- 温度明显升高。
- 总 CPU / GPU 提升。
- 设备进入较高 thermal state。

行为：

- 约 2–3 秒采样。
- 启用 App 级归因。

### LIVE

适用：

- 用户打开 Popover。

行为：

- 约 1 秒更新 App 排名和热模型。
- 温度等较昂贵指标仍可保持 2–5 秒更新。

关闭面板后自动降级。

---

## 11. 自身资源目标

以下为工程预算，不是首版发布前未经实测的承诺。

### 后台 / Cool State

- Average CPU：目标 `< 0.2–0.3%`
- GPU：目标 `0%`
- Idle Wakeups：尽可能接近 0
- Memory：目标 `< 50 MB`
- Disk Write：无持续写盘
- 无持续 UI 绘制

### 面板打开

- Average CPU：目标 `< 1%`
- GPU：接近 0
- UI 更新：约 1Hz

### 产品自监控

未来可展示：

```text
I AM SO HOT's impact

CPU              0.18%
Memory             42 MB
Energy Impact        Low
```

并允许在高级设置中查看本软件自身热贡献。

---

## 12. MVP 范围

### v0.1

必须：

1. macOS 菜单栏常驻。
2. 菜单栏只显示当前温度数字。
3. 点击后展示克制的下拉面板。
4. 识别当前运行 App。
5. 将子进程聚合到所属 App。
6. 显示 App CPU 使用情况。
7. 提供 Relative Heat / Heat Share。
8. 提供实验性的 Estimated `+X°C`。
9. 支持普通 App 的 Quit。
10. 自适应采样。
11. 控制自身 CPU、Wakeups、Memory 和 IO。

### v0.5

增加：

- 动态 Baseline 学习。
- 双时间常数热模型。
- 更可靠的 GPU 归因。
- Mac 型号自校准。
- 温度历史记录。

### v1.0

增加：

- 冷却预测。
- `Quit → 预计降至 X°C`
- 更精确的设备级热模型。
- 更丰富的 process coalition / responsible process 识别。
- 高级诊断模式。

---

## 13. 成功标准

首版最重要的成功标准不是“温度预测误差低于多少”，而是：

### 用户层面

用户能在 3–5 秒内回答：

> 我的 Mac 为什么热？

并获得：

> 是 Chrome / Cursor / Docker 等具体软件。

### 算法层面

- App 排名稳定。
- 高负载 App 能正确排到前列。
- 关闭 App 后，其热贡献不会瞬间归零，而是随热量衰减。
- 不出现大量无法理解的 Helper 进程。

### 性能层面

I AM SO HOT 自身不能成为明显的资源消费者。

---

## 14. 核心产品定义

I AM SO HOT 不是：

> 一个更漂亮的 Activity Monitor。

而是：

> 一个回答“到底是谁把我的 Mac 搞热了？”的轻量工具。

