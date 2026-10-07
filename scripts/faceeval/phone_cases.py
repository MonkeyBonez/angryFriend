#!/usr/bin/env python3
"""Replays the app's matching rule on face chips pulled off the phone (test_data/phone_cases,
gitignored: chips/ + cases.tsv), embedding them with the shipped CoreML model.

- identity rows: the first 24 album photos per friend → the app's template (largest mean-linked
  group at the model's cluster bar, 10 most central faces, mean).
- wrong / wrong-unverified rows: must NOT be given to their album's friend.
- right rows: must stay with their album's friend.
- every other chip of a photo still in an album (album_now.tsv) is used as the "true photos lost" count.

Prints, per candidate rule, how many known problems it still lets through and how many current
album photos it would drop. See scripts/faceeval/README.md.
"""
import csv, sys
from pathlib import Path
import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parents[2]
D = REPO / "test_data" / "phone_cases"
MODEL = REPO / "angryFriend" / "FaceNetR50.mlpackage"
CLUSTER, MARGIN = 0.28, 0.05

def embed_all(paths):
    import coremltools as ct
    m = ct.models.MLModel(str(MODEL)); spec = m.get_spec()
    inp, out = spec.description.input[0].name, spec.description.output[0].name
    cache = D / "embeddings_r50.npz"
    have = dict(np.load(cache)) if cache.exists() else {}
    for p in paths:
        if p.stem in have: continue
        e = np.array(m.predict({inp: Image.open(p).convert("RGB")})[out]).flatten().astype(np.float32)
        have[p.stem] = e / np.linalg.norm(e)
    np.savez_compressed(cache, **have)
    return have

def group(faces, thr):
    groups = []
    for i, f in enumerate(faces):
        best, bs = None, thr
        for gi, g in enumerate(groups):
            m = np.mean([faces[j] for j in g], 0); m /= np.linalg.norm(m)
            if m @ f >= bs: best, bs = gi, m @ f
        if best is None: groups.append([i])
        else: groups[best].append(i)
    return groups

def template(faces):
    g = max(group(faces, CLUSTER), key=len)
    m = np.mean([faces[i] for i in g], 0); m /= np.linalg.norm(m)
    members = sorted(g, key=lambda i: -(m @ faces[i]))[:10]
    t = np.mean([faces[i] for i in members], 0)
    return t / np.linalg.norm(t), np.stack([faces[i] for i in members])

def main():
    cases = list(csv.DictReader(open(D / "cases.tsv"), delimiter="\t"))
    chips = sorted((D / "chips").glob("*.jpg"))
    E = embed_all(chips)
    key = lambda album, i: f"{album.replace(' ', '')}_{i}"
    friends = sorted({c["album"] for c in cases if c["kind"] == "identity"})
    T = {f: template([E[key(f, c["id"])] for c in cases if c["album"] == f and c["kind"] == "identity"]) for f in friends}
    special = {key(c["album"], c["id"]) for c in cases if c["kind"] != "identity"}
    album_of = {p.stem: next(f for f in friends if p.stem.startswith(f.replace(" ", "") + "_")) for p in chips}
    # current album photos (mostly right): chips of photos still in an album per album_now.tsv,
    # the phone's listing of every album (written by -compareModels as dates.tsv)
    now = {key(r["friend"], r["id"]) for r in csv.DictReader(open(D / "album_now.tsv"), delimiter="\t")} \
        if (D / "album_now.tsv").exists() else set(E)
    pool = [s for s in E if s not in special and s in now]

    def owner(e, thr, member_min=None, margin=MARGIN):
        sims = {f: float(T[f][0] @ e) for f in friends}
        top = sorted(sims, key=sims.get, reverse=True)
        f, s, s2 = top[0], sims[top[0]], sims[top[1]]
        if s < thr or s - s2 < margin: return None
        if member_min is not None and float((T[f][1] @ e).max()) < member_min: return None
        return f

    rules = [("today: 0.28", dict(thr=0.28))] + [(f"bar {t:.2f}", dict(thr=t)) for t in (0.30, 0.31, 0.32, 0.33, 0.34, 0.36)] + \
            [(f"0.28 + best stored face ≥ {m:.2f}", dict(thr=0.28, member_min=m)) for m in (0.30, 0.35, 0.40)] + \
            [(f"0.30 + best stored face ≥ {m:.2f}", dict(thr=0.30, member_min=m)) for m in (0.35,)]
    print(f"{len(E)} chips, friends {friends}; problem cases: " + ", ".join(f"{k} {sum(1 for c in cases if c['kind'] == k)}" for k in ("wrong", "wrong-unverified", "right")))
    print(f"{'rule':34s} {'confirmed wrong let in':>22s} {'unverified wrong let in':>24s} {'confirmed right lost':>21s} {'album photos lost':>18s}")
    for name, kw in rules:
        wrong = [c for c in cases if c["kind"] == "wrong" and owner(E[key(c["album"], c["id"])], **kw) == c["album"]]
        unv = [c for c in cases if c["kind"] == "wrong-unverified" and owner(E[key(c["album"], c["id"])], **kw) == c["album"]]
        right = [c for c in cases if c["kind"] == "right" and owner(E[key(c["album"], c["id"])], **kw) != c["album"]]
        lost = {f: 0 for f in friends}
        for s in pool:
            if owner(E[s], **kw) != album_of[s]: lost[album_of[s]] += 1
        base = {f: sum(1 for s in pool if album_of[s] == f) for f in friends}
        lost_txt = ", ".join(f"{f} {lost[f]}/{base[f]}" for f in friends)
        print(f"{name:34s} {len(wrong):>22d} {len(unv):>24d} {len(right):>21d}   {lost_txt}")
        if wrong and "--verbose" in sys.argv:
            for c in wrong: print(f"      let in: {c['album']} {c['id']} sim {T[c['album']][0] @ E[key(c['album'], c['id'])]:.3f} — {c['note'][:60]}")

def not_them_check():
    """"Not them": mark one confirmed-wrong face per album as a negative; how many of that album's
    other confirmed-wrong faces does it also turn away, and how many current album photos?"""
    cases = list(csv.DictReader(open(D / "cases.tsv"), delimiter="\t"))
    E = dict(np.load(D / "embeddings_r50.npz"))
    key = lambda album, i: f"{album.replace(' ', '')}_{i}"
    friends = sorted({c["album"] for c in cases if c["kind"] == "identity"})
    T = {f: template([E[key(f, c["id"])] for c in cases if c["album"] == f and c["kind"] == "identity"]) for f in friends}
    special = {key(c["album"], c["id"]) for c in cases if c["kind"] != "identity"}
    now = {key(r["friend"], r["id"]) for r in csv.DictReader(open(D / "album_now.tsv"), delimiter="\t")} if (D / "album_now.tsv").exists() else set(E)
    print("\n\"Not them\": one wrong face marked → others turned away / album photos turned away")
    for album in friends:
        wrong = [c for c in cases if c["album"] == album and c["kind"] == "wrong"]
        if not wrong: continue
        pool = [E[s] for s in E if s.startswith(album.replace(" ", "") + "_") and s in now and s not in special]
        t = T[album][0]
        for c in wrong:
            n = E[key(album, c["id"])]
            others = [E[key(album, o["id"])] for o in wrong if o is not c]
            caught = sum(1 for o in others if n @ o > t @ o)
            lost = sum(1 for p in pool if n @ p > t @ p)
            print(f"  {album} mark {c['id']}: turns away {caught}/{len(others)} other wrong, {lost}/{len(pool)} album photos")

if __name__ == "__main__":
    main()
    not_them_check()
