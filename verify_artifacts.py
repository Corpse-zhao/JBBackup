#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
JBBackup 产物核验 —— 把 CI 下载回来的 .deb / .ipa 拆开逐项验，不靠 CI 日志里的自述。

用法：  python verify_artifacts.py <deb文件> <ipa文件>
        或直接  python verify_artifacts.py      （自动在 outputs/ 里找）

验什么（每项都是「不说谎，直接读字节」）：
  1. deb：control 字段（尤其 Architecture 必须是 iphoneos-arm64e）
  2. deb：payload 文件清单
  3. Mach-O：每个切片的 cputype/cpusubtype（arm64e 靠 cpusubtype=2 区分，不是靠 cputype）
  4. 代码签名：从 LC_CODE_SIGNATURE → SuperBlob → CS_ENTITLEMENTS 里把 entitlements 抠出来
     —— 这才是 TrollStore 实际会读到的东西，比 grep 二进制里有没有那个字符串靠谱得多
  5. ipa：Payload 结构、Info.plist 字段、二进制的切片与 entitlements
"""
import glob
import io
import os
import plistlib
import struct
import sys
import tarfile
import zipfile

FAIL = 0


def ok(m):
    print("   ✅ " + m)


def bad(m):
    global FAIL
    print("   ❌ " + m)
    FAIL = 1


def head(m):
    print("\n--- " + m + " ---")


# ---------------------------------------------------------------- ar / deb
def deb_members(path):
    """拆 ar 归档，返回 [(名字, 内容)]"""
    raw = open(path, "rb").read()
    assert raw[:8] == b"!<arch>\n", "不是 ar 归档"
    off, out = 8, []
    while off + 60 <= len(raw):
        hdr = raw[off:off + 60]
        name = hdr[0:16].decode(errors="ignore").strip()
        if not name:
            break
        try:
            size = int(hdr[48:58].decode(errors="ignore").strip())
        except ValueError:
            break
        off += 60
        out.append((name, raw[off:off + size]))
        off += size + (size % 2)
    return out


def deb_control(path):
    """Debian 的 control 文件在 control.tar.* 里面，不是 ar 的顶层成员。

    ⚠️ 第一版直接找顶层 `control` 成员 → 永远拿不到，报「Architecture = None」，
       看起来像「产物架构错了」，其实是核验脚本自己找错了地方。
    """
    for name, body in deb_members(path):
        if name.startswith("control.tar"):
            with tarfile.open(fileobj=io.BytesIO(body)) as tf:
                for m in tf.getmembers():
                    if m.name.rstrip("/") in ("control", "./control"):
                        return tf.extractfile(m).read().decode("utf-8", "replace")
    return ""


def deb_data_tar(path):
    for name, body in deb_members(path):
        if name.startswith("data.tar"):
            return name, body
    return None, None


# ---------------------------------------------------------------- Mach-O
# ⚠️ 两个非常容易搞错的地方（本脚本第一版全踩了）：
#  ① cputype 里带了 CPU_ARCH_ABI64 标志位 → 实际是 0x0100000C 而不是 0x0C。
#  ② arm64 与 arm64e 的 cputype **完全相同**，靠 cpusubtype 区分；
#     而 cpusubtype 又带了 CPU_SUBTYPE_MASK/LIB64 高位 → 实际是 0x80000002 而不是 2。
#     所以必须掩码后再比：subtype & 0xFF。
CPU_TYPE_MASK = 0x00FFFFFF
CPU_SUBTYPE_MASK_ = 0xFF000000


def cpu_name(ct, cs):
    base = ct & CPU_TYPE_MASK
    sub = cs & 0xFF
    if base != 0x0C:
        return "cpu=0x%x sub=%d" % (ct, sub)
    return {0: "arm64", 1: "arm64/v8", 2: "arm64e"}.get(sub, "arm64/sub=%d" % sub)


def macho_slices(blob):
    """返回 [(cputype, cpusubtype, slice_bytes)], 支持 fat 与 thin"""
    if blob[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        n = struct.unpack(">I", blob[4:8])[0]
        out, off = [], 8
        for _ in range(n):
            ct, cs, o, sz, al = struct.unpack(">IIIII", blob[off:off + 20])
            off += 20
            out.append((ct, cs, blob[o:o + sz]))
        return out
    if blob[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
        ct, cs = struct.unpack("<II", blob[4:12])
        return [(ct, cs, blob)]
    return []


def entitlements_from_macho(slice_bytes):
    """走 LC_CODE_SIGNATURE → SuperBlob → CS_ENTITLEMENTS，把 entitlements XML 读出来"""
    magic = slice_bytes[:4]
    if magic == b"\xcf\xfa\xed\xfe":          # 64-bit
        ncmds, hdr = struct.unpack("<I", slice_bytes[16:20])[0], 32
    elif magic == b"\xce\xfa\xed\xfe":        # 32-bit
        ncmds, hdr = struct.unpack("<I", slice_bytes[16:20])[0], 28
    else:
        return None
    off = hdr
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", slice_bytes[off:off + 8])
        if cmd == 0x1d:                        # LC_CODE_SIGNATURE
            dataoff, datasize = struct.unpack("<II", slice_bytes[off + 8:off + 16])
            sig = slice_bytes[dataoff:dataoff + datasize]
            if sig[:4] != b"\xfa\xde\x0c\xc0":   # SuperBlob
                return None
            count = struct.unpack(">I", sig[8:12])[0]
            for i in range(count):
                btype, boff = struct.unpack(">II", sig[12 + i * 8:20 + i * 8])
                if btype != 5:                 # CS_ENTITLEMENTS
                    continue
                blob = sig[boff:]
                if blob[:4] != b"\xfa\xde\x71\x71":
                    continue
                blen = struct.unpack(">I", blob[4:8])[0]
                return blob[8:blen].decode("utf-8", "replace")
        off += cmdsize
    return None


def report_binary(label, blob):
    slices = macho_slices(blob)
    head("%s —— Mach-O 切片" % label)
    if not slices:
        bad("不是 Mach-O")
        return None
    names = []
    for ct, cs, sb in slices:
        nm = cpu_name(ct, cs)
        names.append(nm)
        print("   · %-22s 大小 %d 字节 (cputype=0x%x cpusubtype=0x%x)"
              % (nm, len(sb), ct, cs))
    has64 = any((ct & CPU_TYPE_MASK) == 0x0C and (cs & 0xFF) == 0 for ct, cs, _ in slices)
    has64e = any((ct & CPU_TYPE_MASK) == 0x0C and (cs & 0xFF) == 2 for ct, cs, _ in slices)
    if has64:
        ok("含 arm64 切片")
    else:
        bad("缺 arm64 切片")
    # ⚠️ arm64e 的 cputype 与 arm64 **相同**，区别在 cpusubtype=2（且带高位标志）。
    #    只看 cputype 会得出「两个切片都是 arm64」的错误结论（CI 日志里就踩过这个）。
    if has64e:
        ok("含 arm64e 切片（cpusubtype=2）—— roothide 设备的原生切片")
    else:
        bad("缺 arm64e 切片（cpusubtype=2）")
    return slices


def report_entitlements(label, slices):
    head("%s —— 代码签名里的 entitlements（TrollStore 实际会读到的）" % label)
    dumped = 0
    for idx, (ct, cs, sb) in enumerate(slices):
        xml = entitlements_from_macho(sb)
        tag = cpu_name(ct, cs)
        if not xml:
            bad("切片 %d（%s）签名里没找到 entitlements blob" % (idx, tag))
            continue
        dumped += 1
        try:
            ent = plistlib.loads(xml.encode())
        except Exception as e:
            bad("切片 %d entitlements 解析失败：%s" % (idx, e))
            continue
        print("   · 切片 %d（%s）→ %d 项" % (idx, tag, len(ent)))
        for k in sorted(ent):
            print("       %s = %s" % (k, ent[k]))
    if not dumped:
        bad("没有任何切片带 entitlements → TrollStore 保留不到权限，IPA 等于空壳")
        return
    # 把第一个切片的键集拿来做断言
    ent = plistlib.loads(entitlements_from_macho(slices[0][2]).encode())
    must = ["com.apple.private.security.no-sandbox",
            "com.apple.private.security.storage.AppDataContainers",
            "com.apple.security.exception.files.absolute-path.read-write",
            "platform-application"]
    miss = [k for k in must if k not in ent]
    if miss:
        bad("签名里缺关键 entitlements：%s" % miss)
    else:
        ok("无沙盒四件套都在签名里（TrollStore 能保留）")
    ban = ["com.apple.private.cs.debugger", "dynamic-codesigning",
           "com.apple.private.skip-library-validation"]
    hit = [k for k in ban if k in ent]
    if hit:
        bad("签名里出现了被 PPL 禁止的 entitlements（启动即崩）：%s" % hit)
    else:
        ok("没有被禁的 entitlements")


# ---------------------------------------------------------------- main
deb = sys.argv[1] if len(sys.argv) > 1 else None
ipa = sys.argv[2] if len(sys.argv) > 2 else None
if not deb:
    c = sorted(glob.glob("outputs/*.deb")) + sorted(glob.glob("packages/*.deb"))
    deb = c[0] if c else None
if not ipa:
    c = sorted(glob.glob("outputs/*.ipa")) + sorted(glob.glob("packages/*.ipa"))
    ipa = c[0] if c else None

if not deb or not os.path.exists(deb):
    sys.exit("找不到 .deb，请把路径作为第一个参数传进来")
print("deb =", deb)
print("ipa =", ipa or "(未提供)")

# ---------- deb ----------
head("deb —— control 字段")
ctrl = deb_control(deb)
for line in ctrl.strip().splitlines():
    print("   " + line)
arch = None
for line in ctrl.splitlines():
    if line.startswith("Architecture:"):
        arch = line.split(":", 1)[1].strip()
if arch == "iphoneos-arm64e":
    ok("Architecture = iphoneos-arm64e（roothide 设备 Sileo 会接受）")
else:
    bad("Architecture = %s，roothide 设备上 Sileo 会拒装" % arch)

tname, tblob = deb_data_tar(deb)
head("deb —— payload（压缩格式 %s）" % (tname or "?"))
appbin = None
with tarfile.open(fileobj=io.BytesIO(tblob)) as tf:
    for m in tf.getmembers():
        if m.isdir():
            continue
        print("   %-46s %8d  mode=%o" % (m.name, m.size, m.mode & 0o777))
        if m.name.rstrip("/").endswith(".app/JBBackup"):
            appbin = tf.extractfile(m).read()
            print("        ↑ .app 主二进制 mode=%o %s"
                  % (m.mode & 0o777, "（可执行位在）" if m.mode & 0o111 else "（⚠️ 丢了！）"))
if appbin:
    slices = report_binary("deb 里的 JBBackup", appbin)
    if slices:
        report_entitlements("deb 里的 JBBackup", slices)

# ---------- ipa ----------
if ipa and os.path.exists(ipa):
    head("ipa —— 结构")
    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()
        for n in names:
            print("   " + n)
        approot = "Payload/JBBackup.app/"
        if any(n.startswith(approot) for n in names):
            ok("Payload/JBBackup.app 结构正确")
        else:
            bad("没有 Payload/JBBackup.app")
        ip = z.read(approot + "Info.plist")
        d = plistlib.loads(ip)
        head("ipa —— Info.plist")
        for k in ["CFBundleIdentifier", "CFBundleExecutable", "CFBundleDisplayName",
                  "CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion"]:
            print("   %-28s = %s" % (k, d.get(k)))
        if d.get("CFBundleIdentifier") == "com.blr.jbbackup":
            ok("bundle id 正确")
        else:
            bad("bundle id 不对：%s" % d.get("CFBundleIdentifier"))
        ibin = z.read(approot + "JBBackup")
        info = z.getinfo(approot + "JBBackup")
        if (info.external_attr >> 16) & 0o111:
            ok("zip 里保留了可执行位（mode=%o）" % ((info.external_attr >> 16) & 0o777))
        else:
            bad("zip 里丢了可执行位 —— TrollStore 装上点不动图标")
        slices2 = report_binary("ipa 里的 JBBackup", ibin)
        if slices2:
            report_entitlements("ipa 里的 JBBackup", slices2)

print()
if FAIL:
    print("🛑 产物核验未通过")
    sys.exit(1)
print("🎉 产物核验全部通过")
