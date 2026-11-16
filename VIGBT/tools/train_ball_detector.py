#!/usr/bin/env python3
"""
Train VIGBT's golf-ball detector (SPEC §12.10) and export it to Core ML.

A tiny CenterNet-style network (our own code, Apache-2.0): fully convolutional, input 288×512 RGB, output
a ball-centre heatmap and a radius map at stride 4. About 0.2 M parameters, so it runs at the ground
scanner's frame rate on an iPhone Neural Engine.

Open data only (SPEC §8). A dataset directory must contain:
    images/*.jpg|png
    labels/<same name>.txt   YOLO format: "class cx cy w h" (normalised); every class is "golf ball"
    dataset.json             {"licence": "<SPDX id>", "source": "<where it came from>"}
Datasets whose licence is not in OPEN_LICENCES are refused. `--synthetic N` generates N labelled
grass-and-ball images instead (for smoke tests; it says nothing about real-world accuracy).

    pip install torch==2.5.1 coremltools==8.1 pillow numpy
    python3 tools/train_ball_detector.py --data path/to/dataset --epochs 40 --out build/detector
    python3 tools/train_ball_detector.py --synthetic 3000 --epochs 6 --out build/detector-smoke

Outputs: VIGBTBallDetector.mlpackage, VIGBTBallDetector.json (BallDetectorInfo: licences, version;
validatedRangeMeters stays empty until a field test), and metrics.json.
"""
import argparse
import json
import math
import os
import random
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageDraw, ImageFilter

OPEN_LICENCES = {"CC0-1.0", "CC-BY-4.0", "CC-BY-SA-4.0", "MIT", "APACHE-2.0", "BSD-3-CLAUSE", "ODBL-1.0"}
H, W, STRIDE = 288, 512, 4


# ---------------------------------------------------------------- data
def synthetic_sample(rng):
    """Grass with mower stripes, sometimes sky/sand/path; 0–3 balls of mixed colours; distractors."""
    g = rng.uniform(0.35, 0.65)
    base = np.array([rng.uniform(40, 80), rng.uniform(110, 160) * g / 0.5, rng.uniform(30, 60)])
    img = np.clip(base + rng.normal(0, 12, (H, W, 3)), 0, 255)
    stripe = (np.arange(W)[None, :] + np.arange(H)[:, None] * rng.uniform(-0.5, 0.5)) // rng.integers(30, 70) % 2
    img = np.clip(img + stripe[..., None] * rng.uniform(-14, 14), 0, 255)
    if rng.random() < 0.25:  # sky band (bright, unsaturated)
        img[: rng.integers(20, 90)] = np.array([215, 225, 240]) + rng.normal(0, 6, 3)
    if rng.random() < 0.15:  # sand patch
        x0, y0 = rng.integers(0, W - 120), rng.integers(0, H - 80)
        img[y0:y0 + rng.integers(40, 80), x0:x0 + rng.integers(60, 120)] = np.array([215, 195, 150]) + rng.normal(0, 8, 3)
    pil = Image.fromarray(img.astype(np.uint8))
    d = ImageDraw.Draw(pil)
    for _ in range(rng.integers(0, 12)):  # daisies / leaves / specks
        x, y, r = rng.integers(0, W), rng.integers(0, H), rng.uniform(0.6, 2.2)
        col = [(250, 250, 245), (200, 120, 40), (120, 90, 50)][rng.integers(0, 3)]
        d.ellipse([x - r, y - r, x + r, y + r], fill=col)
    if rng.random() < 0.3:  # painted line
        y = rng.integers(0, H)
        d.line([0, y, W, y + rng.integers(-30, 30)], fill=(245, 245, 245), width=int(rng.integers(2, 5)))
    balls = []
    for _ in range(rng.integers(0, 4)):
        r = float(rng.uniform(1.5, 14))
        x, y = rng.uniform(r, W - r), rng.uniform(r, H - r)
        col = [(248, 248, 248), (255, 70, 160), (255, 120, 20), (230, 250, 60)][rng.integers(0, 4)]
        shade = rng.uniform(0.7, 1.0)
        d.ellipse([x - r, y - r, x + r, y + r], fill=tuple(int(c * shade) for c in col))
        if rng.random() < 0.4:  # partly hidden in grass
            for _ in range(int(r)):
                gx, gy = x + rng.uniform(-r, r), y + rng.uniform(0, r)
                d.line([gx, gy, gx + rng.uniform(-2, 2), gy - rng.uniform(2, 2 * r)], fill=tuple(int(v) for v in base), width=1)
        balls.append((x, y, r))
    if rng.random() < 0.5:
        pil = pil.filter(ImageFilter.GaussianBlur(rng.uniform(0.2, 1.0)))
    return np.asarray(pil, dtype=np.uint8), balls


def load_dataset(path):
    meta_path = os.path.join(path, "dataset.json")
    if not os.path.exists(meta_path):
        raise SystemExit(f"Refusing {path}: no dataset.json with a licence (SPEC §8: open data only).")
    meta = json.load(open(meta_path))
    lic = str(meta.get("licence", "")).upper()
    if lic not in OPEN_LICENCES:
        raise SystemExit(f"Refusing {path}: licence '{meta.get('licence')}' is not an approved open licence {sorted(OPEN_LICENCES)}.")
    samples = []
    img_dir, lab_dir = os.path.join(path, "images"), os.path.join(path, "labels")
    for name in sorted(os.listdir(img_dir)):
        stem, _ = os.path.splitext(name)
        im = Image.open(os.path.join(img_dir, name)).convert("RGB")
        sx, sy = W / im.width, H / im.height
        im = im.resize((W, H), Image.BILINEAR)
        balls = []
        lab = os.path.join(lab_dir, stem + ".txt")
        if os.path.exists(lab):
            for line in open(lab):
                p = line.split()
                if len(p) >= 5:
                    cx, cy, bw, bh = (float(v) for v in p[1:5])
                    balls.append((cx * W, cy * H, 0.25 * (bw * W + bh * H)))
        samples.append((np.asarray(im, dtype=np.uint8), balls))
    return samples, meta


def targets(balls):
    """Gaussian heatmap and radius map at stride 4."""
    h, w = H // STRIDE, W // STRIDE
    heat = np.zeros((h, w), np.float32)
    size = np.zeros((h, w), np.float32)
    mask = np.zeros((h, w), np.float32)
    ys, xs = np.mgrid[0:h, 0:w]
    for x, y, r in balls:
        cx, cy = x / STRIDE, y / STRIDE
        sigma = max(0.7, r / STRIDE / 2)
        g = np.exp(-((xs - cx) ** 2 + (ys - cy) ** 2) / (2 * sigma ** 2))
        heat = np.maximum(heat, g)
        ix, iy = min(w - 1, int(cx)), min(h - 1, int(cy))
        size[iy, ix] = r / STRIDE
        mask[iy, ix] = 1
    return heat, size, mask


# ---------------------------------------------------------------- model
class BallNet(nn.Module):
    def __init__(self, c=24):
        super().__init__()
        def block(i, o, s):
            return nn.Sequential(nn.Conv2d(i, o, 3, s, 1, bias=False), nn.BatchNorm2d(o), nn.ReLU(inplace=True))
        self.stem = nn.Sequential(block(3, c, 2), block(c, c, 1), block(c, 2 * c, 2), block(2 * c, 2 * c, 1))  # stride 4
        self.ctx = nn.Sequential(block(2 * c, 4 * c, 2), block(4 * c, 4 * c, 1))  # stride 8 context
        self.fuse = block(2 * c + 4 * c, 2 * c, 1)
        self.heat = nn.Conv2d(2 * c, 1, 1)
        self.size = nn.Conv2d(2 * c, 1, 1)
        nn.init.constant_(self.heat.bias, -2.2)

    def forward(self, x):
        a = self.stem(x)
        b = F.interpolate(self.ctx(a), size=a.shape[-2:], mode="nearest")
        f = self.fuse(torch.cat([a, b], 1))
        return torch.sigmoid(self.heat(f)), F.relu(self.size(f))


def focal(pred, gt):
    pos = gt.eq(1).float() if gt.max() >= 1 else (gt > 0.95).float()
    neg = 1 - pos
    p = pred.clamp(1e-4, 1 - 1e-4)
    pos_loss = -torch.log(p) * (1 - p) ** 2 * pos
    neg_loss = -torch.log(1 - p) * p ** 2 * (1 - gt) ** 4 * neg
    n = pos.sum().clamp(min=1)
    return (pos_loss.sum() + neg_loss.sum()) / n


def decode(heat, size, thresh=0.5):
    """Peaks after 3×3 max-pool NMS → [(x, y, r, conf)] in input pixels."""
    hmax = F.max_pool2d(heat, 3, 1, 1)
    keep = (heat == hmax) & (heat >= thresh)
    out = []
    for b in range(heat.shape[0]):
        ys, xs = torch.nonzero(keep[b, 0], as_tuple=True)
        out.append([((x.item() + 0.5) * STRIDE, (y.item() + 0.5) * STRIDE, size[b, 0, y, x].item() * STRIDE, heat[b, 0, y, x].item())
                    for y, x in zip(ys, xs)])
    return out


def evaluate(model, samples, thresh=0.5):
    model.eval()
    tp = fp = fn = 0
    with torch.no_grad():
        for img, balls in samples:
            x = torch.from_numpy(img).permute(2, 0, 1)[None].float() / 255
            dets = decode(*model(x), thresh)[0]
            used = set()
            for bx, by, br in balls:
                hit = next((i for i, (dx, dy, _, _) in enumerate(dets)
                            if i not in used and math.hypot(dx - bx, dy - by) <= max(4.0, br)), None)
                if hit is None:
                    fn += 1
                else:
                    used.add(hit)
                    tp += 1
            fp += len(dets) - len(used)
    precision = tp / max(1, tp + fp)
    recall = tp / max(1, tp + fn)
    return {"precision": round(precision, 4), "recall": round(recall, 4), "true_positives": tp,
            "false_positives": fp, "missed": fn}


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", help="dataset directory (open licence required)")
    ap.add_argument("--synthetic", type=int, default=0, help="generate N synthetic images instead")
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--out", default="build/detector")
    ap.add_argument("--version", default="0.1.0")
    args = ap.parse_args()
    torch.manual_seed(args.seed)
    rng = np.random.default_rng(args.seed)
    random.seed(args.seed)

    if args.data:
        samples, meta = load_dataset(args.data)
        licences = [meta["licence"]]
        source = meta.get("source", "")
    elif args.synthetic:
        samples = [synthetic_sample(rng) for _ in range(args.synthetic)]
        licences, source = ["CC0-1.0"], "synthetic (tools/train_ball_detector.py)"
    else:
        raise SystemExit("Give --data DIR or --synthetic N.")
    random.shuffle(samples)
    split = max(1, len(samples) // 10)
    val, train = samples[:split], samples[split:]
    print(f"{len(train)} training / {len(val)} validation images; licence {licences}; source {source}")

    model = BallNet()
    print(f"parameters: {sum(p.numel() for p in model.parameters()):,}")
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=3e-3, total_steps=args.epochs * math.ceil(len(train) / args.batch))
    for epoch in range(args.epochs):
        model.train()
        random.shuffle(train)
        t0, total = time.time(), 0.0
        for i in range(0, len(train), args.batch):
            chunk = train[i:i + args.batch]
            x = torch.from_numpy(np.stack([c[0] for c in chunk])).permute(0, 3, 1, 2).float() / 255
            if random.random() < 0.5:
                x = torch.flip(x, [3])
                chunk = [(c[0], [(W - bx, by, br) for bx, by, br in c[1]]) for c in chunk]
            t = [targets(c[1]) for c in chunk]
            heat = torch.from_numpy(np.stack([a for a, _, _ in t]))[:, None]
            size = torch.from_numpy(np.stack([b for _, b, _ in t]))[:, None]
            mask = torch.from_numpy(np.stack([m for _, _, m in t]))[:, None]
            ph, ps = model(x)
            loss = focal(ph, heat) + 0.1 * (F.l1_loss(ps * mask, size * mask, reduction="sum") / mask.sum().clamp(min=1))
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
            total += loss.item() * len(chunk)
        m = evaluate(model, val)
        print(f"epoch {epoch + 1:>3}: loss {total / len(train):.3f}  val precision {m['precision']:.3f} recall {m['recall']:.3f}  ({time.time() - t0:.0f} s)")

    os.makedirs(args.out, exist_ok=True)
    metrics = evaluate(model, val)
    metrics.update({"images": len(samples), "epochs": args.epochs, "synthetic": bool(args.synthetic)})
    json.dump(metrics, open(os.path.join(args.out, "metrics.json"), "w"), indent=2)
    torch.save(model.state_dict(), os.path.join(args.out, "ballnet.pt"))
    info = {"name": "VIGBTBallDetector", "version": args.version, "trainingDataLicences": licences,
            "validatedRangeMeters": None, "source": source, "input": [H, W], "stride": STRIDE}
    json.dump(info, open(os.path.join(args.out, "VIGBTBallDetector.json"), "w"), indent=2)

    try:
        import coremltools as ct
        model.eval()
        traced = torch.jit.trace(model, torch.rand(1, 3, H, W))
        ml = ct.convert(traced, inputs=[ct.ImageType(name="image", shape=(1, 3, H, W), scale=1 / 255)],
                        outputs=[ct.TensorType(name="heatmap"), ct.TensorType(name="radius")],
                        minimum_deployment_target=ct.target.iOS17, convert_to="mlprogram")
        ml.short_description = "VIGBT golf-ball detector: centre heatmap and radius at stride 4"
        ml.license = "Apache-2.0; training data: " + ", ".join(licences)
        ml.version = args.version
        ml.save(os.path.join(args.out, "VIGBTBallDetector.mlpackage"))
        print("Core ML model written:", os.path.join(args.out, "VIGBTBallDetector.mlpackage"))
    except Exception as e:  # coremltools missing or conversion failed: keep the PyTorch weights
        print("Core ML export skipped:", e)
    print("final:", json.dumps(metrics))


if __name__ == "__main__":
    main()
