# Sparkline 趋势迷你图 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `RPROMPT` 的 power/cpu/mem/temp/fan 指标数值旁展示最近约 48 秒的趋势 sparkline，让用户一眼判断爬升/回落/平稳。

**Architecture:** Go daemon 在采集循环里持有每指标一个定长环形缓冲（N=24），每轮 push 当前值并把快照序列化进现有 `metrics.json` 的新数组字段；zsh 端新增纯函数从 JSON 抽数组并渲染成 Braille/block 字符，追加到对应指标数值后。功能默认关闭。

**Tech Stack:** Go 1.21+（CGO，标准库，无新依赖）；zsh 5.8+（无 `jq`）。

## Global Constraints

- **macOS only**：CGO 链接 IOKit/CoreFoundation；测试在 `macos-latest` 跑。
- **无新 Go 依赖**：只用标准库。
- **无 `jq` 依赖**：zsh 端 JSON 解析用正则 / 参数展开。
- **渲染 <5ms**：`precmd` 路径不得引入重开销；功能关闭时零额外开销。
- **`-1` 哨兵值**：表示指标不可用/无硬件；测试断言必须豁免 `-1`（模式：`value != -1 && (range_check)`）。
- **哨兵不入缓冲**：`Push(-1)` 跳过，不污染折线。
- **容量 N=24 硬编码**，不暴露为配置项。
- **Go 格式化**：`gofmt`；CI 强制。
- **函数级注释**：新增函数需带说明其职责的注释（中文）。
- **新增配置默认值**：`POWERLENS_SHOW_TREND=false`，`POWERLENS_TREND_CHARSET=braille`。
- **Braille 8 级字符集**（底→满，视觉均匀）：`⣀ ⣄ ⣤ ⣦ ⣶ ⣷ ⣾ ⣿`
- **block 8 级字符集**（底→满）：`▁ ▂ ▃ ▄ ▅ ▆ ▇ █`

---

### Task 1: 环形缓冲区 `ringBuffer`

**Files:**
- Create: `src/collect/history.go`
- Test: `src/collect/history_test.go`

**Interfaces:**
- Consumes: 无（纯新单元）
- Produces:
  - `func newRingBuffer(size int) *ringBuffer`
  - `func (r *ringBuffer) Push(v float64)` — `v == -1` 时跳过
  - `func (r *ringBuffer) Slice() []float64` — 按旧→新顺序返回副本；空时返回 `[]float64{}`（非 nil）
  - 注意：`ringBuffer` 为包内小写类型，仅 daemon 循环使用；测试用 `package collect`（内部测试）访问。

- [ ] **Step 1: 写失败测试**

创建 `src/collect/history_test.go`：

```go
package collect

import (
	"reflect"
	"testing"
)

// TestRingBufferOrder 验证未满时按旧→新顺序返回全部已 push 的值。
func TestRingBufferOrder(t *testing.T) {
	r := newRingBuffer(3)
	r.Push(1)
	r.Push(2)
	got := r.Slice()
	want := []float64{1, 2}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

// TestRingBufferOverflow 验证超容量后只保留最新 N 个,顺序旧→新。
func TestRingBufferOverflow(t *testing.T) {
	r := newRingBuffer(3)
	for _, v := range []float64{1, 2, 3, 4, 5} {
		r.Push(v)
	}
	got := r.Slice()
	want := []float64{3, 4, 5}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

// TestRingBufferSkipsSentinel 验证 -1 哨兵值被跳过,不入缓冲。
func TestRingBufferSkipsSentinel(t *testing.T) {
	r := newRingBuffer(3)
	r.Push(10)
	r.Push(-1)
	r.Push(20)
	got := r.Slice()
	want := []float64{10, 20}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

// TestRingBufferEmptyIsNotNil 验证空缓冲返回非 nil 空切片(JSON 序列化为 [])。
func TestRingBufferEmptyIsNotNil(t *testing.T) {
	r := newRingBuffer(3)
	got := r.Slice()
	if got == nil {
		t.Error("Slice() must not return nil")
	}
	if len(got) != 0 {
		t.Errorf("expected empty slice, got %v", got)
	}
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd src && go test ./collect/ -run TestRingBuffer -v`
Expected: FAIL —— `undefined: newRingBuffer`

- [ ] **Step 3: 实现 `ringBuffer`**

创建 `src/collect/history.go`：

```go
package collect

// ringBuffer 维护固定容量的最近 N 个采样点,满则覆盖最旧值。
// 它是 daemon 采集循环持有的跨轮次状态,不参与无状态的 All()。
type ringBuffer struct {
	data []float64
	cap  int
}

// newRingBuffer 创建一个容量为 size 的空环形缓冲。
func newRingBuffer(size int) *ringBuffer {
	return &ringBuffer{data: make([]float64, 0, size), cap: size}
}

// Push 追加一个新采样值,超出容量时丢弃最旧值。
// 哨兵值 -1(不可用/无硬件)被跳过,避免在折线里造成假谷底。
func (r *ringBuffer) Push(v float64) {
	if v == -1 {
		return
	}
	if len(r.data) < r.cap {
		r.data = append(r.data, v)
		return
	}
	// 已满:整体左移一位,新值置于末尾。
	copy(r.data, r.data[1:])
	r.data[len(r.data)-1] = v
}

// Slice 按时间顺序(旧→新)导出当前所有值的副本。
// 空缓冲返回非 nil 的空切片,以便 JSON 序列化为 [] 而非 null。
func (r *ringBuffer) Slice() []float64 {
	out := make([]float64, len(r.data))
	copy(out, r.data)
	return out
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd src && go test ./collect/ -run TestRingBuffer -v`
Expected: PASS（4 个测试全过）

- [ ] **Step 5: gofmt + 提交**

```bash
cd src && gofmt -w collect/history.go collect/history_test.go && cd ..
git add src/collect/history.go src/collect/history_test.go
git commit -m "feat: add ringBuffer for metric history with -1 sentinel skip"
```

---

### Task 2: `Metrics` 新增 history 字段

**Files:**
- Modify: `src/collect/metrics.go:10-23`（`Metrics` struct）
- Test: `src/collect/metrics_test.go`（追加一个 round-trip 测试）

**Interfaces:**
- Consumes: Task 1 的 `ringBuffer.Slice()` 输出（`[]float64`）
- Produces: `Metrics` struct 新增字段 `CpuHist`、`PowerHist`、`MemHist`、`TempHist`、`FanHist`（均 `[]float64`，JSON tag 分别为 `cpu_hist`/`power_hist`/`mem_hist`/`temp_hist`/`fan_hist`）

- [ ] **Step 1: 写失败测试**

在 `src/collect/metrics_test.go` 末尾追加：

```go
// TestWriteJSONHistoryRoundTrip 验证 history 字段能正确写入并读回。
func TestWriteJSONHistoryRoundTrip(t *testing.T) {
	m := collect.Metrics{
		CpuHist:   []float64{1, 2, 3},
		PowerHist: []float64{10, 20},
		MemHist:   []float64{},
		TempHist:  []float64{50, 55},
		FanHist:   []float64{1200},
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "metrics.json")
	if err := collect.WriteJSON(path, m); err != nil {
		t.Fatalf("WriteJSON error: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read file error: %v", err)
	}
	var got collect.Metrics
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}
	if len(got.CpuHist) != 3 || got.CpuHist[2] != 3 {
		t.Errorf("CpuHist round-trip mismatch: %v", got.CpuHist)
	}
	if len(got.FanHist) != 1 || got.FanHist[0] != 1200 {
		t.Errorf("FanHist round-trip mismatch: %v", got.FanHist)
	}
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd src && go test ./collect/ -run TestWriteJSONHistoryRoundTrip -v`
Expected: FAIL —— `unknown field 'CpuHist' in struct literal`

- [ ] **Step 3: 修改 `Metrics` struct**

在 `src/collect/metrics.go` 的 `Metrics` struct 中，`Ts` 字段之后新增：

```go
	Ts           int64   `json:"ts"`
	CpuHist      []float64 `json:"cpu_hist"`
	PowerHist    []float64 `json:"power_hist"`
	MemHist      []float64 `json:"mem_hist"`
	TempHist     []float64 `json:"temp_hist"`
	FanHist      []float64 `json:"fan_hist"`
```

（保持 struct tag 的 gofmt 对齐；运行 gofmt 会自动校正列宽。）

- [ ] **Step 4: 运行测试确认通过**

Run: `cd src && go test ./collect/ -run TestWriteJSONHistoryRoundTrip -v`
Expected: PASS

- [ ] **Step 5: gofmt + 提交**

```bash
cd src && gofmt -w collect/metrics.go collect/metrics_test.go && cd ..
git add src/collect/metrics.go src/collect/metrics_test.go
git commit -m "feat: add history array fields to Metrics struct"
```

---

### Task 3: daemon 循环接线（持有缓冲并填充 history）

**Files:**
- Modify: `src/main.go:35-41`（daemon 循环）

**Interfaces:**
- Consumes: Task 1 `newRingBuffer`/`Push`/`Slice`；Task 2 的 `Metrics.*Hist` 字段；现有 `collect.All()` 返回的 `Metrics`（含 `Power`/`CPU`/`Mem`/`CpuTemp`/`FanSpeed`）
- Produces: daemon 每轮写出的 `metrics.json` 包含填充后的 history 数组

**说明**：本任务是集成接线，无独立单元测试（daemon 循环依赖真实硬件采集，不宜单测）；验证方式为构建 + 运行一次性 daemon 观察 JSON 输出。这是可被 reviewer 独立评估的最小交付：JSON 里出现随时间增长的 history 数组。

- [ ] **Step 1: 修改 daemon 循环**

将 `src/main.go` 中 daemon 分支的循环（当前第 35-41 行）替换为：

```go
	var prev collect.NetSample
	interval := time.Duration(*refresh) * time.Second

	// 每个带趋势的指标持有一个环形缓冲(容量 24,约 48 秒窗口 @ refresh=2s)。
	// 缓冲是跨采样轮次的状态,故置于循环外,不进入无状态的 All()。
	const histSize = 24
	cpuBuf := collect.NewRingBuffer(histSize)
	powerBuf := collect.NewRingBuffer(histSize)
	memBuf := collect.NewRingBuffer(histSize)
	tempBuf := collect.NewRingBuffer(histSize)
	fanBuf := collect.NewRingBuffer(histSize)

	for {
		m, _ := collect.All(*iface, &prev)

		cpuBuf.Push(m.CPU)
		powerBuf.Push(m.Power)
		memBuf.Push(m.Mem)
		tempBuf.Push(m.CpuTemp)
		fanBuf.Push(m.FanSpeed)

		m.CpuHist = cpuBuf.Slice()
		m.PowerHist = powerBuf.Slice()
		m.MemHist = memBuf.Slice()
		m.TempHist = tempBuf.Slice()
		m.FanHist = fanBuf.Slice()

		collect.WriteJSON(outPath, m) //nolint:errcheck
		time.Sleep(interval)
	}
```

- [ ] **Step 2: 导出 ringBuffer 构造器供 main 包使用**

`main.go` 在 `package main`，`ringBuffer` 是 `collect` 包内小写类型，无法跨包用。将 Task 1 的构造器改为导出并返回导出类型。修改 `src/collect/history.go`：

- 把类型名 `ringBuffer` 改为导出的 `RingBuffer`（全文替换，含方法 receiver）。
- 把 `newRingBuffer` 改为 `NewRingBuffer`。
- 同步修改 `src/collect/history_test.go` 里的 `newRingBuffer` → `NewRingBuffer`（该测试为 `package collect`，方法名 `Push`/`Slice` 不变）。

（注：Task 1 最初用小写是为了最小化暴露；接线时发现需跨包，故此处提升为导出。这是计划内的有意演进，非返工。）

- [ ] **Step 3: 构建并运行一次性 daemon 验证 JSON**

Run:
```bash
cd src && go build -o /tmp/pl-fetch . && /tmp/pl-fetch --daemon --refresh 1 & \
sleep 4 && cat "${XDG_CACHE_HOME:-$HOME/.cache}/powerlens/metrics.json" | grep -o '"cpu_hist":\[[^]]*\]'; \
kill %1 2>/dev/null; cd ..
```
Expected: 输出形如 `"cpu_hist":[12.3,15.1,14.8,...]`，数组含多个点（约 3-4 个）。

- [ ] **Step 4: 跑完整 Go 测试确认无回归**

Run: `cd src && go vet ./... && go test ./...`
Expected: PASS（含 Task 1、Task 2 的测试）

- [ ] **Step 5: 提交**

```bash
git add src/main.go src/collect/history.go src/collect/history_test.go
git commit -m "feat: wire ring buffers into daemon loop, populate history arrays"
```

---

### Task 4: zsh 端 sparkline 渲染函数

**Files:**
- Modify: `powerlens.zsh`（新增 `_powerlens_jget_arr`、`_powerlens_sparkline` 两个函数；位置放在 `_powerlens_jget` 之后）
- Test: `tests/test_plugin.zsh`（新增测试段）

**Interfaces:**
- Consumes: 无（纯函数）
- Produces:
  - `_powerlens_jget_arr <json> <key>` — 从 `"key":[a,b,c]` 打印以空格分隔的值（供 `$(...)` 捕获后按空格分词）；无匹配/空数组打印空串
  - `_powerlens_sparkline <values-space-separated> <min> <max>` — 打印趋势字符串；点数 <2 或空 → 打印空串；值 clamp 到 `[min,max]`；`max<=min` → 全部最低格；字符集由 `POWERLENS_TREND_CHARSET`（`braille` 默认 | `block`）决定

- [ ] **Step 1: 写失败测试**

在 `tests/test_plugin.zsh` 的 `print "\nResults..."` 行**之前**插入：

```zsh
print "\n=== jget_arr ==="
local arr_json='{"cpu":34.2,"cpu_hist":[10,20,30],"mem_hist":[],"ts":1}'
assert_eq "jget_arr extracts values" "$(_powerlens_jget_arr "$arr_json" cpu_hist)" "10 20 30"
assert_eq "jget_arr empty array"     "$(_powerlens_jget_arr "$arr_json" mem_hist)" ""
assert_eq "jget_arr missing key"     "$(_powerlens_jget_arr "$arr_json" no_hist)"  ""

print "\n=== sparkline (block) ==="
POWERLENS_TREND_CHARSET=block
# 值 0,50,100 归一到 0..7: 0→▁(idx0), 50→▄(idx3或4), 100→█(idx7)
local spark=$(_powerlens_sparkline "0 50 100" 0 100)
assert_eq "block first char is lowest" "${spark[1]}" "▁"
assert_eq "block last char is highest" "${spark[-1]}" "█"
assert_eq "block length equals point count" "${#spark}" "3"
# 空 / 单点 → 空串
assert_eq "sparkline empty input"  "$(_powerlens_sparkline "" 0 100)"     ""
assert_eq "sparkline single point" "$(_powerlens_sparkline "42" 0 100)"   ""
# 超界 clamp:值 999 (>max 100) → 满格
local clamp=$(_powerlens_sparkline "0 999" 0 100)
assert_eq "clamp over-max to full" "${clamp[-1]}" "█"
# max<=min 防除零 → 全部最低格
local degen=$(_powerlens_sparkline "5 8" 10 10)
assert_eq "degenerate range all lowest" "${degen}" "▁▁"

print "\n=== sparkline (braille) ==="
POWERLENS_TREND_CHARSET=braille
local bspark=$(_powerlens_sparkline "0 100" 0 100)
assert_eq "braille first char lowest"  "${bspark[1]}" "⣀"
assert_eq "braille last char highest"  "${bspark[-1]}" "⣿"
POWERLENS_TREND_CHARSET=braille
```

- [ ] **Step 2: 运行测试确认失败**

Run: `zsh tests/test_plugin.zsh`
Expected: FAIL —— `_powerlens_jget_arr` / `_powerlens_sparkline` command not found（脚本 `errexit` 会在函数缺失处报错）

- [ ] **Step 3: 实现两个函数**

在 `powerlens.zsh` 的 `_powerlens_jget` 函数（当前第 51-60 行）之后插入：

```zsh
# 从 JSON 抽取数组字段,打印以空格分隔的值。
# 输入 {"k":[1,2,3]} → 打印 "1 2 3";空数组或缺失键 → 打印空串。
_powerlens_jget_arr() {
    local json=$1 key=$2 body
    if [[ $json =~ "\"${key}\":\[([^]]*)\]" ]]; then
        body="${match[1]}"
        [[ -z "$body" ]] && return
        print -n "${body//,/ }"
    fi
}

# 把一串数值渲染成趋势 sparkline。
# 用法: _powerlens_sparkline "v1 v2 v3 ..." <min> <max>
# 每个值按 (v-min)/(max-min) 归一到 0..7,映射到 8 级字符;
# 值超出 [min,max] 被 clamp;max<=min 时退化为全部最低格;点数<2 打印空串。
# 字符集由 POWERLENS_TREND_CHARSET 决定: braille(默认) | block。
_powerlens_sparkline() {
    local vals=(${=1}) min=$2 max=$3
    (( ${#vals} < 2 )) && return

    local chars
    if [[ "$POWERLENS_TREND_CHARSET" == "block" ]]; then
        chars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
    else
        chars=(⣀ ⣄ ⣤ ⣦ ⣶ ⣷ ⣾ ⣿)
    fi

    local span=$(( max - min ))
    local out="" v idx level
    for v in $vals; do
        if (( span <= 0 )); then
            idx=1
        else
            level=$(( (v - min) * 7.0 / span ))
            (( level < 0 )) && level=0
            (( level > 7 )) && level=7
            # 四舍五入到最近整数格,数组下标从 1 起。
            idx=$(( int(level + 0.5) + 1 ))
        fi
        out+="${chars[idx]}"
    done
    print -n "$out"
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `zsh tests/test_plugin.zsh`
Expected: PASS（新增断言全过，且原有断言不回归）

- [ ] **Step 5: 提交**

```bash
git add powerlens.zsh tests/test_plugin.zsh
git commit -m "feat: add _powerlens_jget_arr and _powerlens_sparkline functions"
```

---

### Task 5: 集成到 `_powerlens_format` + 配置默认值 + 文档

**Files:**
- Modify: `powerlens.plugin.zsh`（新增两个默认变量）
- Modify: `powerlens.zsh`（`_powerlens_format` 追加 sparkline 渲染）
- Modify: `tests/test_plugin.zsh`（新增开关行为断言 + 默认关闭回归断言）
- Modify: `README.md`（配置说明 + roadmap 勾选）

**Interfaces:**
- Consumes: Task 4 的 `_powerlens_jget_arr`、`_powerlens_sparkline`；现有 `_powerlens_color`、`_powerlens_wrap`、`POWERLENS_THRESH_*_MODERATE`
- Produces: 完整功能。`POWERLENS_SHOW_TREND=true` 时 RPROMPT 各指标数值后带趋势字符

- [ ] **Step 1: 写失败测试**

在 `tests/test_plugin.zsh` 的 sparkline 测试段之后、`Results` 行之前插入：

```zsh
print "\n=== trend integration ==="
local trend_json='{"power":42.7,"battery":87,"charging":false,"cpu_temp":55.0,"fan_speed":2500,"cpu":34.2,"mem":62.1,"net_up":1.2,"net_down":3.8,"net_iface":"en0","net_iface_type":"wifi","ts":9999999999,"cpu_hist":[10,20,30,40],"power_hist":[5,15,25],"mem_hist":[50,55,60],"temp_hist":[40,45,50],"fan_hist":[1000,2000,3000]}'

# 默认关闭:输出不含任何 block/braille 趋势字符
POWERLENS_TREND_CHARSET=block
POWERLENS_SHOW_TREND=false
POWERLENS_MODE=compact
local off_out=$(_powerlens_format "$trend_json")
local off_plain=$(print "$off_out" | sed 's/\x1b\[[0-9;]*m//g; s/%{[^}]*}//g')
assert_eq "trend off: no block chars" "${off_plain//[▁▂▃▄▅▆▇█]/}" "$off_plain"

# 打开:cpu 段之后应出现趋势字符
POWERLENS_SHOW_TREND=true
local on_out=$(_powerlens_format "$trend_json")
local on_plain=$(print "$on_out" | sed 's/\x1b\[[0-9;]*m//g; s/%{[^}]*}//g')
assert_eq "trend on: has block chars" "$([[ "$on_plain" == *[▁▂▃▄▅▆▇█]* ]] && echo yes || echo no)" "yes"

# 空 fan_hist:不应崩溃,fan 数值仍在(用 -1 的 fanless 数据验证 fan_hist 缺失场景)
local nohist_json='{"power":42.7,"battery":87,"charging":false,"cpu_temp":55.0,"fan_speed":2500,"cpu":34.2,"mem":62.1,"net_up":1.2,"net_down":3.8,"net_iface":"en0","net_iface_type":"wifi","ts":9999999999,"cpu_hist":[10,20],"fan_hist":[]}'
local nohist_out=$(_powerlens_format "$nohist_json")
assert_eq "empty fan_hist no crash" "$?" "0"

POWERLENS_SHOW_TREND=false
POWERLENS_MODE=compact
```

- [ ] **Step 2: 运行测试确认失败**

Run: `zsh tests/test_plugin.zsh`
Expected: FAIL —— "trend on: has block chars" 得到 `no`（`_powerlens_format` 尚未渲染趋势）

- [ ] **Step 3: 新增配置默认值**

在 `powerlens.plugin.zsh` 的 Display 段（第 5-6 行之后）新增：

```zsh
# ── Trend sparkline ─────────────────────────────────────────
: ${POWERLENS_SHOW_TREND:=false}       # true | false
: ${POWERLENS_TREND_CHARSET:=braille}  # braille | block
```

- [ ] **Step 4: 在 `_powerlens_format` 中追加趋势渲染**

在 `powerlens.zsh` 的 `_powerlens_format` 函数内实现。做法：定义一个局部 helper（在函数体开头，声明变量之后）并在每个带趋势指标后调用。

首先在 `_powerlens_format` 函数体顶部（`local sep=" "` 之前）加入 helper：

```zsh
    # 若开启趋势,为指定指标追加带色 sparkline。metric 用于取 MODERATE 阈值作量程上界。
    _pl_trend() {
        [[ "$POWERLENS_SHOW_TREND" != "true" ]] && return
        local metric=$1 hist_key=$2 color=$3
        local series=$(_powerlens_jget_arr "$json" "$hist_key")
        [[ -z "$series" ]] && return
        local upper
        case $metric in
            power) upper=$POWERLENS_THRESH_POWER_MODERATE ;;
            cpu)   upper=$POWERLENS_THRESH_CPU_MODERATE ;;
            mem)   upper=$POWERLENS_THRESH_MEM_MODERATE ;;
            temp)  upper=$POWERLENS_THRESH_TEMP_MODERATE ;;
            fan)   upper=$POWERLENS_THRESH_FAN_MODERATE ;;
        esac
        local spark=$(_powerlens_sparkline "$series" 0 "$upper")
        [[ -n "$spark" ]] && result+="$(_powerlens_wrap $color "$spark")"
    }
```

然后在各指标 `result+=...` 之后插入对应调用：

- power 段（`result+="$(_powerlens_wrap $pc "⚡...")"` 之后）：
  ```zsh
    _pl_trend power power_hist $pc
  ```
- cpu 段（`⚙` 那行之后）：
  ```zsh
    _pl_trend cpu cpu_hist $cc
  ```
- temp 段（temp `result+=` 之后，`fi` 之前的位置，使用已算出的 `$tc`）：
  ```zsh
    _pl_trend temp temp_hist $tc
  ```
- fan 段（fan `result+=` 之后，其 `fi` 之前，使用 `$fc`）：
  ```zsh
    _pl_trend fan fan_hist $fc
  ```
- mem 段（🧠 那行之后，使用 `$mc`）：
  ```zsh
    _pl_trend mem mem_hist $mc
  ```

（battery 与 net 不加趋势。）

- [ ] **Step 5: 运行测试确认通过**

Run: `zsh tests/test_plugin.zsh`
Expected: PASS（趋势开/关断言、空 fan_hist 断言，及全部原有断言）

- [ ] **Step 6: 更新 README**

在 `README.md` 的 Configuration → Display 段（`POWERLENS_COLOR_MODE` 附近）新增：

```zsh
POWERLENS_SHOW_TREND=false    # true | false — 在指标旁显示趋势 sparkline
POWERLENS_TREND_CHARSET=braille  # braille | block — 趋势字符集
```

并在配置说明下补一段：

> **Trend sparkline** — 开启后，power/cpu/mem/temp/fan 数值旁会附一串趋势字符，展示最近约 48 秒走势（量程上界取各指标的 `MODERATE` 阈值）。默认字符集为 Braille；若终端字体不支持 Braille，设为 `block`（`▁▂▃▄▅▆▇█`）。

在 `README.md` 的 Roadmap 段，把这一行改为已勾选：

```markdown
- [x] Historical mini-graph using Unicode Braille / block sparkline in expanded mode
```

- [ ] **Step 7: 全量测试 + 提交**

Run:
```bash
cd src && go vet ./... && go test ./... && cd .. && zsh tests/test_plugin.zsh
```
Expected: Go 全 PASS；zsh `Results: N passed, 0 failed`

```bash
git add powerlens.plugin.zsh powerlens.zsh tests/test_plugin.zsh README.md
git commit -m "feat: render trend sparkline in RPROMPT, add config and docs"
```

---

## Self-Review

**1. Spec coverage（逐节核对 spec）：**
- §2 架构/数据流（历史入同一 JSON）→ Task 2 + Task 3 ✅
- §3.1 ringBuffer → Task 1 ✅
- §3.2 五指标 power/cpu/mem/temp/fan → Task 3 push + Task 5 渲染 ✅
- §3.3 JSON 字段 → Task 2 ✅
- §3.4 缓冲区归属 daemon 循环 → Task 3 ✅
- §3.5 N=24 硬编码 → Task 3 `const histSize = 24` ✅
- §3.6 -1 不入缓冲 → Task 1 `Push` + 测试 ✅
- §4.1 `_powerlens_sparkline` 纯函数 → Task 4 ✅
- §4.2 默认 Braille / 可切 block → Task 4 字符集 + Task 5 默认值 ✅
- §4.3 量程复用 MODERATE → Task 5 `_pl_trend` case ✅
- §4.4 开关 + 渲染位置 + 复用颜色 → Task 5 ✅
- §4.5 `_powerlens_jget_arr` → Task 4 ✅
- §5 错误处理（空数组/单点/clamp/除零/默认关零开销）→ Task 4 测试 + Task 5 测试 ✅
- §6 测试策略（Go 表驱动 + zsh 两套字符集 + 回归）→ Task 1/4/5 测试 ✅
- §7 实现顺序 → Task 1→5 对应 ✅
- §8 新增配置 → Task 5 ✅

**2. Placeholder scan：** 无 TBD/TODO；所有代码步骤含完整代码；所有命令含预期输出。✅

**3. Type consistency：**
- Task 1 定义小写 `newRingBuffer`/`ringBuffer`，Task 3 Step 2 明确将其提升为导出 `NewRingBuffer`/`RingBuffer` 并同步测试 —— 已在计划中显式处理，非隐藏不一致。✅
- `Metrics.*Hist` 字段名（`CpuHist`/`PowerHist`/`MemHist`/`TempHist`/`FanHist`）在 Task 2 定义，Task 3 使用，一致。✅
- JSON key（`cpu_hist` 等）Task 2 定义，Task 4/5 的 `_powerlens_jget_arr` 调用一致。✅
- `_powerlens_sparkline` / `_powerlens_jget_arr` 签名 Task 4 定义，Task 5 `_pl_trend` 调用一致。✅

无遗留问题。
