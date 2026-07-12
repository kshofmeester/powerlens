package collect

// RingBuffer 维护固定容量的最近 N 个采样点,满则覆盖最旧值。
// 它是 daemon 采集循环持有的跨轮次状态,不参与无状态的 All()。
type RingBuffer struct {
	data []float64
	cap  int
}

// NewRingBuffer 创建一个容量为 size 的空环形缓冲。
func NewRingBuffer(size int) *RingBuffer {
	return &RingBuffer{data: make([]float64, 0, size), cap: size}
}

// Push 追加一个新采样值,超出容量时丢弃最旧值。
// 哨兵值 -1(不可用/无硬件)被跳过,避免在折线里造成假谷底。
func (r *RingBuffer) Push(v float64) {
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
func (r *RingBuffer) Slice() []float64 {
	out := make([]float64, len(r.data))
	copy(out, r.data)
	return out
}
