#!/usr/bin/env python3
"""
VIGBT search-pattern study (SPEC §12.7).

Takes real prediction errors from the Monte Carlo pipeline (shipped configuration: wind entered,
self-correcting compass, roll learning) and simulates a golfer searching for the ball with the Phase 4
ground scanner. Compares search strategies by how far the golfer walks before the ball comes into view.

Frame: metres relative to the predicted rest point; x along the predicted flight line (+ = further from
the tee), y across it. The golfer always approaches from the tee, i.e. from negative x.

    python3 tools/search_sim.py --shots 100000 --detect 6
"""
import argparse
import contextlib
import importlib.util
import io
import math
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
EXT = 1.0
YD = 0.9144


def load_errors(args):
    spec = importlib.util.spec_from_file_location("mc", os.path.join(HERE, "monte_carlo.py"))
    mc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mc)
    captured = {}
    mc.report = lambda D, a: captured.update(D)
    ns = argparse.Namespace(
        shots=args.shots, chunk=min(args.shots, 50_000), seed=args.seed, fit="reprojection", weighted=1, roll=1,
        min_radius_px=1.0, dropout=0.05, centroid_sigma=0.35, radius_sigma=0.2, heading_sigma=3.0, anchor=1,
        placement_yaw=0.0, ideal=0, fit_spin=1, rpm_prior=700, oracle_spin=0, oracle_tilt=0, oracle_wind=0,
        oracle_ground=0, wind_input=1, heading_mode="session", session_size=8, session_shrinkage=1.0,
        ground_model="round", round_size=30, ground_learning=1, roll_prior=2.0, surface_model="fairway", map_surface=1, along=0.22, lateral=0.14,
        tight_along=0.20, tight_lateral=0.10, tight_low_lateral=0.08, low_launch_deg=8.0, low_along=0.45,
        low_lateral=0.12)
    with contextlib.redirect_stdout(io.StringIO()):
        mc.run(ns)
    D = captured
    ok = D["ok"]
    c = D["carry"][ok]
    low = D["launch"][ok] < 8
    tight = D["tight"][ok]
    rp = np.maximum(1, D["restpred"][ok])
    A = np.where(low, 0.45 * rp, np.where(tight, 0.20, 0.22) * c)
    L = np.where(low, np.where(tight, 0.08, 0.12) * rp, np.where(tight, 0.10, 0.14) * c)
    return D["along"][ok], D["lateral"][ok], np.maximum(5, A), np.maximum(5, L)


def polyline(points, step=0.5):
    """Densify a polyline; returns (N,2) points and cumulative walked distance."""
    pts = [np.asarray(points[0], float)]
    for p in points[1:]:
        a, b = pts[-1], np.asarray(p, float)
        n = max(1, int(np.linalg.norm(b - a) / step))
        for k in range(1, n + 1):
            pts.append(a + (b - a) * k / n)
    P = np.array(pts)
    d = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))])
    return P, d


def spiral(center, start_r, spacing, max_r):
    """Archimedean spiral (r grows by `spacing` per turn) from start_r to max_r."""
    pts = []
    th = 0.0
    r = start_r
    while r <= max_r:
        pts.append((center[0] + r * math.cos(th), center[1] + r * math.sin(th)))
        dth = 0.5 / max(r, 0.5)
        th += dth
        r = start_r + spacing * th / (2 * math.pi)
    return pts


def path_for(strategy, A, L, w, budget):
    """Waypoints for one shot. A, L: search semi-axes (m); w: effective sweep half-width (m)."""
    approach = -max(A, 9.0) - 1.0  # where measurement starts: just before the zone, on the approach line
    if strategy == "centre-spiral":
        # v0.10 behaviour: walk to the centre with the scanner off until 9 m out, then spiral outward.
        return [(approach, 0), (0, 0)] + spiral((0, 0), 0.5, 2 * w, budget / 3), approach_scan_start(9.0)
    if strategy == "axis-lanes":
        # Scan from the zone's near end along the long axis to the far end, then sweep lanes 2w apart,
        # alternating sides, across the ellipse width; then widen.
        E = A * EXT  # walk the axis past the ellipse ends: along-line errors have long tails
        pts = [(min(approach, -E - 1), 0), (-E, 0), (E, 0)]
        k, side, x_end = 1, 1, E
        while k * 2 * w <= 2.5 * L and len(pts) < 200:
            y = side * k * 2 * w
            pts += [(x_end, y), (-x_end, y)]
            x_end = -x_end
            if side < 0:
                k += 1
            side = -side
        return pts, None
    if strategy == "axis-lanes-widen":
        # As axis-lanes, then widen: lanes continue outward past 1.25 × the half-width (up to 2.5 ×),
        # each running 1.5 × the ellipse half-length (SearchGuide's second pass, SPEC §12.9).
        pts, _ = path_for("axis-lanes", A, L, w, budget)
        covered = max(abs(p[1]) for p in pts)
        E2 = 1.5 * A
        pts.append((pts[-1][0], pts[-1][1]))
        k = int(covered // (2 * w)) + 1
        side, x_end = 1, (E2 if pts[-1][0] < 0 else -E2)
        while k * 2 * w <= 2.5 * L and len(pts) < 400:
            y = side * k * 2 * w
            pts += [(-x_end, y), (x_end, y)]
            if side < 0:
                k += 1
            side = -side
        return pts, None
    if strategy == "axis-lanes-ellipse":
        # As axis-lanes, but each lane runs only the ellipse's chord at its offset (scaled to 1.3 L), so the
        # walk skips the low-probability corners of the bounding rectangle (SPEC §12.9).
        pts = [(approach, 0), (-A, 0), (A, 0)]
        k, side = 1, 1
        x_sign = 1
        while k * 2 * w <= 1.6 * L and len(pts) < 200:
            y = side * k * 2 * w
            half = A * math.sqrt(max(0.12, 1 - (y / (1.3 * L)) ** 2))
            pts += [(x_sign * half, y), (-x_sign * half, y)]
            x_sign = -x_sign
            if side < 0:
                k += 1
            side = -side
        return pts, None
    if strategy == "ellipse-spiral":
        # Axis walk, then a spiral stretched to the ellipse's shape (y spacing 2w).
        pts = [(approach, 0), (-A, 0), (A, 0), (0, 0)]
        ratio = A / max(L, 1e-6)
        for x, y in spiral((0, 0), 2 * w, 2 * w, budget / 2):
            pts.append((x * ratio, y))
        return pts, None
    if strategy == "axis-spiral":
        pts = [(approach, 0), (-A, 0), (A, 0), (0, 0)] + spiral((0, 0), 2 * w, 2 * w, budget / 3)
        return pts, None
    raise ValueError(strategy)


def approach_scan_start(dist_before_centre):
    return dist_before_centre


def search(along, lateral, A, L, strategy, detect, budget):
    w = 0.7 * detect  # effective half-width a golfer sweeping the phone covers reliably
    walked = np.full(len(along), np.inf)
    cache = {}
    for i in range(len(along)):
        key = (round(A[i]), round(L[i]))
        if key not in cache:
            wp, scan_from = path_for(strategy, A[i], L[i], w, budget)
            P, d = polyline(wp)
            active = np.ones(len(P), bool)
            if scan_from is not None:
                # Scanner is off on the approach until the golfer is within `scan_from` metres of the centre.
                first_leg = abs(wp[0][0] - wp[1][0])
                active = ~((d <= first_leg + 1e-6) & (P[:, 0] < -scan_from))
            cache[key] = (P, d, active)
        P, d, active = cache[key]
        ball = np.array([along[i], lateral[i]])
        dist = np.linalg.norm(P - ball, axis=1)
        hit = np.nonzero((dist <= detect if strategy != "never" else False) & active & (d <= budget))[0]
        if len(hit):
            walked[i] = d[hit[0]]
    return walked


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", type=int, default=50_000)
    ap.add_argument("--seed", type=int, default=31)
    ap.add_argument("--detect", type=float, default=6.0, help="ground scanner detection range, m (pink ≈ 6–8, white ≈ 4–5)")
    ap.add_argument("--ext", type=float, default=1.0, help="axis-lanes: walk the axis to ±ext × the ellipse half-length")
    ap.add_argument("--budget", type=float, default=250.0, help="give up after walking this far in the zone, m")
    args = ap.parse_args()
    global EXT
    EXT = args.ext
    along, lateral, A, L = load_errors(args)
    print(f"VIGBT search-pattern study: {len(along):,} tracked shots, detection range {args.detect} m, "
          f"budget {args.budget:.0f} m of searching")
    print(f"{'strategy':<15}{'found':>8}{'median walk':>13}{'p80':>8}{'p90':>8}{'mean':>8}   (metres after reaching the zone)")
    res = {}
    for s in ("centre-spiral", "axis-lanes", "axis-spiral", "axis-lanes-widen", "axis-lanes-ellipse", "ellipse-spiral"):
        wlk = search(along, lateral, A, L, s, args.detect, args.budget)
        f = np.isfinite(wlk)
        res[s] = wlk
        def q(p):
            v = np.percentile(np.where(f, wlk, np.inf), p)
            return f"{v:.0f}" if np.isfinite(v) else f">{args.budget:.0f}"
        print(f"{s:<15}{f.mean() * 100:7.1f}%{q(50):>12}{q(80):>8}{q(90):>8}{wlk[f].mean():8.0f}")
    a, b = res["centre-spiral"], res["axis-lanes"]
    both = np.isfinite(a) & np.isfinite(b)
    print(f"Axis-lanes walks less than centre-spiral on {np.mean(b[both] < a[both]) * 100:.0f}% of shots found by both; "
          f"short balls (found before the centre): {np.mean(along < 0) * 100:.0f}% of all shots")


if __name__ == "__main__":
    main()
