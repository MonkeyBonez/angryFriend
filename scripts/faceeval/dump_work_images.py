#!/usr/bin/env python3
"""Write the EXIF-normalised 1024px working images (what the app's Vision pass sees) so the
macOS Vision tool and the SCRFD run see identical pixels."""
import sys
from pathlib import Path
import cv2
REPO = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent / "out" / "work"; OUT.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(REPO / "scripts"))
from test_coreml_pipeline import load_images  # noqa
from extract import SETS, fit1024  # noqa
for setname, person, folder in SETS:
    for path, img in load_images(str(folder)):
        cv2.imwrite(str(OUT / f"{setname}_{person}_{Path(path).stem}.jpg"), fit1024(img), [cv2.IMWRITE_JPEG_QUALITY, 95])
print("ok", len(list(OUT.iterdir())))
