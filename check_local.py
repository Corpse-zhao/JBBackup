#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
JBBackup 本地预检 —— 把静态检查放到本地跑，省 CI 轮次。

用法：  python check_local.py
（在工程根目录执行）

⚠️ CI（.github/workflows/build.yml）直接调用本脚本，不另写一份检查 —— 
   两份检查不同步 = 本地绿而 CI 红，白等一轮。

检查重点（每一条都对应一类真实会咬人的事故）：
  A 构建完整性  —— 源码文件缺失 / 漏进 Makefile / 版本号不一致 / entitlement 写错
  B 编译期硬伤  —— 括号不平衡 / 函数名打错 / 格式串 % 没转义 / ARC 桥接 / C 符号没 import
  C 数据安全    —— 还原前的越狱检查、安全快照、按 bundle id 定位容器、危险删除
"""
import glob
import io
import os
import re
import subprocess
import sys

FAIL = 0
HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)


def read(path):
    try:
        return io.open(path, encoding="utf-8", errors="replace").read()
    except IOError:
        return ""


def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return re.sub(r"//[^\n]*", "", s)


def fail(msg):
    global FAIL
    print("   " + msg)
    FAIL = 1


def ok(msg):
    print("   ✅ " + msg)


def head(t):
    print("--- 检查 %s ---" % t)


def _brace_body_at(src, i):
    """从 src[i]（必须是 '{'）开始做花括号计数，返回最外层块的内容。"""
    if i < 0 or i >= len(src) or src[i] != "{":
        return None
    depth = 0
    for j in range(i, len(src)):
        c = src[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[i + 1:j]
    return None


def find_body(src, header_regex):
    """提取函数体（用花括号计数，不能用非贪婪正则 —— 嵌套块会截出半截）。

    ⚠️ header_regex 必须**以 `\\{` 结尾**（即匹配到最外层左花括号）。
       否则 m.end()-1 指向的不是 `{`，会静默返回 None —— 看起来像「函数不存在」。
    """
    m = re.search(header_regex, src)
    if not m:
        return None
    return _brace_body_at(src, m.end() - 1)


def find_method_body(src, selector):
    """按 ObjC 方法选择器文本定位函数体。

    ObjC 方法签名会跨行（选择器片段分行缩进），用 find_body 拼正则既脆弱又易错，
    所以这里改成：先找选择器文本，再向后找第一个 `{`，然后花括号计数。
    """
    k = src.find(selector)
    if k < 0:
        return None
    i = src.find("{", k)
    return _brace_body_at(src, i)


# ===========================================================================
# A. 构建完整性
# ===========================================================================
mk = read("Makefile")

head("A1：Makefile 里列出的每个源文件都必须真实存在")
# 血泪（本项目第一次写就踩）：_FILES 里写了 JBBRootViewController.m，
# 但那个文件当时还没创建 → CI 编译必然失败，白等一轮。
m = re.search(r"^JBBackup_FILES\s*=\s*((?:.*\\\n)*.*)$", mk, re.M)
if not m:
    fail("❌ Makefile 里找不到 JBBackup_FILES")
    listed = []
else:
    listed = re.findall(r"([A-Za-z_][\w./-]*\.(?:m|mm|x|c|cpp))",
                        m.group(1).replace("\\\n", " "))
    missing = [f for f in listed if not os.path.exists(f)]
    if missing:
        fail("❌ Makefile 声明了但文件不存在（编译必挂）：%s" % missing)
    else:
        ok("声明 %d 个源文件，全部存在" % len(listed))

head("A2：目录下的 .m 必须全部进 _FILES（防漏加文件 → 编过了但功能缺失）")
onDisk = sorted(set(glob.glob("*.m")))
notListed = [f for f in onDisk if f not in listed]
if notListed:
    fail("❌ 这些 .m 没有写进 Makefile 的 JBBackup_FILES：%s" % notListed)
    fail("   漏加的症状是「编译通过、链接也过」，但那个类的实现根本没进二进制，")
    fail("   运行时报 unrecognized selector —— 而且编译期一声不响。")
else:
    ok("目录下 %d 个 .m 全部已登记" % len(onDisk))

head("A3：版本号必须三处一致（单一来源 = JBBCommon.h 的 JBB_VERSION）")
ver = None
mm = re.search(r'#define\s+JBB_VERSION\s+@"([^"]+)"', read("JBBCommon.h"))
if not mm:
    fail("❌ JBBCommon.h 里找不到 JBB_VERSION")
else:
    ver = mm.group(1)
    print("   JBB_VERSION = %s" % ver)
    for path, pat, label in [
        ("control", r"^Version:\s*(\S+)", "control"),
        ("Resources/Info.plist", r"<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>",
         "Info.plist CFBundleShortVersionString"),
        ("Resources/Info.plist", r"<key>CFBundleVersion</key>\s*<string>([^<]+)</string>",
         "Info.plist CFBundleVersion"),
    ]:
        m2 = re.search(pat, read(path), re.M)
        if not m2:
            fail("❌ %s 里找不到版本号" % label)
        elif m2.group(1) != ver:
            fail("❌ %s 版本(%s) ≠ JBB_VERSION(%s)" % (label, m2.group(1), ver))
        else:
            ok("%s = %s" % (label, m2.group(1)))
    # 启动横幅也必须是「用常量」的形式，界面上的版本才不可能写死写错
    if re.search(r"JBBackup %@ 启动", read("JBBAppDelegate.m")):
        ok("启动横幅使用 JBB_VERSION 单一来源")
    else:
        fail("❌ JBBAppDelegate.m 的启动横幅不是 'JBBackup %@ 启动' 形式")

head("A4：Info.plist 的 CFBundleExecutable 必须等于 APPLICATION_NAME")
appName = None
m3 = re.search(r"^APPLICATION_NAME\s*=\s*(\S+)", mk, re.M)
if not m3:
    fail("❌ Makefile 里找不到 APPLICATION_NAME")
else:
    appName = m3.group(1)
    exe = re.search(r"<key>CFBundleExecutable</key>\s*<string>([^<]+)</string>",
                    read("Resources/Info.plist"))
    if not exe:
        fail("❌ Info.plist 缺 CFBundleExecutable")
    elif exe.group(1) != appName:
        fail("❌ CFBundleExecutable=%s ≠ APPLICATION_NAME=%s（装上后点图标直接闪退）"
             % (exe.group(1), appName))
    else:
        ok("CFBundleExecutable = %s" % exe.group(1))

head("A5：⭐ entitlements 五件套必须有，三个「禁用项」必须没有")
ent = read("entitlements.plist")
# 没有这些，IPA 版本就只是个被沙盒锁死、连自己家目录之外都读不到的普通 App
REQUIRED_ENT = [
    "com.apple.private.security.no-sandbox",
    "com.apple.private.security.storage.AppDataContainers",
    "com.apple.security.exception.files.absolute-path.read-write",
    "platform-application",
    "com.apple.private.persona-mgmt",
]
# ⚠️ A12+ / iOS 15+ 起 PPL 硬禁：签了这些 entitlements 的进程一启动就被内核杀掉，
#    表现为「点了图标闪一下就没了」，而且不产生普通崩溃报告，极难查。
FORBIDDEN_ENT = [
    "com.apple.private.cs.debugger",
    "dynamic-codesigning",
    "com.apple.private.skip-library-validation",
]
bad = [k for k in REQUIRED_ENT if k not in ent]
if bad:
    fail("❌ entitlements.plist 缺少必需项：%s" % bad)
else:
    ok("五件套齐全")
# 注释里会提到禁用项名字（说明为什么不能用），所以先剥 XML 注释再判
ent_nc = re.sub(r"<!--.*?-->", "", ent, flags=re.S)
banned = [k for k in FORBIDDEN_ENT if k in ent_nc]
if banned:
    fail("❌ entitlements.plist 里出现了被 PPL 禁止的项（签了会启动即崩）：%s" % banned)
else:
    ok("无被禁 entitlements（三个高危项只在注释里说明）")

head("A6：plist 括号平衡 + 必需键（本工程的 plist 是新式 XML，不猜键名）")
for path, keys in [
    ("entitlements.plist", ["<dict>", "</dict>"]),
    ("Resources/Info.plist", ["CFBundleIdentifier", "CFBundleExecutable", "UILaunchScreen"]),
]:
    s = read(path)
    if not s.strip():
        fail("❌ %s 是空文件" % path)
        continue
    if "<?xml" not in s[:200]:
        fail("❌ %s 看起来不是 XML plist（缺 <?xml 头）" % path)
        continue
    body = re.sub(r"<!--.*?-->", "", s, flags=re.S)
    if body.count("<dict>") != body.count("</dict>"):
        fail("❌ %s 的 <dict> 不平衡：%d vs %d"
             % (path, body.count("<dict>"), body.count("</dict>")))
        continue
    miss = [k for k in keys if k not in s]
    if miss:
        fail("❌ %s 缺少 %s" % (path, miss))
    else:
        ok("%s 结构正常" % path)

# UILaunchScreen 缺失 = 兼容模式（大黑边），这是很容易忘但一眼看得见的问题
if "<key>UILaunchScreen</key>" in read("Resources/Info.plist"):
    ok("声明了 UILaunchScreen（不会进兼容模式的上下黑边）")
else:
    fail("❌ Info.plist 没有 UILaunchScreen → 在全面屏上会以兼容模式显示（上下黑边）")

head("A7：DEBIAN 维护脚本的 git 索引权限必须是 100755")
# Windows 上 git 不记录可执行位 → 克隆到 CI 是 644 → 编译全过、倒在最后打包：
#   ERROR: maintainer script 'postinst' has bad permissions 644
# ⚠️ 只在本机 chmod 不够，必须改 git 索引（git update-index --chmod=+x）。
try:
    out = subprocess.run(["git", "ls-files", "-s", "layout/DEBIAN"],
                         capture_output=True, text=True).stdout
    checked = 0
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[3].rsplit("/", 1)[-1] in (
                "postinst", "preinst", "postrm", "prerm"):
            checked += 1
            if parts[0] != "100755":
                fail("❌ git 索引里 %s 是 %s（应为 100755）" % (parts[3], parts[0]))
                fail("   修复：git update-index --chmod=+x %s" % parts[3])
            else:
                ok("git 索引 %s = 100755" % parts[3])
    if checked == 0:
        print("   （git 索引里没有维护脚本，跳过）")
except Exception as e:
    print("   （git 不可用，跳过：%s）" % e)

# ===========================================================================
# B. 编译期硬伤
# ===========================================================================
SRC_M = sorted(glob.glob("*.m"))
SRC_H = sorted(glob.glob("*.h"))

head("B1：括号平衡（剥掉字符串与注释后再数）")
bad = 0
for f in SRC_M + SRC_H:
    s = read(f)
    s2 = re.sub(r'"(?:\\.|[^"\\])*"', '""', s)
    s2 = strip_comments(s2)
    if s2.count("{") != s2.count("}"):
        fail("❌ %s 花括号不平衡：%d { vs %d }" % (f, s2.count("{"), s2.count("}")))
        bad = 1
    if s2.count("(") != s2.count(")"):
        fail("❌ %s 圆括号不平衡：%d ( vs %d )" % (f, s2.count("("), s2.count(")")))
        bad = 1
if not bad:
    ok("全部 %d 个源文件括号平衡" % (len(SRC_M) + len(SRC_H)))

head("B2：⭐ 调用的 JBB* 函数必须真实存在（防「名字打错」被当成隐式声明）")
# C99 下把 JBBJBRoot() 写成 JBBJbRoot() 只会给个 warning + 隐式声明 int，
# 配合 ARC 变成一串看不懂的 error，报在别人看着莫名其妙的行上。
hdr_all = "\n".join(read(f) for f in SRC_H)
declared = set(re.findall(r"\n\s*[\w\s\*<>]*?\b(\w+)\s*\([^;{]*\)\s*;", hdr_all))
declared |= set(re.findall(r"@property[^;]*?\b(\w+)\s*;", hdr_all))
bad = []
for path in SRC_M:
    src = strip_comments(read(path))
    defined = set(re.findall(r"\n\s*(?:static\s+)?[\w\s\*<>]*?\b(\w+)\s*\([^;{]*\)\s*\{", src))
    defined |= set(re.findall(r"@implementation\s+(\w+)", src))
    for name in sorted(set(re.findall(r"(?<![\w.>])(JBB[A-Z]\w*)\s*\(", src))):
        if name in defined or name in declared:
            continue
        bad.append((path, name))
if bad:
    fail("❌ 以下 JBB* 调用既没有定义也没有声明（名字打错？）：")
    for p, n in bad:
        fail("     %s → %s" % (p, n))
else:
    ok("所有 JBB* 调用都有定义或声明（头文件声明 %d 个）" % len(declared))

head("B3：⭐ JBBLog 是 NS_FORMAT_FUNCTION → 文案里的字面 % 必须写成 %%")
# 文案里写 "100% 完成" 会被当成转换符 → -Wformat 报错或读到栈上垃圾。
call = re.compile(r'JBBLog\s*\(\s*@"((?:[^"\\]|\\.)*)"')
conv = re.compile(r"%[-+ #0-9.*]*[lhqzjt]*[diouxXeEfgGaAcspn@]")
bad = []
for f in SRC_M:
    for i, line in enumerate(read(f).splitlines(), 1):
        m = call.search(line)
        if not m:
            continue
        s = m.group(1).replace("%%", "\x00")
        hit = False
        for mm2 in conv.finditer(s):
            nxt = s[mm2.end():mm2.end() + 2]
            if len(nxt) == 2 and all(c.isascii() and c.isalpha() for c in nxt):
                hit = True
                break
        if not hit and "%" in conv.sub("", s).replace("\x00", ""):
            hit = True
        if hit:
            bad.append((f, i, m.group(1)))
if bad:
    fail("❌ 以下 JBBLog 格式串的 %% 未正确转义：")
    for f, i, s in bad:
        fail("   %s:%d  %s" % (f, i, s))
else:
    ok("JBBLog 格式串检查通过")

head("B4：ARC 桥接（ObjC 指针当 C 指针用必须 __bridge）")
bad = []
for f in SRC_M:
    for i, line in enumerate(read(f).splitlines(), 1):
        if "__bridge" in line:
            continue
        s = line.strip()
        if s.startswith("//") or s.startswith("*") or s.startswith("/*"):
            continue
        for mm2 in re.finditer(r"\(\s*void\s*\*\s*\)\s*([A-Za-z_]\w*)", line):
            t = mm2.group(1)
            if t.startswith("&") or re.match(r"^(old|orig|imp)$", t, re.I):
                continue
            bad.append((f, i, t))
if bad:
    for f, i, t in bad:
        fail("❌ %s 第 %d 行 `(void *)%s` 需要 __bridge" % (f, i, t))
else:
    ok("ARC 桥接正确")

head("B5：⭐ 用到的 C 库符号必须有对应 #import（含本地头合并）")
# 本工程把 C 库头集中 import 在 JBBCommon.h，所以要「本文件 + 其 import 的本地头」合并判断。
C_SYMBOL_HEADERS = {
    "dlsym": "dlfcn.h", "dlopen": "dlfcn.h",
    "kill": "signal.h", "signal": "signal.h",
    "getpid": "unistd.h", "pipe": "unistd.h", "read": "unistd.h",
    "close": "unistd.h", "unlink": "unistd.h",
    "posix_spawn": "spawn.h", "waitpid": "sys/wait.h",
    "statfs": "sys/mount.h", "stat": "sys/stat.h",
    "uname": "sys/utsname.h", "localtime_r": "time.h", "strftime": "time.h",
    "malloc": "stdlib.h", "free": "stdlib.h", "atoi": "stdlib.h",
    "printf": "stdio.h", "strlen": "string.h", "memcpy": "string.h",
    "memset": "string.h", "dispatch_after": "dispatch/dispatch.h",
}
bad = 0
for path in SRC_M + SRC_H:
    raw = read(path)
    nc = strip_comments(raw)
    imports = set(re.findall(r'#import\s*[<"]([^>"]+)[>"]', nc))
    merged = nc
    for lh in re.findall(r'#import\s+"([^"]+)"', nc):
        for cand in [lh, os.path.join(os.path.dirname(path), lh)]:
            if os.path.exists(cand):
                lraw = read(cand)
                merged += "\n" + strip_comments(lraw)
                imports |= set(re.findall(r'#import\s*[<"]([^>"]+)[>"]', strip_comments(lraw)))
                break
    miss = []
    for sym, hdr in C_SYMBOL_HEADERS.items():
        if re.search(r"(?<![\w>])" + re.escape(sym) + r"\s*\(", merged):
            if not any(i.endswith(hdr) for i in imports):
                miss.append((sym, hdr))
    for sym, hdr in sorted(set(miss)):
        fail("❌ %s 用了 %s 但没 #import <%s>" % (path, sym, hdr))
        bad = 1
if not bad:
    ok("C 库符号的 import 检查通过")
    ok("（本次检查覆盖 B1~B5；下面是首轮 CI 新学到、本地补上的两类）")

head("B6：⭐ 自定义 property 访问器必须操作 ivar（防「setter 里调自己」无限递归）")
# 血泪（本工程首轮 CI）：
#     - (void)setBusy:(BOOL)busy { self.busy = busy; ... }
# 自定义 setter 里调用自己 = 无限递归爆栈。编译期只报一条
#   ivar '_busy' which backs the property is not referenced in this property's accessor
# 看起来像「有个没用的变量」，实际是运行时必崩；-Werror 下还会直接编译失败。
#
# ⚠️ 为什么本地预检第一版没拦住：B1 只数括号，`self.busy = busy` 括号完全平衡。
#    「平衡」不等于「语义正确」—— 这次补的是语义断言。
bad = 0
for path in SRC_M:
    src = strip_comments(read(path))
    props = set(re.findall(r"@property\s*\([^)]*\)\s*[\w\s\*<>]*?\b(\w+)\s*;", src))
    for name in sorted(props):
        cap = name[0].upper() + name[1:]
        # --- 自定义 setter：- (void)setXxx:(T)xxx { ... } ---
        # 用 ")setXxx:" 当锚点：这样只会命中「方法定义」，不会命中 [self setXxx:...] 这种调用点
        sb = find_method_body(src, ")set" + cap + ":")
        if sb is not None:
            if re.search(r"self\s*\.\s*" + re.escape(name) + r"\s*=", sb):
                fail("❌ %s 的 setter set%s: 里出现 `self.%s = ...` —— 自己调自己，无限递归爆栈"
                     % (path, cap, name))
                bad = 1
            elif ("_" + name) not in sb:
                fail("❌ %s 的 setter set%s: 里没有读写 ivar _%s"
                     % (path, cap, name))
                fail("   十有八九是写成了 self.%s = %s;（自递归）；否则 -Wunused-property-ivar 会报错"
                     % (name, name))
                bad = 1
        # --- 自定义 getter：- (T)xxx { ... } ---
        gm = re.search(r"-\s*\(\s*[\w\s\*<>]*?\b" + re.escape(name) + r"\s*\)\s*"
                       + re.escape(name) + r"\s*\{", src)
        if gm:
            gb = _brace_body_at(src, gm.end() - 1)
            if gb is not None and ("_" + name) not in gb:
                fail("❌ %s 的自定义 getter %s 里没有读 ivar _%s" % (path, name, name))
                bad = 1
if not bad:
    ok("自定义访问器都有对应对的 ivar（无自递归）")

head("B7：⭐ 空消息发送 `[[x y]]`（方括号手滑）")
# 血泪（本工程首轮 CI 的另一个错）：
#     (unsigned long)[[JBBManualPackageNames() count]]
#   ├─ 正确的应该是 [JBBManualPackageNames() count]
#   └─ 写成 [[...]] 后，最外层那对方括号里**只剩一个方括号组、没有选择器**
#      → clang 报 "expected identifier"，但报在行尾的 `]]` 上，很难一眼看出是哪错。
# ⚠️ B1 的括号计数对这个完全无效：`[[ ... ]]` 是平衡的。
# 判据：某对方括号的内容里，**第一个** `[` 的匹配 `]` 恰好落在内容的最后一个字符上
#       → 整段内容就是「单独一个方括号组」，外层没有任何选择器 → 空消息。
# ⚠️ 不能用 inner.startswith("[") and inner.endswith("]") 这种粗糙判据 ——
#    `[[a b] c:[d e]]` 也满足它，但那是完全合法的嵌套消息（血泪：本检查第一版就误报了）。
def find_empty_messages(path):
    text = strip_comments(read(path))
    text = re.sub(r'"(?:\\.|[^"\\])*"', '""', text)   # 先去字符串，避免中文里出现方括号
    stack, hits = [], []
    for idx, ch in enumerate(text):
        if ch == "[":
            if idx and text[idx - 1] == "@":
                continue                                  # @[ ... ] 数组字面量，不是消息发送
            stack.append(idx)
        elif ch == "]":
            if not stack:
                continue
            start = stack.pop()
            inner = text[start + 1:idx]
            stripped = inner.strip()
            if not stripped.startswith("["):
                continue                                  # 外层第一个 token 不是方括号组 → 正常
            # 找 inner 里第一个 "[" 的匹配 "]"，看它是不是刚好在结尾
            depth, match_end = 0, -1
            for k, c in enumerate(inner):
                if c == "[":
                    depth += 1
                elif c == "]":
                    depth -= 1
                    if depth == 0:
                        match_end = k
                        break
            if match_end >= 0 and inner[match_end:].strip() == "]":
                line = text.count("\n", 0, start) + 1
                hits.append((line, stripped))
    return hits


bad = []
for f in SRC_M:
    for line, inner in find_empty_messages(f):
        bad.append((f, line))
if bad:
    for f, line in bad:
        fail("❌ %s 第 %d 行出现空消息发送（多的那个方括号要删掉）：" % (f, line))
        fail("     看这一行的结构：形如 `(unsigned long)[[Foo() count]]`，"
             "正确写法是 `(unsigned long)[Foo() count]`")
else:
    ok("无空消息发送（%d 个源文件）" % len(SRC_M))

# ===========================================================================
# C. 数据安全（本项目最不能出错的部分）
# ===========================================================================
re_src = strip_comments(read("JBBRestoreEngine.m"))
be_src = strip_comments(read("JBBBackupEngine.m"))

head("C1：⭐ 还原必须先确认「已越狱」，否则一律不许写盘")
restore_body = find_method_body(re_src, "restoreConfigsFromBackupName:")
if restore_body is None:
    fail("❌ 找不到 restoreConfigsFromBackupName 函数体")
else:
    i_ready = restore_body.find("JBBJBReady()")
    i_first_write = min([x for x in [
        restore_body.find("JBBRCopyFile("), restore_body.find("JBBRCopyDir("),
        restore_body.find("JBBRSafetyKeep("),
    ] if x >= 0] or [-1])
    if i_ready < 0:
        fail("❌ 还原流程里没有 JBBJBReady() 检查 —— 未越狱时会往不存在的路径乱写")
    elif i_first_write >= 0 and i_ready > i_first_write:
        fail("❌ JBBJBReady() 排在第一次写盘之后 → 前置检查形同虚设")
    else:
        ok("越狱环境检查先于任何写盘动作")

head("C2：⭐ 覆盖前必须先做安全快照（另存现状），保证有退路")
if restore_body is None:
    fail("❌ 拿不到还原函数体，跳过")
else:
    i_safe = restore_body.find("JBBRSafetyKeep(")
    i_copy = restore_body.find("JBBRCopyFile(")
    n_safe = restore_body.count("JBBRSafetyKeep(")
    if i_safe < 0:
        fail("❌ 还原流程里没有调用 JBBRSafetyKeep() —— 会静默覆盖用户当前配置，没有退路")
    elif i_copy >= 0 and i_safe > i_copy:
        fail("❌ JBBRSafetyKeep() 排在 JBBRCopyFile() 之后 → 保下来的是覆盖后的内容，等于没保")
    elif n_safe < 3:
        fail("❌ JBBRSafetyKeep() 只调用 %d 次；全局 / 沙盒 / AppSupport 三处都必须保" % n_safe)
    else:
        ok("三处覆盖前都调用 JBBRSafetyKeep()，且先于写入")

head("C3：⭐ 安全快照目录必须建得出来，建不出就中止（不能「没退路还硬上」）")
if restore_body is None:
    fail("❌ 拿不到还原函数体，跳过")
else:
    m4 = re.search(r"JBBEnsureDir\(\s*safety\s*\)", restore_body)
    if not m4:
        fail("❌ 没有对安全快照目录做 JBBEnsureDir(safety) 校验")
    else:
        after = restore_body[m4.end():m4.end() + 600]
        if not re.search(r"return\s+res", after):
            fail("❌ 安全快照目录创建失败后没有立即 return —— 会在没有退路的情况下继续覆盖")
        else:
            ok("安全快照目录创建失败即中止还原")

head("C4：⭐ 安全快照目录名必须以 _ 开头（否则会被当成一个「备份」列出来）")
if "_restore-safety-" in re_src:
    ok("快照目录名含 _restore-safety-")
else:
    fail("❌ 找不到 _restore-safety- 前缀")
if re.search(r'hasPrefix:\s*@"_"', be_src):
    ok("listBackupNames 会排除 _ 前缀目录")
else:
    fail("❌ listBackupNames 没有排除 _ 前缀 → _restore-safety-* 会混进备份列表，"
         "用户可能对「一份快照」点还原")

head("C5：⭐ App 沙盒配置必须按 bundle id 重新定位容器（不能照抄旧 UUID 路径）")
if "JBBContainerBundleID(" in re_src:
    ok("用 JBBContainerBundleID 重新定位容器")
else:
    fail("❌ 还原时没有按 bundle id 定位容器 —— 重装 App 后容器 UUID 会变，"
         "照备份里的旧路径粘回去等于扔进垃圾桶，且用户看不出任何报错")
# 反向断言：不能出现「用 _map.tsv 里记录的容器路径直接写」的写法
if re.search(r"byBundleID\[", re_src):
    ok("先建 bundleId→容器 索引，再按备份里的 bundleId 查")
else:
    fail("❌ 没有看到按 bundleId 查当前容器的索引")

head("C6：⭐ 危险删除与 shell 逃逸")
bad = 0
for f in SRC_M:
    s = strip_comments(read(f))
    if re.search(r"removeItemAtPath\s*:\s*@\"/", s):
        fail("❌ %s 直接删除了根目录下的固定路径" % f)
        bad = 1
    if re.search(r"\b(system|popen|execl|execlp|execvp|fork)\s*\(", s):
        fail("❌ %s 出现 shell/进程逃逸调用（sandbox 下不可控）" % f)
        bad = 1
    if "rm -rf" in s:
        fail("❌ %s 出现 rm -rf" % f)
        bad = 1
if not bad:
    ok("无根路径删除 / 无 shell 逃逸 / 无 rm -rf")

head("C7：⭐ 进度回调必须切回主线程（否则界面偶发不刷新，且难复现）")
for f in ["JBBBackupEngine.m", "JBBRestoreEngine.m"]:
    s = strip_comments(read(f))
    if "dispatch_async(dispatch_get_main_queue()" in s:
        ok("%s 的进度回调切主线程" % f)
    else:
        fail("❌ %s 没有把进度回调切到主线程" % f)
for f in ["JBBBackupEngine.m", "JBBRestoreEngine.m"]:
    s = strip_comments(read(f))
    if "JBBRReport(progress" in s or "JBBReport(progress" in s:
        continue
    fail("❌ %s 里没有进度上报调用" % f)

head("C8：⭐ 日志必须封顶（不能无限追加，否则回传时读都读不动）")
cm = strip_comments(read("JBBCommon.m"))
if "512ULL * 1024ULL" in cm or "512 * 1024" in cm:
    ok("日志文件有体积上限")
else:
    fail("❌ JBBCommon.m 里没有日志体积上限 —— 追加式日志长到几百 MB 后用户无法回传")
if re.search(r"NSLock|@synchronized|os_unfair_lock|dispatch_semaphore", cm):
    ok("日志缓冲有并发保护（备份线程写 / 主线程读）")
else:
    fail("❌ 日志缓冲没有加锁 —— 后台备份写、主线程读，会随机崩溃")

head("C9：⭐ 输出目录必须与「不会写死盘符/用户名」的常量一致")
for name in ["JBBOutputRoot", "JBBMobileDocumentsDir", "JBBIcloudRoot"]:
    if re.search(r"NSString\s*\*\s*" + name + r"\s*\(void\)", cm):
        ok("%s 有集中定义" % name)
    else:
        fail("❌ JBBCommon.m 里找不到 %s 的定义" % name)

# ===========================================================================
print()
if FAIL:
    print("🛑 本地预检未通过，修完再推 CI")
    sys.exit(1)
print("🎉 本地预检全部通过，可以推 CI 了")
