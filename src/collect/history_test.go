package collect

import (
	"reflect"
	"testing"
)

// TestRingBufferOrder 验证未满时按旧→新顺序返回全部已 push 的值。
func TestRingBufferOrder(t *testing.T) {
	r := NewRingBuffer(3)
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
	r := NewRingBuffer(3)
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
	r := NewRingBuffer(3)
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
	r := NewRingBuffer(3)
	got := r.Slice()
	if got == nil {
		t.Error("Slice() must not return nil")
	}
	if len(got) != 0 {
		t.Errorf("expected empty slice, got %v", got)
	}
}
