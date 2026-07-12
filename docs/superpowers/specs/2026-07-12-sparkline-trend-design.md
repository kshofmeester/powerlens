# PowerLens 趋势迷你图（Sparkline）设计文档

- **日期**：2026-07-12
- **状态**：设计已确认，待实现
- **方向**：深化 glanceable 体验（守住极简定位，只加精不加重）
- **范围**：单一 spec，一个实现计划可覆盖

---

## 1. 背景与目标

### 1.1 问题

PowerLens 当前在 `RPROMPT` 中展示 7 个指标的**此刻值**，但缺失一个关键维度——**趋势**。

"CPU 80% 且在回落" 与 "CPU 80% 还在爬升" 是两种完全不同的系统状态，需要不同的决策。当前显示无法区分二者。趋势是所有指标共同缺失、且对"判断系统正在干什么"最有价值的维度。

### 1.2 目标

在指标数值旁用一串趋势字符（sparkline）展示最近约 48 秒的走势，让用户一眼判断"爬升 / 回落 / 平稳"。

### 1.3 设计约束（继承自项目定位）

- **不增加常态视觉噪音**：功能默认关闭，开箱即用体验不变。
- **不牺牲渲染性能**：`precmd` 渲染仍需 <5ms。
- **不引入新依赖**：Go 端零新依赖，zsh 端无 `jq`。
- **macOS only**：与现有约束一致。

---

## 2. 架构与数据流

改动分两端，各自职责单一：

```
daemon 循环:  采样值 → ringbuf.Push(v) → JSON { ..., "cpu_hist":[..], "power_hist":[..] }
                                                        │
zsh precmd:  读 JSON → _powerlens_jget_arr 取出数组 → _powerlens_sparkline → 拼进 RPROMPT
```

**Go daemon 端**：在采集循环外维护一组定长环形缓冲区（每指标一个，容量 N=24）。每轮采样后 push 当前值，并将缓冲区快照序列化进 JSON 新增字段。环形缓冲逻辑独立成小单元 `history.go`，只做"push 一个值 / 导出定长切片"，可单测。

**zsh 端**：新增纯函数 `_powerlens_sparkline`，输入数值序列 + 量程，输出趋势字符串；新增 `_powerlens_jget_arr` 从 JSON 抽取数组。`_powerlens_format` 在每个带趋势指标数值后按开关追加 sparkline。

### 2.1 关键决策：历史数据放进同一个 `metrics.json`

历史序列写进**现有的** `metrics.json`，而非单独文件。

- **理由**：保持"单文件、mtime 驱动、原子写（write-to-tmp + rename）"的现有模型不变，zsh 端零新增 I/O。
- **代价**：JSON 略微变大（5 指标 × 24 数字 ≈ 数百字节），对 <5ms 渲染无实质影响。

---

## 3. Go daemon 端设计

### 3.1 新增单元 `src/collect/history.go`

极简定长环形缓冲：

```go
// ringBuffer 维护固定容量的最近 N 个采样点,满则覆盖最旧值。
type ringBuffer struct {
    data []float64
    size int
}

// Push 追加一个新采样值,超出容量时丢弃最旧值。
// 哨兵值 -1(不可用/无硬件)被跳过,不入缓冲,避免污染折线。
func (r *ringBuffer) Push(v float64)

// Slice 按时间顺序(旧→新)导出当前所有值的副本。
// 未满时只返回已有点数,不补零;空缓冲返回空切片(非 nil)。
func (r *ringBuffer) Slice() []float64
```

### 3.2 带趋势的指标

只给"变化快、趋势有决策价值"的 **5 个指标**配缓冲区：

| 指标 | 带趋势 | 理由 |
|---|---|---|
| power | ✅ | 功耗变化快,趋势反映负载起落 |
| cpu | ✅ | 核心负载信号 |
| mem | ✅ | 内存压力走势 |
| cpu_temp | ✅ | 热趋势,配合 fan 判断散热 |
| fan | ✅ | 风扇爬升是热负载变化的直观前兆 |
| battery | ❌ | 变化极慢,折线无意义 |
| net | ❌ | 瞬时突发为主,折线意义不大 |

### 3.3 JSON 结构扩展

在 `metrics.go` 的 `Metrics` struct 新增字段：

```go
CpuHist   []float64 `json:"cpu_hist"`
PowerHist []float64 `json:"power_hist"`
MemHist   []float64 `json:"mem_hist"`
TempHist  []float64 `json:"temp_hist"`
FanHist   []float64 `json:"fan_hist"`
```

### 3.4 缓冲区归属

环形缓冲是**跨采样轮次的状态**，不能放进无状态的 `All()`。

- 在 `main.go` 的 daemon 循环里持有一组 `ringBuffer`（每指标一个）。
- 每轮 `All()` 拿到快照后 push 对应值，再把各 `Slice()` 填回 `Metrics` 的 `*Hist` 字段。
- `All()` 保持纯函数，其单测不受影响；状态集中在循环里。

### 3.5 容量 N

**默认硬编码 N=24**。按 `POWERLENS_REFRESH=2s` 计算约 48 秒窗口——足够看清一次编译 / 一个请求的负载起落，JSON 又不会过大。不暴露为配置项（YAGNI）。

### 3.6 哨兵值规则

某轮采样值为 `-1`（无风扇 / temp 不可用）时，该指标当轮**跳过 push**：

- 无风扇的 Mac → `fan_hist` 恒为 `[]` → zsh 端趋势图自动不显示（与现有"无风扇隐藏"行为一致）。
- temp 偶发不可用 → 缓冲区保留上一批有效点，不被 `-1` 污染成假谷底。
- power/cpu/mem 顺带一致处理(防御性)。

---

## 4. zsh 端设计

### 4.1 新增纯函数 `_powerlens_sparkline`

```
_powerlens_sparkline <values-csv> <min> <max>
  → 把每个值按 (v-min)/(max-min) 归一化到 0..7,映射到 8 级字符
```

- 输入定则输出定，无全局状态依赖，可单测。
- 值超出 `[min,max]` → clamp 到边界格，不溢出字符集索引。
- `max <= min`（异常配置）→ 防除零，退化为全部渲染最低格。

### 4.2 字符集：默认 Braille，可一键切 block

由变量 `POWERLENS_TREND_CHARSET` 控制：

| 值 | 字符集 | 说明 |
|---|---|---|
| `braille`（默认） | 8 级纵向填充 Braille（如 `⣀ ⣄ ⣤ ⣦ ⣶ ⣷ ⣿`，实现时校准视觉均匀的 8 级映射） | 精细、技术感强,依赖字体 Braille 覆盖 |
| `block` | `▁▂▃▄▅▆▇█` | 兼容性最好,字体不支持 Braille 时的逃生口 |

**关键技术现实**：shell / 终端**无法可靠探测**当前字体能否渲染某字形（终端不回读字形宽度，缺字形时会静默 fallback 或显示 `□`）。因此**不做运行时自动降级**，而是让用户显式声明（业界 starship / p10k 同做法）。默认 Braille 满足现代等宽 / Nerd Font 用户；不兼容者一键切 `block`。

### 4.3 量程复用现有阈值

让趋势图与颜色语义一致，不新增配置：

- `min` = 0
- `max` = 该指标的 `MODERATE` 阈值（如 `POWERLENS_THRESH_CPU_MODERATE=85`）
- 超出上界 clamp 到满格

效果："折线顶到最高格" ≈ "进入 peak 区间"，与颜色渐变表达同一件事。

### 4.4 渲染位置与开关

- 总开关 `POWERLENS_SHOW_TREND=false`（**默认关**）。默认关的理由：这是进阶增强，保持开箱即用极简；想要的人显式开启。
- 在 `_powerlens_format` 里，每个带趋势指标数值紧跟其 sparkline。compact 模式示例：
  ```
  ⚙34%▂▃▅▇  🧠62%▃▃▄▄
  ```
- sparkline 沿用其所属指标颜色（复用 `_powerlens_color`）。

### 4.5 数组解析 `_powerlens_jget_arr`

现有 `_powerlens_jget` 只抽标量。新增 `_powerlens_jget_arr`：

- 从 `"cpu_hist":[12.3,45.6,...]` 抽出括号内内容，按逗号拆成 zsh 数组。
- 这是**唯一**对现有解析逻辑的改动。

---

## 5. 错误处理与边界

### Go 端

- `ringBuffer.Push(-1)` → 跳过，缓冲区不被污染。
- 空缓冲 → `Slice()` 返回 `[]float64{}`，JSON 序列化为 `[]`（非 `null`）。
- 未满时 `Slice()` 只返回已有点数，不补零。

### zsh 端

- 空数组 `[]` / 点数 <2 → 不渲染 sparkline，只显示数值（无乱码、无空格残留）。
- `max <= min` → 防除零，退化为最低格。
- 值超界 → clamp 到边界格，不溢出索引。
- `POWERLENS_SHOW_TREND=false`（默认）→ 完全跳过，零性能开销，行为与今日逐字节一致。

---

## 6. 测试策略

### 6.1 Go 单测 `src/collect/history_test.go`（表驱动）

- Push 超容量后 `Slice()` 长度恒为 N、为最新 N 个、顺序旧→新。
- Push `-1` 被跳过。
- 空缓冲返回空切片。

### 6.2 zsh 测试（追加到 `tests/test_plugin.zsh`）

- `_powerlens_sparkline "0,50,100" 0 100` → 断言输出为「低、中、满」三格对应字符（Braille 与 block 各测一次）。
- 空序列 / 单点 → 输出为空。
- 超界值 clamp → 输出满格，不报错。
- `_powerlens_jget_arr` 能从样例 JSON 正确抽出数组。

### 6.3 回归

`POWERLENS_SHOW_TREND` 默认关时，现有 `RPROMPT` 输出逐字节不变——由现有测试保证不回归。

### 6.4 CI

无改动即可覆盖（Go 测试在 `macos-latest` 跑；哨兵值 `-1` 已按项目惯例豁免）。

---

## 7. 实现顺序（遵循 TDD）

1. 写 `history_test.go` → 实现 `ringBuffer` → 绿。
2. 写 sparkline zsh 测试 → 实现 `_powerlens_sparkline` + `_powerlens_jget_arr` → 绿。
3. 接线：daemon 循环持有缓冲 + `Metrics` 加字段 + `_powerlens_format` 追加渲染。
4. 文档：README 加配置项（`POWERLENS_SHOW_TREND`、`POWERLENS_TREND_CHARSET`）+ 勾选 roadmap 中 Braille mini-graph 一项。

---

## 8. 新增配置项汇总

| 变量 | 默认值 | 说明 |
|---|---|---|
| `POWERLENS_SHOW_TREND` | `false` | 是否显示趋势 sparkline |
| `POWERLENS_TREND_CHARSET` | `braille` | 趋势字符集：`braille` \| `block` |

（量程复用现有 `POWERLENS_THRESH_*_MODERATE`，容量 N=24 硬编码，均不新增配置。）
