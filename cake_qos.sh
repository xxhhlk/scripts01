#!/usr/bin/bash
# =============================================================================
#  CAKE QoS 双模式脚本 (自动适配隧道接管默认路由版)
#
#  SHARED_MODE="true"  → 共享总额模式: clsact 双向重定向 → ifb0 单棵 HTB 树
#                        上下行通过 ceil 互借带宽，合计不超过 BANDWIDTH_TOTAL
#
#  SHARED_MODE="false" → 独立限速模式: eth0 HTB(上行) + ifb0 HTB(下行) 两棵独立树
#                        上下行各自独立，互不影响
#
#  自动适配 (2026-08-27):
#    1. INTERFACE 检测: 默认路由被隧道接口 (WARP/tailscale/wg/tun) 接管时,
#       自动回退到物理网卡 (eth*/enp*/ens*/eno*), 避免 clsact 建错接口。
#    2. 隧道口泛化: 所有隧道接口 (WARP/tailscale/wg/tun) 统一处理:
#       - 共享模式: 双向重定向到 ifb0 (单树按真实 IP 分上下行类)
#       - 独立模式: 仅 ingress 重定向到 ifb0 (下行限速);
#                   上行原始包走 wg 加密 → 物理口 egress 树, 由上行 CAKE 限
# =============================================================================

# =============================================================================
# [开关] 上下行带宽模式
#   true  = 共享总额（clsact 双向重定向 → ifb0 单树，ceil 互借）
#   false = 独立限速（eth0 上行树 + ifb0 下行树，各自独立）
# =============================================================================
SHARED_MODE="false"

# 1. 自动获取默认网卡
INTERFACE=$(ip route get 223.5.5.5 | grep -Po '(?<=dev )(\S+)')
# 默认路由被隧道接口接管时, 回退到物理网卡
case "$INTERFACE" in
    WARP|tailscale*|wg*|tun*|tap*|utun*)
        INTERFACE=$(ip -o link show | grep -oP '^\d+: \K(eth\w*|enp\w*|ens\w*|eno\w*)' | head -1)
        ;;
esac

# 2. 带宽设置
#   共享模式 (SHARED_MODE=true) 使用全部三个变量：
#     BANDWIDTH_TOTAL — 双向合计的绝对上限
#     BANDWIDTH_UP    — 上行保底速率（空闲时可借用至 TOTAL）
#     BANDWIDTH_DOWN  — 下行保底速率（空闲时可借用至 TOTAL）
#
#   独立模式 (SHARED_MODE=false) 仅使用 BANDWIDTH_UP / BANDWIDTH_DOWN：
#     上行 = BANDWIDTH_UP，下行 = BANDWIDTH_DOWN，各不干扰
BANDWIDTH_TOTAL="200mbit"
BANDWIDTH_UP="100mbit"
BANDWIDTH_DOWN="100mbit"

# 3. 公网 IP 设置
#   手动填写公网IP（推荐，更可靠）
#   留空则自动获取
PUBLIC_IP_V4=""
PUBLIC_IP_V6=""

if [ -z "$INTERFACE" ]; then
    echo "错误：无法识别默认网卡。"
    exit 1
fi

# 如果没有手动设置公网IP，尝试自动获取
if [ -z "$PUBLIC_IP_V4" ]; then
    echo "正在获取公网 IPv4..."
    PUBLIC_IP_V4=$(curl -4 -s --connect-timeout 5 ip.sb 2>/dev/null || curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || curl -4 -s --connect-timeout 5 ipinfo.io/ip 2>/dev/null)
fi

if [ -z "$PUBLIC_IP_V6" ]; then
    echo "正在获取公网 IPv6..."
    PUBLIC_IP_V6=$(curl -6 -s --connect-timeout 5 ip.sb 2>/dev/null || curl -6 -s --connect-timeout 5 ifconfig.me 2>/dev/null || ip -6 addr show dev $INTERFACE | grep -oP 'inet6 \K[\da-f:]+' | grep -v '^fe80' | grep -v '^::1' | head -1)
fi

echo "正在应用 CAKE QoS 到 $INTERFACE..."
echo "=========================================="
if [ "$SHARED_MODE" = "true" ]; then
    echo "  模式           : 共享总额 (上下行 ceil 互借)"
    echo "  双向总带宽上限 : $BANDWIDTH_TOTAL"
    echo "  上行保底带宽   : $BANDWIDTH_UP    (可借用至 $BANDWIDTH_TOTAL)"
    echo "  下行保底带宽   : $BANDWIDTH_DOWN  (可借用至 $BANDWIDTH_TOTAL)"
else
    echo "  模式           : 独立限速 (上下行各不干扰)"
    echo "  上行带宽上限   : $BANDWIDTH_UP"
    echo "  下行带宽上限   : $BANDWIDTH_DOWN"
fi
echo "  公网 IPv4 地址 : $PUBLIC_IP_V4"
echo "  公网 IPv6 地址 : $PUBLIC_IP_V6"
echo "=========================================="

# ==================== 清除现有规则 ====================
echo ""
echo "正在清除现有 tc 规则..."

# 第1步：先删物理口的 clsact（切断所有到 ifb0 的重定向，立即恢复网络）
tc qdisc del dev "$INTERFACE" clsact   2>/dev/null
tc qdisc del dev "$INTERFACE" root     2>/dev/null
tc qdisc del dev "$INTERFACE" ingress  2>/dev/null
tc -6 qdisc del dev "$INTERFACE" root    2>/dev/null
tc -6 qdisc del dev "$INTERFACE" ingress 2>/dev/null
# 隧道口同样清除 (WARP/tailscale/wg 等, 若有)
for tun in $(ip -o link show | grep -oP '^\d+: \K(WARP|tailscale\d*|wg\d*|tun\d*)'); do
    tc qdisc del dev "$tun" clsact 2>/dev/null
done

# 第2步：确保 ifb0 是 UP（down 状态下无法删除 qdisc）
ip link set dev ifb0 up 2>/dev/null

# 第3步：删除 ifb0 上的所有 qdisc
tc qdisc del dev ifb0 root   2>/dev/null
tc -6 qdisc del dev ifb0 root 2>/dev/null

# 第4步：关闭并删除 ifb0 虚拟接口，卸载内核模块
ip link set dev ifb0 down    2>/dev/null
ip link del dev ifb0         2>/dev/null
rmmod ifb                    2>/dev/null

# ==================== IFB 模块加载 & 接口启用 ====================
modprobe ifb numifbs=1 2>/dev/null
ip link set dev ifb0 up

# =============================================================================
# 根据 SHARED_MODE 选择不同的 tc 架构
# =============================================================================

if [ "$SHARED_MODE" = "true" ]; then
    # =====================================================================
    #  共享总额模式
    #  eth0 clsact 双向重定向 → ifb0 单棵 HTB 树
    #
    #                              ┌────────────────────────┐
    #                              │ ifb0 root 1: HTB        │
    #                              │ default 20 (下载类)     │
    #                              └──────────┬─────────────┘
    #                                         │
    #                              ┌──────────▼─────────────┐
    #                              │ class 1:1               │
    #                              │ rate/ceil = TOTAL       │
    #                              └──────────┬─────────────┘
    #                                         │
    #                     ┌───────────────────┴───────────────────┐
    #                     │                                       │
    #          ┌──────────▼──────┐                     ┌──────────▼──────┐
    #          │ class 1:10 上行 │                     │ class 1:20 下行 │
    #          │ rate = UP       │                     │ rate = DOWN     │
    #          │ ceil = TOTAL    │                     │ ceil = TOTAL    │
    #          │ prio 0 (更高)   │                     │ prio 1 (普通)   │
    #          └────────┬────────┘                     └────────┬────────┘
    #                   │                                       │
    #          ┌────────▼────────┐                     ┌────────▼────────┐
    #          │ cake besteffort │                     │ cake besteffort │
    #          │ triple-isolate  │                     │ triple-isolate  │
    #          └─────────────────┘                     └─────────────────┘
    # =====================================================================

    # eth0 clsact：双向流量重定向到 ifb0
    tc qdisc add dev $INTERFACE clsact

    # =====================================================================
    # 优先级约定 (2026-08-26 修复):
    #   限速特例 (外部脚本 tc_limit_bidir) 需要抢占低 pref:
    #     eth0 ingress: pref 1 connmark 还原 / pref 2 skbedit 0x20  (限速用)
    #     ifb0 内:      pref 1-4  fw filter (mark 0x10/0x20 → 1:30/1:31)
    #   本脚本规则全部让出低优先级区间:
    #     eth0 ingress/egress matchall 重定向: pref 100
    #     ifb0 u32 方向分流: pref 11-14
    #   tc 按 pref 从小到大匹配, 限速规则先命中, 其余流量落回本脚本分类。
    # =====================================================================

    # 入站流量（下载） → ifb0
    tc filter add dev $INTERFACE ingress protocol all prio 100 matchall \
        action mirred egress redirect dev ifb0
    echo "已添加: $INTERFACE ingress → ifb0 (下载流量)"

    # 出站流量（上传） → ifb0
    tc filter add dev $INTERFACE egress protocol all prio 100 matchall \
        action mirred egress redirect dev ifb0
    echo "已添加: $INTERFACE egress → ifb0 (上传流量)"

    # =====================================================================
    # 隧道口统一重定向 (2026-08-27 泛化):
    #   背景: 服务流量经隧道 (WARP/tailscale/wg) 时, 原始流量在隧道口进出,
    #         不经过物理口, 导致物理口侧限速不生效
    #         (物理口上只有加密外层封装, 属于隧道进程)。
    #   方案: 隧道口双向重定向到 ifb0, 原始包带真实 IP 进入 ifb0,
    #         u32 按 src/dst=公网IP 分上下行类; 未匹配的落 default。
    # =====================================================================
    for tun in $(ip -o link show | grep -oP '^\d+: \K(WARP|tailscale\d*|wg\d*|tun\d*)'); do
        tc qdisc add dev "$tun" clsact 2>/dev/null
        tc filter add dev "$tun" ingress protocol all prio 100 matchall \
            action mirred egress redirect dev ifb0 2>/dev/null
        echo "已添加: $tun ingress → ifb0 (隧道入站)"
        tc filter add dev "$tun" egress protocol all prio 100 matchall \
            action mirred egress redirect dev ifb0 2>/dev/null
        echo "已添加: $tun egress → ifb0 (隧道出站)"
    done

    # ifb0 HTB 树状流控
    tc qdisc add dev ifb0 root handle 1: htb default 20 r2q 100

    # 根 class: 双向合计绝对上限
    tc class add dev ifb0 parent 1: classid 1:1 htb \
        rate $BANDWIDTH_TOTAL ceil $BANDWIDTH_TOTAL \
        burst 40k cburst 40k

    # 上行子类 (1:10): 保底 → 可借用至总额
    tc class add dev ifb0 parent 1:1 classid 1:10 htb \
        rate $BANDWIDTH_UP ceil $BANDWIDTH_TOTAL prio 0 \
        burst 40k cburst 40k
    tc qdisc add dev ifb0 parent 1:10 handle 10: cake besteffort triple-isolate rtt 300ms nat

    # 下行子类 (1:20): 保底 → 可借用至总额
    tc class add dev ifb0 parent 1:1 classid 1:20 htb \
        rate $BANDWIDTH_DOWN ceil $BANDWIDTH_TOTAL prio 1 \
        burst 40k cburst 40k
    tc qdisc add dev ifb0 parent 1:20 handle 20: cake besteffort triple-isolate rtt 300ms nat

    # 过滤规则：在 ifb0 内按 IP 方向分流
    # (pref 11-14, 让出 pref 1-4 给限速 fw filter)
    if [ -n "$PUBLIC_IP_V4" ]; then
        tc filter add dev ifb0 protocol ip parent 1:0 prio 11 u32 \
            match ip src $PUBLIC_IP_V4/32 flowid 1:10
        echo "IPv4 上行分流: src $PUBLIC_IP_V4 → 上传类 (保底 $BANDWIDTH_UP)"

        tc filter add dev ifb0 protocol ip parent 1:0 prio 12 u32 \
            match ip dst $PUBLIC_IP_V4/32 flowid 1:20
        echo "IPv4 下行分流: dst $PUBLIC_IP_V4 → 下载类 (保底 $BANDWIDTH_DOWN)"
    fi

    if [ -n "$PUBLIC_IP_V6" ]; then
        tc filter add dev ifb0 protocol ipv6 parent 1:0 prio 13 u32 \
            match ip6 src $PUBLIC_IP_V6/128 flowid 1:10
        echo "IPv6 上行分流: src $PUBLIC_IP_V6 → 上传类 (保底 $BANDWIDTH_UP)"

        tc filter add dev ifb0 protocol ipv6 parent 1:0 prio 14 u32 \
            match ip6 dst $PUBLIC_IP_V6/128 flowid 1:20
        echo "IPv6 下行分流: dst $PUBLIC_IP_V6 → 下载类 (保底 $BANDWIDTH_DOWN)"
    fi

else
    # =====================================================================
    #  独立限速模式
    #  eth0 HTB 处理上行 (egress) + ifb0 HTB 处理下行 (ingress)
    #  两棵独立的 HTB 树，各自限速，不共享带宽
    #
    #  eth0 (上行):                      ifb0 (下行):
    #  root 1: HTB                      root 2: HTB
    #  ├─ 1:1  (1000mbit)              ├─ 2:1  (1000mbit)
    #  │  ├─ 1:10 pfifo (本地绕过)     │  ├─ 2:10 pfifo (本地绕过)
    #  │  └─ 1:30 CAKE ($UP)          │  └─ 2:30 CAKE ($DOWN)
    #
    #  隧道口 (WARP/tailscale/wg):
    #     ingress 重定向 → ifb0 (下行原始流量 → 2:30 下行 CAKE)
    #     egress 不重定向 (上行原始流量走 wg 加密 → 物理口 egress 树 → 1:30)
    #     若 egress 也重定向, 上行会混进 ifb0 下行树, 破坏独立限速。
    # =====================================================================

    # ---------- 上行 (egress) — eth0 ----------
    tc qdisc add dev $INTERFACE root handle 1: htb default 30 r2q 100

    tc class add dev $INTERFACE parent 1: classid 1:1 htb \
        rate 1000mbit ceil 1000mbit burst 40k cburst 40k

    # 本地流量，不限速
    tc class add dev $INTERFACE parent 1:1 classid 1:10 htb \
        rate 1000mbit ceil 1000mbit prio 0 burst 40k cburst 40k
    tc qdisc add dev $INTERFACE parent 1:10 handle 10: pfifo limit 1000

    # 普通流量，走 CAKE 限速
    tc class add dev $INTERFACE parent 1:1 classid 1:30 htb \
        rate $BANDWIDTH_UP ceil $BANDWIDTH_UP prio 1 burst 32k cburst 32k
    tc qdisc add dev $INTERFACE parent 1:30 handle 30: cake besteffort triple-isolate rtt 300ms nat
    echo "已添加上行 CAKE: eth0 限速 $BANDWIDTH_UP"

    # 上行过滤规则：仅 dst=公网IP 的包是本地自通信（VPS→自身），绕过 CAKE
    # 正常上传包 (src=公网IP, dst=外部) 不匹配任何 filter → default class 1:30 CAKE
    if [ -n "$PUBLIC_IP_V4" ]; then
        tc filter add dev $INTERFACE protocol ip parent 1:0 prio 1 u32 \
            match ip dst $PUBLIC_IP_V4/32 flowid 1:10
        echo "已添加上行 IPv4 本地绕过规则 (dst $PUBLIC_IP_V4 → 不限速)"
    fi
    if [ -n "$PUBLIC_IP_V6" ]; then
        tc filter add dev $INTERFACE protocol ipv6 parent 1:0 prio 3 u32 \
            match ip6 dst $PUBLIC_IP_V6/128 flowid 1:10
        echo "已添加上行 IPv6 本地绕过规则 (dst $PUBLIC_IP_V6 → 不限速)"
    fi

    # ---------- 下行 (ingress) — eth0 ----------
    tc qdisc add dev $INTERFACE ingress
    tc filter add dev $INTERFACE parent ffff: protocol all prio 10 u32 \
        match u32 0 0 action mirred egress redirect dev ifb0
    echo "已添加: $INTERFACE ingress → ifb0 (下载流量)"
    # =====================================================================
    # 隧道口 ingress 重定向 (2026-08-27 泛化):
    #   背景: 隧道原始下行流量在隧道口 ingress 出现 (加密前), 不进物理口,
    #         物理口 ingress 只有加密封装, 限速粒度一致但无法按真实 IP 分流。
    #   方案: 隧道口 ingress 重定向 → ifb0 2:30 下行 CAKE (default 兜底)。
    #         egress 不重定向: 上行由物理口 egress 树 1:30 限速。
    # =====================================================================
    for tun in $(ip -o link show | grep -oP '^\d+: \K(WARP|tailscale\d*|wg\d*|tun\d*)'); do
        tc qdisc add dev "$tun" clsact 2>/dev/null
        tc filter add dev "$tun" ingress protocol all prio 100 matchall \
            action mirred egress redirect dev ifb0 2>/dev/null
        echo "已添加: $tun ingress → ifb0 (隧道下行限速)"
    done

    # ifb0 HTB 下行限速
    tc qdisc add dev ifb0 root handle 2: htb default 30 r2q 100

    tc class add dev ifb0 parent 2: classid 2:1 htb \
        rate 1000mbit ceil 1000mbit burst 40k cburst 40k

    # 本地流量，不限速
    tc class add dev ifb0 parent 2:1 classid 2:10 htb \
        rate 1000mbit ceil 1000mbit prio 0 burst 40k cburst 40k
    tc qdisc add dev ifb0 parent 2:10 handle 20: pfifo limit 1000

    # 普通流量，走 CAKE 限速
    tc class add dev ifb0 parent 2:1 classid 2:30 htb \
        rate $BANDWIDTH_DOWN ceil $BANDWIDTH_DOWN prio 1 burst 32k cburst 32k
    tc qdisc add dev ifb0 parent 2:30 handle 30: cake besteffort triple-isolate rtt 300ms nat
    echo "已添加下行 CAKE: ifb0 限速 $BANDWIDTH_DOWN"

    # 下行过滤规则：仅 src=公网IP 的包是本地自通信（VPS→自身），绕过 CAKE
    # 正常下载包 (src=外部, dst=公网IP) 不匹配任何 filter → default class 2:30 CAKE
    if [ -n "$PUBLIC_IP_V4" ]; then
        tc filter add dev ifb0 protocol ip parent 2:0 prio 2 u32 \
            match ip src $PUBLIC_IP_V4/32 flowid 2:10
        echo "已添加下行 IPv4 本地绕过规则 (src $PUBLIC_IP_V4 → 不限速)"
    fi
    if [ -n "$PUBLIC_IP_V6" ]; then
        tc filter add dev ifb0 protocol ipv6 parent 2:0 prio 4 u32 \
            match ip6 src $PUBLIC_IP_V6/128 flowid 2:10
        echo "已添加下行 IPv6 本地绕过规则 (src $PUBLIC_IP_V6 → 不限速)"
    fi

fi

# ==================== 状态展示 ====================
echo ""
echo "========== $INTERFACE =========="
tc -s qdisc show dev $INTERFACE
echo ""
echo "--- ingress filters ---"
tc filter show dev $INTERFACE ingress
echo ""
echo "--- egress filters ---"
tc filter show dev $INTERFACE egress 2>/dev/null

for tun in $(ip -o link show | grep -oP '^\d+: \K(WARP|tailscale\d*|wg\d*|tun\d*)'); do
    echo ""
    echo "========== $tun =========="
    tc -s qdisc show dev "$tun"
    echo "--- ingress filters ---"
    tc filter show dev "$tun" ingress 2>/dev/null
done
echo ""
echo "========== ifb0 =========="
tc -s qdisc show dev ifb0
echo ""
echo "--- class ---"
tc -s class show dev ifb0
echo ""
echo "--- filters ---"
tc filter show dev ifb0

echo ""
if [ "$SHARED_MODE" = "true" ]; then
    echo "CAKE QoS 设置完成（共享总额模式）。"
    echo "总计 ≤ $BANDWIDTH_TOTAL | 上传保底 $BANDWIDTH_UP | 下行保底 $BANDWIDTH_DOWN"
else
    echo "CAKE QoS 设置完成（独立限速模式）。"
    echo "上行 ≤ $BANDWIDTH_UP | 下行 ≤ $BANDWIDTH_DOWN"
fi
