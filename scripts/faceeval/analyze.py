#!/usr/bin/env python3
"""Stage 2: label faces per person, then measure how well each model / template
strategy / assignment rule separates the three friends from each other and from strangers."""
import json, sys, random
from pathlib import Path
import numpy as np
from scipy.cluster.hierarchy import linkage, fcluster
from PIL import Image

OUT = Path(__file__).resolve().parent / "out"; OUT.mkdir(exist_ok=True)
APP_THR = 0.27
LABEL_KEY = "r100_5pt"          # strongest model labels the faces
rng = random.Random(7)

meta = json.loads((OUT / "faces.json").read_text())
PEOPLE = sorted({m["person"] for m in meta})
E = dict(np.load(OUT / "embeddings.npz"))
N = len(meta)
for k in E: assert len(E[k]) == N, (k, len(E[k]), N)
sets = np.array([m["set"] for m in meta]); folder = np.array([m["person"] for m in meta])
files = np.array([m["file"] for m in meta]); face_w = np.array([m["face_w"] for m in meta])
blur = np.array([m["blur"] for m in meta]); yaw = np.array([abs(m["yaw"]) for m in meta])

# ---------- Vision-aligned embeddings (the app's exact chip path), matched to SCRFD faces by IoU ----------
vis_mask = np.zeros(N, bool); vis_quality = np.full(N, np.nan); vis_detected = 0
vp = OUT / "vision_embeddings.npz"
if vp.exists():
    VE = dict(np.load(vp)); vfaces = json.loads((OUT / "vision_faces_kept.json").read_text())
    by_file = {}
    for k, f in enumerate(vfaces): by_file.setdefault(f["file"][:-4], []).append(k)
    for key in VE: E[f"{key}_vis2pt"] = np.zeros((N, 512), np.float32)
    V5 = dict(np.load(OUT / "vision5_embeddings.npz")) if (OUT / "vision5_embeddings.npz").exists() else {}
    for key in V5:
        if not key.startswith("have_"): E[key] = np.zeros((N, 512), np.float32)
    def iou(a, b):
        ix = max(0, min(a[2], b[2]) - max(a[0], b[0])); iy = max(0, min(a[3], b[3]) - max(a[1], b[1])); inter = ix * iy
        return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter + 1e-9)
    for i, m in enumerate(meta):
        base = f"{m['set']}_{m['person']}_{Path(m['file']).stem}"
        best, bi = 0.4, None
        for k in by_file.get(base, []):
            f = vfaces[k]; v = iou((m["x1"], m["y1"], m["x2"], m["y2"]), (f["x1"], f["y1"], f["x2"], f["y2"]))
            if v > best: best, bi = v, k
        if bi is not None:
            vis_mask[i] = True; vis_quality[i] = vfaces[bi]["quality"]
            for key in VE: E[f"{key}_vis2pt"][i] = VE[key][bi]
            for key in V5:
                if not key.startswith("have_"): E[key][i] = V5[key][bi]
    vis_detected = len(vfaces)

# ---------- A. label faces with the strongest model ----------
X = E[LABEL_KEY]
label = np.array(["unknown"] * N, dtype=object)
centroid = {}
for p in PEOPLE:
    idx = np.where((sets == "friend") & (folder == p))[0]
    Z = linkage(X[idx], method="average", metric="cosine")
    cl = fcluster(Z, t=0.62, criterion="distance")          # avg cosine sim >= 0.38 within a cluster
    best, best_photos = None, -1
    for c in np.unique(cl):
        members = idx[cl == c]
        n_photos = len(set(files[members]))
        if n_photos > best_photos: best, best_photos = members, n_photos
    label[best] = p
    c = X[best].mean(0); centroid[p] = c / np.linalg.norm(c)
# second pass: pull in hard faces of the same person (own folder) and spot friends in other folders
sim_to = np.stack([X @ centroid[p] for p in PEOPLE], 1)   # N x 3
for i in range(N):
    if label[i] != "unknown": continue
    j = int(sim_to[i].argmax()); s = sim_to[i, j]; p = PEOPLE[j]
    if sets[i] == "friend" and folder[i] == p and s >= 0.30: label[i] = p
    elif s >= 0.45: label[i] = p
    elif sim_to[i].max() < 0.20: label[i] = "stranger"
    else: label[i] = "ambiguous"                              # too close to call: kept out of the metrics
counts = {p: int((label == p).sum()) for p in PEOPLE}
counts.update(stranger=int((label == "stranger").sum()), ambiguous=int((label == "ambiguous").sum()))
cross = [(meta[i]["stem"], label[i]) for i in range(N) if label[i] in PEOPLE and not (sets[i] == "friend" and folder[i] == label[i])]

def sheet(stems, name, cols=12):
    stems = list(stems)[: cols * 6]
    if not stems: return
    im = Image.new("RGB", (cols * 112, ((len(stems) + cols - 1) // cols) * 112), "black")
    for k, s in enumerate(stems):
        try: im.paste(Image.open(OUT / "chips" / f"{s}.jpg"), ((k % cols) * 112, (k // cols) * 112))
        except Exception: pass
    im.save(OUT / f"sheet_{name}.jpg", quality=85)
for p in PEOPLE:
    own = [meta[i]["stem"] for i in range(N) if label[i] == p]; rng.shuffle(own); sheet(own, p)
    sheet([meta[i]["stem"] for i in range(N) if sets[i] == "friend" and folder[i] == p and label[i] != p], f"notP_{p}")
sheet([s for s, _ in cross], "crosslabel")
sheet([meta[i]["stem"] for i in range(N) if label[i] == "ambiguous"], "ambiguous")

# ---------- B. metrics ----------
def pct(x): return f"{100 * x:5.1f}%"

def pairwise(key):
    """Face-vs-face similarities: genuine (same friend) and impostor (friend A face vs friend B face)."""
    V = E[key]; rows = []
    ok = vis_mask if "_vis" in key else np.ones(N, bool)
    lab = np.where(ok, label, "skip")
    for p in PEOPLE:
        a = V[lab == p]; g = a @ a.T; g = g[np.triu_indices(len(a), 1)]
        rows.append(f"  {p:7s} genuine: mean {g.mean():.3f}  p5 {np.percentile(g, 5):.3f}  <{APP_THR}: {pct((g < APP_THR).mean())}")
    for i, p in enumerate(PEOPLE):
        for q in PEOPLE[i + 1:]:
            s = (V[lab == p] @ V[lab == q].T).ravel()
            rows.append(f"  {p:7s}×{q:7s} impostor: mean {s.mean():.3f}  p99 {np.percentile(s, 99):.3f}  max {s.max():.3f}  ≥{APP_THR}: {pct((s >= APP_THR).mean())}")
    st = V[lab == "stranger"]
    for p in PEOPLE:
        s = (V[lab == p] @ st.T).ravel()
        rows.append(f"  {p:7s}×stranger: p99 {np.percentile(s, 99):.3f}  max {s.max():.3f}  ≥{APP_THR}: {pct((s >= APP_THR).mean())}")
    return "\n".join(rows)

def template(V, idx, strategy):
    if strategy == "first3":  idx = idx[:3]
    if strategy == "mean":
        c = V[idx].mean(0); return ("mean", c / np.linalg.norm(c))
    return ("max", V[idx])

def score(V, tmpl):
    kind, T = tmpl
    return V @ T if kind == "mean" else (V @ T.T).max(1)

def simulate(key, strategy, K=10, trials=40, min_face=0, exclusive=False, margin=0.0, thrs=(APP_THR,)):
    """App protocol: each friend is created from K picked photos; every other labelled face is then
    scanned. Returns per-threshold mean counts over trials."""
    V = E[key]; res = {t: dict(recall=[], confusion=0.0, fp=0.0, n_pos=0) for t in thrs}
    ok = vis_mask if "_vis" in key else np.ones(N, bool)
    for _ in range(trials):
        picked_files, tmpls = set(), {}
        for p in PEOPLE:
            own = np.where(label == p)[0]
            photos = sorted(set(files[own])); rng.shuffle(photos); pick = set(photos[:K]); picked_files |= pick
            idx = [i for i in own if files[i] in pick and ok[i]]; rng.shuffle(idx)
            if not idx: idx = [i for i in own if ok[i]][:3]
            tmpls[p] = template(V, np.array(idx), strategy)
        ev = np.array([i for i in range(N) if ok[i] and files[i] not in picked_files and label[i] not in ("ambiguous", "unknown") and face_w[i] >= min_face])
        S = np.stack([score(V[ev], tmpls[p]) for p in PEOPLE], 1)     # faces x friends
        top = S.argmax(1); srt = np.sort(S, 1); mg = srt[:, -1] - srt[:, -2]
        for t in thrs:
            if exclusive:
                A = np.zeros_like(S, bool); acc = (srt[:, -1] >= t) & (mg >= margin); A[np.arange(len(ev)), top] = acc
            else:
                A = S >= t
            lab = label[ev]
            for j, p in enumerate(PEOPLE):
                pos = lab == p
                res[t]["recall"].append(A[pos, j].mean())
                res[t]["confusion"] += A[np.isin(lab, [q for q in PEOPLE if q != p]), j].sum() / trials
            res[t]["fp"] += A[lab == "stranger"].any(1).sum() / trials
            res[t]["n_pos"] = int(np.isin(lab, PEOPLE).sum())
    return {t: dict(recall=float(np.mean(r["recall"])), confusion=r["confusion"], fp=r["fp"], n_pos=r["n_pos"]) for t, r in res.items()}

def fmt(r): return f"recall {pct(r['recall'])}  friend→friend mix-ups {r['confusion']:5.1f}  stranger FPs {r['fp']:5.1f}"

report = []
P = report.append
P(f"# Face-matching evaluation on the local test sets\n")
P(f"{N} faces detected in {len(set(files))} photos. Labels (by {LABEL_KEY}): {counts}")
P(f"Friends spotted in other people's folders: {len(cross)} faces (see sheet_crosslabel.jpg)\n")
agree = (E["mbfcoreml_2pt"] * E["mbf_2pt"]).sum(1)
P(f"CoreML vs ONNX MobileFaceNet agreement on the same chip: mean cos {agree.mean():.4f}, min {agree.min():.4f}\n")

P("## 1. Raw separability, face vs face (no templates)\n")
if vis_mask.any():
    P(f"Vision found {vis_detected} faces vs SCRFD {N}; {vis_mask.sum()} SCRFD faces have a Vision match (IoU>0.4). "
      f"Labelled friend faces with a Vision match: {pct(vis_mask[np.isin(label, PEOPLE)].mean())}; "
      f"of friend faces ≥60px wide: {pct(vis_mask[np.isin(label, PEOPLE) & (face_w >= 60)].mean())}\n")
keys1 = ["mbfcoreml_vis2pt", "mbfcoreml_vis5a", "mbfcoreml_vis5b", "mbfcoreml_2pt", "mbf_5pt", "r50_vis2pt", "r50_vis5a", "r50_vis5b", "r50_2pt", "r50_5pt", "r100_vis2pt", "r100_2pt", "r100_5pt"]
for key in keys1:
    if key in E: P(f"### {key}\n{pairwise(key)}\n")

P("## 2. App protocol (3 friends created from 10 picked photos each, then everything else scanned)\n")
P("Counts are means over 40 random picks. 'mix-ups' = faces of one friend added to another friend's album.\n")
for key in [k for k in ["mbfcoreml_vis2pt", "mbfcoreml_vis5a", "mbfcoreml_vis5b", "r50_vis2pt", "r50_vis5a", "r50_vis5b", "r50_5pt", "r100_5pt"] if k in E]:
    P(f"### {key}")
    for strat in ["first3", "max", "mean"]:
        r = simulate(key, strat)[APP_THR]
        P(f"  template={strat:6s} thr={APP_THR}  non-exclusive (today's rule): {fmt(r)}")
    r = simulate(key, "mean", exclusive=True, margin=0.0)[APP_THR]
    P(f"  template=mean   thr={APP_THR}  exclusive, no margin           : {fmt(r)}")
    r = simulate(key, "mean", exclusive=True, margin=0.05)[APP_THR]
    P(f"  template=mean   thr={APP_THR}  exclusive, margin 0.05         : {fmt(r)}")
    r = simulate(key, "mean", exclusive=True, margin=0.05, min_face=48)[APP_THR]
    P(f"  template=mean   thr={APP_THR}  exclusive, margin 0.05, faces ≥48px: {fmt(r)}")
    thrs = tuple(np.round(np.arange(0.20, 0.61, 0.02), 2))
    sweep = simulate(key, "mean", exclusive=True, margin=0.05, thrs=thrs)
    clean = [t for t in thrs if sweep[t]["confusion"] <= 0.5 and sweep[t]["fp"] <= 1.0]
    if clean:
        t = min(clean); P(f"  → lowest thr with ≤0.5 mix-ups and ≤1 stranger FP: {t}  ({fmt(sweep[t])})")
    P(f"  sweep (mean/exclusive/margin .05): " + "  ".join(f"{t}:{pct(sweep[t]['recall']).strip()}/{sweep[t]['confusion']:.0f}/{sweep[t]['fp']:.0f}" for t in thrs[::2]))
    P("")

P("## 3. Where do the mix-ups come from? (today's pipeline: mbfcoreml_2pt, first3, non-exclusive)\n")
V = E["mbfcoreml_vis2pt"] if vis_mask.any() else E["mbfcoreml_2pt"]
bins = [(0, 40), (40, 60), (60, 100), (100, 10000)]
for lo, hi in bins:
    sel = (face_w >= lo) & (face_w < hi) & np.isin(label, PEOPLE)
    if sel.sum() == 0: continue
    mix = 0; tot = 0
    for p in PEOPLE:
        others = V[sel & (label != p) & np.isin(label, PEOPLE)]; own = V[label == p]
        mix += ((others @ own.T).max(1) >= APP_THR).sum(); tot += len(others)
    P(f"  face width {lo:4d}–{hi:<5d}px: {sel.sum():4d} friend faces, {pct(mix / max(tot, 1))} would match some OTHER friend's best face")
(OUT / "results.md").write_text("\n".join(report))
print("\n".join(report))

# ---------- 4. identity contamination at creation ----------
def discovery_sim(key, K=10, trials=60, link="max"):
    """Replays discoverFriendIdentity on K random photos from a friend's folder (group shots included):
    greedy clustering at 0.27, winner = cluster in the most photos, identity = first 3 members."""
    V = E[key]; ok = vis_mask if "_vis" in key else np.ones(N, bool)
    contaminated = first3_bad = wrong_winner = n = 0
    for p in PEOPLE:
        own_photos = sorted(set(files[(label == p) & ok]))
        for _ in range(trials // len(PEOPLE)):
            rng.shuffle(own_photos); pick = set(own_photos[:K])
            idx = [i for i in range(N) if ok[i] and files[i] in pick and sets[i] == "friend" and folder[i] == p]
            rng.shuffle(idx)                                   # worker completion order is arbitrary in the app
            clusters = []
            for i in idx:
                best, bs = None, APP_THR
                for c, members in enumerate(clusters):
                    if link == "max": sim = (V[members] @ V[i]).max()
                    else:
                        cen = V[members].mean(0); sim = (cen / np.linalg.norm(cen)) @ V[i]
                    if sim >= bs: best, bs = c, sim
                if best is None: clusters.append([i])
                else: clusters[best].append(i)
            winner = max(clusters, key=lambda m: (len(set(files[m])), len(m)))
            bad = np.isin(label[winner], [q for q in PEOPLE if q != p] + ["stranger"])
            n += 1; contaminated += bad.any(); first3_bad += bad[:3].any()
            wrong_winner += (label[winner] == p).mean() < 0.5
    return contaminated / n, first3_bad / n, wrong_winner / n

report.append("\n## 4. Friend creation: does the identity get another person's face in it?\n")
report.append("10 random photos from the friend's own folder (group shots included), app's clustering rule replayed 60×.\n")
for key in [k for k in ["mbfcoreml_vis2pt", "mbfcoreml_2pt", "r50_vis2pt", "r50_5pt", "r100_5pt"] if k in E]:
    for link in ["max", "centroid"]:
        c, f3, ww = discovery_sim(key, link=link)
        report.append(f"  {key:16s} link={link:8s}: winner cluster contains someone else {pct(c)}; one of the 3 stored identity faces is someone else {pct(f3)}; winner is mostly the wrong person {pct(ww)}")
(OUT / "results.md").write_text("\n".join(report))
print("\n".join(report[-12:]))

# ---------- 5. growing the template from confident auto-adds ----------
def growth_sim(key, K=10, trials=24, grow_thr=0.45, cap=24, margin=0.05, thr=APP_THR, mode="static"):
    """Online scan: faces arrive in random order; exclusive assignment with margin; in 'grow' mode a
    face matched with sim >= grow_thr is folded into that friend's template (mean of up to `cap` faces)."""
    V = E[key]; ok = vis_mask if "_vis" in key else np.ones(N, bool)
    recall, confusion, fp, npos = [], 0.0, 0.0, 0
    for _ in range(trials):
        picked, T = set(), {}
        for p in PEOPLE:
            own = np.where((label == p) & ok)[0]; photos = sorted(set(files[own])); rng.shuffle(photos); pick = set(photos[:K]); picked |= pick
            T[p] = [V[i] for i in own if files[i] in pick] or [V[i] for i in own[:3]]
        ev = [i for i in range(N) if ok[i] and files[i] not in picked and label[i] not in ("ambiguous", "unknown")]; rng.shuffle(ev)
        hits = {p: 0 for p in PEOPLE}; tot = {p: 0 for p in PEOPLE}
        for i in ev:
            cents = {p: (np.mean(T[p], 0) / np.linalg.norm(np.mean(T[p], 0))) for p in PEOPLE}
            s = np.array([cents[p] @ V[i] for p in PEOPLE]); o = np.argsort(s)[::-1]
            assigned = PEOPLE[o[0]] if s[o[0]] >= thr and s[o[0]] - s[o[1]] >= margin else None
            if label[i] in PEOPLE:
                tot[label[i]] += 1
                if assigned == label[i]: hits[label[i]] += 1
                elif assigned is not None: confusion += 1 / trials
            elif assigned is not None: fp += 1 / trials
            if mode == "grow" and assigned is not None and s[o[0]] >= grow_thr and len(T[assigned]) < cap:
                T[assigned].append(V[i])
        recall += [hits[p] / max(tot[p], 1) for p in PEOPLE]
    return dict(recall=float(np.mean(recall)), confusion=confusion, fp=fp)

report.append("\n## 5. Letting the identity grow from confident auto-adds (exclusive, margin 0.05, thr 0.27)\n")
for key in [k for k in ["mbfcoreml_vis2pt", "r50_vis2pt", "r50_5pt", "r100_5pt"] if k in E]:
    for mode, gt in [("static", 0), ("grow", 0.45), ("grow", 0.40)]:
        r = growth_sim(key, mode=mode, grow_thr=gt)
        report.append(f"  {key:16s} {mode:6s} grow≥{gt:.2f}: {fmt(r)}")
(OUT / "results.md").write_text("\n".join(report))
print("\n".join(report[-10:]))
