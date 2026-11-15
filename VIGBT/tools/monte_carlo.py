#!/usr/bin/env python3
"""
VIGBT Monte Carlo validation harness (SPEC §12).

Simulates N shots end to end:
  strike (club x strike type) -> true 3D flight (drag, Magnus, spin axis, unknown wind) -> bounce & roll
  -> 120 fps down-the-line camera observation until the camera loses the ball (leaves frame / too small)
  -> VIGBT pipeline (back-projection with *erroneous* calibration, weighted fit, club spin table,
     ballistics, roll prediction, compass heading)
  -> error between predicted and TRUE REST position, and search-zone coverage.

Mirrors VIGBTCore: AerodynamicModel coefficients, LaunchVectorExtractor geometry, ShotSimulator camera
placement, SpinEstimator club table. Usage:

    python3 tools/monte_carlo.py --shots 1000000 --seed 1

Requires numpy.
"""
import argparse
import math
import time

import numpy as np

# ---------------------------------------------------------------- physics (AerodynamicModel)
M, R = 0.04593, 0.021335
A = math.pi * R * R
G = 9.80665
CD0, CDS, CL0, CLS, CLMAX, TAU = 0.18, 0.30, 0.08, 0.60, 0.25, 25.0
YD = 0.9144
MPH = 0.44704


def accel(v, t, axis, omega0, wind, rho):
    vr = v - wind
    sp = np.linalg.norm(vr, axis=1, keepdims=True)
    sp = np.maximum(sp, 1e-6)
    om = omega0[:, None] * np.exp(-t[:, None] / TAU)
    S = R * om / sp
    cd = CD0 + CDS * S
    cl = np.minimum(CLMAX, CL0 + CLS * S)
    k = 0.5 * rho[:, None] * A * sp / M
    lift = np.cross(axis, vr)
    a = -k * cd * vr + k * cl * lift
    a[:, 2] -= G
    return a


def spin_axis(v0, tilt_deg):
    h = v0.copy()
    h[:, 2] = 0
    h /= np.maximum(np.linalg.norm(h, axis=1, keepdims=True), 1e-9)
    back = np.cross(h, np.array([0.0, 0.0, 1.0]))
    t = np.radians(tilt_deg)[:, None]
    ax = back * np.cos(t) - np.array([0.0, 0.0, 1.0]) * np.sin(t)
    return ax / np.linalg.norm(ax, axis=1, keepdims=True)


def fly(v0, rpm, tilt, wind, rho, dt=0.02, tmax=15.0):
    """RK4 to first ground crossing. Returns landing position (N,3), landing velocity (N,3)."""
    n = len(v0)
    p = np.zeros((n, 3))
    v = v0.copy()
    axis = spin_axis(v0, tilt)
    om = rpm * 2 * math.pi / 60
    t = np.zeros(n)
    land_p = np.zeros((n, 3))
    land_v = np.zeros((n, 3))
    active = np.arange(n)
    while len(active) and t[active[0]] < tmax:
        a_ = active
        pp, vv, tt = p[a_], v[a_], t[a_]
        ax, o, w, r = axis[a_], om[a_], wind[a_], rho[a_]
        k1v = accel(vv, tt, ax, o, w, r); k1p = vv
        k2v = accel(vv + k1v * dt / 2, tt + dt / 2, ax, o, w, r); k2p = vv + k1v * dt / 2
        k3v = accel(vv + k2v * dt / 2, tt + dt / 2, ax, o, w, r); k3p = vv + k2v * dt / 2
        k4v = accel(vv + k3v * dt, tt + dt, ax, o, w, r); k4p = vv + k3v * dt
        np_ = pp + (k1p + 2 * k2p + 2 * k3p + k4p) * dt / 6
        nv = vv + (k1v + 2 * k2v + 2 * k3v + k4v) * dt / 6
        landed = np_[:, 2] < 0
        if landed.any():
            dz = pp[landed, 2] - np_[landed, 2]
            f = np.clip(pp[landed, 2] / np.maximum(dz, 1e-12), 0, 1)
            land_p[a_[landed]] = pp[landed] + (np_[landed] - pp[landed]) * f[:, None]
            land_v[a_[landed]] = vv[landed] + (nv[landed] - vv[landed]) * f[:, None]
        p[a_], v[a_], t[a_] = np_, nv, tt + dt
        active = a_[~landed]
    if len(active):  # never landed (should not happen); keep last state
        land_p[active], land_v[active] = p[active], v[active]
    land_p[:, 2] = 0
    return land_p, land_v


def bounce_roll(land_p, land_v, e, mu_b, mu_r):
    """Simplified bounce-and-roll (Penner-style impulse bounces, then rolling friction)."""
    vh = np.linalg.norm(land_v[:, :2], axis=1)
    d = land_v[:, :2] / np.maximum(vh, 1e-9)[:, None]
    vz = np.abs(land_v[:, 2])
    travel = np.zeros(len(vh))
    for _ in range(8):
        vh = np.maximum(0, vh - mu_b * (1 + e) * vz)
        vz = e * vz
        travel += vh * 2 * vz / G
        if (vz < 0.5).all():
            break
    travel += vh ** 2 / (2 * mu_r * G)
    rest = land_p.copy()
    rest[:, :2] += d * travel[:, None]
    return rest


# ---------------------------------------------------------------- strikes
CLUBS = {  # name: (prob, speed mph, launch deg, spin rpm, predicted spin rpm from SpinEstimator club table)
    "driver": (0.35, (125, 155), (10, 15), (2500, 3500), 2700),
    "7-iron": (0.40, (95, 120), (15, 20), (5500, 7500), 6700),
    "wedge": (0.25, (75, 100), (22, 28), (7500, 9500), 8500),
}
STRIKES = ["pure", "slice", "hook", "push", "pull", "thin/skull", "fat", "toe/heel", "topped", "shank", "pop-up"]
STRIKE_P = [0.40, 0.15, 0.08, 0.06, 0.06, 0.08, 0.06, 0.06, 0.03, 0.01, 0.01]


def make_shots(n, rng):
    clubs = list(CLUBS)
    ci = rng.choice(len(clubs), n, p=[CLUBS[c][0] for c in clubs])
    si = rng.choice(len(STRIKES), n, p=STRIKE_P)
    speed = np.empty(n); launch = np.empty(n); spin = np.empty(n); pred_spin = np.empty(n)
    for k, c in enumerate(clubs):
        m = ci == k
        _, sp, la, rp, ps = CLUBS[c]
        speed[m] = rng.uniform(*sp, m.sum()) * MPH
        launch[m] = rng.uniform(*la, m.sum())
        spin[m] = rng.uniform(*rp, m.sum())
        pred_spin[m] = ps
    tilt = rng.normal(0, 5, n)
    az = rng.normal(0, 2, n)
    U = lambda a, b, mask: rng.uniform(a, b, mask.sum())
    S = {s: si == i for i, s in enumerate(STRIKES)}
    m = S["slice"]; tilt[m] += U(15, 35, m); az[m] += U(0, 4, m); spin[m] *= 1.1
    m = S["hook"]; tilt[m] -= U(15, 35, m); az[m] -= U(0, 4, m)
    m = S["push"]; az[m] += U(4, 10, m)
    m = S["pull"]; az[m] -= U(4, 10, m)
    m = S["thin/skull"]; launch[m] *= U(0.4, 0.7, m); spin[m] *= U(0.4, 0.65, m); speed[m] *= U(0.93, 1.0, m)
    m = S["fat"]; speed[m] *= U(0.5, 0.75, m); launch[m] += U(0, 3, m); spin[m] *= U(0.7, 0.9, m)
    m = S["toe/heel"]; speed[m] *= U(0.88, 0.95, m); tilt[m] += rng.choice([-1, 1], m.sum()) * U(8, 20, m)
    m = S["topped"]; launch[m] = U(-3, 3, m); speed[m] *= U(0.4, 0.7, m); spin[m] = U(500, 1500, m)
    m = S["shank"]; az[m] += U(35, 60, m); speed[m] *= U(0.5, 0.7, m)
    m = S["pop-up"]; launch[m] = U(30, 45, m); speed[m] *= U(0.6, 0.8, m); spin[m] *= 1.6
    return ci, si, speed, launch, az, spin, tilt, pred_spin


def velocity(speed, launch, az):
    th, ph = np.radians(launch), np.radians(az)
    return np.stack([speed * np.cos(th) * np.cos(ph), -speed * np.cos(th) * np.sin(ph), speed * np.sin(th)], axis=1)


# ---------------------------------------------------------------- camera (ShotSimulator / LaunchVectorExtractor)
W_PX, H_PX = 1920.0, 1080.0
F_PX = (W_PX / 2) / math.tan(math.radians(108) / 2)
FPS = 120.0
KMAX = 40


def to_camera(world, pitch, roll):
    """World (fwd, left, up) relative to camera -> camera (x right, y down, z fwd). Inverse of level()."""
    lx, ly, lz = -world[..., 1], -world[..., 2], world[..., 0]
    p, r = pitch[:, None], roll[:, None]
    y1 = ly * np.cos(p) + lz * np.sin(p)
    z1 = -ly * np.sin(p) + lz * np.cos(p)
    x0 = lx * np.cos(r) + y1 * np.sin(r)
    y0 = -lx * np.sin(r) + y1 * np.cos(r)
    return x0, y0, z1


def level(cx, cy, cz, pitch, roll):
    p, r = pitch[:, None], roll[:, None]
    x1 = cx * np.cos(r) - cy * np.sin(r)
    y1 = cx * np.sin(r) + cy * np.cos(r)
    y2 = y1 * np.cos(p) - cz * np.sin(p)
    z2 = y1 * np.sin(p) + cz * np.cos(p)
    return x1, y2, z2  # right, down, forward


def early_track(v0, rpm, tilt, wind, rho):
    """Positions relative to the tee at frames 1..KMAX (RK4 at the frame interval)."""
    n = len(v0)
    p = np.zeros((n, 3)); v = v0.copy(); t = np.zeros(n)
    axis = spin_axis(v0, tilt); om = rpm * 2 * math.pi / 60
    out = np.zeros((n, KMAX, 3)); dt = 1 / FPS
    for k in range(KMAX):
        k1v = accel(v, t, axis, om, wind, rho); k1p = v
        k2v = accel(v + k1v * dt / 2, t + dt / 2, axis, om, wind, rho); k2p = v + k1v * dt / 2
        k3v = accel(v + k2v * dt / 2, t + dt / 2, axis, om, wind, rho); k3p = v + k2v * dt / 2
        k4v = accel(v + k3v * dt, t + dt, axis, om, wind, rho); k4p = v + k3v * dt
        p = p + (k1p + 2 * k2p + 2 * k3p + k4p) * dt / 6
        v = v + (k1v + 2 * k2v + 2 * k3v + k4v) * dt / 6
        t = t + dt
        out[:, k] = p
    return out


def model_accel(v, pred_rpm, tilt_deg=None):
    """Acceleration at launch for the reprojection model: gravity + drag + Magnus lift."""
    sp = np.maximum(np.linalg.norm(v, axis=1, keepdims=True), 1e-6)
    S = R * (np.maximum(pred_rpm, 0) * 2 * math.pi / 60)[:, None] / sp
    cd = CD0 + CDS * S
    cl = np.minimum(CLMAX, CL0 + CLS * S)
    k = 0.5 * 1.225 * A * sp / M
    axis = spin_axis(v, np.zeros(len(v)) if tilt_deg is None else tilt_deg)
    a = -k * cd * v + k * cl * np.cross(axis, v)
    a[:, 2] -= G
    return a


def reprojection_fit(v_init, tee_est, pitch_e, roll_e, u_m, v_m, r_m, detected, pred_rpm, args, iters=6):
    """Gauss-Newton on (u, v, r) reprojection residuals, weighted by their measurement noise.
    With args.fit_spin, also estimates spin rate and spin-axis tilt from early curvature, regularised by
    priors (club spin ± 1500 rpm, tilt 0 ± 20°). Returns velocity, rpm, tilt."""
    t = (np.arange(1, KMAX + 1) / FPS)[None, :, None]
    P = 5 if args.fit_spin else 3
    # Parameter scaling: velocity m/s, rpm / 1000, tilt / 10 degrees.
    prior = np.concatenate([np.zeros((len(v_init), 3)), (pred_rpm / 1000)[:, None], np.zeros((len(v_init), 1))], axis=1)
    prior_sigma = np.array([np.inf, np.inf, np.inf, args.rpm_prior / 1000, 2.0])

    def unpack(x):
        rpm = x[:, 3] * 1000 if P == 5 else pred_rpm
        tilt = x[:, 4] * 10 if P == 5 else None
        return x[:, :3], rpm, tilt

    def predict(x):
        vel, rpm, tilt = unpack(x)
        a = model_accel(vel, rpm, tilt)
        pos = tee_est[:, None, :] + vel[:, None, :] * t + 0.5 * a[:, None, :] * t * t
        cx, cy, cz = to_camera(pos, pitch_e, roll_e)
        cz = np.maximum(cz, 0.05)
        return W_PX / 2 + F_PX * cx / cz, H_PX / 2 + F_PX * cy / cz, F_PX * R / cz

    def residuals(x):
        pu, pv, pr = predict(x)
        sc = max(args.centroid_sigma, 0.2)
        sr = max(args.radius_sigma, 0.1) + 0.03 * pr
        res = np.stack([(u_m - pu) / sc, (v_m - pv) / sc, (r_m - pr) / sr], axis=2) * detected[:, :, None]
        res = res.reshape(len(x), -1)
        if P == 5:
            res = np.concatenate([res, (x[:, 3:] - prior[:, 3:]) / prior_sigma[3:]], axis=1)
        return res

    x = np.concatenate([v_init, prior[:, 3:]], axis=1)[:, :P].copy()
    for _ in range(iters):
        r0 = residuals(x)
        J = np.empty((len(x), r0.shape[1], P))
        for j in range(P):
            dx = np.zeros_like(x); dx[:, j] = 0.01
            J[:, :, j] = (residuals(x + dx) - r0) / 0.01
        JTJ = np.einsum("nki,nkj->nij", J, J) + 1e-6 * np.eye(P)
        JTr = np.einsum("nki,nk->ni", J, r0)
        x = x + np.linalg.solve(JTJ, -JTr[:, :, None])[:, :, 0]
    vel, rpm, tilt = unpack(x)
    return vel, (rpm if P == 5 else pred_rpm), (tilt if P == 5 else np.zeros(len(x)))


def observe_and_extract(track, rng, args, pred_rpm=None):
    """Camera observation until lost + VIGBT launch extraction. Returns est. velocity (N,3), n_frames, valid."""
    n = len(track)
    # Tripod placement (down-the-line), randomised per shot.
    dist = rng.uniform(2.5, 4.0, n); height = rng.uniform(0.8, 1.4, n); lat = rng.uniform(-0.4, 0.4, n)
    tee = np.stack([dist, -lat, -height], axis=1)
    pitch = -np.arctan2(height, dist); roll = rng.normal(0, np.radians(1), n)
    # Placement yaw: target line direction expressed in the camera frame (0 = down-the-line,
    # 90 = face-on with the ball crossing to the camera's left, 45 = angled behind).
    yaw = math.radians(args.placement_yaw)
    rot = np.array([[math.cos(yaw), -math.sin(yaw), 0], [math.sin(yaw), math.cos(yaw), 0], [0, 0, 1]])
    world = tee[:, None, :] + track @ rot.T
    cx, cy, cz = to_camera(world, pitch, roll)
    tx, ty, tz = to_camera(tee[:, None, :], pitch, roll)
    u = W_PX / 2 + F_PX * cx / cz; vpx = H_PX / 2 + F_PX * cy / cz
    r = F_PX * R / cz
    ref_true = (F_PX * R / tz)[:, 0]
    inside = (cz > 0.3) & (u > 4) & (u < W_PX - 4) & (vpx > 4) & (vpx < H_PX - 4) & (r >= args.min_radius_px)
    # The camera follows the ball only until it first loses it.
    followed = np.cumprod(inside, axis=1).astype(bool)
    detected = followed & (rng.random(followed.shape) > args.dropout)
    nframes = followed.sum(axis=1)
    # Measurement noise.
    u_m = u + rng.normal(0, args.centroid_sigma, u.shape)
    v_m = vpx + rng.normal(0, args.centroid_sigma, u.shape)
    r_m = np.maximum(0.3, r + rng.normal(0, 1, r.shape) * (args.radius_sigma + 0.03 * r))
    ref_m = ref_true + rng.normal(0, args.radius_sigma / math.sqrt(6), n)  # averaged over 6 resting frames
    # Calibration with errors.
    d_true = tz[:, 0]
    cal = 0.0 if args.ideal else 1.0
    d_est = d_true + cal * rng.normal(0, 0.02, n)
    pitch_e = pitch + cal * rng.normal(0, np.radians(0.5), n)
    roll_e = roll + cal * rng.normal(0, np.radians(0.5), n)
    # Back-projection (LaunchVectorExtractor).
    z = d_est[:, None] * ref_m[:, None] / r_m
    camx = (u_m - W_PX / 2) * z / F_PX; camy = (v_m - H_PX / 2) * z / F_PX
    lx, ly, lz = level(camx, camy, z, pitch_e, roll_e)
    t = (np.arange(1, KMAX + 1) / FPS)[None, :]
    X = np.stack([lz, -lx, -ly + 0.5 * G * t * t], axis=2)  # fwd, left, up (gravity removed)
    # Weighted least squares per sample. Depth noise ~ 1/r^2, so weight ~ r^4 when enabled.
    wgt = detected.astype(float)
    if args.weighted:
        wgt = wgt * r_m ** 4
    tt = np.broadcast_to(t, wgt.shape)
    ok = detected.sum(axis=1) >= 4
    if args.anchor:
        # The ball starts at the tee, whose 3D position is known from calibration: subtract it and fit
        # through the origin (no intercept), which removes the least-constrained parameter.
        z0 = d_est * ref_m / ref_m
        tlx, tly, tlz = level(((tx[:, 0] / tz[:, 0]) * z0)[:, None], ((ty[:, 0] / tz[:, 0]) * z0)[:, None],
                               z0[:, None], pitch_e, roll_e)
        X = X - np.stack([tlz, -tlx, -tly], axis=2)
    quad = args.fit == "quadratic"
    if quad:
        ok_q = detected.sum(axis=1) >= 8
        cols = [np.ones_like(tt), tt, tt * tt]
    else:
        ok_q = np.zeros(n, bool)
        cols = [np.ones_like(tt), tt]
    # Linear fit for everyone (fallback), quadratic where enough points.
    if args.anchor:
        cols = cols[1:]
    def solve(cols_, mask):
        Bm = np.stack(cols_, axis=2)  # (n,K,p)
        WB = Bm * wgt[:, :, None]
        ATA = np.einsum("nkp,nkq->npq", WB, Bm)
        ATy = np.einsum("nkp,nkd->npd", WB, X)
        ATA[~mask] = np.eye(len(cols_))
        sol = np.linalg.solve(ATA, ATy)
        return sol[:, 0 if args.anchor else 1, :]  # derivative at t=0 = velocity
    vel = solve([tt] if args.anchor else [np.ones_like(tt), tt], ok)
    if quad and ok_q.any():
        vq = solve(cols, ok_q)
        vel[ok_q] = vq[ok_q]
    if args.fit == "reprojection" and pred_rpm is not None:
        z0 = d_est
        tlx, tly, tlz = level(((tx[:, 0] / tz[:, 0]) * z0)[:, None], ((ty[:, 0] / tz[:, 0]) * z0)[:, None],
                               z0[:, None], pitch_e, roll_e)
        tee_est = np.stack([tlz[:, 0], -tlx[:, 0], -tly[:, 0]], axis=1)
        fit_ok = ok & (np.linalg.norm(vel, axis=1) > 3)
        vr, rr, tt_ = reprojection_fit(vel[fit_ok], tee_est[fit_ok], pitch_e[fit_ok], roll_e[fit_ok], u_m[fit_ok],
                                       v_m[fit_ok], r_m[fit_ok], detected[fit_ok].astype(float), pred_rpm[fit_ok], args)
        vel[fit_ok] = vr
        est_rpm = pred_rpm.copy(); est_tilt = np.zeros(n)
        est_rpm[fit_ok] = np.clip(rr, 500, 11000); est_tilt[fit_ok] = np.clip(tt_, -45, 45)
        # Tilt is defined about the velocity in the camera frame; the yaw rotation leaves it unchanged.
        vel = vel @ rot
        return vel, nframes, ok, d_true, est_rpm, est_tilt
    vel = vel @ rot  # back to the target-line frame (camera yaw is known from the compass)
    return vel, nframes, ok, d_true, (pred_rpm if pred_rpm is not None else None), np.zeros(n)


# ---------------------------------------------------------------- main
def run(args):
    if args.ideal:
        args.centroid_sigma = args.radius_sigma = args.heading_sigma = args.dropout = 0.0
    rng = np.random.default_rng(args.seed)
    rows = []
    t0 = time.time()
    done = 0
    while done < args.shots:
        n = min(args.chunk, args.shots - done)
        ci, si, speed, launch, az, spin, tilt, pred_spin = make_shots(n, rng)
        v0 = velocity(speed, launch, az)
        # Unknown conditions: wind 0-6 m/s from any direction, air density, ground firmness.
        wdir = rng.uniform(0, 2 * math.pi, n); wsp = rng.uniform(0, 6, n)
        wind = np.stack([wsp * np.cos(wdir), wsp * np.sin(wdir), np.zeros(n)], axis=1)
        rho = rng.uniform(1.12, 1.25, n)
        # Truth.
        lp, lv = fly(v0, spin, tilt, wind, rho)
        g_e, g_mb, g_mr = rng.uniform(0.25, 0.45, n), rng.uniform(0.4, 0.6, n), rng.uniform(0.15, 0.4, n)
        rest_true = bounce_roll(lp, lv, g_e, g_mb, g_mr)
        # Observation + extraction.
        track = early_track(v0, spin, tilt, wind, rho)
        vel, nframes, ok, _, est_rpm, est_tilt = observe_and_extract(track, rng, args, pred_rpm=pred_spin)
        # Prediction: club spin table, no tilt (spin axis is not observable), no wind, nominal ground.
        sp = np.linalg.norm(vel, axis=1)
        ok &= sp > 3
        launch_e = np.degrees(np.arctan2(vel[:, 2], np.hypot(vel[:, 0], vel[:, 1])))
        ok &= launch_e > -5
        rho_n = np.full(n, 1.225)
        p_spin = spin if args.oracle_spin else (est_rpm if args.fit_spin else pred_spin)
        p_tilt = tilt if args.oracle_tilt else (est_tilt if args.fit_spin else np.zeros(n))
        if args.fit_spin:
            rows_spin = (est_rpm - spin, est_tilt - tilt)
        p_wind = wind if args.oracle_wind else np.zeros((n, 3))
        plp, plv = fly(vel, p_spin, p_tilt, p_wind, rho if args.oracle_wind else rho_n)
        land_pred = plp
        if args.oracle_ground:
            rest_pred = bounce_roll(plp, plv, g_e, g_mb, g_mr)
        else:
            rest_pred = bounce_roll(plp, plv, 0.35, 0.5, 0.25) if args.roll else plp
        # Compass heading error rotates the whole prediction about the tee.
        he = np.radians(rng.normal(0, args.heading_sigma, n))
        def rot(P):
            x, y = P[:, 0], P[:, 1]
            return np.stack([x * np.cos(he) - y * np.sin(he), x * np.sin(he) + y * np.cos(he)], axis=1)
        rp = rot(rest_pred); lpr = rot(land_pred)
        err = np.linalg.norm(rp - rest_true[:, :2], axis=1)
        err_land_policy = np.linalg.norm(lpr - rest_true[:, :2], axis=1)  # current app: target = landing point
        carry_pred = np.maximum(1, land_pred[:, 0])
        # Along/lateral error in the predicted flight direction.
        dirv = rp / np.maximum(np.linalg.norm(rp, axis=1, keepdims=True), 1e-9)
        dv = rest_true[:, :2] - rp
        along = (dv * dirv).sum(1)
        lateral = dv[:, 0] * (-dirv[:, 1]) + dv[:, 1] * dirv[:, 0]
        rest_dist = np.linalg.norm(rest_true[:, :2], axis=1)
        sp_t = np.linalg.norm(v0, axis=1)
        la_t = np.degrees(np.arctan2(v0[:, 2], np.hypot(v0[:, 0], v0[:, 1])))
        az_t = np.degrees(np.arctan2(-v0[:, 1], v0[:, 0])); az_e = np.degrees(np.arctan2(-vel[:, 1], vel[:, 0]))
        drpm = (est_rpm - spin) if args.fit_spin else (pred_spin - spin)
        dtilt = (est_tilt - tilt) if args.fit_spin else (0 - tilt)
        rows.append(dict(restpred=np.linalg.norm(rp, axis=1), launch=launch_e, drpm=drpm, dtilt=dtilt, dsp=(sp - sp_t) / MPH, dla=launch_e - la_t, daz=az_e - az_t,
                         ci=ci, si=si, ok=ok, nframes=nframes, err=err, err_land=err_land_policy,
                         carry=carry_pred, along=along, lateral=lateral, rest=rest_dist))
        done += n
        print(f"  {done:>9,} shots  ({time.time() - t0:5.0f} s)", flush=True)
    D = {k: np.concatenate([r[k] for r in rows]) for k in rows[0]}
    report(D, args)


def pct(x, q):
    return np.percentile(x, q) if len(x) else float("nan")


def report(D, args):
    ok = D["ok"]
    print()
    print(f"VIGBT Monte Carlo: {len(ok):,} shots, seed {args.seed}, fit={args.fit}, anchor={args.anchor}, "
          f"placement yaw {args.placement_yaw:.0f}°, fit_spin={args.fit_spin}, weighted={args.weighted}, "
          f"roll={args.roll}, min radius {args.min_radius_px}px, heading σ {args.heading_sigma}°")
    print(f"Tracked (≥4 frames, valid launch): {ok.mean() * 100:.2f}%   "
          f"frames followed: median {np.median(D['nframes']):.0f}, p10 {pct(D['nframes'], 10):.0f}")
    e = D["err"][ok] / YD; el = D["err_land"][ok] / YD; c = D["carry"][ok]
    rad = 0.08 * c
    cov_now = (D["err_land"][ok] <= np.maximum(5, rad)).mean() * 100
    cov_rest = (D["err"][ok] <= np.maximum(5, rad)).mean() * 100
    print(f"Error to final rest (yd): median {np.median(e):.1f}, p80 {pct(e, 80):.1f}, p90 {pct(e, 90):.1f}, p95 {pct(e, 95):.1f}")
    print(f"Search-circle coverage (R = 8% of carry): aimed at landing point (v0.7) {cov_now:.1f}%  |  "
          f"aimed at predicted rest {cov_rest:.1f}%")
    for q in (80, 90, 95):
        f = pct(D["err"][ok] / c, q)
        print(f"  radius needed for {q}% coverage: {f * 100:.1f}% of carry")
    for k, name, unit in (("dsp", "ball speed", "mph"), ("dla", "launch angle", "deg"), ("daz", "azimuth", "deg"),
                          ("drpm", "spin rate", "rpm"), ("dtilt", "spin-axis tilt", "deg")):
        x = D[k][ok]
        print(f"Launch measurement error, {name}: median {np.median(x):+.2f} {unit}, p90 |{pct(np.abs(x), 90):.2f}| {unit}")
    # Elliptical zone aligned with the flight: semi-axes as fractions of predicted carry.
    fa, fl = np.abs(D["along"][ok]) / c, np.abs(D["lateral"][ok]) / c
    for q in (80, 90):
        A_, L_ = pct(fa, q), pct(fl, q)
        # Scale both axes together until q% of shots fall inside the ellipse.
        rr = np.sqrt((fa / A_) ** 2 + (fl / L_) ** 2)
        s_ = pct(rr, q)
        print(f"  ellipse for {q}% coverage: along ±{A_ * s_ * 100:.1f}% of carry, lateral ±{L_ * s_ * 100:.1f}% of carry "
              f"(area {A_ * L_ * s_ * s_ / pct(D['err'][ok] / c, q) ** 2 * 100:.0f}% of the equivalent circle)")
    # Low launches (thin, skulled, topped) roll much further and less predictably: size them separately.
    lowm = D["launch"][ok] < args.low_launch_deg
    rp_ = np.maximum(1, D["restpred"][ok])
    for name, m, base, unit in (("launch ≥ %.0f°" % args.low_launch_deg, ~lowm, c, "carry"),
                                ("launch < %.0f°" % args.low_launch_deg, lowm, rp_, "predicted rest distance")):
        if m.sum() < 100:
            continue
        fa_, fl_ = np.abs(D["along"][ok][m]) / base[m], np.abs(D["lateral"][ok][m]) / base[m]
        A_, L_ = pct(fa_, 80), pct(fl_, 80)
        rr = np.sqrt((fa_ / A_) ** 2 + (fl_ / L_) ** 2)
        s_ = pct(rr, 80)
        print(f"  80% ellipse for {name} ({m.mean() * 100:.1f}% of shots): along ±{A_ * s_ * 100:.1f}%, "
              f"lateral ±{L_ * s_ * 100:.1f}% of {unit}")
    # Coverage of the shipped policy (LandingZoneEstimator defaults), incl. the low-launch rule
    # (low launches are sized from the predicted rest distance instead of carry).
    Af = np.where(lowm, args.low_along, 0.22); Lf = np.where(lowm, args.low_lateral, 0.14)
    basis = np.where(lowm, rp_, c)
    Am = np.maximum(5, Af * basis); Lm = np.maximum(5, Lf * basis)
    inside = (D["along"][ok] / Am) ** 2 + (D["lateral"][ok] / Lm) ** 2 <= 1
    print(f"Shipped policy coverage (ellipse 22%/14%, low-launch {args.low_along * 100:.0f}%/{args.low_lateral * 100:.0f}%, min 5 m): "
          f"{inside.mean() * 100:.1f}% overall, {inside[~lowm].mean() * 100:.1f}% normal, {inside[lowm].mean() * 100:.1f}% low")
    a, l = D["along"][ok] / YD, D["lateral"][ok] / YD
    print(f"Along-line error p90 |{pct(np.abs(a), 90):.1f}| yd, lateral p90 |{pct(np.abs(l), 90):.1f}| yd "
          f"(bias along {np.median(a):+.1f}, lateral {np.median(l):+.1f})")
    print()
    print(f"{'club':<8}{'strike':<12}{'share':>7}{'tracked':>9}{'med err':>9}{'p90 err':>9}{'cover@8%':>10}{'p90 %carry':>11}")
    clubs = list(CLUBS)
    for k, cname in enumerate(clubs):
        for i, s in enumerate(STRIKES):
            m = (D["ci"] == k) & (D["si"] == i)
            if m.sum() < 200:
                continue
            mo = m & ok
            ee = D["err"][mo] / YD
            cc = D["carry"][mo]
            cov = (D["err"][mo] <= np.maximum(5, 0.08 * cc)).mean() * 100 if mo.any() else float("nan")
            print(f"{cname:<8}{s:<12}{m.mean() * 100:6.1f}%{mo.sum() / m.sum() * 100:8.1f}%"
                  f"{np.median(ee) if len(ee) else float('nan'):9.1f}{pct(ee, 90):9.1f}{cov:9.1f}%"
                  f"{pct(D['err'][mo] / cc, 90) * 100:10.1f}%")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", type=int, default=100_000)
    ap.add_argument("--chunk", type=int, default=100_000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--fit", choices=["linear", "quadratic", "reprojection"], default="reprojection")
    ap.add_argument("--weighted", type=int, default=1)
    ap.add_argument("--roll", type=int, default=1, help="predict bounce & roll (1) or target the landing point (0)")
    ap.add_argument("--min-radius-px", type=float, default=1.0)
    ap.add_argument("--dropout", type=float, default=0.05)
    ap.add_argument("--centroid-sigma", type=float, default=0.35)
    ap.add_argument("--radius-sigma", type=float, default=0.2)
    ap.add_argument("--heading-sigma", type=float, default=3.0)
    ap.add_argument("--anchor", type=int, default=1, help="fit through the known tee position")
    ap.add_argument("--placement-yaw", type=float, default=0.0, help="0 down-the-line, 45 angled, 90 face-on")
    ap.add_argument("--fit-spin", type=int, default=1, help="estimate spin rate and axis from early curvature")
    ap.add_argument("--rpm-prior", type=float, default=700, help="prior σ (rpm) pulling spin toward the club table")
    ap.add_argument("--oracle-spin", type=int, default=0, help="ablation: predictor knows true spin rate")
    ap.add_argument("--oracle-tilt", type=int, default=0, help="ablation: predictor knows true spin axis")
    ap.add_argument("--oracle-wind", type=int, default=0, help="ablation: predictor knows wind and air density")
    ap.add_argument("--oracle-ground", type=int, default=0, help="ablation: predictor knows bounce/roll firmness")
    ap.add_argument("--low-launch-deg", type=float, default=8.0)
    ap.add_argument("--low-along", type=float, default=0.45)
    ap.add_argument("--low-lateral", type=float, default=0.12)
    ap.add_argument("--ideal", type=int, default=0, help="1 = no measurement noise or calibration error")
    run(ap.parse_args())
