#!/usr/bin/env python3
"""Embed the Vision-aligned chips (the app's exact 2-pt alignment) with every recogniser."""
import json, sys
from pathlib import Path
import numpy as np, cv2
REPO = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent / "out"; OUT.mkdir(exist_ok=True)
sys.path.insert(0, str(REPO / "scripts"))
from test_coreml_pipeline import CoreMLModel  # noqa
from insightface.model_zoo import get_model
MODELS_DIR = Path.home() / ".insightface" / "models"
recs = {}
for name, rel in [("mbf", "buffalo_sc/w600k_mbf.onnx"), ("r50", "buffalo_l/w600k_r50.onnx"), ("r100", "antelopev2/glintr100.onnx")]:
    m = get_model(str(MODELS_DIR / rel), providers=["CPUExecutionProvider"]); m.prepare(ctx_id=-1); recs[name] = m
coreml = CoreMLModel(REPO / "angryFriend" / "FaceNetR50.mlpackage")  # the shipped model
faces = [json.loads(l) for l in (OUT / "vision_faces.jsonl").read_text().splitlines() if l.strip()]
keep, embs = [], {k: [] for k in list(recs) + ["app"]}
for f in faces:
    if not f["chip"]: continue
    chip = cv2.imread(str(OUT / "vision_chips" / f"{f['stem']}.png"))
    if chip is None or chip.shape[:2] != (112, 112): continue
    keep.append(f)
    for m, rec in recs.items():
        e = rec.get_feat(chip).flatten().astype(np.float32); embs[m].append(e / np.linalg.norm(e))
    e = coreml.embed(chip); embs["app"].append(e if e is not None else np.zeros(512, np.float32))
np.savez_compressed(OUT / "vision_embeddings.npz", **{k: np.stack(v) for k, v in embs.items()})
(OUT / "vision_faces_kept.json").write_text(json.dumps(keep))
print("embedded", len(keep), "of", len(faces), "vision faces")
