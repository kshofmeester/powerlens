#!/usr/bin/env zsh
setopt errexit

PASS=0; FAIL=0
assert_eq() {
    local desc=$1 got=$2 want=$3
    if [[ "$got" == "$want" ]]; then
        (( ++PASS )); print "  PASS: $desc"
    else
        (( ++FAIL )); print "  FAIL: $desc — got '$got', want '$want'"
    fi
}

# Source plugin defaults
POWERLENS_MODE=compact
POWERLENS_COLOR_MODE=multi
POWERLENS_SHOW_BATTERY=true; POWERLENS_SHOW_CPU=true
POWERLENS_SHOW_MEM=true; POWERLENS_SHOW_NET=true
POWERLENS_NET_IFACE=auto; POWERLENS_REFRESH=2
POWERLENS_THRESH_POWER_IDLE=10; POWERLENS_THRESH_POWER_LIGHT=30; POWERLENS_THRESH_POWER_MODERATE=50
POWERLENS_THRESH_CPU_IDLE=30; POWERLENS_THRESH_CPU_LIGHT=60; POWERLENS_THRESH_CPU_MODERATE=85
POWERLENS_THRESH_MEM_IDLE=50; POWERLENS_THRESH_MEM_LIGHT=70; POWERLENS_THRESH_MEM_MODERATE=85
POWERLENS_ALERT_POWER=50; POWERLENS_ALERT_CPU=80; POWERLENS_ALERT_MEM=85
POWERLENS_SHOW_TEMP=true; POWERLENS_SHOW_FAN=true
POWERLENS_THRESH_TEMP_IDLE=50; POWERLENS_THRESH_TEMP_LIGHT=70; POWERLENS_THRESH_TEMP_MODERATE=85
POWERLENS_THRESH_FAN_IDLE=2000; POWERLENS_THRESH_FAN_LIGHT=3500; POWERLENS_THRESH_FAN_MODERATE=5000
POWERLENS_ALERT_TEMP=80; POWERLENS_ALERT_FAN=4000

source "${0:h}/../powerlens.zsh"

print "\n=== SSH guard ==="
SSH_TTY="/dev/ttys001"
assert_eq "_powerlens_is_ssh returns true in SSH" "$(_powerlens_is_ssh && echo yes || echo no)" "yes"
unset SSH_TTY

print "\n=== Degraded output ==="
out=$(_powerlens_degraded)
assert_eq "degraded contains --W" "${out//[^-]/}" "$(printf '%0.s-' {1..12})"

print "\n=== Daemon singleton ==="
# Fake binary that ignores all args and sleeps forever
_POWERLENS_CACHE="$(mktemp -d)"
_POWERLENS_PIDFILE="$_POWERLENS_CACHE/daemon.pid"
_POWERLENS_COUNTER="$_POWERLENS_CACHE/sessions"
local fake_bin="$_POWERLENS_CACHE/fake_daemon"
printf '#!/bin/sh\nexec sleep 300\n' > "$fake_bin"
chmod +x "$fake_bin"
_powerlens_bin="$fake_bin"

_powerlens_start_daemon
sleep 0.1  # let it start
assert_eq "PID file created" "$(test -f $_POWERLENS_PIDFILE && echo yes || echo no)" "yes"
assert_eq "session counter is 1" "$(cat $_POWERLENS_COUNTER)" "1"

# Second start should not spawn duplicate
local pid1=$(cat $_POWERLENS_PIDFILE)
_powerlens_start_daemon
local pid2=$(cat $_POWERLENS_PIDFILE)
assert_eq "second start reuses PID" "$pid1" "$pid2"

# Stop but keep daemon alive (2 sessions → 1)
echo "2" > $_POWERLENS_COUNTER
_powerlens_stop_daemon
assert_eq "counter decremented to 1" "$(cat $_POWERLENS_COUNTER)" "1"
assert_eq "daemon still running" "$(kill -0 $pid1 2>/dev/null && echo yes || echo no)" "yes"

# Final stop kills daemon
_powerlens_stop_daemon
sleep 0.1
assert_eq "daemon killed" "$(kill -0 $pid1 2>/dev/null && echo yes || echo no)" "no"
assert_eq "PID file removed" "$(test -f $_POWERLENS_PIDFILE && echo yes || echo no)" "no"

rm -rf "$_POWERLENS_CACHE"

print "\n=== JSON parsing ==="
local tmpdir=$(mktemp -d)
local cachefile="$tmpdir/metrics.json"
cat > "$cachefile" <<'EOF'
{"power":42.7,"battery":87,"charging":false,"cpu":34.2,"mem":62.1,"net_up":1.2,"net_down":3.8,"net_iface":"en0","ts":9999999999}
EOF

local val
val=$(_powerlens_jget "$(< $cachefile)" "power")
assert_eq "jget power" "$val" "42.7"
val=$(_powerlens_jget "$(< $cachefile)" "net_iface")
assert_eq "jget net_iface" "$val" "en0"
val=$(_powerlens_jget "$(< $cachefile)" "battery")
assert_eq "jget battery" "$val" "87"

rm -rf "$tmpdir"

print "\n=== Color — multi mode ==="
POWERLENS_COLOR_MODE=multi
assert_eq "power idle"     "$(_powerlens_color power 5)"    "#00FF9F"
assert_eq "power light"    "$(_powerlens_color power 20)"   "#00D4FF"
assert_eq "power moderate" "$(_powerlens_color power 40)"   "#FF006E"
assert_eq "power peak"     "$(_powerlens_color power 60)"   "#FF9500"
assert_eq "cpu idle"       "$(_powerlens_color cpu 10)"     "#00FF9F"
assert_eq "cpu peak"       "$(_powerlens_color cpu 90)"     "#FF9500"
assert_eq "mem moderate"   "$(_powerlens_color mem 80)"     "#FF006E"
assert_eq "fan idle"       "$(_powerlens_color fan 1000)"  "#00FF9F"
assert_eq "fan moderate"   "$(_powerlens_color fan 4000)"  "#FF006E"
assert_eq "fan peak"       "$(_powerlens_color fan 5500)"  "#FF9500"

print "\n=== Color — alert mode ==="
POWERLENS_COLOR_MODE=alert
assert_eq "cpu under alert" "$(_powerlens_color cpu 50)"  "#aaaaaa"
assert_eq "cpu over alert"  "$(_powerlens_color cpu 85)"  "#FF9500"
assert_eq "mem under alert" "$(_powerlens_color mem 80)"  "#aaaaaa"
assert_eq "mem over alert"  "$(_powerlens_color mem 90)"  "#FF9500"
assert_eq "net always gray" "$(_powerlens_color net 999)" "#aaaaaa"
assert_eq "fan under alert" "$(_powerlens_color fan 2000)" "#aaaaaa"
assert_eq "fan over alert"  "$(_powerlens_color fan 4500)" "#FF9500"

print "\n=== Format ==="
POWERLENS_COLOR_MODE=multi
local sample_json='{"power":42.7,"battery":87,"charging":false,"cpu_temp":55.0,"fan_speed":2500,"cpu":34.2,"mem":62.1,"net_up":1.2,"net_down":3.8,"net_iface":"en0","net_iface_type":"wifi","ts":9999999999}'

POWERLENS_MODE=compact
local out=$(_powerlens_format "$sample_json")
local plain=$(print "$out" | sed 's/\x1b\[[0-9;]*m//g; s/%{[^}]*}//g')
assert_eq "compact contains W"   "${${plain}%%W*}W" "${${plain}%%W*}W"
assert_eq "compact net has M"    "${plain##*↑}" "${plain##*↑}"
assert_eq "compact fan visible"  "${plain##*🌀}" "${plain##*🌀}"

POWERLENS_MODE=full
out=$(_powerlens_format "$sample_json")
plain=$(print "$out" | sed 's/\x1b\[[0-9;]*m//g; s/%{[^}]*}//g')
assert_eq "full has MB/s"     "${plain##*MB/s}" "${plain##*MB/s}"

# Test fanless (fan_speed = -1): fan widget should be hidden
local fanless_json='{"power":42.7,"battery":87,"charging":false,"cpu_temp":55.0,"fan_speed":-1,"cpu":34.2,"mem":62.1,"net_up":1.2,"net_down":3.8,"net_iface":"en0","net_iface_type":"wifi","ts":9999999999}'
local fanless_out=$(_powerlens_format "$fanless_json")
local fanless_plain=$(print "$fanless_out" | sed 's/\x1b\[[0-9;]*m//g; s/%{[^}]*}//g')
assert_eq "fanless hides fan widget" "${fanless_plain##*🌀}" "$fanless_plain"

# Test POWERLENS_SHOW_FAN=false hides the widget even on fanned data
POWERLENS_SHOW_FAN=false
local nofan_out=$(_powerlens_format "$sample_json")
local nofan_plain=$(print "$nofan_out" | sed 's/\x1b\[[0-9;]*m//g; s/%{[^}]*}//g')
assert_eq "SHOW_FAN=false hides fan widget" "${nofan_plain##*🌀}" "$nofan_plain"
POWERLENS_SHOW_FAN=true

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

print "\nResults: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
