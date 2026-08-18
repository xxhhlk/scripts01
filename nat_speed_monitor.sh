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
# 环境变量:
#   NAT_MON_TARGETS      受控目标列表 (空格分隔, 格式 "type:name"), 必须设置, 无默认值
#                        例: NAT_MON_TARGETS="systemd:nat.service docker:iptv-rust 1pctl:"
#   NAT_MON_LIMIT_TARGET 限速特例目标 (留空则关闭该特例, 无默认值)
#   NAT_MON_LIMIT_KBIT   限速特例上行速率 (kbit/s, 默认 40)
#   NAT_MON_LIMIT_DOWN_KBIT 限速特例下行速率 (kbit/s, 默认 40)
#   PUBIP_FALLBACK       在线获取公网IP失败时的回退地址 (无默认值, 不设置且获取失败则退出)
#   DRY_RUN=1            只记录动作, 不真正执行
#   MODE=start           一次性手动启动所有目标并退出
#
set -u

# ===== 配置 =====
URL='https://aliyun-client-assist.oss-accelerate.aliyuncs.com/client/releases/win32/x64/alibaba-cloud-client-latest.exe?spm=a2c4g.11186623.0.0.2a784f2eAiRpmW&file=alibaba-cloud-client-latest.exe'
THRESHOLD_KBPS=200          # wget 复测带宽阈值 (KB/s)
FLOW_THRESHOLD_KBPS=200     # 真实流量每方向每秒阈值 (KB/s)
SAMPLE_INTERVAL=2           # 采样间隔 (秒)
WINDOW_TIME=60              # 滑动窗口时间长度 (秒)，会自动换算为采样点数
PROBE_VALID_NORMAL=60       # 正常结果缓存有效期 (秒)
PROBE_VALID_THROTTLED=180   # 限速结果缓存有效期 (秒)
HIGH_THRESHOLD_PEAK=4       # 高峰时段窗口中需高于流量阈值的秒数
HIGH_THRESHOLD_OFFPEAK=2    # 低谷时段窗口中需高于流量阈值的秒数
# 低谷时间: 工作日 1:00~7:00, 周末 2:00~8:00
DURATION=3                  # wget 下载探测秒数
TRIG_COOLDOWN=60            # 同类型 TRIG 提示冷却时间(秒)，防止低流量常态下刷屏
LOG_FILE='/var/log/nat_speed_monitor.log'
DRY_RUN="${DRY_RUN:-0}"
MODE="${MODE:-daemon}"
WINDOW_SAMPLES=$((WINDOW_TIME / SAMPLE_INTERVAL))  # 窗口采样点数

# 本机公网 IPv4: 运行时在线获取 (见 get_pubip); 获取失败则回退 PUBIP_FALLBACK(仅当已显式设置)
# 用于 nftables 排除公网回环虚高
# PUBIP_FALLBACK 无默认值 —— 必须显式设置, 否则在线获取失败则退出
PUBIP_FALLBACK="${PUBIP_FALLBACK:-}"
PUBIP=''   # 运行时由 get_pubip 填充
NFT_TABLE='inet natmon'

# 受控目标列表: 每行 "type:name" (无默认值, 由 NAT_MON_TARGETS 提供)
#   systemd -> systemctl stop/start <name>
#   docker  -> docker stop/start <name>
#   1pctl   -> 1pctl stop / 1pctl start (name 留空, 即 "1pctl:")
#   x-ui    -> x-ui stop / x-ui start (name 留空, 即 "x-ui:")
# 必须通过环境变量 NAT_MON_TARGETS 提供 (无默认值); 未设置则 TARGETS 为空
if [ -n "${NAT_MON_TARGETS:-}" ]; then
  TARGETS=()
  set -f   # 禁用路径名展开, 防止目标名含 * ? 触发 glob
  for entry in $NAT_MON_TARGETS; do
    [ -n "$entry" ] && TARGETS+=("$entry")
  done
  set +f
fi

# 限速特例目标: 停止动作不杀进程，改为双向分别限速 (单位 kbit/s)
#   上行: OUTPUT 打 mark 0x10 经 ifb0 class 1:30 限速
#   下行: 上行 CONNMARK 保存, eth0 ingress 还原为 mark 0x20 经 ifb0 class 1:31 限速
#   5KB/s = 40kbit; 若想改回 5kbit ≈ 0.6KB/s
# 通过环境变量 NAT_MON_LIMIT_TARGET 提供 (留空则关闭该特例, 无默认值)
LIMIT_TARGET="${NAT_MON_LIMIT_TARGET:-}"
LIMIT_UP_KBIT="${NAT_MON_LIMIT_KBIT:-40}"
LIMIT_DOWN_KBIT="${NAT_MON_LIMIT_DOWN_KBIT:-40}"

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

# ===== 在线获取本机公网 IPv4 =====
# 依次尝试多个端点 (curl 优先, 否则 wget), 提取首个合法 IPv4; 全部失败返回空串
get_pubip() {
  local ip ep
  local eps=(
    "https://ifconfig.me/ip"
    "https://ip.sb"
    "https://api.ipify.org"
    "https://icanhazip.com"
    "https://myip.ipip.net"
  )
  for ep in "${eps[@]}"; do
    if command -v curl >/dev/null 2>&1; then
      ip=$(curl -s --max-time 5 "$ep" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
      ip=$(wget -qO- --timeout=5 "$ep" 2>/dev/null)
    else
      return 1
    fi
    ip=$(printf '%s' "$ip" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

# ===== nftables 真实公网流量计数器 =====
# 背景: eth0 的 /proc/net/dev 计数含"公网回环"虚高 —— 本机 derper↔tailscaled 经
#       本机公网 IP 走回环, 数据出又进各计一次, 中继转发量虚增约一倍。
# 方案: 只统计"非回环"的公网流量:
#   真实公网入站 = 源 != 本机公网IP  (回环入站的源 = 本机公网IP)
#   真实公网出站 = 目标 != 本机公网IP (回环出站的目标 = 本机公网IP)
# 说明: 阿里云网关会把公网 IP 与内网 IP(eth0)互做 NAT, 但回环包在 eth0 上
#       源/目标仍表现为本机公网IP, 上述两条规则即可精确排除。
init_nft() {
  if ! nft list table "$NFT_TABLE" >/dev/null 2>&1; then
    nft add table "$NFT_TABLE"
    nft add counter "$NFT_TABLE" in_real
    nft add counter "$NFT_TABLE" out_real
    nft add chain "$NFT_TABLE" in "{ type filter hook prerouting priority -200; policy accept; }"
    nft add chain "$NFT_TABLE" out "{ type filter hook postrouting priority -200; policy accept; }"
  fi
  # 幂等重建规则 (counter 累计值保留, 由 init_counters 做基线)
  nft flush chain "$NFT_TABLE" in 2>/dev/null
  nft flush chain "$NFT_TABLE" out 2>/dev/null
  nft add rule "$NFT_TABLE" in iif "$INTERFACE" ip saddr != "$PUBIP" counter name in_real
  nft add rule "$NFT_TABLE" out oif "$INTERFACE" ip daddr != "$PUBIP" counter name out_real
}

# 读取 nft 计数器累计字节, 失败返回空串
nft_get_bytes() {
  nft list counter "$NFT_TABLE" "$1" 2>/dev/null \
    | grep -oE 'bytes [0-9]+' | grep -oE '[0-9]+' | head -1
}

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

# ===== 双向分别限速 (并入 ifb0 CAKE 架构, 完全不动 eth0/fq_pie) =====
# 前提: cake_qos.sh (SHARED_MODE=true) 已建 ifb0 htb 1: 树 (class 1:10 上行 / 1:20 下行)
#      且 eth0 入站已重定向到 ifb0 (ingress qdisc 存在)
# 上行: iptables OUTPUT cgroup 打 mark 0x10 (IPv4+IPv6) → ifb0 prio 0 fw filter → class 1:30
# 下行: 上行时对 conntrack 做 CONNMARK --save-mark 0x10;
#       eth0 ingress 用 tc action connmark 还原 → skbedit mark 0x20 → ifb0 class 1:31
#       (进站 skb 此时尚无 cgroup/skb->sk, xt_cgroup 不可靠, 必须走 connmark)
tc_limit_bidir() {
  systemctl start "$LIMIT_TARGET" >/dev/null 2>&1   # 限速≠停止，确保服务在跑
  if ! tc qdisc show dev ifb0 | grep -q 'htb 1:'; then
    log "[LIMIT] 错误: ifb0 无 htb 1: 树 (未运行 cake_qos.sh?)，跳过限速"
    return 1
  fi

  # ---------- 上行: OUTPUT 打标 + CONNMARK 保存 ----------
  iptables -t mangle -C OUTPUT -m cgroup --path "system.slice/${LIMIT_TARGET}" -j MARK --set-mark 0x10 2>/dev/null \
    || iptables -t mangle -A OUTPUT -m cgroup --path "system.slice/${LIMIT_TARGET}" -j MARK --set-mark 0x10
  ip6tables -t mangle -C OUTPUT -m cgroup --path "system.slice/${LIMIT_TARGET}" -j MARK --set-mark 0x10 2>/dev/null \
    || ip6tables -t mangle -A OUTPUT -m cgroup --path "system.slice/${LIMIT_TARGET}" -j MARK --set-mark 0x10
  # CONNMARK 保存: 让该连接的下行回包能被识别
  iptables -t mangle -C OUTPUT -m cgroup --path "system.slice/${LIMIT_TARGET}" -j CONNMARK --save-mark 2>/dev/null \
    || iptables -t mangle -A OUTPUT -m cgroup --path "system.slice/${LIMIT_TARGET}" -j CONNMARK --save-mark
  ip6tables -t mangle -C OUTPUT -m cgroup --path "system.slice/${LIMIT_TARGET}" -j CONNMARK --save-mark 2>/dev/null \
    || ip6tables -t mangle -A OUTPUT -m cgroup --path "system.slice/${LIMIT_TARGET}" -j CONNMARK --save-mark

  # ---------- 下行: eth0 ingress connmark 还原 -> mark 0x20 ----------
  if tc qdisc show dev "$INTERFACE" | grep -q 'ingress'; then
    # prio 98: 还原 conntrack mark 到 skb (不终止, 继续走后续 filter)
    if ! tc filter add dev "$INTERFACE" ingress parent ffff: prio 98 protocol all u32 match u32 0 0 action connmark 2>/dev/null; then
      log "[LIMIT] 警告: 添加 eth0 ingress connmark 过滤器失败 (缺 act_connmark 模块?), 下行限速可能不生效"
    fi
    # prio 99: 还原后 mark==0x10 的连接 -> 改写为 0x20 (仅命中限速连接)
    tc filter add dev "$INTERFACE" ingress parent ffff: prio 99 protocol all handle 0x10 fw action skbedit mark 0x20 2>/dev/null \
      || true
  else
    log "[LIMIT] 警告: ${INTERFACE} 无 ingress qdisc (cake_qos.sh 未重定向入站?), 下行限速可能不生效"
  fi

  # ---------- ifb0 双向限速类 ----------
  # 上行 1:30
  if tc class show dev ifb0 | grep -q 'class htb 1:30'; then
    tc class change dev ifb0 classid 1:30 htb rate "${LIMIT_UP_KBIT}kbit" ceil "${LIMIT_UP_KBIT}kbit" burst 8k cburst 8k
  else
    tc class add dev ifb0 parent 1:1 classid 1:30 htb rate "${LIMIT_UP_KBIT}kbit" ceil "${LIMIT_UP_KBIT}kbit" burst 8k cburst 8k
    tc qdisc add dev ifb0 parent 1:30 handle 30: cake besteffort triple-isolate rtt 100ms nat
  fi
  tc filter add dev ifb0 protocol ip parent 1:0 prio 0 handle 0x10 fw flowid 1:30 2>/dev/null
  tc filter add dev ifb0 protocol ipv6 parent 1:0 prio 0 handle 0x10 fw flowid 1:30 2>/dev/null
  # 下行 1:31
  if tc class show dev ifb0 | grep -q 'class htb 1:31'; then
    tc class change dev ifb0 classid 1:31 htb rate "${LIMIT_DOWN_KBIT}kbit" ceil "${LIMIT_DOWN_KBIT}kbit" burst 8k cburst 8k
  else
    tc class add dev ifb0 parent 1:1 classid 1:31 htb rate "${LIMIT_DOWN_KBIT}kbit" ceil "${LIMIT_DOWN_KBIT}kbit" burst 8k cburst 8k
    tc qdisc add dev ifb0 parent 1:31 handle 31: cake besteffort triple-isolate rtt 100ms nat
  fi
  tc filter add dev ifb0 protocol ip parent 1:0 prio 0 handle 0x20 fw flowid 1:31 2>/dev/null
  tc filter add dev ifb0 protocol ipv6 parent 1:0 prio 0 handle 0x20 fw flowid 1:31 2>/dev/null

  log "[LIMIT] 已限 ${LIMIT_TARGET} 上行 ${LIMIT_UP_KBIT}kbit/s / 下行 ${LIMIT_DOWN_KBIT}kbit/s (ifb0 1:30/1:31 cake)"
}

tc_limit_bidir_clear() {
  systemctl start "$LIMIT_TARGET" >/dev/null 2>&1   # 恢复启动语义: 确保服务在跑
  # 上行标记 + connmark
  iptables -t mangle -D OUTPUT -m cgroup --path "system.slice/${LIMIT_TARGET}" -j MARK --set-mark 0x10 2>/dev/null
  ip6tables -t mangle -D OUTPUT -m cgroup --path "system.slice/${LIMIT_TARGET}" -j MARK --set-mark 0x10 2>/dev/null
  iptables -t mangle -D OUTPUT -m cgroup --path "system.slice/${LIMIT_TARGET}" -j CONNMARK --save-mark 2>/dev/null
  ip6tables -t mangle -D OUTPUT -m cgroup --path "system.slice/${LIMIT_TARGET}" -j CONNMARK --save-mark 2>/dev/null
  # 下行 eth0 ingress 过滤器 (按 prio 精确删除, 不动 cake_qos.sh 其它规则)
  tc filter del dev "$INTERFACE" ingress prio 98 2>/dev/null
  tc filter del dev "$INTERFACE" ingress prio 99 2>/dev/null
  # ifb0 双向限速类 + fw filter
  tc filter del dev ifb0 protocol ip parent 1:0 prio 0 handle 0x10 fw 2>/dev/null
  tc filter del dev ifb0 protocol ipv6 parent 1:0 prio 0 handle 0x10 fw 2>/dev/null
  tc filter del dev ifb0 protocol ip parent 1:0 prio 0 handle 0x20 fw 2>/dev/null
  tc filter del dev ifb0 protocol ipv6 parent 1:0 prio 0 handle 0x20 fw 2>/dev/null
  tc qdisc del dev ifb0 parent 1:30 handle 30: 2>/dev/null
  tc class del dev ifb0 parent 1:1 classid 1:30 2>/dev/null
  tc qdisc del dev ifb0 parent 1:31 handle 31: 2>/dev/null
  tc class del dev ifb0 parent 1:1 classid 1:31 2>/dev/null
  log "[LIMIT] 已解除 ${LIMIT_TARGET} 双向限速并确保服务运行"
}


# ===== 对单个目标执行 stop/start =====
apply_one() {
  local action="$1" type="$2" name="$3" rc label
  label="${type}: ${name:-${type}}"
  case "$type" in
    systemd)
      systemctl list-unit-files "$name" >/dev/null 2>&1 || { log "[SKIP] 未找到 unit: $name"; return; }
      if [ "$name" = "$LIMIT_TARGET" ]; then
        # 特例: 对应服务不停止，改为双向分别限速 / 恢复时解除限速
        if [ "$action" = "stop" ]; then tc_limit_bidir; else tc_limit_bidir_clear; fi
      elif [ "$action" = "stop" ]; then
        systemctl stop "$name"
      else
        systemctl start "$name"
      fi
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

# ===== 读取本秒真实公网流量 (分方向 RX/TX KB/s) =====
# 数据源: nftables 计数器 in_real (真实公网入站) / out_real (真实公网出站)
#         已排除本机公网回环, 不再读 /proc/net/dev (含回环虚高)
read_flow() {
  local cur_in cur_out din dout
  cur_in=$(nft_get_bytes in_real)
  cur_out=$(nft_get_bytes out_real)
  if [ -z "$cur_in" ] || [ -z "$cur_out" ]; then
    init_nft
    cur_in=$(nft_get_bytes in_real)
    cur_out=$(nft_get_bytes out_real)
    [ -z "$cur_in" ] && cur_in=0
    [ -z "$cur_out" ] && cur_out=0
  fi
  if [ "$PREV_RX" -eq 0 ] && [ "$PREV_TX" -eq 0 ]; then
    PREV_RX=$cur_in; PREV_TX=$cur_out
    FLOW_RX=0; FLOW_TX=0
    return
  fi
  din=$((cur_in - PREV_RX))
  dout=$((cur_out - PREV_TX))
  PREV_RX=$cur_in; PREV_TX=$cur_out
  if [ "$din" -lt 0 ]; then din=0; fi
  if [ "$dout" -lt 0 ]; then dout=0; fi
  FLOW_RX=$(awk -v d="$din" -v n="$SAMPLE_INTERVAL" 'BEGIN{printf "%.1f", d/1024/n}')
  FLOW_TX=$(awk -v d="$dout" -v n="$SAMPLE_INTERVAL" 'BEGIN{printf "%.1f", d/1024/n}')
}

# ===== 初始化计数器 =====
init_counters() {
  PREV_RX=$(nft_get_bytes in_real)
  PREV_TX=$(nft_get_bytes out_real)
  [ -z "$PREV_RX" ] && PREV_RX=0
  [ -z "$PREV_TX" ] && PREV_TX=0
}

# ===== 窗口判断 (传入窗口数组引用名) =====
win_all_below() {
  local -n arr
  arr="$1"
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
  local -n arr
  arr="$1"
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
  local -n arr
  arr="$1"
  local kbps="$2"
  if [ "${#arr[@]}" -lt "$WINDOW_SAMPLES" ]; then
    arr+=("$kbps")
  else
    arr[WIN_IDX]="$kbps"
  fi
}

# ===== 窗口统计 (传入数组引用名) =====
# 结果通过全局 WIN_MIN / WIN_MAX / WIN_AVG 返回
win_stats() {
  local -n arr
  arr="$1"
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

# ===== 在线获取本机公网 IPv4 =====
PUBIP="$(get_pubip)"
if [ -z "$PUBIP" ]; then
  if [ -n "$PUBIP_FALLBACK" ]; then
    log "[WARN] 在线获取公网IP失败, 回退 PUBIP_FALLBACK=${PUBIP_FALLBACK}"
    PUBIP="$PUBIP_FALLBACK"
  else
    log "[FATAL] 在线获取公网IP失败且未设置 PUBIP_FALLBACK, 无法排除公网回环, 退出"
    exit 1
  fi
else
  log "[INFO] 在线获取公网IP: ${PUBIP}"
fi

init_nft
log "[INFO] daemon 启动 | 网卡=${INTERFACE} | 真实公网流量(nft ${NFT_TABLE}, 排除${PUBIP}回环) | 采样=${SAMPLE_INTERVAL}s | 阈值=${FLOW_THRESHOLD_KBPS} KB/s (分方向) | 窗口=${WINDOW_TIME}s(${WINDOW_SAMPLES}点) | 缓存: 正常=${PROBE_VALID_NORMAL}s 限速=${PROBE_VALID_THROTTLED}s | DRY_RUN=${DRY_RUN}${LIMIT_TARGET:+| 限速特例=${LIMIT_TARGET}(上${LIMIT_UP_KBIT}/下${LIMIT_DOWN_KBIT}kbit)}"
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
