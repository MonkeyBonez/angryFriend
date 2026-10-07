#!/usr/bin/env python3
"""5-point ArcFace alignment from Vision's own landmarks (eye centroids, nose tip, mouth corners)."""
import json, sys
from pathlib import Path
import numpy as np, cv2
REPO = Path(__file__).resolve().parents[2]; OUT = Path(__file__).resolve().parent / "out"; OUT.mkdir(exist_ok=True)
sys.path.insert(0, str(REPO / "scripts"))
from test_coreml_pipeline import CoreMLModel, umeyama_similarity, ARCFACE_DST, OUTPUT_SIZE  # noqa
from insightface.model_zoo import get_model
MD = Path.home() / ".insightface" / "models"
recs = {}
for name, rel in [("mbf", "buffalo_sc/w600k_mbf.onnx"), ("r50", "buffalo_l/w600k_r50.onnx")]:
    m = get_model(str(MD / rel), providers=["CPUExecutionProvider"]); m.prepare(ctx_id=-1); recs[name] = m
coreml = CoreMLModel(REPO / "angryFriend" / "FaceNetR50.mlpackage")  # the shipped model
kept = json.loads((OUT / "vision_faces_kept.json").read_text())
new_by_file = {}
for l in (OUT / "vision_faces5.jsonl").read_text().splitlines():
    if l.strip(): f = json.loads(l); new_by_file.setdefault(f["file"], []).append(f)
def iou(a, b):
    ix = max(0, min(a["x2"], b["x2"]) - max(a["x1"], b["x1"])); iy = max(0, min(a["y2"], b["y2"]) - max(a["y1"], b["y1"])); inter = ix * iy
    return inter / ((a["x2"] - a["x1"]) * (a["y2"] - a["y1"]) + (b["x2"] - b["x1"]) * (b["y2"] - b["y1"]) - inter + 1e-9)
def pts_for(f):
    best = max(new_by_file.get(f["file"], []), key=lambda g: iou(f, g), default=None)
    return best["pts"] if best is not None and iou(f, best) > 0.8 else {}

def five(p, variant):
    eyes = sorted([p["leftEye"], p["rightEye"]], key=lambda q: q[0])
    lips = p["outerLips"]; mouth = sorted([min(lips, key=lambda q: q[0]), max(lips, key=lambda q: q[0])], key=lambda q: q[0])
    if variant == "a": nose = p["noseCrest"][-1]
    else: nose = np.mean(np.array(p["nose"]), 0).tolist()
    return np.array(eyes + [nose] + mouth, np.float32)

variants = ["a", "b"]
embs = {f"{m}_vis5{v}": [] for m in list(recs) + ["app"] for v in variants}
have = {v: [] for v in variants}
imgs = {}
sheet = []
for k, f in enumerate(kept):
    p = pts_for(f)
    img = imgs.get(f["file"])
    if img is None: img = imgs[f["file"]] = cv2.imread(str(OUT / "work" / f["file"]))
    for v in variants:
        ok = bool(p.get("leftEye")) and bool(p.get("rightEye")) and len(p.get("outerLips", [])) >= 2 and len(p.get("noseCrest", [])) >= 1 and len(p.get("nose", [])) >= 1
        chip = None
        if ok:
            try: chip = cv2.warpAffine(img, umeyama_similarity(five(p, v), ARCFACE_DST), OUTPUT_SIZE, flags=cv2.INTER_LINEAR)
            except ValueError: chip = None
        have[v].append(chip is not None)
        if chip is None:
            for m in list(recs) + ["app"]: embs[f"{m}_vis5{v}"].append(np.zeros(512, np.float32))
            continue
        if v == "a" and len(sheet) < 36: sheet.append(chip)
        for m, rec in recs.items():
            e = rec.get_feat(chip).flatten().astype(np.float32); embs[f"{m}_vis5{v}"].append(e / np.linalg.norm(e))
        e = coreml.embed(chip); embs[f"app_vis5{v}"].append(e if e is not None else np.zeros(512, np.float32))
    if len(imgs) > 40: imgs.clear()
np.savez_compressed(OUT / "vision5_embeddings.npz", **{k: np.stack(x) for k, x in embs.items()}, **{f"have_{v}": np.array(have[v]) for v in variants})
rows = [np.hstack(sheet[i:i + 12]) for i in range(0, len(sheet) - len(sheet) % 12, 12)]
if rows: cv2.imwrite(str(OUT / "sheet_vision5a.jpg"), np.vstack(rows))
print("done", {v: int(sum(have[v])) for v in variants}, "of", len(kept))
