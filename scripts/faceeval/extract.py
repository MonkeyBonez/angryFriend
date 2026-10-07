#!/usr/bin/env python3
"""Stage 1: detect every face in the test sets at the app's 1024px working size,
cut 2-pt and 5-pt aligned chips, embed with several recognisers, cache to disk."""
import sys, json, time
from pathlib import Path
import numpy as np, cv2
REPO = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent / "out"; OUT.mkdir(exist_ok=True)
sys.path.insert(0, str(REPO / "scripts"))
from test_coreml_pipeline import load_images, align_2pt, align_5pt, CoreMLModel  # noqa

PEOPLE = sorted(p.name for p in (REPO / "PhotosOfFriends").iterdir() if p.is_dir())
SETS = [("friend", p, REPO / "PhotosOfFriends" / p) for p in PEOPLE] + \
       [("random", p, REPO / "PhotosOfRandoms" / p) for p in PEOPLE]
MODELS_DIR = Path.home() / ".insightface" / "models"
WORK_LONG_SIDE = 1024  # the app loads photos at 1024x1024 aspect-fit

def fit1024(img):
    h, w = img.shape[:2]
    s = WORK_LONG_SIDE / max(h, w)
    if s >= 1: return img
    return cv2.resize(img, (round(w * s), round(h * s)), interpolation=cv2.INTER_AREA)

def main():
    from insightface.model_zoo import get_model
    det = get_model(str(MODELS_DIR / "buffalo_l" / "det_10g.onnx"), providers=["CPUExecutionProvider"])
    det.prepare(ctx_id=-1, input_size=(1024, 1024), det_thresh=0.5)
    recs = {}
    for name, rel in [("mbf", "buffalo_sc/w600k_mbf.onnx"), ("r50", "buffalo_l/w600k_r50.onnx"), ("r100", "antelopev2/glintr100.onnx")]:
        p = MODELS_DIR / rel
        if p.exists():
            m = get_model(str(p), providers=["CPUExecutionProvider"]); m.prepare(ctx_id=-1); recs[name] = m
        else:
            print("missing", p)
    coreml = CoreMLModel(REPO / "angryFriend" / "FaceNetR50.mlpackage")  # the shipped model
    aligns = {"2pt": align_2pt, "5pt": align_5pt}
    chips_dir = OUT / "chips"; chips_dir.mkdir(exist_ok=True)

    meta, embs = [], {f"{m}_{a}": [] for m in list(recs) + ["app"] for a in aligns}
    t0 = time.time(); n_img = 0
    for setname, person, folder in SETS:
        images = load_images(str(folder))
        print(f"[{setname}/{person}] {len(images)} images", flush=True)
        for path, img0 in images:
            img = fit1024(img0); n_img += 1
            bboxes, kpss = det.detect(img, max_num=0, metric="default")
            for i, (bb, kps) in enumerate(zip(bboxes, kpss)):
                x1, y1, x2, y2, score = bb
                chips = {a: fn(img, kps.astype(np.float32)) for a, fn in aligns.items()}
                if any(c is None for c in chips.values()): continue
                gray = cv2.cvtColor(chips["5pt"], cv2.COLOR_BGR2GRAY)
                blur = float(cv2.Laplacian(gray, cv2.CV_64F).var())
                # eye-line asymmetry as a crude yaw proxy: nose x relative to the eyes
                le, re, nose = kps[0], kps[1], kps[2]
                yaw = float((nose[0] - (le[0] + re[0]) / 2) / max(1e-3, abs(re[0] - le[0])))
                stem = f"{setname}_{person}_{Path(path).stem}_{i}"
                cv2.imwrite(str(chips_dir / f"{stem}.jpg"), chips["5pt"], [cv2.IMWRITE_JPEG_QUALITY, 92])
                meta.append(dict(set=setname, person=person, file=Path(path).name, face=i, stem=stem,
                                 x1=float(x1), y1=float(y1), x2=float(x2), y2=float(y2), score=float(score),
                                 face_w=float(x2 - x1), img_w=img.shape[1], img_h=img.shape[0], blur=blur, yaw=yaw,
                                 n_faces=int(len(bboxes))))
                for a, chip in chips.items():
                    for m, rec in recs.items():
                        e = rec.get_feat(chip).flatten().astype(np.float32); embs[f"{m}_{a}"].append(e / np.linalg.norm(e))
                    e = coreml.embed(chip); embs[f"app_{a}"].append(e if e is not None else np.zeros(512, np.float32))
            if n_img % 25 == 0:
                print(f"  {n_img} images, {len(meta)} faces, {time.time() - t0:.0f}s", flush=True)
    np.savez_compressed(OUT / "embeddings.npz", **{k: np.stack(v) if v else np.zeros((0, 512), np.float32) for k, v in embs.items()})
    (OUT / "faces.json").write_text(json.dumps(meta))
    print(f"done: {n_img} images, {len(meta)} faces in {time.time() - t0:.0f}s")

if __name__ == "__main__":
    main()
