#!/bin/bash
#
# nat_speed_monitor.sh (daemon 版，分方向监控)
# 常驻后台，每秒读取 /proc/net/dev 上下行各自流量；
# 上下行各维护 30 秒滑动窗口；
# 两个方向窗口内全部低于阈值 → wget 复测 → 确认限速则停止所有 TARGETS；
# 任一方向窗口内出现高于阈值      → wget 复测 → 确认恢复则启动所有 TARGETS。
# wget 复测结果缓存 60 秒，有效期内不重复探测。
#
# 用法:
#   /usr/local/bin/nat_speed_monitor.sh            # 前台运行 daemon
#   DRY_RUN=1 .../nat_speed_monitor.sh             # 只记录动作，不真正执行
#   MODE=start .../nat_speed_monitor.sh            # 一次性手动启动所有目标并退出
#
set -u

# ===== 配置 =====
URL='https://aliyun-client-assist.oss-accelerate.aliyuncs.com/client/releases/win32/x64/alibaba-cloud-client-latest.exe?spm=a2c4g.11186623.0.0.2a784f2eAiRpmW&file=alibaba-cloud-client-latest.exe'
THRESHOLD_KBPS=200          # wget 复测带宽阈值 (KB/s)
FLOW_THRESHOLD_KBPS=300     # 真实流量每方向每秒阈值 (KB/s)
SAMPLE_INTERVAL=2           # 采样间隔 (秒)
WINDOW_TIME=60              # 滑动窗口时间长度 (秒)，会自动换算为采样点数
PROBE_VALID_NORMAL=100       # 正常结果缓存有效期 (秒)
PROBE_VALID_THROTTLED=300   # 限速结果缓存有效期 (秒)
HIGH_THRESHOLD_PEAK=3       # 高峰时段窗口中需高于流量阈值的秒数
HIGH_THRESHOLD_OFFPEAK=1    # 低谷时段窗口中需高于流量阈值的秒数
# 低谷时间: 工作日 1:00~7:00, 周末 2:00~8:00
DURATION=3                  # wget 下载探测秒数
TRIG_COOLDOWN=60            # 同类型 TRIG 提示冷却时间(秒)，防止低流量常态下刷屏
LOG_FILE='/var/log/nat_speed_monitor.log'
DRY_RUN="${DRY_RUN:-0}"
MODE="${MODE:-daemon}"
WINDOW_SAMPLES=$((WINDOW_TIME / SAMPLE_INTERVAL))  # 窗口采样点数

# 受控目标列表: 每行 "type:name"
#   systemd -> systemctl stop/start <name>
#   docker  -> docker stop/start <name>
#   1pctl   -> 1pctl stop / 1pctl start (name 留空)
#   x-ui    -> x-ui stop / x-ui start (name 留空)
TARGETS=(
  "systemd:nat.service"
  "systemd:uinetd.service"
  "systemd:hentaihome.service"
  "1pctl:"
  "docker:1Panel-openresty-RoFl"
  "docker:iptv-rust"
  "x-ui:"
)

# ===== 工具探测 =====
HAS_DOCKER="$(command -v docker >/dev/null 2>&1 && echo 1 || echo 0)"
ONEPCTL_BIN="$(command -v 1pctl 2>/dev/null || true)"
[ -z "$ONEPCTL_BIN" ] && [ -x /usr/local/bin/1pctl ] && ONEPCTL_BIN=/usr/local/bin/1pctl
[ -z "$ONEPCTL_BIN" ] && [ -x /opt/1panel/1pctl ] && ONEPCTL_BIN=/opt/1panel/1pctl
XUI_BIN="$(command -v x-ui 2>/dev/null || true)"

# 主网卡
INTERFACE=$(ip route get 223.5.5.5 2>/dev/null | grep -Po '(?<=dev )(\S+)')
[ -z "${INTERFACE:-}" ] && INTERFACE=$(ip link show | grep -Po '^\d+: \K[^:@]+' | grep -v lo | head -1)
[ -z "${INTERFACE:-}" ] && { echo "$(date '+%F %T') [FATAL] 无法识别主网卡" >> "$LOG_FILE"; exit 1; }

# ===== 全局状态 =====
STATE='UNKNOWN'                       # UNKNOWN → 窗口满后立即 wget 决定初始状态 → NORMAL / STOPPED
LAST_PROBE_RESULT=''                  # throttled / normal / ''
LAST_PROBE_TS=0                       # epoch seconds
# 分方向窗口: RX=下载方向(download), TX=上传方向(upload)
declare -a WIN_RX=() WIN_TX=()
declare -i WIN_IDX=0
declare -i HIGH_COUNT=0   # UNKNOWN 采集期高于阈值的秒数
LAST_TRIG_TS=0            # 上次 TRIG 日志时间戳(秒)，用于冷却抑制
LAST_CACHE_TS=0           # 上次 CACHE 跳过复测日志时间戳(秒)，用于冷却抑制
PREV_RX=0 PREV_TX=0

# ===== 工具函数 =====
log() { echo "$(date '+%F %T') $*" >> "$LOG_FILE"; }

# ===== TRIG 日志冷却抑制 (TRIG_COOLDOWN 秒内同类型只记录一次) =====
trig_log() {
  local now
  now=$(date +%s)
  if [ $(( now - LAST_TRIG_TS )) -ge "$TRIG_COOLDOWN" ]; then
    LAST_TRIG_TS=$now
    log "$*"
  fi
}

# ===== CACHE 跳过复测日志冷却抑制 (TRIG_COOLDOWN 秒内只记录一次) =====
cache_log() {
  local now
  now=$(date +%s)
  if [ $(( now - LAST_CACHE_TS )) -ge "$TRIG_COOLDOWN" ]; then
    LAST_CACHE_TS=$now
    log "$*"
  fi
}

# ===== 对单个目标执行 stop/start =====
apply_one() {
  local action="$1" type="$2" name="$3" rc label
  label="${type}: ${name:-${type}}"
  case "$type" in
    systemd)
      systemctl list-unit-files "$name" >/dev/null 2>&1 || { log "[SKIP] 未找到 unit: $name"; return; }
      if [ "$action" = "stop" ]; then systemctl stop "$name"; else systemctl start "$name"; fi
      ;;
    1pctl)
      [ -n "$ONEPCTL_BIN" ] || { log "[SKIP] 1pctl 不可用"; return; }
      if [ "$action" = "stop" ]; then "$ONEPCTL_BIN" stop; else "$ONEPCTL_BIN" start; fi
      ;;
    x-ui)
      [ -n "$XUI_BIN" ] || { log "[SKIP] x-ui 不可用"; return; }
      if [ "$action" = "stop" ]; then "$XUI_BIN" stop; else "$XUI_BIN" start; fi
      ;;
    docker)
      [ "$HAS_DOCKER" = "1" ] || { log "[SKIP] docker 不可用"; return; }
      docker inspect "$name" >/dev/null 2>&1 || { log "[SKIP] 容器不存在: $name"; return; }
      if [ "$action" = "stop" ]; then docker stop "$name"; else docker start "$name"; fi
      ;;
    *)
      log "[SKIP] 未知类型: $type"; return ;;
  esac
  rc=$?
  log "[ACTION] ${action} (${label}) 返回码: $rc"
}

apply_all() {
  local action="$1" verb
  [ "$action" = "stop" ] && verb='停止' || verb='启动'
  for t in "${TARGETS[@]}"; do
    local type="${t%%:*}" name="${t#*:}"
    if [ "$DRY_RUN" = "1" ]; then
      log "[DRYRUN] 将${verb}: (${type}) ${name:-${type}}"
    else
      apply_one "$action" "$type" "$name"
    fi
  done
}

# ===== wget 复测 =====
wget_probe() {
  local OUT BYTES SECS SPEED_BPS SPEED_KBPS THRESHOLD_BPS
  OUT=$(timeout "$DURATION" wget -O - "$URL" 2>/dev/null | dd of=/dev/null 2>&1)
  BYTES=$(printf '%s\n' "$OUT" | grep -oE '[0-9]+ bytes' | grep -oE '^[0-9]+' | head -1)
  SECS=$(printf '%s\n' "$OUT"  | grep -oE 'copied, [0-9.]+ s' | grep -oE '[0-9.]+')
  THRESHOLD_BPS=$(awk -v t="$THRESHOLD_KBPS" 'BEGIN{printf "%.0f", t*1024}')

  if [ -z "$BYTES" ] || [ -z "$SECS" ] || [ "${SECS:-0}" = "0" ]; then
    log "[PROBE] wget 复测失败 (无有效输出)"
    return 2   # 无法判断
  fi

  SPEED_BPS=$(awk -v b="$BYTES" -v s="$SECS" 'BEGIN{printf "%.0f", b/s}')
  SPEED_KBPS=$(awk -v b="$BYTES" -v s="$SECS" 'BEGIN{printf "%.1f", b/s/1024}')
  log "[PROBE] wget 平均速度 ${SPEED_KBPS} KB/s (阈值 ${THRESHOLD_KBPS} KB/s) | ${BYTES} 字节 / ${SECS}s"

  LAST_PROBE_TS=$(date +%s)
  if [ "$SPEED_BPS" -lt "$THRESHOLD_BPS" ]; then
    LAST_PROBE_RESULT='throttled'
    return 1
  else
    LAST_PROBE_RESULT='normal'
    return 0
  fi
}

# ===== 读取本秒流量 (分方向 RX/TX KB/s) =====
# 注意: 通过全局变量 FLOW_RX / FLOW_TX 返回，不能放在 $() 子shell中调用
read_flow() {
  local read_line rx_bytes tx_bytes drx dtx
  read_line=$(grep "^ *${INTERFACE}:" /proc/net/dev 2>/dev/null)
  if [ -z "$read_line" ]; then
    FLOW_RX=0; FLOW_TX=0
    return
  fi
  rx_bytes=$(echo "$read_line" | awk '{print $2}')
  tx_bytes=$(echo "$read_line" | awk '{print $10}')
  if [ "$PREV_RX" -eq 0 ] && [ "$PREV_TX" -eq 0 ]; then
    PREV_RX=$rx_bytes; PREV_TX=$tx_bytes
    FLOW_RX=0; FLOW_TX=0
    return
  fi
  drx=$((rx_bytes - PREV_RX))
  dtx=$((tx_bytes - PREV_TX))
  PREV_RX=$rx_bytes; PREV_TX=$tx_bytes
  if [ "$drx" -lt 0 ]; then drx=0; fi
  if [ "$dtx" -lt 0 ]; then dtx=0; fi
  FLOW_RX=$(awk -v d="$drx" -v n="$SAMPLE_INTERVAL" 'BEGIN{printf "%.1f", d/1024/n}')
  FLOW_TX=$(awk -v d="$dtx" -v n="$SAMPLE_INTERVAL" 'BEGIN{printf "%.1f", d/1024/n}')
}

# ===== 初始化计数器 =====
init_counters() {
  local read_line rx_bytes tx_bytes
  read_line=$(grep "^ *${INTERFACE}:" /proc/net/dev 2>/dev/null)
  if [ -n "$read_line" ]; then
    rx_bytes=$(echo "$read_line" | awk '{print $2}')
    tx_bytes=$(echo "$read_line" | awk '{print $10}')
    PREV_RX=$rx_bytes; PREV_TX=$tx_bytes
  fi
}

# ===== 窗口判断 (传入窗口数组引用名) =====
win_all_below() {
  local -n arr="$1"
  local v
  [ "${#arr[@]}" -lt "$WINDOW_SAMPLES" ] && return 1
  for v in "${arr[@]}"; do
    if awk -v a="$v" -v t="$FLOW_THRESHOLD_KBPS" 'BEGIN{exit(a>=t?0:1)}'; then
      return 1
    fi
  done
  return 0
}

win_any_above() {
  local -n arr="$1"
  local v
  [ "${#arr[@]}" -lt "$WINDOW_SAMPLES" ] && return 1
  for v in "${arr[@]}"; do
    if awk -v a="$v" -v t="$FLOW_THRESHOLD_KBPS" 'BEGIN{exit(a>=t?0:1)}'; then
      return 0
    fi
  done
  return 1
}

# 统计窗口中任一方向高于阈值的样本数
win_high_count() {
  local v rx_cnt=0 tx_cnt=0
  for v in "${WIN_RX[@]}"; do
    if awk -v a="$v" -v t="$FLOW_THRESHOLD_KBPS" 'BEGIN{exit(a>=t?0:1)}'; then
      rx_cnt=$((rx_cnt + 1))
    fi
  done
  for v in "${WIN_TX[@]}"; do
    if awk -v a="$v" -v t="$FLOW_THRESHOLD_KBPS" 'BEGIN{exit(a>=t?0:1)}'; then
      tx_cnt=$((tx_cnt + 1))
    fi
  done
  # 返回 max(rx_cnt, tx_cnt) — 任一方达到即可
  [ "$rx_cnt" -ge "$tx_cnt" ] && echo "$rx_cnt" || echo "$tx_cnt"
}

# 根据当前时间返回高速判定阈值 (高峰3次 / 低谷1次)
# 低谷: 工作日 1:00~7:00, 周末 2:00~8:00
get_high_threshold() {
  local dow hour
  dow=$(date +%u)                  # 1=Mon..7=Sun
  hour=$(date +%k | tr -d ' ')     # 0-23
  if [ "$dow" -ge 6 ]; then
    # 周末: 低谷 2:00~8:00
    [ "$hour" -ge 2 ] && [ "$hour" -lt 8 ] && { echo "$HIGH_THRESHOLD_OFFPEAK"; return; }
  else
    # 工作日: 低谷 1:00~7:00
    [ "$hour" -ge 1 ] && [ "$hour" -lt 7 ] && { echo "$HIGH_THRESHOLD_OFFPEAK"; return; }
  fi
  echo "$HIGH_THRESHOLD_PEAK"
}

# ===== 滑动窗口维护 =====
push_win() {
  local -n arr="$1"
  local kbps="$2"
  if [ "${#arr[@]}" -lt "$WINDOW_SAMPLES" ]; then
    arr+=("$kbps")
  else
    arr[$WIN_IDX]="$kbps"
  fi
}

# ===== 窗口统计 (传入数组引用名) =====
# 结果通过全局 WIN_MIN / WIN_MAX / WIN_AVG 返回
win_stats() {
  local -n arr="$1"
  local v sum
  WIN_MIN=$(printf '%s\n' "${arr[@]}" | sort -n | head -1)
  WIN_MAX=$(printf '%s\n' "${arr[@]}" | sort -n | tail -1)
  sum=0
  for v in "${arr[@]}"; do sum=$(awk -v s="$sum" -v v="$v" 'BEGIN{printf "%.1f", s+v}'); done
  WIN_AVG=$(awk -v s="$sum" -v n="${#arr[@]}" 'BEGIN{printf "%.1f", s/n}')
}

# ===== 复测缓存 =====
# 根据缓存结论获取对应的有效期
_probe_ttl() {
  if [ "$LAST_PROBE_RESULT" = "throttled" ]; then
    echo "$PROBE_VALID_THROTTLED"
  else
    echo "$PROBE_VALID_NORMAL"
  fi
}

probe_cache_hit() {
  local expected="$1" ttl now
  now=$(date +%s)
  [ "$LAST_PROBE_RESULT" = "$expected" ] || return 1
  ttl=$(_probe_ttl)
  [ $(( now - LAST_PROBE_TS )) -lt "$ttl" ] || return 1
  return 0
}

probe_cache_valid() {
  local ttl now
  now=$(date +%s)
  [ -n "$LAST_PROBE_RESULT" ] || return 1
  ttl=$(_probe_ttl)
  [ $(( now - LAST_PROBE_TS )) -lt "$ttl" ] || return 1
  return 0
}

# ===== 信号处理 =====
cleanup() {
  log "[INFO] 收到终止信号，退出 daemon (当前状态=${STATE})"
  exit 0
}
trap cleanup SIGINT SIGTERM

# ===== 状态转换 =====
clear_windows() {
  WIN_RX=(); WIN_TX=()
  WIN_IDX=0
  init_counters
}

do_stop() {
  local prev="$STATE"
  log "[STATE] ${prev} → STOPPED，正在停止所有目标"
  apply_all stop
  STATE='STOPPED'
  HIGH_COUNT=0
  clear_windows
}

do_start() {
  local prev="$STATE"
  log "[STATE] ${prev} → NORMAL，正在启动所有目标"
  apply_all start
  STATE='NORMAL'
  HIGH_COUNT=0
  clear_windows
}

# =====================================================================
#  主入口
# =====================================================================

# 手动恢复模式 (一次性)
if [ "$MODE" = "start" ]; then
  log "[INFO] 手动恢复模式 (MODE=start)，启动全部目标并退出"
  apply_all start
  exit 0
fi

log "[INFO] daemon 启动 | 网卡=${INTERFACE} | 采样=${SAMPLE_INTERVAL}s | 阈值=${FLOW_THRESHOLD_KBPS} KB/s (分方向) | 窗口=${WINDOW_TIME}s(${WINDOW_SAMPLES}点) | 缓存: 正常=${PROBE_VALID_NORMAL}s 限速=${PROBE_VALID_THROTTLED}s | DRY_RUN=${DRY_RUN}"
init_counters
sleep "$SAMPLE_INTERVAL"   # 先等采样间隔建立初始计数器基线

# ===== daemon 主循环 =====
while true; do
  read_flow   # 通过全局 FLOW_RX / FLOW_TX 返回
  push_win WIN_RX "$FLOW_RX"
  push_win WIN_TX "$FLOW_TX"
  # UNKNOWN 状态：采集期出现高速流量，攒够阈值次数直接跳过 wget
  if [ "$STATE" = "UNKNOWN" ] && ( awk -v a="$FLOW_RX" -v t="$FLOW_THRESHOLD_KBPS" 'BEGIN{exit(a>=t?0:1)}' || awk -v a="$FLOW_TX" -v t="$FLOW_THRESHOLD_KBPS" 'BEGIN{exit(a>=t?0:1)}' ); then
    HIGH_COUNT=$((HIGH_COUNT + 1))
    if [ "$HIGH_COUNT" -ge "$(get_high_threshold)" ]; then
      log "[INIT] 采集期已${HIGH_COUNT}次高于阈值 (需$(get_high_threshold)次)，直接判定为 normal (跳过 wget)"
      LAST_PROBE_RESULT='normal'
      LAST_PROBE_TS=$(date +%s)
      do_start
      sleep "$SAMPLE_INTERVAL"
      continue
    fi
    log "[INIT] 采集期第${#WIN_RX[@]}s 出现高速 (rx=${FLOW_RX} tx=${FLOW_TX} KB/s)，已${HIGH_COUNT}/$(get_high_threshold)次"
  fi

  # 两个窗口同步写入，只需对一个判断是否满即可
  if [ "${#WIN_RX[@]}" -lt "$WINDOW_SAMPLES" ]; then
    log "[MON] 第${#WIN_RX[@]}/${WINDOW_SAMPLES}次 (${SAMPLE_INTERVAL}s采样) rx=${FLOW_RX} tx=${FLOW_TX} KB/s 状态=${STATE} (窗口采集中)"
    sleep "$SAMPLE_INTERVAL"
    continue
  fi

  # 更新 WIN_IDX（两个窗口共用同一个环形索引）
  WIN_IDX=$(( (WIN_IDX + 1) % WINDOW_SAMPLES ))

  # 窗口统计
  win_stats WIN_RX; rx_avg="$WIN_AVG"; rx_min="$WIN_MIN"; rx_max="$WIN_MAX"
  win_stats WIN_TX; tx_avg="$WIN_AVG"; tx_min="$WIN_MIN"; tx_max="$WIN_MAX"

  if [ -z "$LAST_PROBE_RESULT" ]; then
    log "[MON] rx=${FLOW_RX} KB/s (avg=${rx_avg} min=${rx_min} max=${rx_max}) | tx=${FLOW_TX} KB/s (avg=${tx_avg} min=${tx_min} max=${tx_max}) | 状态=${STATE} | 缓存=无"
  else
    log "[MON] rx=${FLOW_RX} KB/s (avg=${rx_avg} min=${rx_min} max=${rx_max}) | tx=${FLOW_TX} KB/s (avg=${tx_avg} min=${tx_min} max=${tx_max}) | 状态=${STATE} | 缓存=${LAST_PROBE_RESULT}($(( $(date +%s) - LAST_PROBE_TS ))s前)"
  fi

  # ----- UNKNOWN 状态：窗口满后立即 wget 复测决定初始状态 -----
  if [ "$STATE" = "UNKNOWN" ]; then
    log "[INIT] 初始窗口采集完成 (高速${HIGH_COUNT}/30次)，wget 复测决定初始状态"
    wget_probe
    wget_rc=$?
    init_counters  # wget 下载期间计数器已增长，重置基线避免下次 read_flow 偏高
    if [ "$wget_rc" = "1" ]; then do_stop; elif [ "$wget_rc" = "0" ]; then do_start; else log "[INIT] wget 复测失败，下个周期重试"; fi

  # ----- NORMAL 状态：两个方向窗口都全低速 → 疑似限速 -----
  elif [ "$STATE" = "NORMAL" ] && win_all_below WIN_RX && win_all_below WIN_TX; then
    trig_log "[TRIG] 双向窗口 30s 全低速 (高速0/30)，疑似限速"

    if probe_cache_hit 'throttled'; then
      log "[CACHE] 复测缓存命中 (限速, $(( $(date +%s) - LAST_PROBE_TS ))s前)，直接停止"
      do_stop
    elif probe_cache_valid; then
      cache_log "[CACHE] 缓存有效 (${LAST_PROBE_RESULT}, $(( $(date +%s) - LAST_PROBE_TS ))s前)，跳过复测"
    else
      wget_probe
      wget_rc=$?
      init_counters  # 重置计数器基线
      if [ "$wget_rc" = "1" ]; then do_stop; elif [ "$wget_rc" = "0" ]; then log "[TRIG] wget 复测正常，保持 NORMAL"; else log "[TRIG] wget 复测失败，保持 NORMAL 不变"; fi
    fi

  # ----- NORMAL 状态：缓存过期，无论窗口如何都要主动复测 -----
  elif [ "$STATE" = "NORMAL" ] && ! probe_cache_valid; then
    HIGH_CNT=$(win_high_count)
    if [ "$HIGH_CNT" -ge "$(get_high_threshold)" ]; then
      log "[CACHE] 窗口高速${HIGH_CNT}/30 次 (需$(get_high_threshold)次)，直接刷新 normal 缓存 (跳过 wget)"
      LAST_PROBE_RESULT='normal'
      LAST_PROBE_TS=$(date +%s)
    else
      log "[PROBE] 缓存过期，wget 复测检查是否限速"
      wget_probe
      wget_rc=$?
      init_counters
      if [ "$wget_rc" = "1" ]; then do_stop; else log "[PROBE] 复测正常/失败，刷新缓存"; fi
    fi

  # ----- STOPPED 状态：任一方向窗口出现高速 → 疑似恢复 -----
  elif [ "$STATE" = "STOPPED" ] && ( win_any_above WIN_RX || win_any_above WIN_TX ); then
    HIGH_CNT=$(win_high_count)
    trig_log "[TRIG] 窗口出现高速 (${HIGH_CNT}/30 次 >${FLOW_THRESHOLD_KBPS} KB/s)，疑似恢复"

    if probe_cache_hit 'normal'; then
      log "[CACHE] 复测缓存命中 (正常, $(( $(date +%s) - LAST_PROBE_TS ))s前)，直接启动"
      do_start
    elif [ "$HIGH_CNT" -ge "$(get_high_threshold)" ]; then
      log "[CACHE] 窗口高速 ${HIGH_CNT}/30 ≥$(get_high_threshold) 次，直接判定 normal 并启动 (跳过 wget)"
      LAST_PROBE_RESULT='normal'
      LAST_PROBE_TS=$(date +%s)
      do_start
    elif probe_cache_valid; then
      cache_log "[CACHE] 缓存有效 (${LAST_PROBE_RESULT}, $(( $(date +%s) - LAST_PROBE_TS ))s前)，跳过复测"
    else
      wget_probe
      wget_rc=$?
      init_counters
      if [ "$wget_rc" = "0" ]; then do_start; elif [ "$wget_rc" = "1" ]; then log "[TRIG] wget 复测仍限速，保持 STOPPED"; else log "[TRIG] wget 复测失败，保持 STOPPED 不变"; fi
    fi

  # ----- STOPPED 状态：缓存过期，无论窗口如何都要主动复测 -----
  elif [ "$STATE" = "STOPPED" ] && ! probe_cache_valid; then
    HIGH_CNT=$(win_high_count)
    if [ "$HIGH_CNT" -ge "$(get_high_threshold)" ]; then
      log "[CACHE] 缓存过期但窗口高速 ${HIGH_CNT}/30 ≥$(get_high_threshold) 次，直接判定 normal 并启动 (跳过 wget)"
      LAST_PROBE_RESULT='normal'
      LAST_PROBE_TS=$(date +%s)
      do_start
    else
      log "[PROBE] 缓存过期，wget 复测检查是否恢复"
      wget_probe
      wget_rc=$?
      init_counters
      if [ "$wget_rc" = "0" ]; then do_start; else log "[PROBE] 复测仍限速/失败，刷新缓存"; fi
    fi
  fi

  sleep "$SAMPLE_INTERVAL"
done
