# -*- coding: utf-8 -*-
"""小文件冷数据检测 —— 用 4KB 随机读**延迟分布**替代吞吐。

为什么吞吐不行：
  小文件读取量被文件大小锁死（4MB 文件最多读 4MB，2.9GB/s 下仅 1.4ms），
  固定开销 + 调度噪声占比过大，NAND 层面的差异被淹没。

为什么延迟可以：
  NAND 电荷泄漏 -> Vth 漂移 -> LDPC 硬判决失败 -> 软判决重读（多次换参考
  电压重读同一页）-> **单页读延迟成倍增加**。该信号在主机侧可见，且与
  读取量无关。4KB 随机读没有预取/流水线掩盖，对单页状态最敏感。

判据：同体积档「冷组」vs「暖组」比三个量
  - 中位延迟   ：整体是否右移
  - p90 延迟   ：是否只有一部分页变慢
  - 变异系数 CV：退化不均匀 -> 离散度变大

用法: python cold_tiny_check.py <目录1> [目录2 ...] [--per N] [--pages N]
"""
import ctypes
import os
import random
import statistics
import sys
import time
from ctypes import wintypes

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

GENERIC_READ = 0x80000000
FILE_SHARE_READ = 1
FILE_SHARE_WRITE = 2
OPEN_EXISTING = 3
FILE_FLAG_NO_BUFFERING = 0x20000000
INVALID = ctypes.c_void_p(-1).value
PAGE = 4096

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.CreateFileW.restype = ctypes.c_void_p
k32.CreateFileW.argtypes = [ctypes.c_wchar_p, wintypes.DWORD, wintypes.DWORD,
                            ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                            ctypes.c_void_p]
k32.ReadFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD,
                         ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
k32.SetFilePointerEx.argtypes = [ctypes.c_void_p, ctypes.c_longlong,
                                 ctypes.POINTER(ctypes.c_longlong),
                                 wintypes.DWORD]
k32.CloseHandle.argtypes = [ctypes.c_void_p]
k32.VirtualAlloc.restype = ctypes.c_void_p
k32.VirtualAlloc.argtypes = [ctypes.c_void_p, ctypes.c_size_t, wintypes.DWORD,
                             wintypes.DWORD]
k32.VirtualFree.argtypes = [ctypes.c_void_p, ctypes.c_size_t, wintypes.DWORD]

MEM_COMMIT_RESERVE = 0x3000
MEM_RELEASE = 0x8000
PAGE_READWRITE = 0x04

SKIP = {"$recycle.bin", "system volume information", "$winreagent",
        "config.msi", "$sysreset", "recovery", "$extend", "onedrivetemp"}


def open_raw(path):
    h = k32.CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                        None, OPEN_EXISTING, FILE_FLAG_NO_BUFFERING, None)
    return None if h in (None, INVALID) else h


def read_at(h, buf, off):
    pos = ctypes.c_longlong(0)
    if not k32.SetFilePointerEx(h, ctypes.c_longlong(off), ctypes.byref(pos), 0):
        return None
    n = wintypes.DWORD(0)
    t0 = time.perf_counter()
    ok = k32.ReadFile(h, ctypes.c_void_p(buf), PAGE, ctypes.byref(n), None)
    dt = time.perf_counter() - t0
    return dt * 1e6 if (ok and n.value == PAGE) else None


def probe(path, pages, rounds, seed=12345):
    """返回该文件 4KB 随机页读延迟列表（微秒）。"""
    try:
        sz = os.path.getsize(path)
    except OSError:
        return None
    nblk = sz // PAGE
    if nblk < 1:
        return None
    buf = k32.VirtualAlloc(None, PAGE, MEM_COMMIT_RESERVE, PAGE_READWRITE)
    if not buf:
        return None
    h = open_raw(path)
    if not h:
        k32.VirtualFree(ctypes.c_void_p(buf), 0, MEM_RELEASE)
        return None
    try:
        rnd = random.Random(seed)
        offs = sorted(rnd.sample(range(nblk), min(pages, nblk)))
        lat = []
        for _ in range(rounds):
            for b in offs:
                dt = read_at(h, buf, b * PAGE)
                if dt is not None:
                    lat.append(dt)
        return lat or None
    finally:
        k32.CloseHandle(h)
        k32.VirtualFree(ctypes.c_void_p(buf), 0, MEM_RELEASE)


def scan(roots, lo, hi, cold_days, warm_days):
    now = time.time()
    cold, warm = [], []
    for root in roots:
        stack = [root]
        while stack:
            cur = stack.pop()
            try:
                it = os.scandir(cur)
            except OSError:
                continue
            with it:
                for e in it:
                    try:
                        if e.is_symlink():
                            continue
                        if e.is_dir(follow_symlinks=False):
                            if e.name.lower() not in SKIP:
                                stack.append(e.path)
                            continue
                        st = e.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    if not (lo <= st.st_size <= hi):
                        continue
                    age = (now - st.st_mtime) / 86400.0
                    if age >= cold_days:
                        cold.append((e.path, st.st_size, age))
                    elif age <= warm_days:
                        warm.append((e.path, st.st_size, age))
    return cold, warm


def pick(items, n):
    items.sort(key=lambda x: x[1])
    if len(items) <= n:
        return items
    step = len(items) / float(n)
    return [items[min(len(items) - 1, int(i * step))] for i in range(n)]


def summarize(lat):
    if not lat:
        return None
    s = sorted(lat)
    med = statistics.median(s)
    p90 = s[min(len(s) - 1, int(len(s) * 0.9))]
    cv = (statistics.pstdev(s) / med * 100) if med else 0
    return med, p90, cv, len(s)


def run_group(files, pages, rounds, label):
    per_file = []
    for path, size, age in files:
        lat = probe(path, pages, rounds)
        if lat:
            per_file.append((path, size, age, lat))
    if not per_file:
        return None, []
    # 文件级中位 -> 组中位（避免单文件页数不同造成加权偏差）
    meds = sorted(statistics.median(l) for _, _, _, l in per_file)
    all_lat = [v for _, _, _, l in per_file for v in l]
    grp_med = statistics.median(meds)
    grp_p90 = sorted(all_lat)[min(len(all_lat) - 1, int(len(all_lat) * 0.9))]
    cv = statistics.pstdev(all_lat) / statistics.median(all_lat) * 100
    return {"n": len(per_file), "file_med": grp_med, "p90": grp_p90,
            "cv": cv, "all": all_lat, "meds": meds}, per_file


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    per = 60
    pages = 32
    rounds = 3
    for i, a in enumerate(sys.argv):
        if a == "--per" and i + 1 < len(sys.argv):
            per = int(sys.argv[i + 1])
        if a == "--pages" and i + 1 < len(sys.argv):
            pages = int(sys.argv[i + 1])
        if a == "--rounds" and i + 1 < len(sys.argv):
            rounds = int(sys.argv[i + 1])

    roots = args or ["D:\\", "E:\\"]
    lo, hi = 4 * 1024 ** 2, 8 * 1024 ** 2
    cold_days, warm_days = 300, 14

    print("扫描 %s 中 %g-%g MB 的文件 ..." % (roots, lo / 1024 ** 2, hi / 1024 ** 2))
    t0 = time.time()
    cold, warm = scan(roots, lo, hi, cold_days, warm_days)
    print("冷候选 %d 个 | 暖候选 %d 个 | 用时 %.1fs"
          % (len(cold), len(warm), time.time() - t0))
    print("每文件随机 %d 页 x %d 轮 = %d 次 4KB 读；每组取 %d 个文件\n"
          % (pages, rounds, pages * rounds, per))

    cf = pick(cold, per)
    wf = pick(warm, per)
    print("测量冷组（%d 文件）..." % len(cf))
    cs, cdetail = run_group(cf, pages, rounds, "冷")
    print("测量暖组（%d 文件）..." % len(wf))
    ws, wdetail = run_group(wf, pages, rounds, "暖")

    print()
    print("=" * 96)
    print("4KB 随机读延迟（微秒，越小越快）")
    print("=" * 96)
    if not cs or not ws:
        print("样本不足：冷 %s 暖 %s" % (cs and cs["n"], ws and ws["n"]))
        return 1

    print("%-6s %6s %12s %10s %10s %8s" % ("组", "文件数", "文件级中位", "p90", "CV%", "读数"))
    print("-" * 96)
    for tag, s in (("冷", cs), ("暖", ws)):
        print("%-6s %6d %12.1f %10.1f %10.1f %8d"
              % (tag, s["n"], s["file_med"], s["p90"], s["cv"], len(s["all"])))
    print("-" * 96)
    r_med = cs["file_med"] / ws["file_med"] if ws["file_med"] else 0
    r_p90 = cs["p90"] / ws["p90"] if ws["p90"] else 0
    print("冷/暖 比值：中位 %.3f   p90 %.3f   CV差 %.1f 个百分点"
          % (r_med, r_p90, cs["cv"] - ws["cv"]))

    print()
    print("=" * 96)
    print("判定")
    print("=" * 96)
    if r_med < 1.15 and r_p90 < 1.25:
        print("【未检测到冷数据退化】冷组延迟与暖组无显著差异（中位 %.2fx）。" % r_med)
        print("  含义：这些文件虽然长期未写入，但读取没有触发额外的 ECC 重读。")
    else:
        print("【存在延迟升高】冷组比暖组慢 中位 %.2fx / p90 %.2fx。" % (r_med, r_p90))
        print("  需复测确认（换 --pages 64 再跑一次），排除目录局部性。")

    print()
    print("最慢的 10 个冷文件（文件级中位，微秒）：")
    for path, size, age, l in sorted(cdetail, key=lambda x: -statistics.median(x[3]))[:10]:
        print("  %8.1f us  %6.1f MB  %5d 天  %s"
              % (statistics.median(l), size / 1024 ** 2, age, path[-72:]))
    print()
    print("最快的 5 个暖文件（对照，微秒）：")
    for path, size, age, l in sorted(wdetail, key=lambda x: statistics.median(x[3]))[:5]:
        print("  %8.1f us  %6.1f MB  %5d 天  %s"
              % (statistics.median(l), size / 1024 ** 2, age, path[-72:]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
