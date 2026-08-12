#!/usr/bin/env bash
#
# gen_reject_handshake.sh
# ------------------------------------------------------------------
# 自动扫描 1Panel OpenResty 网站配置中所有 "listen ... ssl" 的端口，
# 为每个端口生成一份 default_server 兜底配置（ssl_reject_handshake），
# 用 IP 直接访问这些端口时直接拒绝 TLS 握手，彻底隐藏真实证书。
# 生成后自动在 OpenResty 容器内做配置测试并热重载。
#
# 用法:
#   ./gen_reject_handshake.sh            # 生成 + 重载
#   ./gen_reject_handshake.sh --dry-run  # 只打印将要写入的内容，不落盘、不重载
#   ./gen_reject_handshake.sh --no-reload# 生成文件，但不重载
#
# 说明:
#   - 容器名前缀为 1Panel-openresty-（后缀随机），脚本自动用 docker ps 匹配。
#   - 按网络栈（IPv4 / IPv6）分别兜底：仅对确实存在非回环监听的栈生成 default_server，
#     回环监听（127.0.0.1 / [::1]）所在栈不兜底。若某栈的通配地址已声明 default_server，
#     则跳过该栈，避免 "a duplicate default server" 导致 nginx 启动/重载失败。
#   - 若容器不支持 IPv6，生成的 listen [::]:port 行会让 openresty -t 失败；
#     此时脚本会中止重载，运行中的服务不受影响，你可按提示注释掉 IPv6 行。
# ------------------------------------------------------------------

set -uo pipefail

# ---------- 路径配置 ----------
CONF_DIR="${CONF_DIR:-/opt/1panel/apps/openresty/openresty/conf}"
OUT_DIR="$CONF_DIR/conf.d"
OUT_FILE="$OUT_DIR/00_default_reject_handshake.conf"
GEN_NAME="00_default_reject_handshake.conf"   # 用于排除自身及历史备份
CONTAINER_PREFIX="1Panel-openresty-"

DRY_RUN=0
NO_RELOAD=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --no-reload) NO_RELOAD=1 ;;
    -h|--help)
      grep -E '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

# ---------- 前置检查 ----------
if [[ ! -d "$CONF_DIR" ]]; then
  echo "错误: 配置目录不存在: $CONF_DIR" >&2
  exit 1
fi

# ---------- 收集所有 listen 指令（排除生成的输出文件及其备份） ----------
TMP_LISTEN="$(mktemp)"
trap 'rm -f "$TMP_LISTEN"' EXIT

find "$CONF_DIR" -type f -name '*.conf' ! -name "${GEN_NAME}*" -print0 \
  | while IFS= read -r -d '' f; do
      grep -iE '^[[:space:]]*listen[[:space:]]' "$f" 2>/dev/null
    done > "$TMP_LISTEN"

# ---------- 解析端口 ----------
declare -A V4          # port -> 1 : 存在非回环的 IPv4 监听（裸端口=0.0.0.0 通配 / 0.0.0.0 / 公网 IP）
declare -A V6          # port -> 1 : 存在非回环的 IPv6 监听（[::] 通配 / 公网 IPv6）
declare -A DEF_V4      # port -> 1 : IPv4 通配地址上已声明 default_server（跳过该栈避免冲突）
declare -A DEF_V6      # port -> 1 : IPv6 通配地址([::])上已声明 default_server（跳过该栈避免冲突）

extract_port() {
  # $1: 完整的 listen 指令行（可能带前导空白/缩进）
  local rest="$1"
  rest="${rest%%;*}"                                  # 去掉行尾分号及之后
  rest="${rest#"${rest%%[![:space:]]*}"}"             # 去掉前导空白（缩进）
  rest="${rest#listen}"                               # 去掉 listen 关键字
  rest="${rest#"${rest%%[![:space:]]*}"}"             # 去掉 listen 之后的前导空白
  local port
  if [[ "$rest" == *:* ]]; then
    port="${rest##*:}"                                # 取最后一个冒号之后的内容
  else
    port="${rest%%[[:space:]]*}"                      # 否则取首个 token
  fi
  port="${port%%[[:space:]]*}"                        # 去掉端口后可能跟的 "ssl http2" 等
  port="${port//[^0-9]/}"                             # 只保留数字
  printf '%s' "$port"
}

extract_addr() {
  # $1: 完整的 listen 指令行；返回绑定地址（裸端口/无具体地址则返回空串）
  local rest="$1"
  rest="${rest%%;*}"                                  # 去掉行尾分号及之后
  rest="${rest#"${rest%%[![:space:]]*}"}"             # 去掉前导空白（缩进）
  rest="${rest#listen}"                               # 去掉 listen 关键字
  rest="${rest#"${rest%%[![:space:]]*}"}"             # 去掉 listen 之后的前导空白
  local addr=""
  if [[ "$rest" == \[* ]]; then
    addr="${rest#\[}"                                 # IPv6：[addr]:port
    addr="${addr%%\]*}"
  elif [[ "$rest" == *:* ]]; then
    addr="${rest%%:*}"                                # IPv4：addr:port
  else
    addr=""                                           # 裸端口：绑定所有接口
  fi
  printf '%s' "$addr"
}

is_loopback() {
  # $1: 绑定地址；回环地址返回 0，否则返回 1
  case "$1" in
    127.0.0.1|::1|localhost) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  lower="$(printf '%s' "$line" | tr 'A-Z' 'a-z')"
  [[ "$lower" != *"ssl"* ]] && continue              # 只处理含 ssl 的 listen

  addr="$(extract_addr "$line")"
  if is_loopback "$addr"; then
    # 仅监听本地回环（127.0.0.1 / [::1] / localhost），外部不可达，
    # 该网络栈无需防泄露兜底，也避免与站点自身的回环监听冲突
    continue
  fi

  port="$(extract_port "$line")"
  [[ -z "$port" ]] && continue
  if (( port < 1 || port > 65535 )); then
    continue
  fi

  if [[ "$addr" == *:* ]]; then
    # IPv6 监听（含 [::] 通配、公网 IPv6）；能到这里说明已非回环
    V6["$port"]=1
    # 仅在 IPv6 通配地址([::])上已声明 default_server 时跳过该栈，避免 duplicate default server
    if [[ "$lower" == *"default_server"* && "$addr" == "::" ]]; then
      DEF_V6["$port"]=1
    fi
  else
    # IPv4 监听（裸端口=0.0.0.0 通配 / 0.0.0.0 / 公网 IP）；能到这里说明已非回环
    V4["$port"]=1
    if [[ "$lower" == *"default_server"* && ( "$addr" == "" || "$addr" == "0.0.0.0" ) ]]; then
      DEF_V4["$port"]=1
    fi
  fi
done < "$TMP_LISTEN"

# 汇总所有需兜底的端口（IPv4 或 IPv6 任一栈存在非回环监听即纳入）
PORT_LIST="$( { printf '%s\n' "${!V4[@]}"; printf '%s\n' "${!V6[@]}"; } | sort -n -u )"
PORT_COUNT="$(printf '%s\n' "$PORT_LIST" | grep -c .)"

# ---------- 拼装生成内容 ----------
GEN=""
GEN+="# ========================================="$'\n'
GEN+="# 自动生成的防泄漏兜底配置 (使用 ssl_reject_handshake)"$'\n'
GEN+="# 当用 IP 直接访问这些端口时，直接拒绝 TLS 握手，彻底隐藏真实证书"$'\n'
GEN+="# 集成 http2 与 TLSv1.3，兼容 REALITY 偷自己域名的指纹提取"$'\n'
GEN+="# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"$'\n'
GEN+="# 扫描到 SSL 端口数: ${PORT_COUNT}"$'\n'
GEN+="# ========================================="$'\n'

PORT_LIST="$( { printf '%s\n' "${!V4[@]}"; printf '%s\n' "${!V6[@]}"; } | sort -n -u )"

if [[ -z "$PORT_LIST" ]]; then
  GEN+=$'\n'"# 未扫描到任何 listen ssl 的非回环端口，配置为空。"$'\n'
else
  while IFS= read -r port; do
    [[ -z "$port" ]] && continue
    # 逐栈兜底：仅对确实存在非回环监听、且通配地址上尚无 default_server 的网络栈生成
    srv=""
    if [[ -n "${V4[$port]+x}" && -z "${DEF_V4[$port]+x}" ]]; then
      srv+="    listen ${port} ssl http2 default_server;"$'\n'
    fi
    if [[ -n "${V6[$port]+x}" && -z "${DEF_V6[$port]+x}" ]]; then
      srv+="    listen [::]:${port} ssl http2 default_server;"$'\n'
    fi
    # 两个栈都因已有 default_server 而跳过时不生成空 server 块
    [[ -z "$srv" ]] && continue

    GEN+=$'\n'
    GEN+="server {"$'\n'
    GEN+="$srv"
    GEN+="    server_name _;"$'\n'
    GEN+=$'\n'
    GEN+="    # 必须显式声明协议，防止 SNI 路由前上下文降级，兼容 REALITY 透传探测"$'\n'
    GEN+="    ssl_protocols TLSv1.2 TLSv1.3;"$'\n'
    GEN+=$'\n'
    GEN+="    # Nginx 终极防泄露指令：直接拒绝 TLS 握手，无需假证书"$'\n'
    GEN+="    ssl_reject_handshake on;"$'\n'
    GEN+="    return 444;"$'\n'
    GEN+="}"$'\n'
  done <<< "$PORT_LIST"
fi

# ---------- 输出 ----------
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "===== DRY RUN: 以下内容将写入 $OUT_FILE ====="
  printf '%s' "$GEN"
  echo
  echo "===== 发现的 SSL 端口: $(printf '%s ' $PORT_LIST) ====="
  exit 0
fi

mkdir -p "$OUT_DIR"

# 备份旧文件
if [[ -f "$OUT_FILE" ]]; then
  cp -p "$OUT_FILE" "${OUT_FILE}.bak.$(date +%Y%m%d%H%M%S)"
fi

printf '%s' "$GEN" > "$OUT_FILE"
echo "已生成: $OUT_FILE  (共 ${PORT_COUNT} 个 SSL 端口)"

if [[ "$NO_RELOAD" -eq 1 ]]; then
  echo "已跳过重载 (--no-reload)"
  exit 0
fi

# ---------- 找到 OpenResty 容器（前缀匹配，后缀随机） ----------
CONTAINER="$(docker ps --format '{{.Names}}' | grep -E "^${CONTAINER_PREFIX}" | head -n1)"
if [[ -z "$CONTAINER" ]]; then
  echo "错误: 未找到以 ${CONTAINER_PREFIX} 开头的运行中的容器，无法重载。" >&2
  echo "请手动重载，或确认 docker 命令可用 / 容器正在运行。" >&2
  exit 1
fi
echo "找到 OpenResty 容器: $CONTAINER"

# 容器内用 openresty 还是 nginx
BIN="openresty"
if ! docker exec "$CONTAINER" command -v openresty >/dev/null 2>&1; then
  BIN="nginx"
fi

# 尝试从 1 号进程命令行取得 -c 配置路径（容器视角）
CONF_ARG=""
CMD="$(docker exec "$CONTAINER" cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ')"
if [[ "$CMD" == *"-c"* ]]; then
  CONF_ARG="$(printf '%s' "$CMD" | grep -oE '\-c[ =]*[^[:space:]]+' | sed -E 's/^-c[ =]*//' | head -n1)"
fi

# ---------- 配置测试 ----------
echo "测试配置 (${BIN} -t) ..."
if [[ -n "$CONF_ARG" ]]; then
  if ! docker exec "$CONTAINER" "$BIN" -t -c "$CONF_ARG"; then
    echo "配置测试失败，已中止重载。请按上方错误修正后再试。" >&2
    exit 1
  fi
else
  if ! docker exec "$CONTAINER" "$BIN" -t; then
    echo "配置测试失败，已中止重载。请按上方错误修正后再试。" >&2
    exit 1
  fi
fi

# ---------- 热重载 ----------
echo "热重载 OpenResty (${BIN} -s reload) ..."
if docker exec "$CONTAINER" "$BIN" -s reload; then
  echo "重载完成。"
else
  echo "重载失败，请检查容器日志: docker logs --tail 50 $CONTAINER" >&2
  exit 1
fi
