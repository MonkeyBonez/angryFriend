#!/usr/bin/env python3
"""
test_coreml_pipeline.py — CoreML-based face pipeline comparison harness.

Two modes:

  --dataset lfw
      Downloads 10+10 pre-aligned 112×112 face chips from HuggingFace LFW.
      Since chips are already ArcFace-aligned, detection/alignment is skipped.
      Tests three embedding paths:
        • broken    : retina bug simulation (112→336→112) then CoreML
        • fixed     : direct CoreML (no degradation)
        • reference : direct insightface ONNX model (known-good baseline)
      This isolates the retina double-interpolation bug's effect on accuracy.

  --seed / --positives / --negatives
      Real photos. Tests the full pipeline including detection + alignment:
        • broken    : 5-pt Umeyama + retina bug + CoreML
        • fixed     : 2-pt eye-only alignment + CoreML
        • reference : insightface end-to-end ONNX

Pass criteria (fixed pipeline): same-person sim > 0.4, different-person sim < 0.25

Dependencies: coremltools, insightface, opencv-python-headless, numpy, Pillow, datasets
"""

import argparse
import json
import math
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

# ─── Paths ────────────────────────────────────────────────────────────────────

REPO_ROOT = Path(__file__).resolve().parent.parent
MLPACKAGE_PATH = REPO_ROOT / "angryFriend" / "MobileFaceNet.mlpackage"
DEBUG_DIR = REPO_ROOT / "debug_chips"
TEST_DATA_DIR = REPO_ROOT / "test_data" / "lfw_pairs"

# ─── ArcFace 5-point template ─────────────────────────────────────────────────

ARCFACE_DST = np.array([
    [38.2946, 51.6963],  # left eye  (image-left = subject's right)
    [73.5318, 51.5014],  # right eye
    [56.0252, 71.7366],  # nose tip
    [41.5493, 92.3655],  # left mouth corner
    [70.7299, 92.2041],  # right mouth corner
], dtype=np.float32)

# 2-point targets (from Swift fallback constants)
EYE_DIST_TARGET = 35.24
EYE_MIDPOINT_TARGET = (55.91, 51.60)
OUTPUT_SIZE = (112, 112)


# ─── Math helpers ─────────────────────────────────────────────────────────────

def umeyama_similarity(src: np.ndarray, dst: np.ndarray) -> np.ndarray:
    """2-D similarity transform (Umeyama 1991). Returns 2×3 matrix for cv2.warpAffine."""
    assert src.shape == dst.shape and src.shape[1] == 2
    n = len(src)
    mean_src, mean_dst = src.mean(0), dst.mean(0)
    src_d, dst_d = src - mean_src, dst - mean_dst
    var_src = np.sum(src_d ** 2) / n
    if var_src < 1e-10:
        raise ValueError("Source points degenerate")
    a = np.sum(dst_d[:, 0] * src_d[:, 0] + dst_d[:, 1] * src_d[:, 1]) / (n * var_src)
    b = np.sum(dst_d[:, 1] * src_d[:, 0] - dst_d[:, 0] * src_d[:, 1]) / (n * var_src)
    tx = mean_dst[0] - a * mean_src[0] + b * mean_src[1]
    ty = mean_dst[1] - b * mean_src[0] - a * mean_src[1]
    return np.array([[a, -b, tx], [b, a, ty]], dtype=np.float32)


def cosine_sim(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b))


# ─── CoreML model ─────────────────────────────────────────────────────────────

class CoreMLModel:
    def __init__(self, path: Path):
        import coremltools as ct
        print(f"[CoreML] Loading {path.name} …", end=" ", flush=True)
        self.model = ct.models.MLModel(str(path))
        self._output_name = self.model.get_spec().description.output[0].name
        print(f"ok  (output='{self._output_name}')")

    def embed(self, chip_bgr: np.ndarray) -> np.ndarray | None:
        """Embed 112×112 BGR chip → L2-normalised 512-dim vector."""
        assert chip_bgr.shape == (112, 112, 3)
        pil = Image.fromarray(cv2.cvtColor(chip_bgr, cv2.COLOR_BGR2RGB))
        try:
            pred = self.model.predict({"input_1": pil})
        except Exception as e:
            print(f"  [CoreML] predict error: {e}")
            return None
        emb = np.array(pred[self._output_name]).flatten().astype(np.float32)
        norm = np.linalg.norm(emb)
        return emb / norm if norm > 1e-6 else None


# ─── Face detector (insightface, detection-only) ──────────────────────────────

class FaceDetector:
    def __init__(self):
        from insightface.app import FaceAnalysis
        self.app = FaceAnalysis(name="buffalo_sc", allowed_modules=["detection"])
        self.app.prepare(ctx_id=-1)
        print("[Detector] insightface buffalo_sc detection loaded")

    def get_kps(self, img_bgr: np.ndarray) -> np.ndarray | None:
        """Largest face only — matches old behaviour."""
        faces = self.app.get(img_bgr)
        if not faces:
            return None
        face = max(faces, key=lambda f: (f.bbox[2]-f.bbox[0])*(f.bbox[3]-f.bbox[1]))
        return face.kps.astype(np.float32) if face.kps is not None else None

    def get_all_kps(self, img_bgr: np.ndarray) -> list[np.ndarray]:
        """All detected faces — matches Swift evaluateAsset behaviour."""
        faces = self.app.get(img_bgr)
        return [f.kps.astype(np.float32) for f in faces if f.kps is not None]

    def count_faces(self, img_bgr: np.ndarray) -> int:
        return len(self.app.get(img_bgr))

    def largest_face_area(self, img_bgr: np.ndarray) -> float:
        """Area of largest detected face in pixels² — used to rank seed quality."""
        faces = self.app.get(img_bgr)
        if not faces:
            return 0.0
        return max((f.bbox[2]-f.bbox[0]) * (f.bbox[3]-f.bbox[1]) for f in faces)


def find_single_face_photos(photo_list: list[tuple[str, np.ndarray]],
                             det: FaceDetector,
                             max_seeds: int = 3) -> tuple[list[tuple[str, np.ndarray]],
                                                          list[tuple[str, np.ndarray]]]:
    """
    Split photo_list into (seed_candidates, rest).
    seed_candidates = photos with exactly 1 detected face, ranked by face area descending.
    rest = everything else (0 faces or 2+ faces).
    Returns at most max_seeds seed candidates.
    """
    single, multi = [], []
    print(f"  Scanning {len(photo_list)} photos for face count…")
    for path, img in photo_list:
        n = det.count_faces(img)
        if n == 1:
            area = det.largest_face_area(img)
            single.append((path, img, area))
        else:
            multi.append((path, img))

    # Sort single-face by face area descending → clearest portrait first
    single.sort(key=lambda x: x[2], reverse=True)
    print(f"  1-face photos: {len(single)}  |  0- or multi-face: {len(multi)}")

    seed_candidates = [(p, img) for p, img, _ in single[:max_seeds]]
    # "rest" = all photos not used as seeds (multi-face + remaining single-face)
    rest = [(p, img) for p, img, _ in single[max_seeds:]] + multi
    return seed_candidates, rest


# ─── Embedding paths ──────────────────────────────────────────────────────────

def embed_broken_chip(chip_bgr: np.ndarray, coreml: CoreMLModel) -> np.ndarray | None:
    """Broken: simulate retina double-interpolation (112→336→112) then CoreML embed."""
    big = cv2.resize(chip_bgr, (336, 336), interpolation=cv2.INTER_LINEAR)
    degraded = cv2.resize(big, OUTPUT_SIZE, interpolation=cv2.INTER_LINEAR)
    return coreml.embed(degraded)


def embed_fixed_chip(chip_bgr: np.ndarray, coreml: CoreMLModel) -> np.ndarray | None:
    """Fixed: direct CoreML embed (no degradation)."""
    return coreml.embed(chip_bgr)


def embed_reference_chip(chip_bgr: np.ndarray, insightface_recognizer) -> np.ndarray | None:
    """Reference: insightface ONNX recognition on pre-aligned chip."""
    rgb = cv2.cvtColor(chip_bgr, cv2.COLOR_BGR2RGB).astype(np.float32)
    norm_img = (rgb / 127.5) - 1.0
    inp = norm_img.transpose(2, 0, 1)[np.newaxis]  # NCHW
    out = insightface_recognizer.get_feat(inp)
    emb = out.flatten().astype(np.float32)
    n = np.linalg.norm(emb)
    return emb / n if n > 1e-6 else None


# ─── Full pipeline (detection + alignment + embed) ────────────────────────────

def align_5pt(img_bgr: np.ndarray, kps: np.ndarray) -> np.ndarray | None:
    try:
        M = umeyama_similarity(kps, ARCFACE_DST)
    except ValueError:
        return None
    return cv2.warpAffine(img_bgr, M, OUTPUT_SIZE, flags=cv2.INTER_LINEAR)


def align_2pt(img_bgr: np.ndarray, kps: np.ndarray) -> np.ndarray | None:
    left_eye, right_eye = kps[0].copy(), kps[1].copy()
    if left_eye[0] > right_eye[0]:
        left_eye, right_eye = right_eye, left_eye
    dx, dy = right_eye[0] - left_eye[0], right_eye[1] - left_eye[1]
    dist = math.sqrt(dx*dx + dy*dy)
    if dist < 1e-3:
        return None
    scale = EYE_DIST_TARGET / dist
    angle = math.atan2(dy, dx)
    cos_a, sin_a = math.cos(-angle) * scale, math.sin(-angle) * scale
    mid_x, mid_y = (left_eye[0]+right_eye[0])/2, (left_eye[1]+right_eye[1])/2
    tx = EYE_MIDPOINT_TARGET[0] - (cos_a*mid_x - sin_a*mid_y)
    ty = EYE_MIDPOINT_TARGET[1] - (sin_a*mid_x + cos_a*mid_y)
    M = np.array([[cos_a, -sin_a, tx], [sin_a, cos_a, ty]], dtype=np.float32)
    return cv2.warpAffine(img_bgr, M, OUTPUT_SIZE, flags=cv2.INTER_LINEAR)


def full_broken(img_bgr: np.ndarray, det: FaceDetector, coreml: CoreMLModel) -> np.ndarray | None:
    """Full broken: 5-pt alignment + retina bug + CoreML."""
    kps = det.get_kps(img_bgr)
    if kps is None:
        return None
    chip = align_5pt(img_bgr, kps)
    if chip is None:
        return None
    return embed_broken_chip(chip, coreml)


def full_fixed(img_bgr: np.ndarray, det: FaceDetector, coreml: CoreMLModel,
               save_chip: str = "") -> np.ndarray | None:
    """Full fixed: 2-pt alignment + CoreML."""
    kps = det.get_kps(img_bgr)
    if kps is None:
        return None
    chip = align_2pt(img_bgr, kps)
    if chip is None:
        return None
    if save_chip:
        out = DEBUG_DIR / "fixed"
        out.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(str(out / f"{save_chip}.jpg"), chip)
    return embed_fixed_chip(chip, coreml)


def full_fixed_with_embedding(img_bgr: np.ndarray, det: FaceDetector, coreml: CoreMLModel) -> np.ndarray | None:
    """Same as full_fixed but always returns embedding (no chip saving). Largest face only."""
    return full_fixed(img_bgr, det, coreml)


def full_fixed_all_faces(img_bgr: np.ndarray, det: FaceDetector, coreml: CoreMLModel,
                         align_mode: str = "2pt") -> list[np.ndarray]:
    """
    Embed ALL detected faces in the image — matches Swift evaluateAsset behaviour.
    Returns a (possibly empty) list of L2-normalised 512-dim embeddings.
    align_mode: "2pt" (eye-only), "5pt" (Umeyama), "hybrid" (5pt with 2pt fallback)
    """
    all_embs = []
    for kps in det.get_all_kps(img_bgr):
        if align_mode == "5pt":
            chip = align_5pt(img_bgr, kps)
        elif align_mode == "hybrid":
            chip = align_5pt(img_bgr, kps)
            if chip is None:
                chip = align_2pt(img_bgr, kps)
        else:
            chip = align_2pt(img_bgr, kps)
        if chip is None:
            continue
        emb = embed_fixed_chip(chip, coreml)
        if emb is not None:
            all_embs.append(emb)
    return all_embs


def best_sim_all_faces(img_bgr: np.ndarray, det: FaceDetector, coreml: CoreMLModel,
                        pool: list[np.ndarray]) -> tuple[float, np.ndarray | None]:
    """
    Score an image against a seed pool using ALL detected faces.
    Returns (best_similarity, best_embedding) — the face that best matches the pool.
    Returns (-inf, None) if no faces found.
    """
    best_score = float("-inf")
    best_emb   = None
    for emb in full_fixed_all_faces(img_bgr, det, coreml):
        sim = max_sim_to_pool(emb, pool)
        if sim > best_score:
            best_score = sim
            best_emb   = emb
    return best_score, best_emb


def full_reference(img_bgr: np.ndarray, ref_app) -> np.ndarray | None:
    """Full reference: insightface end-to-end."""
    faces = ref_app.get(img_bgr)
    if not faces:
        return None
    face = max(faces, key=lambda f: (f.bbox[2]-f.bbox[0])*(f.bbox[3]-f.bbox[1]))
    emb = face.embedding
    n = np.linalg.norm(emb)
    return (emb / n).astype(np.float32) if n > 1e-6 else None


# ─── Evaluation ───────────────────────────────────────────────────────────────

def eval_pairs(name: str, pairs: list[dict], embed_fn) -> dict:
    """Evaluate a pipeline. embed_fn(img_bgr) → embedding or None."""
    pos_scores, neg_scores, errors = [], [], 0
    for pair in pairs:
        e1 = embed_fn(pair["img1"])
        e2 = embed_fn(pair["img2"])
        label = pair["label"]
        same = pair["same"]
        if e1 is None or e2 is None:
            err = ("img1: no face" if e1 is None else "") + (" img2: no face" if e2 is None else "")
            print(f"  [{'SAME' if same else 'DIFF'}] {label:<35}  SKIP ({err.strip()})")
            errors += 1
            continue
        sim = cosine_sim(e1, e2)
        tag = "SAME" if same else "DIFF"
        marker = "✓" if (same and sim >= 0.35) or (not same and sim < 0.35) else "✗"
        print(f"  {marker} [{tag}] {label:<35}  sim={sim:.4f}")
        (pos_scores if same else neg_scores).append(sim)
    return {"name": name, "pos": pos_scores, "neg": neg_scores, "errors": errors}


def print_stats(r: dict):
    pos, neg = r["pos"], r["neg"]
    if pos:
        print(f"  same-person  : n={len(pos):3d}  mean={np.mean(pos):.4f}  min={min(pos):.4f}  max={max(pos):.4f}")
    if neg:
        print(f"  diff-person  : n={len(neg):3d}  mean={np.mean(neg):.4f}  min={min(neg):.4f}  max={max(neg):.4f}")
    if pos and neg:
        sm, dm = np.mean(pos), np.mean(neg)
        print(f"  separation   : {sm-dm:.4f}")
        print(f"  pass: same>0.4 → {'PASS ✓' if sm > 0.4 else 'FAIL ✗'}   diff<0.25 → {'PASS ✓' if dm < 0.25 else 'FAIL ✗'}")
    if r["errors"]:
        print(f"  skipped      : {r['errors']} pairs (no face detected)")


def threshold_sweep(r: dict):
    pos, neg = r["pos"], r["neg"]
    if not pos or not neg:
        return
    lo = min(min(pos), min(neg))
    hi = max(max(pos), max(neg))
    thresholds = np.linspace(lo, hi, 20)
    best_f1, best_t = 0.0, 0.0
    rows = []
    for t in thresholds:
        tp = sum(1 for s in pos if s >= t)
        fn = len(pos) - tp
        fp = sum(1 for s in neg if s >= t)
        tn = len(neg) - fp
        tpr = tp / (tp+fn) if (tp+fn) > 0 else 0.0
        prec = tp / (tp+fp) if (tp+fp) > 0 else 0.0
        f1 = 2*prec*tpr/(prec+tpr) if (prec+tpr) > 0 else 0.0
        fpr = fp / (fp+tn) if (fp+tn) > 0 else 0.0
        rows.append((t, tpr, fpr, f1))
        if f1 > best_f1:
            best_f1, best_t = f1, t
    print(f"\n  {'Thresh':>7}  {'TPR':>6}  {'FPR':>6}  {'F1':>6}")
    for i, (t, tpr, fpr, f1) in enumerate(rows):
        if i % 4 == 0 or abs(t-best_t) < 1e-9:
            marker = " ←best" if abs(t-best_t) < 1e-9 else ""
            print(f"  {t:>7.4f}  {tpr:>6.3f}  {fpr:>6.3f}  {f1:>6.3f}{marker}")
    print(f"  → best F1={best_f1:.3f} at threshold={best_t:.4f}")


def section(title: str):
    print(f"\n{'='*72}")
    print(f"  {title}")
    print(f"{'='*72}")


# ─── LFW download ─────────────────────────────────────────────────────────────

def download_lfw_pairs(n_pos: int = 10, n_neg: int = 10) -> list[dict]:
    TEST_DATA_DIR.mkdir(parents=True, exist_ok=True)
    manifest_path = TEST_DATA_DIR / "manifest.json"

    if manifest_path.exists():
        print(f"[LFW] Loading cached pairs from {TEST_DATA_DIR}")
        with open(manifest_path) as f:
            manifest = json.load(f)
        pairs = []
        for e in manifest:
            i1 = cv2.imread(str(TEST_DATA_DIR / e["img1"]))
            i2 = cv2.imread(str(TEST_DATA_DIR / e["img2"]))
            if i1 is not None and i2 is not None:
                pairs.append({"img1": i1, "img2": i2, "same": e["same"], "label": e["label"]})
        if pairs:
            print(f"[LFW] Loaded {len(pairs)} pairs from cache")
            return pairs
        print("[LFW] Cache incomplete, re-downloading …")

    from datasets import load_dataset
    print("[LFW] Downloading cat-claws/face-verification (lfw split) …")
    ds = load_dataset("cat-claws/face-verification", split="lfw")
    print(f"[LFW] {len(ds)} rows  (note: images are pre-aligned 112×112 ArcFace chips)")

    pairs, manifest = [], []
    pos_count = neg_count = 0

    for i, row in enumerate(ds):
        if pos_count >= n_pos and neg_count >= n_neg:
            break
        target = row.get("target", row.get("same"))
        if target is None:
            continue
        same = bool(target)
        tag = "pos" if same else "neg"
        count = pos_count if same else neg_count
        if (same and pos_count >= n_pos) or (not same and neg_count >= n_neg):
            continue

        try:
            pil1 = row["image1"].convert("RGB")
            pil2 = row["image2"].convert("RGB")
        except Exception:
            continue

        idx = pos_count if same else neg_count
        f1, f2 = f"{tag}_{idx:03d}_1.jpg", f"{tag}_{idx:03d}_2.jpg"
        pil1.save(str(TEST_DATA_DIR / f1))
        pil2.save(str(TEST_DATA_DIR / f2))

        i1 = cv2.cvtColor(np.array(pil1), cv2.COLOR_RGB2BGR)
        i2 = cv2.cvtColor(np.array(pil2), cv2.COLOR_RGB2BGR)
        label = f"{tag}_{idx:03d}"

        pairs.append({"img1": i1, "img2": i2, "same": same, "label": label})
        manifest.append({"img1": f1, "img2": f2, "same": same, "label": label})

        if same:
            pos_count += 1
        else:
            neg_count += 1

    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"[LFW] Saved {pos_count} pos + {neg_count} neg pairs to {TEST_DATA_DIR}")
    return pairs


# ─── LFW mode (pre-aligned chips, tests retina bug in isolation) ──────────────

def run_lfw_mode(args, coreml: CoreMLModel, ref_recognizer):
    pairs = download_lfw_pairs(n_pos=10, n_neg=10)

    print(f"\n[LFW] {len(pairs)} pairs loaded")
    print("[LFW] Images are pre-aligned 112×112 chips — detection skipped")
    print("[LFW] Testing: broken=retina-bug+CoreML  fixed=CoreML  reference=insightface-ONNX")

    all_results = []

    def _save_chip(chip_bgr: np.ndarray, subdir: str, label: str):
        if not args.save_chips:
            return
        out = DEBUG_DIR / subdir
        out.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(str(out / f"{label}.jpg"), chip_bgr)

    def _embed_broken_with_save(img: np.ndarray, label: str) -> np.ndarray | None:
        big = cv2.resize(img, (336, 336), interpolation=cv2.INTER_LINEAR)
        degraded = cv2.resize(big, OUTPUT_SIZE, interpolation=cv2.INTER_LINEAR)
        _save_chip(degraded, "broken", label)
        return coreml.embed(degraded)

    def _embed_fixed_with_save(img: np.ndarray, label: str) -> np.ndarray | None:
        _save_chip(img, "fixed", label)
        return coreml.embed(img)

    if not args.skip_broken:
        section("BROKEN — retina bug (112→336→112) + CoreML")
        print("  Note: on pre-aligned 112×112 chips, 3× upsample+downsample is nearly lossless.")
        print("  Identical scores to FIXED confirm the double-interp alone is not the root cause.")
        r = {"name": "broken", "pos": [], "neg": [], "errors": 0}
        for pair in pairs:
            e1 = _embed_broken_with_save(pair["img1"], f"{pair['label']}_1")
            e2 = _embed_broken_with_save(pair["img2"], f"{pair['label']}_2")
            if e1 is None or e2 is None:
                r["errors"] += 1
                continue
            sim = cosine_sim(e1, e2)
            tag = "SAME" if pair["same"] else "DIFF"
            m = "✓" if (pair["same"] and sim >= 0.35) or (not pair["same"] and sim < 0.35) else "✗"
            print(f"  {m} [{tag}] {pair['label']:<35}  sim={sim:.4f}")
            (r["pos"] if pair["same"] else r["neg"]).append(sim)
        print_stats(r)
        threshold_sweep(r)
        all_results.append(r)

    if not args.skip_fixed:
        section("FIXED — direct CoreML (no degradation)")
        r = {"name": "fixed", "pos": [], "neg": [], "errors": 0}
        for pair in pairs:
            e1 = _embed_fixed_with_save(pair["img1"], f"{pair['label']}_1")
            e2 = _embed_fixed_with_save(pair["img2"], f"{pair['label']}_2")
            if e1 is None or e2 is None:
                r["errors"] += 1
                continue
            sim = cosine_sim(e1, e2)
            tag = "SAME" if pair["same"] else "DIFF"
            m = "✓" if (pair["same"] and sim >= 0.35) or (not pair["same"] and sim < 0.35) else "✗"
            print(f"  {m} [{tag}] {pair['label']:<35}  sim={sim:.4f}")
            (r["pos"] if pair["same"] else r["neg"]).append(sim)
        print_stats(r)
        threshold_sweep(r)
        all_results.append(r)

    if not args.skip_reference and ref_recognizer is not None:
        section("REFERENCE — insightface ONNX")
        r = eval_pairs("reference", pairs, lambda img: embed_reference_chip(img, ref_recognizer))
        print_stats(r)
        threshold_sweep(r)
        all_results.append(r)
        # Note: reference saves same chips as fixed (pre-aligned input, no transformation)

    if len(all_results) > 1:
        section("SUMMARY")
        print(f"  {'Pipeline':<35}  {'same_mean':>9}  {'diff_mean':>9}  {'gap':>7}")
        print(f"  {'-'*35}  {'-'*9}  {'-'*9}  {'-'*7}")
        for r in all_results:
            sm = np.mean(r["pos"]) if r["pos"] else float("nan")
            dm = np.mean(r["neg"]) if r["neg"] else float("nan")
            gap = sm - dm if not (math.isnan(sm) or math.isnan(dm)) else float("nan")
            print(f"  {r['name']:<35}  {sm:>9.4f}  {dm:>9.4f}  {gap:>7.4f}")


# ─── Seed/pos/neg mode (real photos, tests full alignment pipeline) ────────────

def load_images(path: str) -> list[tuple[str, np.ndarray]]:
    p = Path(path)
    if p.is_file():
        img = _read_image(p)
        return [(str(p), img)] if img is not None else []
    results = []
    # Case-insensitive glob for all supported formats
    exts = ("jpg", "jpeg", "png", "JPG", "JPEG", "PNG", "tif", "tiff", "TIF", "TIFF",
            "heic", "heif", "HEIC", "HEIF", "avif", "AVIF", "webp", "WEBP")
    seen = set()
    for ext in exts:
        for f in sorted(p.glob(f"*.{ext}")):
            if f in seen:
                continue
            seen.add(f)
            img = _read_image(f)
            if img is not None:
                results.append((str(f), img))
    return sorted(results, key=lambda x: x[0])


def _read_image(path: Path) -> np.ndarray | None:
    """Read an image with EXIF orientation applied — matches Swift's normalizeOrientation()."""
    try:
        from PIL import ImageOps
        try:
            from pillow_heif import register_heif_opener
            register_heif_opener()
        except ImportError:
            pass
        pil = Image.open(path).convert("RGB")
        pil = ImageOps.exif_transpose(pil)  # apply EXIF rotation, matching Swift behaviour
        return cv2.cvtColor(np.array(pil), cv2.COLOR_RGB2BGR)
    except Exception:
        # Last resort: cv2 (no EXIF — only for formats Pillow can't open)
        return cv2.imread(str(path))


def run_seed_mode(args, coreml: CoreMLModel, det: FaceDetector, ref_app):
    seed_list = load_images(args.seed)
    if not seed_list:
        print(f"ERROR: No seed image at {args.seed}"); sys.exit(1)
    pos_list = load_images(args.positives)
    neg_list = load_images(args.negatives)
    if not pos_list:
        print(f"ERROR: No positives in {args.positives}"); sys.exit(1)
    if not neg_list:
        print(f"ERROR: No negatives in {args.negatives}"); sys.exit(1)

    _, seed_bgr = seed_list[0]
    pairs = (
        [{"img1": seed_bgr, "img2": img, "same": True,  "label": Path(p).stem} for p, img in pos_list] +
        [{"img1": seed_bgr, "img2": img, "same": False, "label": Path(p).stem} for p, img in neg_list]
    )

    all_results = []

    if not args.skip_broken:
        section("BROKEN — 5-pt Umeyama + retina bug + CoreML")
        r = eval_pairs("broken", pairs,
                       lambda img: full_broken(img, det, coreml))
        print_stats(r); threshold_sweep(r)
        all_results.append(r)

    if not args.skip_fixed:
        section("FIXED — 2-pt eye alignment + CoreML")
        save_tag = "fixed" if args.save_chips else ""
        r = eval_pairs("fixed", pairs,
                       lambda img: full_fixed(img, det, coreml, save_chip=save_tag and Path(img.tobytes()[:16].hex()).name))
        print_stats(r); threshold_sweep(r)
        all_results.append(r)

    if not args.skip_reference and ref_app is not None:
        section("REFERENCE — insightface end-to-end")
        r = eval_pairs("reference", pairs,
                       lambda img: full_reference(img, ref_app))
        print_stats(r); threshold_sweep(r)
        all_results.append(r)

    if len(all_results) > 1:
        section("SUMMARY")
        print(f"  {'Pipeline':<35}  {'same_mean':>9}  {'diff_mean':>9}  {'gap':>7}")
        print(f"  {'-'*35}  {'-'*9}  {'-'*9}  {'-'*7}")
        for r in all_results:
            sm = np.mean(r["pos"]) if r["pos"] else float("nan")
            dm = np.mean(r["neg"]) if r["neg"] else float("nan")
            gap = sm - dm if not (math.isnan(sm) or math.isnan(dm)) else float("nan")
            print(f"  {r['name']:<35}  {sm:>9.4f}  {dm:>9.4f}  {gap:>7.4f}")


# ─── Query Expansion mode ─────────────────────────────────────────────────────

def max_sim_to_pool(emb: np.ndarray, pool: list[np.ndarray]) -> float:
    """Return the highest cosine similarity between emb and any vector in pool."""
    return max(cosine_sim(emb, s) for s in pool)


def is_diverse_enough(emb: np.ndarray, pool: list[np.ndarray], diversity_threshold: float) -> bool:
    """True if emb is sufficiently different from all existing pool members."""
    if not pool:
        return True
    return max_sim_to_pool(emb, pool) < diversity_threshold


def normalize(v: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(v)
    return v / n if n > 1e-6 else v


def photo_max_sim(face_embs: list[np.ndarray], pool: list[np.ndarray]) -> float:
    """Best cosine similarity across all face embeddings × all pool members."""
    if not face_embs or not pool:
        return float("-inf")
    return max(cosine_sim(e, p) for e in face_embs for p in pool)


def photo_best_emb(face_embs: list[np.ndarray], pool: list[np.ndarray]) -> np.ndarray | None:
    """Return the face embedding with the highest similarity to any pool member."""
    if not face_embs:
        return None
    return max(face_embs, key=lambda e: max_sim_to_pool(e, pool))


def _embed_single_face_aligned(img_bgr: np.ndarray, det: FaceDetector, coreml: CoreMLModel,
                               align_mode: str = "2pt") -> np.ndarray | None:
    """Largest face only, using specified alignment mode."""
    kps = det.get_kps(img_bgr)
    if kps is None:
        return None
    if align_mode == "5pt":
        chip = align_5pt(img_bgr, kps)
    elif align_mode == "hybrid":
        chip = align_5pt(img_bgr, kps)
        if chip is None:
            chip = align_2pt(img_bgr, kps)
    else:
        chip = align_2pt(img_bgr, kps)
    if chip is None:
        return None
    return embed_fixed_chip(chip, coreml)


def embed_photo(img_bgr: np.ndarray, det: FaceDetector, coreml: CoreMLModel,
                all_faces: bool, align_mode: str = "2pt") -> list[np.ndarray]:
    """Return list of embeddings: all faces if all_faces=True, else just the largest face."""
    if all_faces:
        return full_fixed_all_faces(img_bgr, det, coreml, align_mode=align_mode)
    emb = _embed_single_face_aligned(img_bgr, det, coreml, align_mode=align_mode)
    return [emb] if emb is not None else []


# ─── Centroid refinement mode ─────────────────────────────────────────────────

def run_auto_seed_mode(args, coreml: CoreMLModel, det: FaceDetector):
    """
    Auto-seed mode:
      1. Scan --positives dir and split into:
         - seed_photos: exactly 1 face detected (up to --max-seeds, ranked by face area)
         - test_photos: everything else (group shots + no-face photos)
      2. Embed the seed photos → seed pool.
      3. Score ALL positives and ALL negatives with --all-faces.
      4. Report TPR/FPR split by: seed photos | single-face positives | group positives.

    With --align-sweep: runs all combos of align_mode × threshold and prints a grid summary.
    """
    align_sweep = getattr(args, 'align_sweep', False)
    if align_sweep:
        align_modes = ["2pt", "5pt", "hybrid"]
        thresholds  = [0.26, 0.27, 0.28, 0.29, 0.30]
    else:
        align_modes = [getattr(args, 'align', '2pt')]
        thresholds  = [args.match_threshold]

    pos_list  = load_images(args.positives)
    neg_list  = load_images(args.negatives)
    max_seeds = args.max_seeds

    print(f"\n[AutoSeed] Splitting {len(pos_list)} positives into seeds vs test…")
    seed_photos, _ = find_single_face_photos(pos_list, det, max_seeds=max_seeds)
    if not seed_photos:
        print("ERROR: no single-face photos found in positives dir — can't auto-pick seeds")
        return

    seed_paths_set = {p for p, _ in seed_photos}
    sweep_results: list[dict] = []

    for align_mode in align_modes:
        section(f"AUTO-SEED  align={align_mode}")

        # Embed seeds with this alignment mode
        seed_pool: list[np.ndarray] = []
        for path, img in seed_photos:
            emb = _embed_single_face_aligned(img, det, coreml, align_mode=align_mode)
            if emb is not None:
                seed_pool.append(emb)
                print(f"  ✓ {Path(path).name}")
            else:
                print(f"  ✗ {Path(path).name}  (alignment failed)")

        if not seed_pool:
            print(f"  ERROR: all seed alignments failed for align={align_mode}"); continue

        # Pre-embed all photos (compute once per alignment mode, reuse across thresholds)
        print(f"\n[AutoSeed] Embedding all photos (align={align_mode}, all-faces)…")
        pos_embedded = [
            (p, embed_photo(img, det, coreml, all_faces=True, align_mode=align_mode))
            for p, img in pos_list
        ]
        neg_embedded = [
            (p, embed_photo(img, det, coreml, all_faces=True, align_mode=align_mode))
            for p, img in neg_list
        ]

        # Compute similarities once per alignment mode
        pos_sims = []
        for path, embs in pos_embedded:
            sim = photo_max_sim(embs, seed_pool)
            pos_sims.append({
                "path": path, "name": Path(path).name, "sim": sim,
                "is_seed": path in seed_paths_set, "n_faces": len(embs),
            })
        neg_sims = []
        for path, embs in neg_embedded:
            sim = photo_max_sim(embs, seed_pool)
            neg_sims.append({"path": path, "name": Path(path).name, "sim": sim})

        for threshold in thresholds:
            pos_with_face = [r for r in pos_sims if r["sim"] > float("-inf")]
            neg_with_face = [r for r in neg_sims if r["sim"] > float("-inf")]
            tp_all = sum(1 for r in pos_with_face if r["sim"] >= threshold)
            fp_all = sum(1 for r in neg_with_face if r["sim"] >= threshold)
            tpr = tp_all / len(pos_with_face) if pos_with_face else 0.0
            fpr = fp_all / len(neg_with_face) if neg_with_face else 0.0

            if not align_sweep:
                # Full verbose output for single-mode run
                section(f"AUTO-SEED RESULTS  (align={align_mode}, threshold={threshold:.2f}, {len(seed_pool)} seed(s))")
                print(f"  {'Category':<35}  {'Photos':>6}  {'w/face':>6}  {'TP/TN':>6}  {'Rate':>6}")
                print(f"  {'-'*35}  {'-'*6}  {'-'*6}  {'-'*6}  {'-'*6}")

                seed_r  = [r for r in pos_sims if r["is_seed"]]
                seed_tp = sum(1 for r in seed_r if r["sim"] >= threshold)
                print(f"  {'Seed photos (should = 100%)':<35}  {len(seed_r):>6d}  {len(seed_r):>6d}  {seed_tp:>6d}  {seed_tp/len(seed_r):.1%}")

                single_r  = [r for r in pos_sims if not r["is_seed"] and r["n_faces"] == 1]
                single_wf = [r for r in single_r if r["sim"] > float("-inf")]
                single_tp = sum(1 for r in single_wf if r["sim"] >= threshold)
                rate_s = single_tp / len(single_wf) if single_wf else 0.0
                print(f"  {'Single-face positives':<35}  {len(single_r):>6d}  {len(single_wf):>6d}  {single_tp:>6d}  {rate_s:.1%}")

                group_r  = [r for r in pos_sims if not r["is_seed"] and r["n_faces"] != 1]
                group_wf = [r for r in group_r if r["sim"] > float("-inf")]
                group_tp = sum(1 for r in group_wf if r["sim"] >= threshold)
                rate_g = group_tp / len(group_wf) if group_wf else 0.0
                print(f"  {'Group / multi-face positives':<35}  {len(group_r):>6d}  {len(group_wf):>6d}  {group_tp:>6d}  {rate_g:.1%}")

                print(f"\n  {'TOTAL POSITIVES':<35}  {len(pos_sims):>6d}  {len(pos_with_face):>6d}  {tp_all:>6d}  {tpr:.1%}")
                print(f"  {'TOTAL NEGATIVES (FPR)':<35}  {len(neg_sims):>6d}  {len(neg_with_face):>6d}  {fp_all:>6d}  {fpr:.1%}")

                fps = [r for r in neg_sims if r["sim"] >= threshold]
                if fps:
                    print(f"\n  False positives ({len(fps)}):")
                    for r in sorted(fps, key=lambda x: -x["sim"])[:10]:
                        print(f"    {r['name']:<55}  sim={r['sim']:.4f}")
                else:
                    print("\n  No false positives.")

                seed_r_count = len([r for r in pos_sims if r["is_seed"]])
                missed = [r for r in pos_sims
                          if not r["is_seed"] and r["sim"] < threshold and r["sim"] > float("-inf")]
                print(f"\n  Missed positives ({len(missed)} of {len(pos_with_face)-seed_r_count} non-seed with-face):")
                for r in sorted(missed, key=lambda x: -x["sim"])[:15]:
                    tag = f"[{r['n_faces']}face]"
                    print(f"    {tag:<8} {r['name']:<50}  sim={r['sim']:.4f}")

            sweep_results.append({
                "align": align_mode, "threshold": threshold,
                "tpr": tpr, "fpr": fpr, "tp": tp_all, "fp": fp_all,
                "n_pos": len(pos_with_face), "n_neg": len(neg_with_face),
            })

    if align_sweep and sweep_results:
        section("ALIGNMENT × THRESHOLD SWEEP SUMMARY")
        print(f"  {'Align':<8}  {'Thresh':>7}  {'TPR':>7}  {'FPR':>7}  {'TP':>5}  {'FP':>5}  {'N_pos':>6}  {'N_neg':>6}")
        print(f"  {'-'*8}  {'-'*7}  {'-'*7}  {'-'*7}  {'-'*5}  {'-'*5}  {'-'*6}  {'-'*6}")
        for r in sweep_results:
            marker = " ← 0FPR" if r["fpr"] == 0.0 else ""
            print(f"  {r['align']:<8}  {r['threshold']:>7.2f}  {r['tpr']:>7.3f}  {r['fpr']:>7.3f}  "
                  f"{r['tp']:>5d}  {r['fp']:>5d}  {r['n_pos']:>6d}  {r['n_neg']:>6d}{marker}")
        zero_fpr = [r for r in sweep_results if r["fpr"] == 0.0]
        if zero_fpr:
            best = max(zero_fpr, key=lambda r: r["tpr"])
            print(f"\n  BEST (zero FPR, highest TPR): align={best['align']}, threshold={best['threshold']:.2f}")
            print(f"    TPR={best['tpr']:.3f}  FPR={best['fpr']:.3f}  TP={best['tp']}  FP={best['fp']}")
        else:
            best = max(sweep_results, key=lambda r: r["tpr"] - r["fpr"] * 10)
            print(f"\n  BEST (penalised for FP): align={best['align']}, threshold={best['threshold']:.2f}")


def run_centroid_mode(args, coreml: CoreMLModel, det: FaceDetector):
    """
    Centroid-based seed refinement:
      Instead of adding more vectors to a pool (which causes FP drift when
      expanded embeddings overlap with similar-looking people), we:
        1. Start with the mean (centroid) of seed embeddings.
        2. Scan positives in confidence-descending order.
        3. When a match scores >= centroid_update_threshold, fold its embedding
           into the running centroid and re-normalise.
        4. After scanning, score ALL photos against the final centroid.

    This produces a single refined vector that represents the "average appearance"
    of the target person across all confirmed high-confidence views — naturally
    regularised, less prone to drift toward look-alikes.

    Sweep configs: vary centroid_update_threshold and max_updates.
    """
    seed_paths = [p.strip() for p in args.seed.split(",")]
    pos_list = load_images(args.positives)
    neg_list = load_images(args.negatives)
    match_threshold: float = args.match_threshold

    if not pos_list:
        print(f"ERROR: No positives in {args.positives}"); return
    if not neg_list:
        print(f"ERROR: No negatives in {args.negatives}"); return

    # Embed seeds → initial centroid
    print(f"\n[Centroid] Embedding {len(seed_paths)} seed(s)…")
    seed_embs: list[np.ndarray] = []
    for sp in seed_paths:
        imgs = load_images(sp)
        if not imgs:
            print(f"  WARNING: no image at {sp}"); continue
        _, img = imgs[0]
        emb = full_fixed_with_embedding(img, det, coreml)
        if emb is not None:
            seed_embs.append(emb)
            print(f"  seed embedded: {Path(sp).name}")
        else:
            print(f"  WARNING: no face in seed {sp}")
    if not seed_embs:
        print("ERROR: no seed embeddings"); return

    initial_centroid = normalize(np.sum(seed_embs, axis=0))

    # Pre-embed all photos (all faces per photo if --all-faces)
    use_all = getattr(args, "all_faces", False)
    mode_tag = "all-faces" if use_all else "largest-face"
    print(f"\n[Centroid] Pre-embedding {len(pos_list)} positives + {len(neg_list)} negatives ({mode_tag})…")
    # Each entry: (path, list[np.ndarray])  — empty list = no face detected
    pos_embedded: list[tuple[str, list[np.ndarray]]] = []
    neg_embedded: list[tuple[str, list[np.ndarray]]] = []
    for path, img in pos_list:
        pos_embedded.append((path, embed_photo(img, det, coreml, use_all)))
    for path, img in neg_list:
        neg_embedded.append((path, embed_photo(img, det, coreml, use_all)))

    pos_detectable = [(p, embs) for p, embs in pos_embedded if embs]
    neg_detectable = [(p, embs) for p, embs in neg_embedded if embs]
    print(f"  positives with face: {len(pos_detectable)}/{len(pos_list)}")
    print(f"  negatives with face: {len(neg_detectable)}/{len(neg_list)}")

    # Baseline scores (initial centroid, no update) — best face per photo
    pool0 = [initial_centroid]
    baseline_pos = [photo_max_sim(embs, pool0) for _, embs in pos_detectable]
    baseline_neg = [photo_max_sim(embs, pool0) for _, embs in neg_detectable]
    baseline_tp  = sum(1 for s in baseline_pos if s >= match_threshold)
    baseline_fp  = sum(1 for s in baseline_neg if s >= match_threshold)
    baseline_tpr = baseline_tp / len(pos_detectable) if pos_detectable else 0.0
    baseline_fpr = baseline_fp / len(neg_detectable) if neg_detectable else 0.0

    # Sweep configs: (centroid_update_threshold, max_updates)
    if args.expansion_sweep:
        configs = [
            (0.40, 3), (0.40, 5), (0.40, 10), (0.40, 20),
            (0.45, 3), (0.45, 5), (0.45, 10), (0.45, 20),
            (0.50, 3), (0.50, 5), (0.50, 10),
            (0.35, 5), (0.35, 10),
        ]
    else:
        configs = [(args.expansion_threshold, args.max_expansion)]

    all_summaries = []

    for update_thresh, max_updates in configs:
        # Sort positives by descending similarity to initial centroid first
        ordered_pos = sorted(pos_detectable,
                             key=lambda pe: photo_max_sim(pe[1], pool0),
                             reverse=True)

        # Running centroid update — use best-matching face embedding from each photo
        centroid_sum = np.sum(seed_embs, axis=0).copy()
        updates = 0

        for path, embs in ordered_pos:
            current_centroid = normalize(centroid_sum)
            sim = photo_max_sim(embs, [current_centroid])
            if sim >= update_thresh and updates < max_updates:
                best_emb = photo_best_emb(embs, [current_centroid])
                if best_emb is not None:
                    centroid_sum += best_emb
                    updates += 1

        final_centroid = normalize(centroid_sum)

        # Score everything against final centroid
        final_pos = [photo_max_sim(embs, [final_centroid]) for _, embs in pos_detectable]
        final_neg = [photo_max_sim(embs, [final_centroid]) for _, embs in neg_detectable]

        exp_tp  = sum(1 for s in final_pos if s >= match_threshold)
        exp_fp  = sum(1 for s in final_neg if s >= match_threshold)
        exp_tpr = exp_tp / len(pos_detectable) if pos_detectable else 0.0
        exp_fpr = exp_fp / len(neg_detectable) if neg_detectable else 0.0

        newly_found = []
        for (path, embs), bs, es in zip(pos_detectable, baseline_pos, final_pos):
            if bs < match_threshold <= es:
                newly_found.append((Path(path).name, bs, es))
        new_fps = []
        for (path, embs), bs, es in zip(neg_detectable, baseline_neg, final_neg):
            if bs < match_threshold <= es:
                new_fps.append((Path(path).name, bs, es))
        newly_lost = []
        for (path, embs), bs, es in zip(pos_detectable, baseline_pos, final_pos):
            if bs >= match_threshold > es:
                newly_lost.append((Path(path).name, bs, es))

        label = f"update_thresh={update_thresh:.2f} max_updates={max_updates}"
        section(f"CENTROID — {label}")
        print(f"  Seeds: {len(seed_embs)} initial  +  {updates} centroid updates")
        print(f"  {'Metric':<30}  {'Baseline':>10}  {'Centroid':>10}  {'Delta':>8}")
        print(f"  {'-'*30}  {'-'*10}  {'-'*10}  {'-'*8}")
        print(f"  {'TPR (detectable)':<30}  {baseline_tpr:>10.3f}  {exp_tpr:>10.3f}  {exp_tpr-baseline_tpr:>+8.3f}")
        print(f"  {'FPR':<30}  {baseline_fpr:>10.3f}  {exp_fpr:>10.3f}  {exp_fpr-baseline_fpr:>+8.3f}")
        print(f"  {'TP':<30}  {baseline_tp:>10d}  {exp_tp:>10d}  {exp_tp-baseline_tp:>+8d}")
        print(f"  {'FP':<30}  {baseline_fp:>10d}  {exp_fp:>10d}  {exp_fp-baseline_fp:>+8d}")
        if newly_found:
            print(f"\n  Newly recovered ({len(newly_found)}):")
            for n, b, e in newly_found: print(f"    {n:<50}  {b:.4f} → {e:.4f}")
        if new_fps:
            print(f"\n  New false positives ({len(new_fps)}):")
            for n, b, e in new_fps: print(f"    {n:<50}  {b:.4f} → {e:.4f}")
        else:
            print("  No new false positives.")
        if newly_lost:
            print(f"\n  Lost positives ({len(newly_lost)}):")
            for n, b, e in newly_lost: print(f"    {n:<50}  {b:.4f} → {e:.4f}")

        all_summaries.append({
            "label": label, "updates": updates,
            "baseline_tpr": baseline_tpr, "exp_tpr": exp_tpr,
            "baseline_fpr": baseline_fpr, "exp_fpr": exp_fpr,
            "delta_tpr": exp_tpr - baseline_tpr, "new_fps": len(new_fps),
            "lost": len(newly_lost),
        })

    if len(all_summaries) > 1:
        section(f"CENTROID SWEEP SUMMARY  (match_threshold={match_threshold:.2f})")
        print(f"  {'Config':<40}  {'Updates':>7}  {'Base TPR':>8}  {'Ctr TPR':>8}  {'ΔTPR':>7}  {'Base FPR':>8}  {'Ctr FPR':>8}  {'New FP':>6}  {'Lost':>5}")
        print(f"  {'-'*40}  {'-'*7}  {'-'*8}  {'-'*8}  {'-'*7}  {'-'*8}  {'-'*8}  {'-'*6}  {'-'*5}")
        for s in all_summaries:
            fp_tag = "  " if s["new_fps"] == 0 else f"+{s['new_fps']}FP"
            print(f"  {s['label']:<40}  {s['updates']:>7d}  {s['baseline_tpr']:>8.3f}  "
                  f"{s['exp_tpr']:>8.3f}  {s['delta_tpr']:>+7.3f}  "
                  f"{s['baseline_fpr']:>8.3f}  {s['exp_fpr']:>8.3f}  {fp_tag:>6}  {s['lost']:>5d}")
        zero_fp = [s for s in all_summaries if s["new_fps"] == 0]
        if zero_fp:
            best = max(zero_fp, key=lambda s: s["delta_tpr"])
            print(f"\n  WINNER (zero FPs, best recall): {best['label']}")
            print(f"    ΔTPR = {best['delta_tpr']:+.3f}  ({best['baseline_tpr']:.3f} → {best['exp_tpr']:.3f})")
        else:
            best = min(all_summaries, key=lambda s: s["new_fps"] - s["delta_tpr"] * 10)
            print(f"\n  BEST tradeoff: {best['label']}")


def run_expansion_mode(args, coreml: CoreMLModel, det: FaceDetector):
    """
    Query-expansion scan:
      1. Embed all seed images → initial pool.
      2. Pre-embed ALL positives + negatives (compute once, reuse).
      3. Run a sequential scan in a chosen order.
         For each photo: score = max cosine_sim to current pool.
         If score >= expansion_threshold AND pool hasn't hit max_expansion limit
         AND (diversity filtering) the embedding is dissimilar enough to existing
         pool members → add embedding to pool.
      4. After the full scan, report TPR/FPR at match_threshold (0.28).
    """
    import random

    seed_paths = [p.strip() for p in args.seed.split(",")]
    pos_list = load_images(args.positives)
    neg_list = load_images(args.negatives)

    if not pos_list:
        print(f"ERROR: No positives in {args.positives}"); return
    if not neg_list:
        print(f"ERROR: No negatives in {args.negatives}"); return

    # --- Embed seeds ---
    print(f"\n[Expansion] Embedding {len(seed_paths)} seed(s)…")
    initial_pool: list[np.ndarray] = []
    for sp in seed_paths:
        imgs = load_images(sp)
        if not imgs:
            print(f"  WARNING: no image found at {sp}"); continue
        _, img = imgs[0]
        emb = full_fixed_with_embedding(img, det, coreml)
        if emb is not None:
            initial_pool.append(emb)
            print(f"  seed embedded: {Path(sp).name}")
        else:
            print(f"  WARNING: no face detected in seed {sp}")
    if not initial_pool:
        print("ERROR: no seed embeddings"); return

    # --- Pre-embed all photos: ALL faces per photo, computed once ---
    # Group shots contain multiple faces. Embedding only the largest face (the old
    # behaviour) could seed the pool with a stranger from a group positive, which then
    # boosts strangers in the negatives → false positives. We keep every face and both
    # match and expand on the best-MATCHING face, exactly like the Swift scan.
    print(f"\n[Expansion] Pre-embedding {len(pos_list)} positives + {len(neg_list)} negatives (all faces)…")
    pos_embedded: list[tuple[str, list[np.ndarray]]] = []
    neg_embedded: list[tuple[str, list[np.ndarray]]] = []

    for path, img in pos_list:
        pos_embedded.append((path, full_fixed_all_faces(img, det, coreml)))
    for path, img in neg_list:
        neg_embedded.append((path, full_fixed_all_faces(img, det, coreml)))

    pos_detectable = [(p, e) for p, e in pos_embedded if e]
    neg_detectable = [(p, e) for p, e in neg_embedded if e]
    pos_no_face    = [p for p, e in pos_embedded if not e]
    neg_no_face    = [p for p, e in neg_embedded if not e]
    print(f"  positives with face: {len(pos_detectable)}/{len(pos_list)}")
    print(f"  negatives with face: {len(neg_detectable)}/{len(neg_list)}")

    def photo_best(face_embs: list[np.ndarray], pool: list[np.ndarray]) -> "tuple[float, np.ndarray | None]":
        """Best-matching face in a photo vs the pool → (score, that face's embedding)."""
        best_score, best_emb = float("-inf"), None
        for emb in face_embs:
            sim = max_sim_to_pool(emb, pool)
            if sim > best_score:
                best_score, best_emb = sim, emb
        return best_score, best_emb

    # Parameters from args
    expansion_threshold: float = args.expansion_threshold
    max_expansion: int          = args.max_expansion
    match_threshold: float      = args.match_threshold
    diversity_min: float        = args.diversity_min
    scan_order: str             = args.scan_order

    # Configs to try — if any were overridden by explicit args, just run one config.
    # We always run the single config specified by args (callers loop externally or
    # pass --expansion-sweep to run a preset grid).
    configs = [(expansion_threshold, max_expansion, diversity_min, scan_order)]

    if args.expansion_sweep:
        # Preset grid of interesting configs
        configs = [
            # (exp_thresh, max_exp, diversity_min, order)
            (0.35, 5,  0.92, "natural"),
            (0.35, 10, 0.92, "natural"),
            (0.40, 5,  0.92, "natural"),
            (0.40, 10, 0.92, "natural"),
            (0.35, 5,  0.85, "natural"),   # tighter diversity
            (0.40, 5,  0.85, "natural"),
            (0.35, 10, 0.92, "conf_desc"), # sort positives by confidence first
            (0.40, 10, 0.92, "conf_desc"),
            (0.28, 10, 0.92, "natural"),   # very low expansion threshold
            (0.30, 10, 0.92, "natural"),
        ]

    all_summaries = []

    for cfg_et, cfg_me, cfg_div, cfg_order in configs:

        # --- Baseline (no expansion, single pass) ---
        baseline_pos_scores = [photo_best(embs, initial_pool)[0] for _, embs in pos_detectable]
        baseline_neg_scores = [photo_best(embs, initial_pool)[0] for _, embs in neg_detectable]

        baseline_tp  = sum(1 for s in baseline_pos_scores if s >= match_threshold)
        baseline_fp  = sum(1 for s in baseline_neg_scores if s >= match_threshold)
        baseline_tpr = baseline_tp / len(pos_detectable) if pos_detectable else 0.0
        baseline_fpr = baseline_fp / len(neg_detectable) if neg_detectable else 0.0
        # TPR over ALL positives (including no-face ones = always missed)
        baseline_tpr_all = baseline_tp / len(pos_list) if pos_list else 0.0

        # --- Expansion scan ---
        pool = list(initial_pool)  # fresh copy per config

        # Determine scan order for positives (we only expand from positives)
        if cfg_order == "conf_desc":
            # Sort positives by descending best-face similarity to seed before scanning,
            # so high-confidence matches expand the pool first.
            ordered_pos = sorted(pos_detectable,
                                 key=lambda pe: photo_best(pe[1], initial_pool)[0],
                                 reverse=True)
        elif cfg_order == "random":
            ordered_pos = list(pos_detectable)
            random.shuffle(ordered_pos)
        else:  # "natural" = filesystem/sorted order
            ordered_pos = list(pos_detectable)

        expanded_count = 0

        # First pass: sequential scan, expanding the pool with the best-MATCHING face
        # of each confident positive (not the largest face).
        for path, embs in ordered_pos:
            sim, best_emb = photo_best(embs, pool)
            remaining_slots = cfg_me - expanded_count
            if remaining_slots > 0 and sim >= cfg_et and best_emb is not None:
                if is_diverse_enough(best_emb, pool, cfg_div):
                    pool.append(best_emb)
                    expanded_count += 1

        # Second pass: re-score with the fully-expanded pool (so even early-scanned
        # photos benefit from later-added seeds). Score = best face vs final pool.
        final_pos_scores = [photo_best(embs, pool)[0] for _, embs in pos_detectable]
        final_neg_scores = [photo_best(embs, pool)[0] for _, embs in neg_detectable]

        exp_tp  = sum(1 for s in final_pos_scores if s >= match_threshold)
        exp_fp  = sum(1 for s in final_neg_scores if s >= match_threshold)
        exp_tpr = exp_tp / len(pos_detectable) if pos_detectable else 0.0
        exp_fpr = exp_fp / len(neg_detectable) if neg_detectable else 0.0
        exp_tpr_all = exp_tp / len(pos_list) if pos_list else 0.0

        recall_gain = exp_tpr - baseline_tpr

        label = (f"exp_thresh={cfg_et:.2f} max={cfg_me} "
                 f"div={cfg_div:.2f} order={cfg_order}")
        section(f"EXPANSION — {label}")
        print(f"  Seeds: {len(initial_pool)} initial  +  {expanded_count} expanded  =  {len(pool)} total")
        print(f"  (max_expansion cap={cfg_me}, diversity_min={cfg_div})")
        print()
        print(f"  {'Metric':<30}  {'Baseline':>10}  {'Expansion':>10}  {'Delta':>8}")
        print(f"  {'-'*30}  {'-'*10}  {'-'*10}  {'-'*8}")
        print(f"  {'TPR (detectable only)':<30}  {baseline_tpr:>10.3f}  {exp_tpr:>10.3f}  {exp_tpr-baseline_tpr:>+8.3f}")
        print(f"  {'TPR (all positives)':<30}  {baseline_tpr_all:>10.3f}  {exp_tpr_all:>10.3f}  {exp_tpr_all-baseline_tpr_all:>+8.3f}")
        print(f"  {'FPR':<30}  {baseline_fpr:>10.3f}  {exp_fpr:>10.3f}  {exp_fpr-baseline_fpr:>+8.3f}")
        print(f"  {'TP  (detectable)':<30}  {baseline_tp:>10d}  {exp_tp:>10d}  {exp_tp-baseline_tp:>+8d}")
        print(f"  {'FP':<30}  {baseline_fp:>10d}  {exp_fp:>10d}  {exp_fp-baseline_fp:>+8d}")
        print(f"  {'No-face positives':<30}  {len(pos_no_face):>10d}  {'(same)':>10}  {'':>8}")
        print()

        # Show which positives were newly found by expansion
        newly_found = []
        for (path, _embs), base_sim, exp_sim in zip(
                pos_detectable, baseline_pos_scores, final_pos_scores):
            was_tp = base_sim >= match_threshold
            now_tp = exp_sim >= match_threshold
            if now_tp and not was_tp:
                newly_found.append((Path(path).name, base_sim, exp_sim))
        if newly_found:
            print(f"  Newly recovered positives ({len(newly_found)}):")
            for name, bs, es in newly_found:
                print(f"    {name:<50}  baseline={bs:.4f} → expanded={es:.4f}")
        else:
            print("  No new positives recovered by expansion.")

        # Show any new false positives
        new_fps = []
        for (path, _embs), base_sim, exp_sim in zip(
                neg_detectable, baseline_neg_scores, final_neg_scores):
            was_fp = base_sim >= match_threshold
            now_fp = exp_sim >= match_threshold
            if now_fp and not was_fp:
                new_fps.append((Path(path).name, base_sim, exp_sim))
        if new_fps:
            print(f"\n  New false positives introduced ({len(new_fps)}):")
            for name, bs, es in new_fps:
                print(f"    {name:<50}  baseline={bs:.4f} → expanded={es:.4f}")
        else:
            print("  No new false positives introduced.")

        all_summaries.append({
            "label": label,
            "expanded_count": expanded_count,
            "baseline_tpr": baseline_tpr,
            "exp_tpr": exp_tpr,
            "baseline_fpr": baseline_fpr,
            "exp_fpr": exp_fpr,
            "recall_gain": recall_gain,
            "new_fps": len(new_fps),
        })

    # --- Grand summary across all configs ---
    if len(all_summaries) > 1:
        section("EXPANSION SWEEP SUMMARY  (match_threshold={:.2f})".format(match_threshold))
        print(f"  {'Config':<55}  {'Expanded':>8}  {'Base TPR':>8}  {'Exp TPR':>8}  {'ΔTPR':>7}  {'Base FPR':>8}  {'Exp FPR':>8}  {'New FP':>6}")
        print(f"  {'-'*55}  {'-'*8}  {'-'*8}  {'-'*8}  {'-'*7}  {'-'*8}  {'-'*8}  {'-'*6}")
        for s in all_summaries:
            clean = "  " if s["new_fps"] == 0 else f"+{s['new_fps']}FP"
            print(f"  {s['label']:<55}  {s['expanded_count']:>8d}  {s['baseline_tpr']:>8.3f}  "
                  f"{s['exp_tpr']:>8.3f}  {s['recall_gain']:>+7.3f}  "
                  f"{s['baseline_fpr']:>8.3f}  {s['exp_fpr']:>8.3f}  {clean:>6}")

        # Highlight best: max recall gain with zero new FPs
        zero_fp = [s for s in all_summaries if s["new_fps"] == 0]
        if zero_fp:
            best = max(zero_fp, key=lambda s: s["recall_gain"])
            print(f"\n  WINNER (zero new FPs, best recall gain): {best['label']}")
            print(f"    ΔTPR = {best['recall_gain']:+.3f}  ({best['baseline_tpr']:.3f} → {best['exp_tpr']:.3f})")
        else:
            best = max(all_summaries, key=lambda s: s["recall_gain"] - s["new_fps"] * 0.1)
            print(f"\n  BEST (penalised for new FPs): {best['label']}")


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="CoreML face pipeline comparison harness",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dataset", choices=["lfw"],
                      help="Use LFW pairs (auto-downloads pre-aligned 112×112 chips)")
    mode.add_argument("--seed", help="Seed image path (real-photo mode). Comma-separate multiple paths.")
    parser.add_argument("--positives", help="Same-person image dir (real-photo mode)")
    parser.add_argument("--negatives", help="Different-person image dir (real-photo mode)")
    parser.add_argument("--save-chips", action="store_true",
                        help=f"Save aligned chips to {DEBUG_DIR}/")
    parser.add_argument("--skip-broken",    action="store_true")
    parser.add_argument("--skip-fixed",     action="store_true")
    parser.add_argument("--skip-reference", action="store_true")
    parser.add_argument("--mlpackage", default=str(MLPACKAGE_PATH))
    # Query-expansion flags
    parser.add_argument("--auto-seed", action="store_true",
                        help="Auto-pick seeds from single-face photos in --positives dir")
    parser.add_argument("--max-seeds", type=int, default=3,
                        help="Max seeds to auto-pick (default 3)")
    parser.add_argument("--centroid", action="store_true",
                        help="Run centroid-based seed refinement mode")
    parser.add_argument("--expansion", action="store_true",
                        help="Run query-expansion mode instead of standard seed mode")
    parser.add_argument("--expansion-sweep", action="store_true",
                        help="With --expansion: run a preset grid of configs and compare")
    parser.add_argument("--expansion-threshold", type=float, default=0.35,
                        help="Cosine sim threshold to admit a match into the seed pool (default 0.35)")
    parser.add_argument("--max-expansion", type=int, default=10,
                        help="Max number of embeddings to add to seed pool (default 10)")
    parser.add_argument("--match-threshold", type=float, default=0.28,
                        help="Cosine threshold used for final TP/FP classification (default 0.28)")
    parser.add_argument("--diversity-min", type=float, default=0.92,
                        help="Don't add embedding if it's already ≥ this similar to a pool member (default 0.92)")
    parser.add_argument("--scan-order", choices=["natural", "conf_desc", "random"], default="natural",
                        help="Order in which photos are scanned for expansion (default: natural/filesystem)")
    parser.add_argument("--all-faces", action="store_true",
                        help="Check ALL detected faces per photo (like Swift), not just the largest face")
    parser.add_argument("--align", choices=["2pt", "5pt", "hybrid"], default="2pt",
                        help="Alignment mode for --auto-seed: 2pt=eye-only, 5pt=Umeyama, hybrid=5pt+2pt fallback (default: 2pt)")
    parser.add_argument("--align-sweep", action="store_true",
                        help="With --auto-seed: run all align modes × thresholds [0.26,0.27,0.28] and print summary grid")
    args = parser.parse_args()

    if args.dataset is None and args.seed is None and not args.auto_seed:
        parser.print_help()
        print("\nERROR: specify --dataset lfw  OR  --seed  OR  --auto-seed  with --positives and --negatives")
        sys.exit(1)
    if (args.seed or args.auto_seed) and (not args.positives or not args.negatives):
        print("ERROR: --seed / --auto-seed requires --positives and --negatives")
        sys.exit(1)

    mlpkg = Path(args.mlpackage)
    if not mlpkg.exists():
        print(f"ERROR: MobileFaceNet.mlpackage not found at {mlpkg}"); sys.exit(1)

    coreml = CoreMLModel(mlpkg)

    # Load reference insightface recognizer (ONNX, for chip embedding)
    ref_recognizer = None
    ref_app = None
    if not args.skip_reference:
        try:
            import onnxruntime as ort
            from insightface.app import FaceAnalysis
            import os
            model_dir = Path.home() / ".insightface" / "models" / "buffalo_sc"
            rec_path = model_dir / "w600k_mbf.onnx"
            if rec_path.exists():
                sess = ort.InferenceSession(str(rec_path),
                                            providers=["CoreMLExecutionProvider", "CPUExecutionProvider"])
                class _Rec:
                    def __init__(self, session): self._sess = session
                    def get_feat(self, inp):
                        name = self._sess.get_inputs()[0].name
                        return self._sess.run(None, {name: inp})[0]
                ref_recognizer = _Rec(sess)
                print(f"[Reference] ONNX recognizer loaded ({rec_path.name})")
            else:
                print(f"[Reference] ONNX model not found at {rec_path}; reference disabled")
        except Exception as e:
            print(f"[Reference] Disabled: {e}")

        if args.seed:  # real-photo mode needs full insightface app
            try:
                from insightface.app import FaceAnalysis
                ref_app = FaceAnalysis(name="buffalo_sc")
                ref_app.prepare(ctx_id=-1)
            except Exception as e:
                print(f"[Reference] Full app disabled: {e}")

    if args.save_chips:
        DEBUG_DIR.mkdir(parents=True, exist_ok=True)

    if args.dataset == "lfw":
        run_lfw_mode(args, coreml, ref_recognizer)
    elif args.auto_seed:
        det = FaceDetector()
        run_auto_seed_mode(args, coreml, det)
    elif args.centroid:
        det = FaceDetector()
        run_centroid_mode(args, coreml, det)
    elif args.expansion:
        det = FaceDetector()
        run_expansion_mode(args, coreml, det)
    else:
        det = FaceDetector()
        run_seed_mode(args, coreml, det, ref_app)

    print("\nDone.")


if __name__ == "__main__":
    main()
