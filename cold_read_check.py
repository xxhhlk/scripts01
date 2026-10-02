#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cold_read_check.py —— 纯只读的 SSD 冷数据掉速诊断

与 infrost/ColDataRefresh 的区别：
  * 全程不向目标盘写入任何一个字节（CreateFileW 只带 GENERIC_READ）
  * 不做"刷新/覆写"，只测量并给出"是否掉速"的结论
  * 用 FILE_FLAG_NO_BUFFERING 绕过系统页缓存，读到的是真实设备速度
    （原工具的 benchmark 会往目标目录写 1GB 随机数据，本工具用同盘
     "近期写入过的文件"作为暖数据基准，替代 benchmark）

判定逻辑：
  暖数据(近 warm_days 天内被写入的大文件)读速  ≈ 该盘"新鲜数据"的上限
  冷数据(超过 cold_days 天未写入的大文件)读速  < 上限 * ratio  → 判定掉速

用法：
  python cold_read_check.py D:\\                       # 扫描 D 盘
  python cold_read_check.py E:\\ --cold-days 180
  python cold_read_check.py D:\\SteamLibrary --max-files 20 --json r.json
"""

import argparse
import ctypes
import ctypes.wintypes as wintypes
import json
import os
import stat
import statistics
import sys
import time

IS_WIN = sys.platform == "win32"

# ---------------------------------------------------------------- 直接 I/O

GENERIC_READ = 0x80000000
FILE_SHARE_READ = 0x00000001
FILE_SHARE_WRITE = 0x00000002
OPEN_EXISTING = 3
FILE_FLAG_NO_BUFFERING = 0x20000000
FILE_FLAG_SEQUENTIAL_SCAN = 0x08000000
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
MEM_COMMIT = 0x1000
MEM_RESERVE = 0x2000
MEM_RELEASE = 0x8000
PAGE_READWRITE = 0x04

CHUNK = 4 * 1024 * 1024   # 4 MiB，满足任何 512/4096 扇区对齐要求
WINDOW = 8 * CHUNK        # 32 MiB，固定窗口。所有测量共用同一块缓冲区，
                          # 否则缓冲区越大、首次触碰的页越多，缺页开销会把
                          # 顺序读速度系统性压低（实测可差 25%+）

_BUF = None


def _get_buffer():
    """进程内复用的固定窗口缓冲，预触碰一次消除缺页/置零开销。"""
    global _BUF
    if _BUF is None:
        _BUF = _k32.VirtualAlloc(None, WINDOW, MEM_COMMIT | MEM_RESERVE,
                                 PAGE_READWRITE)
        if _BUF:
            ctypes.memset(ctypes.c_void_p(_BUF), 0, WINDOW)
    return _BUF

if IS_WIN:
    _k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _k32.CreateFileW.restype = wintypes.HANDLE
    _k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                 ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                                 wintypes.HANDLE]
    _k32.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                              ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
    _k32.SetFilePointerEx.argtypes = [wintypes.HANDLE, ctypes.c_longlong,
                                      ctypes.POINTER(ctypes.c_longlong), wintypes.DWORD]
    _k32.CloseHandle.argtypes = [wintypes.HANDLE]
    _k32.VirtualAlloc.restype = ctypes.c_void_p
    _k32.VirtualAlloc.argtypes = [ctypes.c_void_p, ctypes.c_size_t,
                                  wintypes.DWORD, wintypes.DWORD]
    _k32.VirtualFree.argtypes = [ctypes.c_void_p, ctypes.c_size_t, wintypes.DWORD]


def _read_span_direct(fh, buf, offset, length, win=WINDOW):
    """从 offset 起无缓冲读 length 字节，分 win 大小窗口复用同一缓冲。"""
    pos = ctypes.c_longlong(0)
    done = 0
    read = wintypes.DWORD(0)
    t0 = time.perf_counter()
    while done < length:
        want = min(win, length - done)
        if not _k32.SetFilePointerEx(fh, ctypes.c_longlong(offset + done),
                                     ctypes.byref(pos), 0):
            raise OSError("SetFilePointerEx failed: %d" % ctypes.get_last_error())
        if not _k32.ReadFile(fh, ctypes.c_void_p(buf), want,
                             ctypes.byref(read), None):
            raise OSError("ReadFile failed: %d" % ctypes.get_last_error())
        if read.value == 0:
            break
        done += read.value
    dt = time.perf_counter() - t0
    if done == 0:
        raise OSError("zero bytes read")
    return dt, done


def _read_span_buffered(path, offset, length, win=WINDOW):
    t0 = time.perf_counter()
    done = 0
    with open(path, "rb") as f:
        f.seek(offset)
        while done < length:
            b = f.read(min(win, length - done))
            if not b:
                break
            done += len(b)
    dt = time.perf_counter() - t0
    if done == 0:
        raise OSError("zero bytes read")
    return dt, done


def measure(path, size, read_bytes, spans, direct=True):
    """返回 (MB/s, 实测字节数, 是否走了无缓冲路径, 错误信息)"""
    spans = max(1, spans)
    per_span = max(CHUNK, (read_bytes // spans) // CHUNK * CHUNK)
    usable = size // CHUNK * CHUNK
    if usable < CHUNK:
        return None, 0, False, "文件不足 4MiB，跳过"

    per_span = min(per_span, usable)
    if spans == 1 or usable <= per_span:
        offsets = [0]
    else:
        # 均匀采样：首 / 中 / 尾，避免只测到文件头部
        span = per_span
        last = usable - span
        if spans == 2:
            offsets = [0, last]
        else:
            offsets = [round(i * last / (spans - 1)) // CHUNK * CHUNK
                       for i in range(spans)]
        offsets = sorted({min(o, last) for o in offsets})

    fh = None
    used_direct = False
    if IS_WIN and direct:
        fh = _k32.CreateFileW(path, GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, None,
                              OPEN_EXISTING,
                              FILE_FLAG_NO_BUFFERING | FILE_FLAG_SEQUENTIAL_SCAN,
                              None)
        if fh and fh != INVALID_HANDLE_VALUE:
            used_direct = bool(_get_buffer())
        else:
            fh = None
            return None, 0, False, ("无法打开（文件被占用或权限不足，err=%d）"
                                    % ctypes.get_last_error())

    total_bytes = 0
    total_time = 0.0
    err = ""
    try:
        for off in offsets:
            try:
                if used_direct:
                    dt, n = _read_span_direct(fh, _BUF, off, per_span)
                else:
                    dt, n = _read_span_buffered(path, off, per_span)
                total_bytes += n
                total_time += dt
            except OSError as e:
                err = str(e)
                if not total_bytes:
                    return None, 0, used_direct, err
    finally:
        if fh:
            _k32.CloseHandle(fh)

    if total_time <= 0:
        return None, 0, used_direct, "计时异常"
    return total_bytes / total_time / 1024 ** 2, total_bytes, used_direct, err


def measure_stable(path, size, read_bytes, spans, direct=True,
                   min_bytes=64 * 1024 ** 2, max_reps=8):
    """重复测量取中位，直到累计读取量达到 min_bytes 或达到 max_reps。

    为什么需要：~10MB 文件单次只读 12MiB，耗时仅 1.8~3.7ms。这个量级上任何
    系统抖动（中断、CPU 调频、其它进程 I/O）都能造成 30%+ 偏差 —— 实测同一个
    13.3MB 文件连测 10 次极差 12%，不同文件最高 32%；而同盘 512MB~1GB 文件
    极差只有 3~6%。大文件单次就读几百 MB，天然稳定，所以 reps=1 不改变行为。

    返回 (speed, bytes, direct, err, reps, total_ms)
    """
    runs = []
    total_nb = 0
    total_ms = 0.0
    err = ""
    used_direct = False
    for _ in range(max(1, max_reps)):
        spd, nb, d, e = measure(path, size, read_bytes, spans, direct=direct)
        if spd is None:
            if not runs:
                return None, total_nb, d, e, 0, total_ms
            err = e
            break
        used_direct = d
        runs.append(spd)
        total_nb += nb
        total_ms += nb / (spd * 1024 ** 2) * 1000.0
        if total_nb >= min_bytes:
            break
    if not runs:
        return None, 0, used_direct, err or "无有效测量", 0, total_ms
    return statistics.median(runs), total_nb, used_direct, err, len(runs), total_ms


# ---------------------------------------------------------------- 扫描

SKIP_DIRS = {"$RECYCLE.BIN", "System Volume Information", "$WinREAgent",
             "Config.Msi", "$SysReset", "Recovery",
             # Windows 升级/安装残留：常含数 GB 的 install.wim 或整份旧系统
             "$Windows.~BT", "$Windows.~WS", "$GetCurrent", "Windows.old",
             # 文件系统元数据
             "$Extend",
             # 杀软沙盒 / 云同步缓存：内容常被独占锁定，读不到且无诊断价值
             "$AV_ASW", "OneDriveTemp",
             # Office 安装缓存
             "MSOCache"}
# 目录名匹配**必须大小写不敏感**：NTFS 保留大小写，盘上实际可能是
# `$Recycle.Bin` / `recovery` 等变体，精确匹配会漏掉（实测本机有 `recovery`）。
_SKIP_DIRS_LOWER = {d.lower() for d in SKIP_DIRS}
SKIP_FILES = {"pagefile.sys", "hiberfil.sys", "swapfile.sys",
              "DumpStack.log.tmp", "DumpStack.log"}

# 本工具**不按 HIDDEN / SYSTEM 属性过滤**：隐藏文件和系统文件默认全部纳入范围。
# 实测 C: 233 万文件中有 HIDDEN 1800 个、SYSTEM 120528 个，其中 ≥64MB 且非
# 压缩/云端的为 0 个 —— 因为最大的隐藏+系统文件恰好是 pagefile/hiberfil
# （已按名字排除），注册表 hive 所在目录 C:\Windows\System32\config 权限拒绝
# 而根本没被枚举。默认 --min-mb 64 下它们对结果零影响；但若调小 --min-mb，
# 或盘上存在大体积隐藏文件（虚拟机镜像、沙盒缓存、备份），就会被纳入。
_HIDDEN_ATTR = getattr(stat, "FILE_ATTRIBUTE_HIDDEN", 0x2)
_SYSTEM_ATTR = getattr(stat, "FILE_ATTRIBUTE_SYSTEM", 0x4)

# 云端占位文件（OneDrive / 网盘 Files On-Demand）：数据不在本地，
# 读它 = 现场从网上拉，速度天然是"网速"。必须排除，否则必然误报掉速。
_RECALL_FLAGS = (getattr(stat, "FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS", 0x400000)
                 | getattr(stat, "FILE_ATTRIBUTE_RECALL_ON_OPEN", 0x40000))
_OFFLINE = getattr(stat, "FILE_ATTRIBUTE_OFFLINE", 0x1000)


def is_cloud_placeholder(st):
    fa = getattr(st, "st_file_attributes", 0)
    return bool(fa & (_RECALL_FLAGS | _OFFLINE))


# NTFS 压缩 / 稀疏文件：读的时候文件系统要实时解压，CPU 密集、速度天然只有
# 普通文件的 1/3（实测 CPU 时间 0.44~0.64 秒/GB vs 普通 0.00~0.13 秒/GB）。
# 这不是盘的问题，必须排除，否则 C:\Windows\Installer 那类目录会整片误报。
_COMPRESSED_FLAGS = (getattr(stat, "FILE_ATTRIBUTE_COMPRESSED", 0x800)
                     | getattr(stat, "FILE_ATTRIBUTE_SPARSE_FILE", 0x200))


def is_compressed_or_sparse(st):
    return bool(getattr(st, "st_file_attributes", 0) & _COMPRESSED_FLAGS)


def scan(root, min_bytes, cold_days, warm_days, limit_entries=400000,
         include_compressed=False):
    """只读遍历，返回 (cold, warm, seen)。不跟随 junction/symlink。
    limit_entries=0 表示不限制（全量）。

    用 os.scandir 而非 os.walk + os.stat：Windows 上 DirEntry.stat() 直接取自
    目录枚举返回的 WIN32_FIND_DATA，**不产生额外系统调用**；而 os.walk 再
    os.stat 每个文件 = 每个文件多一次 syscall。实测全盘快 5~10 倍。
    """
    now = time.time()
    cold, warm = [], []
    seen = 0
    skipped_cloud = 0
    skipped_comp = 0
    skipped_perm = 0        # 因权限/占用而打不开的目录数
    n_hidden = 0            # 进入候选的隐藏/系统属性文件数
    last_report = now
    unlimited = not limit_entries
    stack = [root]
    while stack:
        cur = stack.pop()
        try:
            it = os.scandir(cur)
        except OSError:
            skipped_perm += 1
            continue
        with it:
            for e in it:
                try:
                    # is_symlink() 读的是缓存的 reparse 属性，junction 也算 → 一并挡住
                    if e.is_symlink():
                        continue
                    if e.is_dir(follow_symlinks=False):
                        # 大小写不敏感匹配，避免 $Recycle.Bin / recovery 等变体漏网
                        if e.name.lower() not in _SKIP_DIRS_LOWER:
                            stack.append(e.path)
                        continue
                    if e.name.lower() in SKIP_FILES:
                        continue
                    seen += 1
                    if not unlimited and seen > limit_entries:
                        print("  [warn] 条目数超过 %d，提前结束扫描（用 --max-entries 0 解除）"
                              % limit_entries)
                        return cold, warm, seen
                    st = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                if is_cloud_placeholder(st):
                    skipped_cloud += 1          # 云端占位，读它等于测网速
                    continue
                if not include_compressed and is_compressed_or_sparse(st):
                    skipped_comp += 1           # NTFS 压缩/稀疏，读速天然 1/3
                    continue
                size = st.st_size
                if size < min_bytes:
                    continue
                if getattr(st, "st_file_attributes", 0) & (_HIDDEN_ATTR | _SYSTEM_ATTR):
                    n_hidden += 1               # 不按属性过滤，仅统计以便用户知情
                age_days = (now - st.st_mtime) / 86400.0
                if age_days >= cold_days:
                    cold.append((e.path, size, st.st_mtime))
                elif age_days <= warm_days:
                    warm.append((e.path, size, st.st_mtime))
        t = time.time()
        if t - last_report >= 20:
            last_report = t
            print("  ...已遍历 %d 条目 | 冷候选 %d | 暖候选 %d | 跳过云端占位 %d | 用时 %.0fs"
                  % (seen, len(cold), len(warm), skipped_cloud, t - now))
    if skipped_cloud:
        print("  [跳过 %d 个云端占位文件（OneDrive/网盘按需下载，读速=网速，不可作磁盘判据）]"
              % skipped_cloud)
    if skipped_comp:
        print("  [跳过 %d 个 NTFS 压缩/稀疏文件（读取需实时解压，速度天然只有 1/3，"
              "非磁盘故障；用 --include-compressed 强制纳入）]" % skipped_comp)
    if n_hidden:
        print("  [范围提示] 候选中含 %d 个 **隐藏/系统属性** 文件 —— 本工具不按属性"
              "过滤，如需排除请自行加 --min-mb 或调整目录" % n_hidden)
    if skipped_perm:
        print("  [注意] 有 %d 个目录因权限不足或占用被静默跳过（本机实测含 "
              "C:\\Windows\\System32\\config 这类注册表 hive 目录）。"
              "\n         如需完整覆盖，请以管理员身份运行。" % skipped_perm)
    cold.sort(key=lambda x: -x[1])
    warm.sort(key=lambda x: -x[1])
    return cold, warm, seen


def scan_mft(letter, min_bytes, cold_days, warm_days):
    """直读 $MFT 枚举整卷（需管理员）。返回同 scan() 的 (cold, warm, seen)。"""
    import ntfs_mft
    now = time.time()
    print("  正在直读 NTFS $MFT（WizTree 方式，需管理员权限）...")
    files, meta = ntfs_mft.enumerate_volume(
        letter, progress=lambda m: print("    " + m))
    print("  MFT 枚举完成：%d 条记录 / %d 个文件 / 读 %.2f GB / 用时 %.1fs"
          % (meta["records"], meta["files"], meta["mft_bytes"] / 1024 ** 3,
             meta["seconds"]))
    cold, warm = [], []
    seen = 0
    for f in files:
        seen += 1
        size = f["size"]
        if size < min_bytes:
            continue
        age_days = (now - f["mtime"]) / 86400.0
        if age_days >= cold_days:
            cold.append((f["path"], size, f["mtime"]))
        elif age_days <= warm_days:
            warm.append((f["path"], size, f["mtime"]))
    cold.sort(key=lambda x: -x[1])
    warm.sort(key=lambda x: -x[1])
    return cold, warm, seen


# ---------------------------------------------------------------- 输出

def human(n):
    for u in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024:
            return "%.1f %s" % (n, u)
        n /= 1024.0
    return "%.1f PiB" % n


def fmt_age(ts):
    return time.strftime("%Y-%m-%d", time.localtime(ts))


def short(p, width=68):
    return p if len(p) <= width else "..." + p[-(width - 3):]


class RefTracker:
    """参考文件追踪器。

    为什么需要：消费级 NVMe 的读速会随时间/负载漂移（实测 D 盘持续读到
    ~130GB 后从 3770 掉到 2760 MB/s 并保持）。若只比绝对速度，同一批文件
    在第一分钟测是"快"、第三分钟测就变成"掉速"，全是假阳性。
    做法：固定一个参考文件，穿插测量，用它的实时速度把每个候选归一化，
    时间漂移就被约掉了。"""

    def __init__(self, path, size, read_mb, every):
        self.path = path
        self.size = size
        self.read_mb = read_mb
        self.every = max(1, every)
        self.trace = []          # [(perf_counter, speed)]

    def poke(self, label=""):
        if not self.path:
            return None
        want = min(self.read_mb * 1024 ** 2, self.size)
        spd, _, _, _ = measure(self.path, self.size, want, 3)
        if spd:
            self.trace.append((time.perf_counter(), spd))
            if label:
                print("  [参考] %s 当前盘速 %.1f MB/s" % (label, spd))
        return spd

    def at(self, t):
        """取 t 时刻的参考速度（线性插值）。"""
        if not self.trace:
            return None
        if t <= self.trace[0][0]:
            return self.trace[0][1]
        if t >= self.trace[-1][0]:
            return self.trace[-1][1]
        for i in range(1, len(self.trace)):
            t0, s0 = self.trace[i - 1]
            t1, s1 = self.trace[i]
            if t0 <= t <= t1:
                if t1 == t0:
                    return s1
                k = (t - t0) / (t1 - t0)
                return s0 + (s1 - s0) * k
        return self.trace[-1][1]


def run_group(label, items, args, budget_bytes, top=None, ref=None):
    if not items:
        print("\n[%s] 无符合条件的文件" % label)
        return [], []
    total = min(args.max_files, len(items))
    print("\n[%s] 候选 %d 个，共 %s；本次测试 %d 个"
          % (label, len(items), human(sum(i[1] for i in items)), total))
    print("-" * 100)
    print("%-72s %10s %12s %12s" % ("文件", "大小", "修改日期", "读取速度"))
    print("-" * 100)

    results, skipped = [], []
    t_start = time.time()
    for idx, (path, size, mtime) in enumerate(items[:args.max_files]):
        if budget_bytes <= 0:
            print("  [budget] 读取预算用尽，剩余 %d 个未测（用 --budget-gb 调大）"
                  % (total - idx))
            break
        if ref and idx and idx % ref.every == 0:
            ref.poke("第 %d/%d 个后" % (idx, total))
        want = min(args.max_read_mb * 1024 ** 2, budget_bytes, size)
        t_meas = time.perf_counter()
        try:
            spd, nbytes, direct, err, reps, ms = measure_stable(
                path, size, want, args.spans, direct=not args.no_direct,
                min_bytes=args.min_sample_mb * 1024 ** 2,
                max_reps=args.max_reps)
        except Exception as e:  # noqa: BLE001
            spd, nbytes, direct, err, reps, ms = None, 0, False, str(e), 0, 0.0
        budget_bytes -= nbytes
        if spd is None:
            skipped.append({"path": path, "size": size, "reason": err or "?"})
            continue
        r = {"path": path, "size": size, "mtime": mtime,
             "speed_mbps": round(spd, 1),
             "read_mb": round(nbytes / 1024 ** 2, 1),
             "direct_io": direct, "t": t_meas,
             "reps": reps, "ms": round(ms, 1)}
        rs = ref.at(t_meas) if ref else None
        if rs:
            r["ref_mbps"] = round(rs, 1)
            r["norm"] = round(spd / rs, 4)      # 归一化速度：抵消时间漂移
        results.append(r)
        if top is None or total <= top:
            extra = "" if direct else "  (缓存路径)"
            if reps > 1:
                extra += "  x%d/%.0fms" % (reps, ms)
            print("%-72s %10s %12s %9.1f MB/s%s"
                  % (short(path), human(size), fmt_age(mtime), spd, extra))
        elif (idx + 1) % 25 == 0:
            print("  ...已测 %d/%d，用时 %.0fs" % (idx + 1, total, time.time() - t_start))

    if ref and ref.path:
        ref.poke("%s 组结束" % label)

    if top is not None and total > top:
        print("-" * 100)
        print("（共 %d 个，此处只列最慢的 %d 个；完整清单见 --csv / --json）"
              % (len(results), top))
        print("-" * 100)
        for r in sorted(results, key=lambda x: x["speed_mbps"])[:top]:
            print("%-72s %10s %12s %9.1f MB/s"
                  % (short(r["path"]), human(r["size"]), fmt_age(r["mtime"]),
                     r["speed_mbps"]))

    if skipped:
        print("\n  [跳过 %d 个]" % len(skipped))
        reasons = {}
        for s in skipped:
            key = s["reason"].split("(")[0].strip()[:40]
            reasons[key] = reasons.get(key, 0) + 1
        for k, v in sorted(reasons.items(), key=lambda x: -x[1]):
            print("    %4d 个: %s" % (v, k))
        for s in skipped[:5]:
            print("      %s  → %s" % (short(s["path"], 60), s["reason"]))
    return results, skipped


def write_csv(path, cold, warm):
    import csv
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["组", "读速MB/s", "参考盘速MB/s", "归一化", "同档归一化基准",
                    "同档基准来源", "归一化%", "重复次数", "测量ms",
                    "大小字节", "最后写入", "年龄天数", "路径"])
        now = time.time()
        for grp, rows in (("冷", cold), ("暖", warm)):
            for r in sorted(rows, key=lambda x: x["speed_mbps"]):
                w.writerow([grp, r["speed_mbps"], r.get("ref_mbps", ""),
                            r.get("norm", ""), r.get("norm_base", ""),
                            r.get("norm_base_src", ""), r.get("pct_norm", ""),
                            r.get("reps", ""), r.get("ms", ""),
                            r["size"],
                            time.strftime("%Y-%m-%d %H:%M:%S",
                                          time.localtime(r["mtime"])),
                            round((now - r["mtime"]) / 86400), r["path"]])




BUCKETS = [(0, 8), (8, 16), (16, 32), (32, 64), (64, 128), (128, 256),
           (256, 512), (512, 1024), (1024, 2048), (2048, 1 << 62)]
BUCKET_NAMES = ["<8MB", "8-16MB", "16-32MB", "32-64MB", "64-128MB",
                "128-256MB", "256-512MB", "512MB-1GB", "1-2GB", ">2GB"]


def bucket_of(size):
    mb = size / 1024 ** 2
    for i, (lo, hi) in enumerate(BUCKETS):
        if lo <= mb < hi:
            return i
    return len(BUCKETS) - 1


def build_baselines(warm):
    """按体积分档建基准。小文件的顺序读速天生低于大文件（命令开销/寻道占比），
    不分档会把大量小文件误判成冷数据。返回 {bucket: (中位速度, 样本数)}"""
    by = {}
    for r in warm:
        by.setdefault(bucket_of(r["size"]), []).append(r["speed_mbps"])
    out = {}
    for b, sp in by.items():
        out[b] = (statistics.median(sp), len(sp))
    return out


def baseline_for(size, bl, global_med):
    b = bucket_of(size)
    if b in bl and bl[b][1] >= 2:
        return bl[b][0], "同体积档(%s)暖数据 n=%d" % (BUCKET_NAMES[b], bl[b][1])
    # 相邻档合并
    merged = []
    for nb in (b, b - 1, b + 1):
        if nb in bl:
            merged.append(bl[nb][0])
    if merged:
        return statistics.median(merged), "相邻体积档暖数据 n=%d档" % len(merged)
    return global_med, "全盘暖数据中位"


def verdict(cold, warm, args):
    print("\n" + "=" * 100)
    if not cold:
        print("结论：未找到符合条件的冷数据候选文件（%d 天以上未写入且 ≥ %s）"
              % (args.cold_days, human(args.min_mb * 1024 ** 2)))
        return 0

    cold_sp = sorted(r["speed_mbps"] for r in cold)
    global_med = (statistics.median([r["speed_mbps"] for r in warm]) if warm
                  else cold_sp[max(0, int(len(cold_sp) * 0.9) - 1)])
    bl = build_baselines(warm)

    # 逐文件用「同体积档」基准判，消除体积效应（绝对速度口径）
    for r in cold:
        b, why = baseline_for(r["size"], bl, global_med)
        r["baseline"] = round(b, 1)
        r["pct"] = round(r["speed_mbps"] / b * 100, 1) if b else 0.0
        r["baseline_src"] = why

    # 归一化口径：用参考文件抵消盘速的时间漂移，这是更可靠的主判据
    use_norm = (bool(warm) and all("norm" in r for r in cold)
                and all("norm" in r for r in warm))
    bad_abs = [r for r in cold if r["pct"] < args.ratio * 100]

    if use_norm:
        warm_norm = statistics.median([r["norm"] for r in warm])
        # 归一化也要按体积分档。小文件的归一化值天生比大文件低约 10%（实测
        # 8-16MB 档中位 0.90 vs 512MB-1GB 档 1.01）。若拿"全盘暖数据中位"当唯一
        # 基准，会同时犯两个错：把同档正常的小文件判合格、把真正慢的小文件漏掉。
        byb = {}
        for r in warm:
            byb.setdefault(bucket_of(r["size"]), []).append(r["norm"])
        bln = {b: statistics.median(v) for b, v in byb.items() if len(v) >= 2}
        for r in cold:
            b = bucket_of(r["size"])
            if b in bln:
                base = bln[b]
                src = "同体积档(%s) n=%d" % (BUCKET_NAMES[b], len(byb[b]))
            else:
                base, src = None, ""
                for nb in (b - 1, b + 1):
                    if nb in bln:
                        base = bln[nb]
                        src = "相邻档(%s) n=%d" % (BUCKET_NAMES[nb], len(byb[nb]))
                        break
                if base is None:
                    base, src = warm_norm, "全盘暖数据中位"
            r["norm_base"] = round(base, 3)
            r["norm_base_src"] = src
            r["pct_norm"] = round(r["norm"] / base * 100, 1)
        bad_raw = [r for r in cold if r["pct_norm"] < args.ratio * 100]
        print("主判据：**参考文件归一化**（抵消盘速漂移）+ **同体积档基准**（消除体积效应）")
        print("  全盘暖数据归一化中位 = %.3f（%d 个样本）" % (warm_norm, len(warm)))
        print("  逐文件以所属体积档的暖数据归一化中位为基准；档内样本 <2 时退到相邻档/全盘中位")
        print("  判定：归一化值 < 同档基准 x %.2f 即判掉速" % args.ratio)
        print("  冷数据归一化：中位 %.3f / 最低 %.3f"
              % (statistics.median([r["norm"] for r in cold]),
                 min(r["norm"] for r in cold)))
        print("  按此判据掉速：%d / %d" % (len(bad_raw), len(cold)))
        if len(bad_raw) != len(bad_abs):
            print("  对比：按绝对速度（同体积档基准）判为掉速的有 %d 个 —— 差值 %d 个"
                  % (len(bad_abs), len(bad_abs) - len(bad_raw)))
            print("        说明存在时间漂移导致的假阳性，以归一化结果为准。")
    else:
        bad_raw = bad_abs
        print("主判据：绝对速度 vs 同体积档暖基准（未启用参考文件归一化）")

    # 低置信度分离，两种原因：
    #   ① 测量时长不足 —— 单次几毫秒，随机噪声可达 30%+
    #   ② 读取量不足 —— 读取量上限被文件大小锁死（<16MiB 的文件最多只能读 12MiB），
    #      此时归一化值被"物理布局/碎片/目录局部性"主导，与 NAND 电荷状态无关。
    #      实测 4-8MB 档跨文件离散度 38%，但与文件年龄**正相关**（r=+0.477，
    #      老文件反而更快）→ 不是冷数据退化。这类文件不适用于冷数据判定。
    lowconf = []
    for r in bad_raw:
        # 判据用**文件大小**而非累计读取量：重复测量只能压随机噪声，压不掉
        # "单次读取量被文件大小锁死"带来的物理布局主导效应。
        if r.get("size", 1 << 60) < args.min_detect_mb * 1024 ** 2:
            r["low_reason"] = "文件仅 %.1fMB < %gMB，单次读取量被锁死" % (
                r.get("size", 0) / 1024 ** 2, args.min_detect_mb)
            lowconf.append(r)
        elif r.get("ms", 1e9) < args.low_conf_ms:
            r["low_reason"] = "测量时长 %.1fms < %.0fms" % (r.get("ms", 0), args.low_conf_ms)
            lowconf.append(r)
    low_ids = {id(r) for r in lowconf}
    bad = [r for r in bad_raw if id(r) not in low_ids]
    if lowconf:
        print("  !! 其中 %d 个判为**不适用/低置信度**，已单列、不计入掉速"
              "（原因见末尾清单）" % len(lowconf))

    print("\n冷数据读速：中位 %.1f / 最快 %.1f / 最慢 %.1f MB/s"
          % (statistics.median(cold_sp), cold_sp[-1], cold_sp[0]))

    print("\n按体积档汇总（绝对值口径）：")
    print("  %-12s %6s %10s %10s %10s %8s" %
          ("体积档", "样本", "中位读速", "最慢", "档基准", "掉速数"))
    for i, name in enumerate(BUCKET_NAMES):
        rows = [r for r in cold if bucket_of(r["size"]) == i]
        if not rows:
            continue
        sp = sorted(r["speed_mbps"] for r in rows)
        base = rows[0]["baseline"]
        nbad = sum(1 for r in rows if r["pct"] < args.ratio * 100)
        print("  %-12s %6d %10.1f %10.1f %10.1f %8d"
              % (name, len(rows), statistics.median(sp), sp[0], base, nbad))

    if len(cold_sp) >= 5:
        key = "pct_norm" if use_norm else "pct"
        vals = sorted(r[key] for r in cold)
        print("\n离散度（归一化口径）：标准差 %.1f%% | p10 %.0f%% / p90 %.0f%%"
              % (statistics.pstdev(vals), vals[max(0, int(len(vals) * 0.1) - 1)],
                 vals[min(len(vals) - 1, int(len(vals) * 0.9))]))
        print("\n读速分布（相对基准的百分比；真冷数据掉速会呈双峰）：")
        buckets = [0] * 10
        for r in cold:
            buckets[min(9, max(0, int(r[key] // 10)))] += 1
        peak = max(buckets) or 1
        for i, cnt in enumerate(buckets):
            lo = i * 10
            print("  %3d-%3d%%  %-30s %4d" % (lo, lo + 10, "#" * int(cnt / peak * 30), cnt))
    print("掉速文件（置信度合格）：%d / %d" % (len(bad), len(cold)))
    if lowconf:
        print("低置信度待复测：%d 个" % len(lowconf))
    print("=" * 100)

    if lowconf:
        print("\n[不适用 / 低置信度，未计入结论] 共 %d 个：读取量或测量时长不足，"
              "读数被噪声或物理布局主导" % len(lowconf))
        for r in sorted(lowconf, key=lambda x: x.get("pct_norm", x["pct"]))[:args.top]:
            print("  %7.1f MB/s  归一化 %5.1f%%  %6.1fMB x%d/%.1fms  %-32s  %s"
                  % (r["speed_mbps"], r.get("pct_norm", r["pct"]),
                     r.get("size", 0) / 1024 ** 2, r.get("reps", 0), r.get("ms", 0),
                     r.get("low_reason", ""), short(r["path"], 46)))
        print("  读取量不足的文件无法靠「多测几轮」补救——读取量上限被文件大小锁死。"
              "\n  要判冷数据请把 --min-mb 提到 16 以上；小于该量级的文件只能抓"
              "断崖式退化（>3 倍）。")

    if bad:
        print("\n【结论：存在掉速】以下文件读速低于基准，符合冷数据特征：")
        for r in sorted(bad, key=lambda x: x.get("pct_norm", x["pct"]))[:args.top]:
            print("  %7.1f MB/s  (归一化 %5.1f%%)  x%d/%.0fms  %s"
                  % (r["speed_mbps"], r.get("pct_norm", r["pct"]),
                     r.get("reps", 1), r.get("ms", 0), r["path"]))
        if len(bad) > args.top:
            print("  ...另有 %d 个，见 --csv 输出" % (len(bad) - args.top))
        print("\n注意：本工具只诊断，不修复。修不了是正常的——冷数据只和【写入】有关，"
              "\n      重复读取不会让它「加温」。修复办法是把文件复制到别处再复制回来。")
        return 1

    print("\n【结论：未检测到掉速】所有被测冷文件读速都在基准的 %.0f%% 以上。"
          % (args.ratio * 100))
    if not warm:
        print("  提示：本次没有找到同盘暖数据做基准，用的是自基准，结论偏保守。")
    if not use_norm:
        print("  提示：本次未启用参考文件归一化，若盘速随时间漂移可能出现假阳性。")
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="纯只读 SSD 冷数据掉速诊断（不向目标盘写入任何数据）")
    ap.add_argument("path", help="要扫描的目录，如 D:\\ 或 D:\\SteamLibrary")
    ap.add_argument("--cold-days", type=float, default=300,
                    help="超过多少天未写入算冷数据（默认 300）")
    ap.add_argument("--warm-days", type=float, default=7,
                    help="多少天内写入过的文件算暖数据基准（默认 7）")
    ap.add_argument("--min-mb", type=float, default=64,
                    help="只测大于该体积的文件，单位 MB（默认 64）")
    ap.add_argument("--max-files", type=int, default=25,
                    help="每组最多测试的文件数（默认 25）")
    ap.add_argument("--all", action="store_true",
                    help="全量模式：测试所有冷候选文件，不设数量上限")
    ap.add_argument("--max-entries", type=int, default=400000,
                    help="遍历条目上限，0=不限制（全盘扫描必须设 0，默认 400000）")
    ap.add_argument("--fast", action="store_true",
                    help="直读 NTFS $MFT 枚举整卷（WizTree 方式，秒级；需管理员）")
    ap.add_argument("--elevate", action="store_true",
                    help="通过一次 UAC 提权重启本命令（--fast 需要）")
    ap.add_argument("--top", type=int, default=25,
                    help="控制台最多列出多少个最慢文件（默认 25，完整清单看 --csv）")
    ap.add_argument("--max-read-mb", type=int, default=1024,
                    help="每个文件最多读取多少 MB（默认 1024，0=整文件）")
    ap.add_argument("--spans", type=int, default=3,
                    help="每个文件均匀采样几段（默认 3=首/中/尾）")
    ap.add_argument("--budget-gb", type=float, default=40,
                    help="本次总共最多读取多少 GB（默认 40；全量扫描建议 200+）")
    ap.add_argument("--ratio", type=float, default=0.5,
                    help="低于基准的这个比例即判定掉速（默认 0.5）")
    ap.add_argument("--min-sample-mb", type=int, default=64,
                    help="每个文件至少累计读取多少 MB；不足则自动重复测量取中位"
                         "（默认 64，用于压制小文件的测量噪声）")
    ap.add_argument("--max-reps", type=int, default=8,
                    help="单个文件最多重复测量几轮（默认 8）")
    ap.add_argument("--low-conf-ms", type=float, default=20,
                    help="单文件累计测量时长低于该值判为低置信度，单列不计入掉速"
                         "（默认 20ms）")
    ap.add_argument("--min-detect-mb", type=float, default=16,
                    help="文件小于该值判为不适用于冷数据判定，单列不计入掉速（默认 16MB；"
                         "<16MB 文件单次读取量被锁死，读数被物理布局主导，与年龄无关）")
    ap.add_argument("--ref-file", metavar="PATH",
                    help="参考文件（穿插测量以抵消盘速时间漂移）。默认自动选一个暖文件")
    ap.add_argument("--ref-every", type=int, default=10,
                    help="每测多少个候选后插一次参考测量（默认 10）")
    ap.add_argument("--ref-read-mb", type=int, default=256,
                    help="每次参考测量读多少 MB（默认 256）")
    ap.add_argument("--no-ref", action="store_true",
                    help="关闭参考文件归一化（不推荐：盘速漂移会造成假阳性）")
    ap.add_argument("--include-compressed", action="store_true",
                    help="把 NTFS 压缩/稀疏文件也纳入（读速天然 1/3，通常应排除）")
    ap.add_argument("--no-direct", action="store_true",
                    help="不用无缓冲 I/O（会有页缓存干扰，不推荐）")
    ap.add_argument("--json", metavar="FILE", help="把结果写入 JSON")
    ap.add_argument("--csv", metavar="FILE", help="把每个文件的实测结果写入 CSV")
    args = ap.parse_args()

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    if args.all:
        args.max_files = 10 ** 9

    root = os.path.abspath(args.path)
    if not os.path.isdir(root):
        print("目录不存在: %s" % root)
        return 2

    # --fast 需要管理员（raw volume 访问）。--elevate 通过一次 UAC 重启自己。
    if args.fast and IS_WIN:
        try:
            import ntfs_mft
            _probe = ntfs_mft._open_volume(root[:1])
            ntfs_mft._k32.CloseHandle(_probe)
        except PermissionError as e:
            if args.elevate:
                import subprocess
                print("需要管理员权限，正在通过 UAC 重启...")
                params = subprocess.list2cmdline([sys.executable] + sys.argv[1:])
                rc = ctypes.windll.shell32.ShellExecuteW(
                    None, "runas", sys.executable, params, os.getcwd(), 1)
                if rc > 32:
                    print("已在新窗口以管理员身份启动（输出写入 --json/--csv 指定文件）。")
                    return 0
                print("UAC 被拒绝或启动失败 (rc=%d)" % rc)
                return 3
            print("!! %s" % e)
            print("   --fast 需要管理员权限：请以管理员身份运行，或加 --elevate 弹一次 UAC。")
            print("   无管理员权限时用默认 scandir 模式（已优化，比 os.walk 快 5~10 倍）。")
            return 3
        except Exception as e:  # noqa: BLE001
            print("!! 无法直读 $MFT: %s（回退到 scandir 模式）" % e)
            args.fast = False

    print("目标: %s" % root)
    print("模式: 只读（目标盘零写入） | 直接I/O: %s | 采样 %d 段/文件"
          % ("开" if not args.no_direct else "关", args.spans))
    print("冷数据: >= %g 天未写入 | 暖基准: <= %g 天内写入 | 最小 %g MB"
          % (args.cold_days, args.warm_days, args.min_mb))
    print("扫描方式: %s | 范围: %s | 遍历上限 %s | 读取预算 %.0f GB"
          % ("NTFS $MFT 直读" if args.fast else "目录遍历(os.scandir)",
             "全量（所有冷候选）" if args.all else "最多 %d 个/组" % args.max_files,
             "不限" if not args.max_entries else "%d 条目" % args.max_entries,
             args.budget_gb))
    if args.min_mb < 32:
        print("  !! --min-mb %.0f 会把小文件纳入。实测读取量对结果的影响（同一文件，"
              "只改读取量）：\n     读 4MiB 归一化 0.733 / 8MiB 0.803 / 12MiB 0.838 / "
              "24MiB 0.854 / 48MiB 0.870 / 96MiB 0.925\n"
              "     → 读取量 <16MiB 时体积效应 >15%%，且读数被物理布局主导"
              "（4-8MB 档跨文件离散 38%%，但与年龄**正相关** r=+0.477，老文件反而更快）。\n"
              "     → 本工具会把读取量 < %gMB 的判为「不适用」，单列不计入掉速。"
              % (args.min_mb, args.min_detect_mb))

    t0 = time.time()
    print("\n扫描中（只读，不修改任何文件）...")
    if args.fast:
        cold, warm, seen = scan_mft(root[:1], args.min_mb * 1024 ** 2,
                                    args.cold_days, args.warm_days)
    else:
        cold, warm, seen = scan(root, args.min_mb * 1024 ** 2, args.cold_days,
                                args.warm_days, args.max_entries,
                                include_compressed=args.include_compressed)
    print("扫描完成：%d 个文件，用时 %.1fs" % (seen, time.time() - t0))
    if args.max_entries and seen > args.max_entries:
        print("  !! 扫描被上限截断，结果不完整。全量请加 --max-entries 0")

    budget = args.budget_gb * 1024 ** 3

    # 选参考文件：**必须够大**。小文件（尤其刚写入的）可能还在 SLC 缓存里，
    # 读速比普通文件高 40%+，会把基准整体抬高、制造一片假阳性。
    # 优先 ≥2GB（跨 GB 能摊平局部差异，且基本落在 TLC），再退到 ≥512MB / ≥64MB。
    # 另外必须**实测可读**——pagefile.sys / 被占用文件打不开，会静默让归一化失效。
    ref = None
    if not args.no_ref:
        pool = []
        if args.ref_file and os.path.exists(args.ref_file):
            pool.append(args.ref_file)
        elif args.ref_file:
            print("!! 指定的参考文件不存在，改用自动选择")
        allf = [(p, s) for p, s, m in cold] + [(p, s) for p, s, m in warm]
        allf.sort(key=lambda x: -x[1])
        for floor in (2 * 1024 ** 3, 512 * 1024 ** 2, 64 * 1024 ** 2):
            pool += [p for p, s in allf if s >= floor]
            if len(pool) >= 8:
                break
        for p in pool[:12]:
            try:
                sz = os.path.getsize(p)
            except OSError:
                continue
            t = RefTracker(p, sz, args.ref_read_mb, args.ref_every)
            if t.poke():                       # 真能读出来才算
                ref = t
                break
            print("  [参考] 跳过不可读: %s" % short(p, 62))
        if ref:
            print("\n[参考文件] %s (%.0f MB)"
                  % (short(ref.path, 70), ref.size / 1024 ** 2))
            print("  [参考] 起始 当前盘速 %.1f MB/s" % ref.trace[0][1])
        else:
            print("\n[参考文件] 未找到可读的暖文件，本次不做归一化。"
                  "可用 --ref-file 手动指定一个文件当盘速探针。")

    cr, cskip = run_group("冷数据候选", cold, args, budget,
                          top=None if not args.all else args.top, ref=ref)
    wr, _ = run_group("暖数据基准", warm, args, args.budget_gb * 1024 ** 3 * 0.2,
                      ref=ref)
    rc = verdict(cr, wr, args)

    print("\n总用时 %.1fs" % (time.time() - t0))
    if ref and ref.trace:
        sp = [s for _, s in ref.trace]
        print("[参考文件速度轨迹] %d 次采样：%.1f ~ %.1f MB/s（中位 %.1f）"
              % (len(sp), min(sp), max(sp), statistics.median(sp)))
        if max(sp) > min(sp) * 1.3:
            print("  !! 参考速度波动 %.0f%%，说明该盘读速随时间漂移明显；"
                  "绝对速度口径不可靠，请以归一化结论为准。"
                  % ((max(sp) - min(sp)) / statistics.median(sp) * 100))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump({"root": root, "args": vars(args), "scanned_entries": seen,
                       "cold": cr, "cold_skipped": cskip, "warm": wr,
                       "ref_trace": (ref.trace if ref else []),
                       "generated": time.strftime("%Y-%m-%d %H:%M:%S")},
                      f, ensure_ascii=False, indent=2)
        print("结果已写入 %s" % args.json)
    if args.csv:
        write_csv(args.csv, cr, wr)
        print("逐文件清单已写入 %s" % args.csv)
    return rc


if __name__ == "__main__":
    sys.exit(main())
