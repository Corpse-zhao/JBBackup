#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
JBBackup 图标生成 —— 纯 Python 光栅化 + 手写 PNG 编码，不依赖 PIL / 不消耗生成额度。

输出（Theos 会把 Resources/ 整个拷进 .app）：
    Resources/AppIcon60x60@2x.png   120x120
    Resources/AppIcon60x60@3x.png   180x180

图形：圆角方底（蓝渐变）+ 白色「下载/归档托盘 + 向下箭头」。
用 4x 超采样再盒式降采样做抗锯齿（180 → 内部 720 渲染）。
"""
import os
import struct
import zlib

SS = 4                      # 超采样倍数
OUT = [
    ("Resources/AppIcon60x60@2x.png", 120),
    ("Resources/AppIcon60x60@3x.png", 180),
]


def lerp(a, b, t):
    return a + (b - a) * t


def rounded_rect_dist(x, y, x0, y0, x1, y1, r):
    """圆角矩形的有符号距离（<0 在内部）"""
    cx = (x0 + x1) / 2.0
    cy = (y0 + y1) / 2.0
    hx = (x1 - x0) / 2.0 - r
    hy = (y1 - y0) / 2.0 - r
    qx = abs(x - cx) - hx
    qy = abs(y - cy) - hy
    ox, oy = max(qx, 0.0), max(qy, 0.0)
    return (ox * ox + oy * oy) ** 0.5 + min(max(qx, qy), 0.0) - r


def in_triangle(px, py, a, b, c):
    def sign(p1, p2, p3):
        return (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1])
    d1 = sign((px, py), a, b)
    d2 = sign((px, py), b, c)
    d3 = sign((px, py), c, a)
    neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (neg and pos)


def render(size):
    """返回 (w, h, RGBA bytes)，坐标为 [0,1] 归一化"""
    n = size * SS
    px = bytearray(n * n * 4)
    f = 1.0 / n

    for j in range(n):
        y = (j + 0.5) * f
        for i in range(n):
            x = (i + 0.5) * f

            # ---- 底：圆角方形 + 对角渐变 ----
            d = rounded_rect_dist(x, y, 0.035, 0.035, 0.965, 0.965, 0.215)
            if d > 0:
                continue
            t = max(0.0, min(1.0, (x + y) / 2.0))
            r = int(lerp(38, 106, t))
            g = int(lerp(99, 166, t))
            b = int(lerp(235, 255, t))
            a = 255
            if d > -f * 1.6:                     # 边缘 1px 软过渡
                a = int(255 * (1.0 - (d + f * 1.6) / (f * 1.6)))

            # ---- 白色图形（托盘 + 向下箭头）----
            white = False
            # 托盘：圆角矩形描边，并把顶边切掉 → 得到一个 U 形
            tray = rounded_rect_dist(x, y, 0.255, 0.505, 0.745, 0.775, 0.075)
            if abs(tray) <= 0.052 and y > 0.545:
                white = True
            # 托盘顶部的两个小提耳
            if 0.236 <= y <= 0.545:
                if abs(x - 0.255) <= 0.052 or abs(x - 0.745) <= 0.052:
                    if 0.505 <= y <= 0.60:
                        white = True
            # 箭杆
            if 0.463 <= x <= 0.537 and 0.215 <= y <= 0.525:
                white = True
            # 箭头（向下三角）
            if in_triangle(x, y, (0.5, 0.615), (0.335, 0.425), (0.665, 0.425)):
                white = True

            if white:
                # 白色叠在蓝底上：按覆盖率混合
                cov = 1.0
                r = int(r + (255 - r) * cov)
                g = int(g + (255 - g) * cov)
                b = int(b + (255 - b) * cov)

            o = (j * n + i) * 4
            px[o] = r
            px[o + 1] = g
            px[o + 2] = b
            px[o + 3] = a

    # ---- 盒式降采样 SSxSS ----
    out = bytearray(size * size * 4)
    area = SS * SS
    for j in range(size):
        for i in range(size):
            sr = sg = sb = sa = 0
            for dj in range(SS):
                base = ((j * SS + dj) * n + i * SS) * 4
                for di in range(SS):
                    o = base + di * 4
                    sa += px[o + 3]
                    # 按 alpha 做预乘平均，避免透明边缘发黑
                    sr += px[o] * px[o + 3]
                    sg += px[o + 1] * px[o + 3]
                    sb += px[o + 2] * px[o + 3]
            o = (j * size + i) * 4
            a = sa // area
            if sa:
                out[o] = sr // sa
                out[o + 1] = sg // sa
                out[o + 2] = sb // sa
            out[o + 3] = a
    return size, size, bytes(out)


def write_png(path, w, h, rgba):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)                               # filter type 0
        raw += rgba[y * stride:(y + 1) * stride]

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(png)
    return len(png)


if __name__ == "__main__":
    # 脚本在 tools/ 下，但要写到工程根的 Resources/（那才是 Theos 的默认资源目录）
    os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for path, size in OUT:
        w, h, rgba = render(size)
        n = write_png(path, w, h, rgba)
        print("%-38s %dx%d  %d 字节" % (path, w, h, n))
    print("✅ 图标已生成")
