#!/usr/bin/env python3
"""从母版抽出闭合轮廓，写入 Flutter 侧的可填充 Path 数据。

母版 tool/assets/runner-master.png 平涂出身体、独立的头与两条速度线。
这里按颜色分出两组，各自用 marching squares 抽轮廓、RDP 抽稀、
Chaikin 圆滑，换算到 48 网格坐标。App 内图标与 launcher 图标同源。

输出：lib/widgets/runner_mark.dart
运行：python3 tool/make_mark.py
"""

import math
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASTER = os.path.join(ROOT, "tool", "assets", "runner-master.png")

INK = (253, 253, 252)
DASH = (144, 191, 231)
GRID = 48.0
FILL = 0.90
EPS = 1.2


def masks():
    a = np.asarray(Image.open(MASTER).convert("RGB")).astype(int)
    ink = np.abs(a - np.array(INK)).sum(2) < 30
    dash = np.abs(a - np.array(DASH)).sum(2) < 40
    return ink, dash


def marching_squares(binary):
    """返回若干闭合多边形（像素坐标）。线段按无向边收集，再逐条走成闭环。"""
    h, w = binary.shape
    adj = {}

    def link(a, b):
        adj.setdefault(a, []).append(b)
        adj.setdefault(b, []).append(a)

    for y in range(h - 1):
        row = binary[y]
        nxt = binary[y + 1]
        for x in range(w - 1):
            idx = ((1 if row[x] else 0) | (2 if row[x + 1] else 0) |
                   (4 if nxt[x + 1] else 0) | (8 if nxt[x] else 0))
            if idx in (0, 15):
                continue
            top = (x + 0.5, float(y))
            right = (float(x + 1), y + 0.5)
            bottom = (x + 0.5, float(y + 1))
            left = (float(x), y + 0.5)
            table = {
                1: [(left, top)],
                2: [(top, right)],
                3: [(left, right)],
                4: [(right, bottom)],
                5: [(left, bottom), (top, right)],
                6: [(top, bottom)],
                7: [(left, bottom)],
                8: [(bottom, left)],
                9: [(bottom, top)],
                10: [(top, left), (bottom, right)],
                11: [(bottom, right)],
                12: [(right, left)],
                13: [(right, top)],
                14: [(top, left)],
            }[idx]
            for a, b in table:
                link(a, b)

    loops = []
    while adj:
        start = next(iter(adj))
        loop = [start]
        cur = start
        guard = 0
        while True:
            guard += 1
            if guard > 200000:
                break
            outs = adj.get(cur)
            if not outs:
                break
            nxt = outs.pop()
            if not outs:
                del adj[cur]
            peer = adj.get(nxt)
            if peer and cur in peer:
                peer.remove(cur)
                if not peer:
                    del adj[nxt]
            loop.append(nxt)
            cur = nxt
            if cur == start:
                break
        if len(loop) > 40:
            loops.append(loop)
    return loops


def rdp(points, eps):
    if len(points) < 3:
        return points
    start, end = points[0], points[-1]
    dx, dy = end[0] - start[0], end[1] - start[1]
    norm = math.hypot(dx, dy)
    best_i, best_d = 0, -1.0
    for i in range(1, len(points) - 1):
        px, py = points[i]
        if norm == 0:
            d = math.hypot(px - start[0], py - start[1])
        else:
            d = abs(dy * px - dx * py + end[0] * start[1] -
                    end[1] * start[0]) / norm
        if d > best_d:
            best_i, best_d = i, d
    if best_d <= eps:
        return [start, end]
    left = rdp(points[:best_i + 1, :], eps)
    right = rdp(points[best_i:, :], eps)
    return np.vstack([left[:-1], right])


def chaikin(points, iterations=2):
    pts = points
    for _ in range(iterations):
        out = []
        n = len(pts)
        for i in range(n):
            p, q = pts[i], pts[(i + 1) % n]
            out.append((0.75 * p[0] + 0.25 * q[0], 0.75 * p[1] + 0.25 * q[1]))
            out.append((0.25 * p[0] + 0.75 * q[0], 0.25 * p[1] + 0.75 * q[1]))
        pts = out
    return pts


def to_grid(loops, scale, cx, cy):
    out = []
    for loop in loops:
        if np.allclose(loop[0], loop[-1]):
            loop = loop[:-1]
        simp = rdp(loop, EPS)
        smooth = chaikin([tuple(p) for p in simp], 2)
        out.append([(GRID / 2 + (x - cx) * scale, GRID / 2 + (y - cy) * scale)
                    for x, y in smooth])
    return out


def emit(name, doc, loops, lines):
    lines.append(doc)
    lines.append(f"const List<List<double>> {name} = <List<double>>[")
    for loop in loops:
        flat = []
        for x, y in loop:
            flat.append(f"{x:.3f}")
            flat.append(f"{y:.3f}")
        lines.append("  <double>[" + ", ".join(flat) + "],")
    lines.append("];")
    lines.append("")


def main():
    ink, dash = masks()
    body = marching_squares(ink)
    speed = marching_squares(dash)

    xs, ys = [], []
    for loop in body + speed:
        xs += [p[0] for p in loop]
        ys += [p[1] for p in loop]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    scale = GRID * FILL / max(x1 - x0, y1 - y0)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2

    body.sort(key=lambda l: -len(l))
    speed.sort(key=lambda l: -len(l))

    body_grid = to_grid([np.array(l, dtype=float) for l in body], scale, cx, cy)
    speed_grid = to_grid([np.array(l, dtype=float) for l in speed], scale, cx, cy)

    lines = [
        "// 由 tool/make_mark.py 从 tool/assets/runner-master.png 生成，请勿手改。",
        "// 坐标为 48 网格，闭合轮廓用偶数填充。",
        "",
    ]
    emit("runnerContours",
         "/// 身体与头部：每段都是一条闭合曲线，末端与拐角全为圆头。",
         body_grid, lines)
    emit("runnerDashes", "/// 两道速度线，同样为闭合轮廓。", speed_grid, lines)

    path = os.path.join(ROOT, "lib", "widgets", "runner_mark.dart")
    with open(path, "w") as f:
        f.write("\n".join(lines))
    n = sum(len(l) for l in body_grid) + sum(len(l) for l in speed_grid)
    print("body", [len(l) for l in body_grid],
          "dash", [len(l) for l in speed_grid], "points", n)
    print("wrote", os.path.relpath(path, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
