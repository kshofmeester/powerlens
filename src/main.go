package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/user/powerlens/collect"
)

func main() {
	daemon := flag.Bool("daemon", false, "run as background daemon")
	iface := flag.String("iface", "default", "network interface: default | wifi | ethernet")
	refresh := flag.Int("refresh", 2, "poll interval in seconds")
	flag.Parse()

	if !*daemon {
		// One-shot mode: print JSON to stdout (for debugging)
		var prev collect.NetSample
		m, _ := collect.All(*iface, &prev)
		json.NewEncoder(os.Stdout).Encode(m)
		return
	}

	cacheDir := collect.XDGCacheDir()
	if err := os.MkdirAll(cacheDir, 0755); err != nil {
		fmt.Fprintln(os.Stderr, "powerlens: cannot create cache dir:", err)
		os.Exit(1)
	}
	outPath := filepath.Join(cacheDir, "metrics.json")

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
}
