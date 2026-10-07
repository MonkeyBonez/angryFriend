# faceeval — face-matching accuracy harness

Measures, on the local (gitignored) photo sets `PhotosOfFriends/<person>/` and
`PhotosOfRandoms/<person>/`, how well a model / alignment / matching rule tells the
friends apart from each other and from strangers. Everything runs locally; outputs
(chips, embeddings, contact sheets, `results.md`) go to `scripts/faceeval/out/`, which
is gitignored because the chips are faces.

Needs: `insightface`, `onnxruntime`, `coremltools`, `opencv-python`, `scipy`, `Pillow`,
and the insightface packs `buffalo_sc`, `buffalo_l`, `antelopev2` under `~/.insightface/models/`
(antelopev2.zip unpacks into a nested folder — flatten it).

```
python3 scripts/faceeval/extract.py           # SCRFD faces at the app's 1024px size, 2-pt/5-pt chips, embeddings (~12 min)
python3 scripts/faceeval/dump_work_images.py  # the same 1024px images for the Vision tool
swiftc -O -framework Vision -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers \
    scripts/faceeval/visionchips.swift -o scripts/faceeval/out/visionchips
scripts/faceeval/out/visionchips scripts/faceeval/out/vision_chips scripts/faceeval/out/work/*.jpg > scripts/faceeval/out/vision_faces.jsonl
cp scripts/faceeval/out/vision_faces.jsonl scripts/faceeval/out/vision_faces5.jsonl   # same run also carries the landmarks
python3 scripts/faceeval/vision_embed.py      # the app's exact 2-pt chips, embedded
python3 scripts/faceeval/vision5_embed.py     # 5-pt chips from Vision's own landmarks
python3 scripts/faceeval/analyze.py           # labels faces, prints/saves results.md
```

`analyze.py` sections: raw face-vs-face separability per model; the app protocol (friends
created from 10 picked photos, everything else scanned) for today's rule vs mean template /
exclusive assignment / margin / size gate, with a threshold sweep; mix-ups by face size;
identity contamination at creation; template growth. Keys: `app` = the shipped CoreML model (ResNet50 since 2026-10-07),
`mbf`/`r50`/`r100` = MobileFaceNet / ResNet50 / ResNet100 via ONNX; `_vis2pt` = the app's Vision 2-pt alignment,
`_vis5a` = 5-pt from Vision landmarks, `_5pt` = reference SCRFD 5-pt.
