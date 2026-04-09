#!/usr/bin/env python3
"""
Convert a MobileFaceNet ONNX model to CoreML (.mlpackage) for use in angryFriend.

Usage:
    pip3 install coremltools onnx onnx2pytorch
    python3 scripts/convert_face_model.py path/to/model.onnx

Or use the insightface buffalo_sc model (auto-downloads):
    pip3 install insightface onnxruntime coremltools onnx onnx2pytorch
    python3 scripts/convert_face_model.py --insightface

Output: angryFriend/MobileFaceNet.mlpackage
Then drag it into Xcode and verify target membership.
"""

import sys
import os
import argparse

def convert_onnx(onnx_path: str, output_path: str):
    import onnx
    import coremltools as ct
    import numpy as np

    try:
        from onnx2pytorch import ConvertModel
        import torch

        print(f"Loading ONNX model from {onnx_path}...")
        onnx_model = onnx.load(onnx_path)

        print("Converting ONNX → PyTorch...")
        pytorch_model = ConvertModel(onnx_model)
        pytorch_model.eval()

        print("Tracing PyTorch model...")
        example_input = torch.randn(1, 3, 112, 112)
        traced_model = torch.jit.trace(pytorch_model, example_input)

        print("Converting PyTorch → CoreML...")
        cml_model = ct.convert(
            traced_model,
            inputs=[ct.ImageType(
                name="input.1",
                shape=(1, 3, 112, 112),
                scale=1/127.5,
                bias=[-1, -1, -1],
                color_layout=ct.colorlayout.RGB
            )],
            compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.iOS17,
        )

    except ImportError:
        print("onnx2pytorch not found, trying direct coremltools ONNX conversion...")
        import coremltools as ct
        onnx_model = onnx.load(onnx_path)
        cml_model = ct.convert(
            onnx_model,
            source="onnx",
            inputs=[ct.ImageType(
                name="input.1",
                shape=(1, 3, 112, 112),
                scale=1/127.5,
                bias=[-1, -1, -1],
                color_layout=ct.colorlayout.RGB
            )],
            compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.iOS17,
        )

    print(f"Saving to {output_path}...")
    cml_model.save(output_path)
    print("Done!")


def download_insightface_model():
    from insightface.app import FaceAnalysis
    print("Downloading buffalo_sc model via insightface...")
    app = FaceAnalysis(name="buffalo_sc", providers=["CPUExecutionProvider"])
    app.prepare(ctx_id=-1, det_size=(640, 640))
    model_path = os.path.expanduser("~/.insightface/models/buffalo_sc/w600k_mbf.onnx")
    print(f"Model at: {model_path}")
    return model_path


def main():
    parser = argparse.ArgumentParser(description="Convert face recognition ONNX model to CoreML")
    parser.add_argument("onnx_path", nargs="?", help="Path to ONNX model (112x112 input, embedding output)")
    parser.add_argument("--insightface", action="store_true", help="Auto-download buffalo_sc from insightface")
    parser.add_argument("--output", default=None, help="Output .mlpackage path")
    args = parser.parse_args()

    # Determine project root (scripts/ is one level below project root)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    default_output = os.path.join(project_root, "angryFriend", "MobileFaceNet.mlpackage")
    output_path = args.output or default_output

    if args.insightface:
        onnx_path = download_insightface_model()
    elif args.onnx_path:
        onnx_path = args.onnx_path
    else:
        parser.print_help()
        sys.exit(1)

    convert_onnx(onnx_path, output_path)
    print(f"\nNext steps:")
    print(f"  1. Open angryFriend.xcodeproj in Xcode")
    print(f"  2. Verify MobileFaceNet.mlpackage has target membership (check the project navigator)")
    print(f"  3. Build and run")


if __name__ == "__main__":
    main()
