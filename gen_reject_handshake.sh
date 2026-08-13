#!/usr/bin/env bash
#
# gen_reject_handshake.sh
# ------------------------------------------------------------------
# 自动扫描 1Panel OpenResty 网站配置中所有 "listen ... ssl" 的监听，
# 为每一个 "listen <地址>:<端口> ssl" 生成同地址同端口的 default_server 兜底配置
# （ssl_reject_handshake），IP 直连这些地址/端口时直接拒绝 TLS 握手，彻底隐藏真实证书。
# 生成后自动在 OpenResty 容器内做配置测试并热重载。
#
# 用法:
#   ./gen_reject_handshake.sh            # 生成 + 重载
#   ./gen_reject_handshake.sh --dry-run  # 只打印将要写入的内容，不落盘、不重载
#   ./gen_reject_handshake.sh --no-reload# 生成文件，但不重载
#
# 说明:
#   - 容器名前缀为 1Panel-openresty-（后缀随机），脚本自动用 docker ps 匹配。
#   - 1:1 精确兜底：为每一个 "listen <地址>:<端口> ssl" 生成同地址同端口的
#     default_server 兜底块（含回环地址，如 127.0.0.1 / [::1]）。监听什么地址就兜底什么地址，
#     不会额外新增该端口在其它地址上的兜底。原样保留 socket 级选项（如 proxy_protocol）。
#   - 若某地址在原配置里已声明 default_server，则跳过该地址，避免 "a duplicate default server"。
#   - 若容器不支持 IPv6，生成的 listen [::]:... 行会让 openresty -t 失败；
#     此时脚本会中止重载，运行中的服务不受影响，你可按提示注释掉对应行。
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

# ---------- 解析 listen 指令 ----------
# 语义：监听什么地址就兜底什么地址（1:1 精确兜底）。
# 为每一个 "listen <地址>:<端口> ssl" 生成同地址同端口的 default_server 兜底块，
# 原样保留 socket 级选项（如 proxy_protocol），不再忽略回环地址。

split_listen() {
  # $1: 完整 listen 指令行
  # 输出: addrport|port|extra_flags|has_default
  local raw="$1"
  raw="${raw%%;*}"                                  # 去掉分号及之后
  raw="${raw#"${raw%%[![:space:]]*}"}"              # 去前导空白
  raw="${raw#listen}"                               # 去掉 listen 关键字
  raw="${raw#"${raw%%[![:space:]]*}"}"              # 去掉 listen 后的前导空白
  local first="${raw%%[[:space:]]*}"                # 首个 token = 地址:端口
  local rest="${raw#"$first"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"            # 其余 token
  local port
  if [[ "$first" == *:* ]]; then
    port="${first##*:}"                             # 取最后一个冒号后内容（兼容 IPv6 多冒号）
  else
    port="$first"
  fi
  port="${port//[^0-9]/}"                           # 只保留数字（unix socket 会得到空）
  local flags="" has_def=0 tok
  for tok in $rest; do
    case "$tok" in
      ssl|http2|default_server|default) : ;;        # 由脚本统一生成/忽略
      *) flags="${flags:+$flags }$tok" ;;            # 保留 socket 级选项（proxy_protocol 等）
    esac
    case "$tok" in
      default_server|default) has_def=1 ;;
    esac
  done
  printf '%s|%s|%s|%s' "$first" "$port" "$flags" "$has_def"
}

declare -A PORT_ADDRS   # port -> "addrport1 addrport2 ..."（同端口下的监听地址，去重）
declare -A ADDR_FLAGS   # "addrport" -> 需保留的额外 socket 选项（如 proxy_protocol）
declare -A ADDR_DEF     # "addrport" -> 1 表示原配置已声明 default_server（跳过以免冲突）

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  lower="$(printf '%s' "$line" | tr 'A-Z' 'a-z')"
  [[ "$lower" != *"ssl"* ]] && continue              # 只处理含 ssl 的 listen（非 ssl 不会泄露证书）

  IFS='|' read -r LP_ADDRPORT LP_PORT LP_FLAGS LP_DEF <<< "$(split_listen "$line")"
  [[ -z "$LP_PORT" ]] && continue                    # unix socket 等无端口，跳过
  if (( LP_PORT < 1 || LP_PORT > 65535 )); then
    continue
  fi

  if [[ "$LP_DEF" == "1" ]]; then
    ADDR_DEF["$LP_ADDRPORT"]=1
  fi

  if [[ -z "${ADDR_FLAGS[$LP_ADDRPORT]+x}" ]]; then
    # 首次见到该地址：登记并挂到对应端口
    ADDR_FLAGS["$LP_ADDRPORT"]="$LP_FLAGS"
    if [[ -z "${PORT_ADDRS[$LP_PORT]+x}" ]]; then
      PORT_ADDRS["$LP_PORT"]="$LP_ADDRPORT"
    elif [[ " ${PORT_ADDRS[$LP_PORT]} " != *" $LP_ADDRPORT "* ]]; then
      PORT_ADDRS["$LP_PORT"]+=" $LP_ADDRPORT"
    fi
  else
    # 已见过：仅合并可能新增的 socket 选项（default 等已由 split 排除）
    for f in $LP_FLAGS; do
      if [[ " ${ADDR_FLAGS[$LP_ADDRPORT]} " != *" $f "* ]]; then
        ADDR_FLAGS["$LP_ADDRPORT"]+=" $f"
      fi
    done
  fi
done < "$TMP_LISTEN"

PORT_LIST="$(printf '%s\n' "${!PORT_ADDRS[@]}" | sort -n)"

# 统计需兜底的监听地址数（已 default_server 的地址不计入）
COUNT=0
for p in "${!PORT_ADDRS[@]}"; do
  for ap in ${PORT_ADDRS[$p]}; do
    [[ -z "${ADDR_DEF[$ap]+x}" ]] && COUNT=$((COUNT+1))
  done
done

# ---------- 拼装生成内容 ----------
GEN=""
GEN+="# ========================================="$'\n'
GEN+="# 自动生成的防泄漏兜底配置 (使用 ssl_reject_handshake)"$'\n'
GEN+="# 监听什么地址就兜底什么地址：为每个 listen <addr>:<port> ssl 生成同地址同端口的"$'\n'
GEN+="# default_server 兜底块；IP 直连这些地址/端口时直接拒绝 TLS 握手，彻底隐藏真实证书。"$'\n'
GEN+="# 集成 http2，兼容 REALITY 偷自己域名的指纹提取。"$'\n'
GEN+="# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"$'\n'
GEN+="# 需兜底的监听地址数: ${COUNT}"$'\n'
GEN+="# ========================================="$'\n'

if [[ "$COUNT" -eq 0 ]]; then
  GEN+=$'\n'"# 未扫描到任何需兜底的 listen ssl 配置，配置为空。"$'\n'
else
  while IFS= read -r port; do
    [[ -z "$port" ]] && continue
    listens=""
    for ap in ${PORT_ADDRS[$port]}; do
      if [[ -n "${ADDR_DEF[$ap]+x}" ]]; then
        GEN+=$'\n'"# 地址 $ap 已声明 default_server，跳过以免冲突"$'\n'
        continue
      fi
      extra="${ADDR_FLAGS[$ap]}"
      listens+="    listen ${ap} ssl http2 default_server${extra:+ $extra};"$'\n'
    done
    [[ -z "$listens" ]] && continue
    GEN+=$'\n'
    GEN+="server {"$'\n'
    GEN+="$listens"
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
  echo "===== 需兜底的监听地址 (${COUNT}): ====="
  for p in $PORT_LIST; do
    for ap in ${PORT_ADDRS[$p]}; do
      if [[ -z "${ADDR_DEF[$ap]+x}" ]]; then
        echo "  $ap"
      else
        echo "  $ap  (已 default_server，跳过)"
      fi
    done
  done
  exit 0
fi

mkdir -p "$OUT_DIR"

# 备份旧文件
if [[ -f "$OUT_FILE" ]]; then
  cp -p "$OUT_FILE" "${OUT_FILE}.bak.$(date +%Y%m%d%H%M%S)"
fi

printf '%s' "$GEN" > "$OUT_FILE"
echo "已生成: $OUT_FILE  (共 ${COUNT} 个监听地址兜底)"

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
