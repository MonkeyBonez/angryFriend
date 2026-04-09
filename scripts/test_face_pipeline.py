#!/usr/bin/env python3
"""
test_face_pipeline.py — Measure face recognition pipeline quality.

Usage:
    python3 scripts/test_face_pipeline.py \
        --seed path/to/seed.jpg \
        --positives path/to/same_person/ \
        --negatives path/to/different_people/

    python3 scripts/test_face_pipeline.py \
        --seed seed.jpg \
        --positives pos/ \
        --negatives neg/ \
        --model path/to/w600k_mbf.onnx

Dependencies:
    pip install insightface onnxruntime opencv-python numpy

The script runs two pipelines:
  1. insightface reference (buffalo_sc model, downloads automatically)
  2. Manual ONNX pipeline replicating our iOS code (same ArcFace template alignment)

Outputs:
  - Per-image similarity scores for positives and negatives
  - Threshold sweep: TPR / FPR / F1 at each threshold
  - Recommended threshold based on best F1
"""

import argparse
import os
import sys
import numpy as np
import cv2
from pathlib import Path


# ─── ArcFace constants (must match iOS FaceMatchingService.swift) ────────────

ARCFACE_DST = np.array([
    [38.2946, 51.6963],  # left eye  (image left  = subject's right)
    [73.5318, 51.5014],  # right eye (image right = subject's left)
    [56.0252, 71.7366],  # nose tip
    [41.5493, 92.3655],  # left mouth corner
    [70.7299, 92.2041],  # right mouth corner
], dtype=np.float32)

OUTPUT_SIZE = (112, 112)


# ─── Umeyama similarity transform (replicates Swift estimateSimilarity) ──────

def umeyama_similarity(src: np.ndarray, dst: np.ndarray) -> np.ndarray:
    """
    Estimate 2-D similarity transform (scale + rotation + translation)
    mapping src → dst via least-squares (Umeyama 1991).

    Returns a 2×3 affine matrix compatible with cv2.warpAffine.
    """
    assert src.shape == dst.shape and src.shape[1] == 2
    n = len(src)

    mean_src = src.mean(axis=0)
    mean_dst = dst.mean(axis=0)

    src_d = src - mean_src
    dst_d = dst - mean_dst

    var_src = np.sum(src_d ** 2) / n
    if var_src < 1e-10:
        raise ValueError("Source points are degenerate (zero variance)")

    # a = s*cos θ, b = s*sin θ
    sum_a = np.sum(dst_d[:, 0] * src_d[:, 0] + dst_d[:, 1] * src_d[:, 1])
    sum_b = np.sum(dst_d[:, 1] * src_d[:, 0] - dst_d[:, 0] * src_d[:, 1])
    a = sum_a / (n * var_src)
    b = sum_b / (n * var_src)

    tx = mean_dst[0] - a * mean_src[0] + b * mean_src[1]
    ty = mean_dst[1] - b * mean_src[0] - a * mean_src[1]

    return np.array([[a, -b, tx], [b, a, ty]], dtype=np.float32)


# ─── Manual pipeline (replicates iOS code) ───────────────────────────────────

class ManualPipeline:
    """Replicates the iOS FaceMatchingService alignment using MediaPipe or dlib,
    then runs inference via ONNX Runtime."""

    def __init__(self, onnx_model_path: str | None = None):
        self.ort_session = None
        if onnx_model_path:
            try:
                import onnxruntime as ort
                self.ort_session = ort.InferenceSession(
                    onnx_model_path,
                    providers=["CoreMLExecutionProvider", "CPUExecutionProvider"],
                )
                print(f"[Manual] Loaded ONNX model: {onnx_model_path}")
            except Exception as e:
                print(f"[Manual] Failed to load ONNX model: {e}")

        # Use insightface's face detector for landmark extraction
        try:
            from insightface.app import FaceAnalysis
            self._detector = FaceAnalysis(name="buffalo_sc", allowed_modules=["detection", "landmark_2d_106"])
            self._detector.prepare(ctx_id=-1)
        except Exception:
            self._detector = None
            print("[Manual] insightface not available for landmark detection; manual pipeline disabled")

    def _get_landmarks_5pt(self, img_bgr: np.ndarray):
        """Returns 5×2 array of landmark coordinates (image pixel space) or None."""
        if self._detector is None:
            return None
        faces = self._detector.get(img_bgr)
        if not faces:
            return None
        face = faces[0]
        # insightface kps: [left_eye, right_eye, nose, left_mouth, right_mouth]
        # (viewer perspective: left_eye = image left = subject's right)
        kps = face.kps  # shape (5, 2)
        return kps.astype(np.float32)

    def align(self, img_bgr: np.ndarray) -> np.ndarray | None:
        """Align face chip to 112×112 using 5-point ArcFace template."""
        kps = self._get_landmarks_5pt(img_bgr)
        if kps is None:
            return None
        try:
            M = umeyama_similarity(kps, ARCFACE_DST)
            chip = cv2.warpAffine(img_bgr, M, OUTPUT_SIZE, flags=cv2.INTER_LINEAR)
            return chip
        except ValueError:
            return None

    def embed(self, img_bgr: np.ndarray) -> np.ndarray | None:
        """Extract 512-dim L2-normalised embedding from a BGR image."""
        chip = self.align(img_bgr)
        if chip is None:
            return None

        if self.ort_session is None:
            return None

        # Preprocess: BGR → RGB, float32, [-1, 1] (scale 1/127.5 − 1)
        rgb = cv2.cvtColor(chip, cv2.COLOR_BGR2RGB).astype(np.float32)
        rgb = (rgb / 127.5) - 1.0
        inp = rgb.transpose(2, 0, 1)[np.newaxis]  # NCHW

        input_name = self.ort_session.get_inputs()[0].name
        output = self.ort_session.run(None, {input_name: inp})[0][0]
        norm = np.linalg.norm(output)
        if norm == 0:
            return None
        return output / norm


# ─── insightface reference pipeline ─────────────────────────────────────────

class InsightFacePipeline:
    def __init__(self):
        try:
            from insightface.app import FaceAnalysis
            self.app = FaceAnalysis(name="buffalo_sc")
            self.app.prepare(ctx_id=-1)
            print("[Reference] Loaded insightface buffalo_sc")
        except ImportError:
            raise RuntimeError("insightface not installed. Run: pip install insightface")

    def embed(self, img_bgr: np.ndarray) -> np.ndarray | None:
        faces = self.app.get(img_bgr)
        if not faces:
            return None
        # Return embedding of the largest face
        face = max(faces, key=lambda f: f.bbox[2] * f.bbox[3])
        emb = face.embedding
        norm = np.linalg.norm(emb)
        return emb / norm if norm > 0 else None

    def quality(self, img_bgr: np.ndarray) -> float:
        """Face detection confidence as a proxy for quality."""
        faces = self.app.get(img_bgr)
        if not faces:
            return 0.0
        return float(max(faces, key=lambda f: f.det_score).det_score)


# ─── Evaluation helpers ───────────────────────────────────────────────────────

def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b))


def load_images(path: str) -> list[tuple[str, np.ndarray]]:
    """Load all images from a file or directory. Returns [(path, bgr_array)]."""
    p = Path(path)
    if p.is_file():
        img = cv2.imread(str(p))
        return [(str(p), img)] if img is not None else []
    elif p.is_dir():
        results = []
        for ext in ("*.jpg", "*.jpeg", "*.png", "*.heic", "*.HEIC"):
            for f in sorted(p.glob(ext)):
                img = cv2.imread(str(f))
                if img is not None:
                    results.append((str(f), img))
        return results
    return []


def threshold_sweep(pos_scores: list[float], neg_scores: list[float]):
    """Print TPR / FPR / F1 across threshold range."""
    all_scores = sorted(set(pos_scores + neg_scores + [0.0, 0.5, 1.0]))
    thresholds = np.linspace(min(all_scores), max(all_scores), 100)

    best_f1 = 0.0
    best_thresh = 0.0

    print(f"\n{'Threshold':>10}  {'TPR':>6}  {'FPR':>6}  {'F1':>6}  {'TP':>4}  {'FP':>4}  {'FN':>4}  {'TN':>4}")
    print("-" * 65)

    for t in thresholds:
        tp = sum(1 for s in pos_scores if s >= t)
        fn = sum(1 for s in pos_scores if s < t)
        fp = sum(1 for s in neg_scores if s >= t)
        tn = sum(1 for s in neg_scores if s < t)

        tpr = tp / (tp + fn) if (tp + fn) > 0 else 0.0
        fpr = fp / (fp + tn) if (fp + tn) > 0 else 0.0
        prec = tp / (tp + fp) if (tp + fp) > 0 else 0.0
        f1 = 2 * prec * tpr / (prec + tpr) if (prec + tpr) > 0 else 0.0

        if f1 > best_f1:
            best_f1 = f1
            best_thresh = t

        # Only print interesting rows (near thresholds or step every ~10)
        if abs(tpr - 1.0) < 0.05 or abs(fpr) < 0.05 or f1 == best_f1:
            print(f"{t:>10.4f}  {tpr:>6.3f}  {fpr:>6.3f}  {f1:>6.3f}  {tp:>4}  {fp:>4}  {fn:>4}  {tn:>4}")

    print(f"\n  → Best F1={best_f1:.3f} at threshold={best_thresh:.4f}")
    return best_thresh, best_f1


def run_pipeline(name: str, pipeline, seed_img, pos_imgs, neg_imgs):
    print(f"\n{'='*60}")
    print(f"  Pipeline: {name}")
    print(f"{'='*60}")

    seed_emb = pipeline.embed(seed_img)
    if seed_emb is None:
        print("  ERROR: Could not extract seed embedding.")
        return

    print(f"\n  Seed embedding norm (post-normalize): {np.linalg.norm(seed_emb):.4f}")

    pos_scores = []
    print(f"\n  Positives ({len(pos_imgs)} images):")
    for path, img in pos_imgs:
        emb = pipeline.embed(img)
        if emb is None:
            print(f"    {Path(path).name:<40}  NO FACE")
            continue
        sim = cosine_similarity(seed_emb, emb)
        pos_scores.append(sim)
        h, w = img.shape[:2]
        print(f"    {Path(path).name:<40}  sim={sim:.4f}  size={w}×{h}")

    neg_scores = []
    print(f"\n  Negatives ({len(neg_imgs)} images):")
    for path, img in neg_imgs:
        emb = pipeline.embed(img)
        if emb is None:
            print(f"    {Path(path).name:<40}  NO FACE")
            continue
        sim = cosine_similarity(seed_emb, emb)
        neg_scores.append(sim)
        print(f"    {Path(path).name:<40}  sim={sim:.4f}")

    if not pos_scores or not neg_scores:
        print("\n  Not enough data for threshold analysis.")
        return

    print(f"\n  Positive scores: mean={np.mean(pos_scores):.4f}  min={min(pos_scores):.4f}  max={max(pos_scores):.4f}")
    print(f"  Negative scores: mean={np.mean(neg_scores):.4f}  min={min(neg_scores):.4f}  max={max(neg_scores):.4f}")
    print(f"  Separation gap:  {np.mean(pos_scores) - np.mean(neg_scores):.4f}")

    threshold_sweep(pos_scores, neg_scores)


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Test face recognition pipeline quality")
    parser.add_argument("--seed", required=True, help="Seed image (path to file)")
    parser.add_argument("--positives", required=True, help="Directory or file of same-person photos")
    parser.add_argument("--negatives", required=True, help="Directory or file of different-person photos")
    parser.add_argument("--model", default=None, help="Path to w600k_mbf.onnx for manual pipeline")
    parser.add_argument("--skip-reference", action="store_true", help="Skip insightface reference pipeline")
    parser.add_argument("--skip-manual", action="store_true", help="Skip manual ONNX pipeline")
    args = parser.parse_args()

    # Load images
    seed_imgs = load_images(args.seed)
    if not seed_imgs:
        print(f"ERROR: Could not load seed image: {args.seed}")
        sys.exit(1)
    _, seed_img = seed_imgs[0]

    pos_imgs = load_images(args.positives)
    neg_imgs = load_images(args.negatives)

    if not pos_imgs:
        print(f"ERROR: No positive images found in: {args.positives}")
        sys.exit(1)
    if not neg_imgs:
        print(f"ERROR: No negative images found in: {args.negatives}")
        sys.exit(1)

    print(f"Seed: {args.seed}")
    print(f"Positives: {len(pos_imgs)} images from {args.positives}")
    print(f"Negatives: {len(neg_imgs)} images from {args.negatives}")

    # Reference pipeline
    if not args.skip_reference:
        try:
            ref = InsightFacePipeline()
            run_pipeline("insightface buffalo_sc (REFERENCE)", ref, seed_img, pos_imgs, neg_imgs)
        except RuntimeError as e:
            print(f"\n[Reference] Skipped: {e}")

    # Manual pipeline (replicates iOS code)
    if not args.skip_manual:
        manual = ManualPipeline(onnx_model_path=args.model)
        if manual.ort_session is not None or manual._detector is not None:
            run_pipeline("Manual ONNX (iOS replica)", manual, seed_img, pos_imgs, neg_imgs)
        else:
            print("\n[Manual] Skipped: no ONNX model provided and insightface unavailable.")
            print("  Provide --model path/to/w600k_mbf.onnx to enable the manual pipeline.")

    print("\nDone.")


if __name__ == "__main__":
    main()
